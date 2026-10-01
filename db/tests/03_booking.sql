-- slots, two-step changes (propose -> confirm), double booking, reschedule, cancel
do $$
declare
  t1      uuid := pg_temp.tenant('t1');
  r       jsonb;
  r2      jsonb;
  conv    uuid;
  conv2   uuid;
  client  uuid;
  client2 uuid;
  res     jsonb;
  p       jsonb;
  ctx     jsonb;
  fin     jsonb;
  appt    uuid;
  day     text := to_char((now() at time zone 'Europe/Kyiv')::date + 1, 'YYYY-MM-DD');
  pid     uuid;
begin
  r := pg_temp.say('u1', 'I want a cleaning');
  conv := (r ->> 'conversation_id')::uuid;
  client := (r ->> 'client_id')::uuid;

  res := find_slots(t1, 'cleaning', 'center');
  assert (res ->> 'ok')::boolean and res ->> 'result' like 'Free start times for Cleaning (60 min, 1500 UAH) at Center%', res::text;
  assert res ->> 'result' like '%dr-a%';
  res := find_slots(t1, 'cleaning', 'center', null, day, day);
  assert res ->> 'result' like '%' || day || '%', 'date filter';
  assert array_length(regexp_split_to_array(split_part(split_part(res ->> 'result', E'\n', 2), ': ', 2), ', '), 1) <= 8,
    'at most 8 times per day';
  res := find_slots(t1, 'whitening', 'center');
  assert not (res ->> 'ok')::boolean and res ->> 'error' like '%Known services: cleaning, consult.%', res::text;
  res := find_slots(t1, 'cleaning', 'podil');
  assert res ->> 'result' like 'No free time%', 'nobody does cleaning at podil';
  res := find_slots(t1, 'cleaning', 'center', 'dr-b');
  assert res ->> 'error' like 'Dr B does not provide Cleaning%', res::text;
  res := find_slots(t1, 'cleaning', 'center', null, 'someday');
  assert res ->> 'error' like 'Dates must be%';

  p := propose_action(t1, conv, 'book', jsonb_build_object('service', 'cleaning', 'branch', 'center', 'start', day || ' 10:00'));
  assert not (p ->> 'ok')::boolean and p ->> 'error' like 'Missing client name or phone%', p::text;
  assert not (save_client_info(t1, client, null, '123') ->> 'ok')::boolean, 'invalid phone rejected';
  res := save_client_info(t1, client, 'Ivan Petrenko', '050 123 45 67');
  assert (res ->> 'ok')::boolean;
  assert (select phone from clients where id = client) = '+380501234567';

  p := propose_action(t1, conv, 'book', jsonb_build_object('service', 'cleaning', 'branch', 'center', 'start', day || ' 10:10'));
  assert p ->> 'error' like '%is not a free slot%', 'off-grid time is not a slot';
  p := propose_action(t1, conv, 'book', jsonb_build_object('service', 'cleaning', 'branch', 'center', 'start', 'soon'));
  assert p ->> 'error' like 'start must be%';

  -- the proposing turn gets Confirm / Cancel buttons
  perform pg_temp.say('u1', 'tomorrow 10:00 please');
  ctx := begin_turn(conv, 'exec-b1');
  p := propose_action(t1, conv, 'book', jsonb_build_object('service', 'cleaning', 'branch', 'center',
                                                           'start', day || ' 10:00', 'reason', 'check-up'));
  assert (p ->> 'ok')::boolean, p::text;
  pid := (p ->> 'pending_id')::uuid;
  assert (select payload ->> 'doctor_id' from pending_actions where id = pid) =
         (select id::text from doctors where tenant_id = t1 and slug = 'dr-a'), 'doctor picked from the free slot';
  assert client_prompt(client, conv) like '%Open proposal%Book Cleaning%', 'the next turn sees the proposal';
  fin := finish_turn(conv, 'exec-b1', pg_temp.ids(ctx), 'Please confirm', true, '[]', 'exec-b1',
                     (ctx ->> 'turn_started_at')::timestamptz);
  assert (select payload -> 'buttons' -> 0 -> 0 ->> 'data' from messages where id = (fin ->> 'out_message_id')::bigint)
         = 'pa:' || pid || ':y', 'confirm button carries the pending id';

  -- button confirm
  res := resolve_pending(t1, conv, pid, 'y');
  assert (res ->> 'ok')::boolean and res ->> 'kind' = 'book', res::text;
  assert res ->> 'reply' like '✅ Booked: Cleaning with Dr A, Center (1 Main St), % 10:00. See you!', res ->> 'reply';
  appt := (res ->> 'appointment_id')::uuid;
  assert (select status from appointments where id = appt) = 'booked';
  assert (select reason from appointments where id = appt) = 'check-up';
  assert (select gcal_synced_at from appointments where id = appt) is null, 'calendar mirror is pending';
  res := resolve_pending(t1, conv, pid, 'y');
  assert (res ->> 'already')::boolean, 'double click returns the first result';
  assert (select count(*) from appointments where client_id = client) = 1, 'no second appointment';
  assert client_prompt(client, conv) like '%A1: % 10:00, Cleaning, Dr A, Center%', client_prompt(client, conv);

  -- another client: the taken slot is not offered, and a stale proposal hits the exclusion constraint
  r2 := pg_temp.say('u2', 'hi');
  conv2 := (r2 ->> 'conversation_id')::uuid;
  client2 := (r2 ->> 'client_id')::uuid;
  perform save_client_info(t1, client2, 'Olga', '0671112233');
  p := propose_action(t1, conv2, 'book', jsonb_build_object('service', 'cleaning', 'branch', 'center', 'start', day || ' 10:00'));
  assert p ->> 'error' like '%is not a free slot%', 'taken slot is not free';
  insert into pending_actions (tenant_id, conversation_id, kind, payload, summary)
  select t1, conv2, 'book', payload, summary from pending_actions where id = pid
  returning id into pid;
  res := confirm_action(t1, pid);
  assert res ->> 'error' = 'slot_taken', res::text;
  assert (select status from pending_actions where id = pid) = 'failed';
  begin
    insert into appointments (tenant_id, client_id, doctor_id, branch_id, service_id, period)
    select tenant_id, client2, doctor_id, branch_id, service_id, period from appointments where id = appt;
    raise exception 'double booking must be impossible';
  exception when exclusion_violation then null;
  end;

  -- reschedule re-arms reminders and the calendar mirror
  update appointments set reminder_24h_sent_at = now(), gcal_synced_at = now() where id = appt;
  p := propose_action(t1, conv, 'reschedule', jsonb_build_object('appointment', 'a1', 'start', day || ' 12:00'));
  assert (p ->> 'ok')::boolean, p::text;
  res := confirm_action(t1, (p ->> 'pending_id')::uuid);
  assert res ->> 'kind' = 'reschedule' and res ->> 'reply' like '✅ Moved:%12:00.', res::text;
  assert (select reminder_24h_sent_at is null and gcal_synced_at is null from appointments where id = appt), 'marks reset';
  p := propose_action(t1, conv, 'reschedule', jsonb_build_object('appointment', 'A7', 'start', day || ' 12:00'));
  assert p ->> 'error' like 'No upcoming appointment "A7"%';

  -- words-confirm only for proposals made before the current turn
  p := propose_action(t1, conv, 'cancel', jsonb_build_object('appointment', 'A1'));
  assert (p ->> 'ok')::boolean, p::text;
  res := confirm_open_action(t1, conv, now());
  assert not (res ->> 'ok')::boolean, 'a proposal of this very turn cannot be confirmed by the model';
  -- a "yes" the client sent before the proposal was shown answers something else
  r := pg_temp.say('u1', 'yes');
  update messages set created_at = now() - interval '5 seconds' where id = (r ->> 'message_id')::bigint;
  res := confirm_open_action(t1, conv, now() + interval '1 second');
  assert not (res ->> 'ok')::boolean, 'a yes older than the proposal does not confirm it';
  update messages set created_at = now() + interval '1 second' where id = (r ->> 'message_id')::bigint;
  res := confirm_open_action(t1, conv, now() + interval '1 second');
  assert res ->> 'kind' = 'cancel', res::text;
  assert (select status from appointments where id = appt) = 'cancelled';

  -- reject and expiry
  p := propose_action(t1, conv, 'book', jsonb_build_object('service', 'consult', 'branch', 'podil', 'start', day || ' 15:00'));
  assert (p ->> 'ok')::boolean, p::text;
  res := resolve_pending(t1, conv, (p ->> 'pending_id')::uuid, 'n');
  assert res ->> 'kind' = 'rejected';
  assert resolve_pending(t1, conv, (p ->> 'pending_id')::uuid, 'y') ->> 'error' = 'rejected';
  p := propose_action(t1, conv, 'book', jsonb_build_object('service', 'consult', 'branch', 'podil', 'start', day || ' 15:00'));
  update pending_actions set expires_at = now() - interval '1 minute' where id = (p ->> 'pending_id')::uuid;
  assert confirm_action(t1, (p ->> 'pending_id')::uuid) ->> 'error' = 'expired';
  p := propose_action(t1, conv, 'book', jsonb_build_object('service', 'consult', 'branch', 'podil', 'start', day || ' 15:00'));
  perform propose_action(t1, conv, 'book', jsonb_build_object('service', 'consult', 'branch', 'podil', 'start', day || ' 15:30'));
  assert (select status from pending_actions where id = (p ->> 'pending_id')::uuid) = 'expired', 'a new proposal replaces the old one';

  -- reminder buttons
  p := propose_action(t1, conv, 'book', jsonb_build_object('service', 'consult', 'branch', 'podil', 'start', day || ' 16:00'));
  appt := (confirm_action(t1, (p ->> 'pending_id')::uuid) ->> 'appointment_id')::uuid;
  res := appointment_action(t1, conv, appt, 'c');
  assert res ->> 'kind' = 'attend' and (select confirmed_at is not null from appointments where id = appt);
  res := appointment_action(t1, conv, appt, 'x');
  assert res ->> 'kind' = 'cancel_ask' and res ->> 'reply' like 'Cancel your visit: Consultation, %16:00?', res::text;
  assert (select kind from pending_actions where id = (res ->> 'pending_id')::uuid) = 'cancel';
  assert (select status from appointments where id = appt) = 'booked', 'cancel from a reminder still needs confirmation';
  res := appointment_action(t1, conv2, appt, 'c');
  assert res ->> 'error' = 'not_found', 'another client cannot touch the appointment';
end $$;
