-- P1: glue by phone, visit follow-ups, reviews, reactivation
do $$
declare
  t1    uuid := pg_temp.tenant('t1');
  tg    jsonb := pg_temp.say('tg-user', 'hello');
  web   jsonb := pg_temp.say('web-visitor', 'hi from the site', 't1-widget');
  res   jsonb;
  p     jsonb;
  appt  uuid;
  day   text := to_char((now() at time zone 'Europe/Kyiv')::date + 1, 'YYYY-MM-DD');
begin
  perform save_client_info(t1, (tg ->> 'client_id')::uuid, 'Ivan', '+380501112233');
  p := propose_action(t1, (tg ->> 'conversation_id')::uuid, 'book',
                      jsonb_build_object('service', 'cleaning', 'branch', 'center', 'start', day || ' 11:00'));
  appt := (confirm_action(t1, (p ->> 'pending_id')::uuid) ->> 'appointment_id')::uuid;

  -- the web visitor types the same phone: it proves nothing, so the profiles stay apart (C-01)
  res := save_client_info(t1, (web ->> 'client_id')::uuid, null, '050 111 22 33');
  assert (res ->> 'ok')::boolean and res ->> 'merged_into' is null and res ->> 'result' = 'Saved.', res::text;
  assert (select client_id from client_identities where external_user_id = 'web-visitor')::text = web ->> 'client_id';
  assert (select merged_into from clients where id = (web ->> 'client_id')::uuid) is null;
  assert (select phone from clients where id = (web ->> 'client_id')::uuid) = '+380501112233', 'kept on the visitor profile';
  assert client_prompt((web ->> 'client_id')::uuid, (web ->> 'conversation_id')::uuid) not like '%Cleaning%', 'no foreign appointments';
  assert (select last_identity_id from conversations where id = (tg ->> 'conversation_id')::uuid) =
         (select id from client_identities where external_user_id = 'tg-user'), 'replies still go to Telegram';
  res := escalate((web ->> 'conversation_id')::uuid, null, 'user_request', 'test-key');
  assert (res ->> 'possible_duplicate')::boolean, 'the operator card flags the duplicate';

  -- a Telegram contact shared by someone else does not verify; the client's own contact does
  res := ingest_message(pg_temp.account('t1-bot'), 'tg-user', 'tg-user', 'contact-1', 'My phone: +380501112233',
                        '{"contact": {"phone_number": "+380501112233", "user_id": "someone-else"}}', '{}');
  assert not (select phone_verified from clients where id = (tg ->> 'client_id')::uuid);
  res := ingest_message(pg_temp.account('t1-bot'), 'tg-user', 'tg-user', 'contact-2', 'My phone: +380501112233',
                        '{"contact": {"phone_number": "380501112233", "user_id": "tg-user"}}', '{}');
  assert (select phone_verified from clients where id = (tg ->> 'client_id')::uuid), 'own contact verifies';

  -- WhatsApp proves its number: the same person writing there joins the verified profile
  insert into channel_accounts (tenant_id, channel, external_id) values (t1, 'whatsapp', 't1-wa');
  res := ingest_message(pg_temp.account('t1-wa'), '380501112233', '380501112233', 'wamid-1', 'hi from WhatsApp', '{}', '{}');
  assert res ->> 'client_id' = tg ->> 'client_id' and res ->> 'conversation_id' = tg ->> 'conversation_id', res::text;
  assert (select last_identity_id from conversations where id = (tg ->> 'conversation_id')::uuid) =
         (select id from client_identities where external_user_id = '380501112233'), 'replies go where the client wrote last';
  assert (conversation_client((tg ->> 'conversation_id')::uuid)).id::text = tg ->> 'client_id';
  assert client_prompt((tg ->> 'client_id')::uuid, (tg ->> 'conversation_id')::uuid) like '%A1:%Cleaning%';
  -- another WhatsApp number stays a separate client
  res := ingest_message(pg_temp.account('t1-wa'), '380509998877', '380509998877', 'wamid-2', 'hello', '{}', '{}');
  assert res ->> 'client_id' <> tg ->> 'client_id' and (select phone_verified from clients where id = (res ->> 'client_id')::uuid);

  -- visit happened: auto-complete, then a review request with 5 buttons
  update appointments set period = tstzrange(now() - interval '5 hours', now() - interval '4 hours') where id = appt;
  assert complete_past_appointments() = 1;
  assert (select status from appointments where id = appt) = 'done';
  res := claim_followups();
  assert jsonb_array_length(res) = 1 and res -> 0 ->> 'kind' = 'done', res::text;
  assert (select jsonb_array_length(payload -> 'buttons' -> 0) from messages where id = (res -> 0 ->> 'message_id')::bigint) = 5;
  assert jsonb_array_length(claim_followups()) = 0, 'once';
  res := record_review(t1, (tg ->> 'conversation_id')::uuid, appt, 2);
  assert res ->> 'escalate' = 'complaint' and (select review_score from appointments where id = appt) = 2, res::text;
  assert (record_review(t1, (tg ->> 'conversation_id')::uuid, appt, 5) ->> 'escalate') is null;

  -- reactivation: last visit 7 months ago, daily cap 2 per tenant
  update appointments set period = tstzrange(now() - interval '7 months', now() - interval '7 months' + interval '1 hour') where id = appt;
  res := claim_reactivation();
  assert jsonb_array_length(res) = 1 and res -> 0 ->> 'client_id' = tg ->> 'client_id', res::text;
  assert (select text from messages where id = (res -> 0 ->> 'message_id')::bigint) like 'Hi, Ivan! It has been a while%';
  assert jsonb_array_length(claim_reactivation()) = 0, 'not twice';
end $$;
