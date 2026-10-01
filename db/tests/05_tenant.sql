-- onboarding from config, shifts, tenant isolation
do $$
declare
  t1  uuid := pg_temp.tenant('t1');
  t2  uuid := pg_temp.tenant('t2');
  res jsonb;
  n   int;
begin
  assert (select count(*) from branches where tenant_id = t1) = 2;
  assert (select count(*) from doctor_services where tenant_id = t1) = 3;
  assert (select count(*) from doctor_shifts where tenant_id = t1 and upper(period) > now()) between 14 and 18,
    'a shift per doctor per day for the 7-day horizon';
  n := (select count(*) from doctor_shifts where tenant_id = t1);
  assert ensure_shifts(7, t1) = 0, 'ensure_shifts is idempotent';

  -- re-running the same config changes nothing; dropping a service deactivates it
  res := upsert_tenant((select jsonb_build_object('slug', 't1', 'name', 'Test Clinic 2', 'timezone', 'Europe/Kyiv',
    'branches', '[{"slug": "center", "name": "Center"}]'::jsonb,
    'services', '[{"slug": "cleaning", "name": "Cleaning", "price": 1600, "duration_min": 60}]'::jsonb,
    'doctors', '[{"slug": "dr-a", "name": "Dr A", "services": ["cleaning"], "schedule": [{"branch": "center", "days": ["mon"], "from": "09:00", "to": "12:00"}]}]'::jsonb,
    'channels', '[{"channel": "telegram", "external_id": "t1-bot", "api_base": "http://stub:3000/telegram"}]'::jsonb)), 'test-key');
  assert res ->> 'tenant_id' = t1::text, 'upsert by slug';
  assert (select name from tenants where id = t1) = 'Test Clinic 2';
  assert (select price from services where tenant_id = t1 and slug = 'cleaning') = 1600, 'price updated';
  assert not (select active from services where tenant_id = t1 and slug = 'consult'), 'missing service deactivated';
  assert not (select active from doctors where tenant_id = t1 and slug = 'dr-b'), 'missing doctor deactivated';
  assert (select count(*) from branches where tenant_id = t1) = 2, 'branches are never dropped';
  assert tenant_bot(t1, 'test-key') ->> 'token' = '123:secret', 'token kept when the config has none';
  insert into channel_accounts (tenant_id, channel, external_id, api_base, token_enc, created_at)
  values (t1, 'telegram', '777', 'https://api.telegram.org', pgp_sym_encrypt('777:real', 'test-key'), now() + interval '1 minute');
  assert tenant_bot(t1, 'test-key') ->> 'token' = '777:real', 'a bot added later (real over stub) serves the operator group';
  assert (select count(*) from doctor_shifts where tenant_id = t1 and lower(period) > now()
          and extract(isodow from lower(period) at time zone 'Europe/Kyiv') <> 1) = 0, 'future shifts follow the new schedule';

  -- back to the stub bot and a new operator group: the dropped bot stops serving, old topics are forgotten
  perform pg_temp.say('topic-user', 'hi');
  update clients set operator_topic_id = 55 where tenant_id = t1;
  res := upsert_tenant(jsonb_build_object('slug', 't1', 'name', 'Test Clinic 2', 'timezone', 'Europe/Kyiv',
    'config', jsonb_build_object('operator', jsonb_build_object('chat_id', '-1002')),
    'channels', '[{"channel": "telegram", "external_id": "t1-bot", "api_base": "http://stub:3000/telegram"}]'::jsonb), 'test-key');
  assert tenant_bot(t1, 'test-key') ->> 'token' = '123:secret', 'the stub bot serves the operator group again';
  assert channel_account_auth((select id::text from channel_accounts where external_id = '777'), 'telegram',
                              (select webhook_secret from channel_accounts where external_id = '777')) is null,
    'webhooks of a dropped bot are rejected';
  assert (select active from channel_accounts where external_id = 't1-widget'), 'kinds the document does not list are kept';
  assert not (res -> 'channels') @> '[{"external_id": "777"}]', 'only active accounts are listed';
  assert (select count(*) from clients where tenant_id = t1 and operator_topic_id is not null) = 0, 'topics of the old group';

  -- knowledge base search stays inside the clinic
  insert into kb_chunks (text, metadata, embedding) values
    ('Parking behind the building.', jsonb_build_object('tenant_id', t1, 'article', 'parking'), '[1,0,0]'),
    ('Card or cash.', jsonb_build_object('tenant_id', t1, 'article', 'payment'), '[0,1,0]'),
    ('Other clinic parking.', jsonb_build_object('tenant_id', t2, 'article', 'parking'), '[1,0,0]');
  res := kb_search(t1, '[0.9,0.1,0]', 4);
  assert jsonb_array_length(res) = 2 and res -> 0 ->> 'article' = 'parking' and res -> 0 ->> 'text' like 'Parking%', res::text;

  begin
    perform upsert_tenant('{"slug": "t3", "channels": [{"channel": "telegram", "external_id": "t2-bot"}]}', 'k');
    raise exception 'stealing a channel must fail';
  exception when raise_exception then
    if sqlerrm = 'stealing a channel must fail' then raise; end if;
  end;
  begin
    perform upsert_tenant('{"slug": "Bad Slug"}', 'k');
    raise exception 'bad slug must fail';
  exception when raise_exception then
    if sqlerrm = 'bad slug must fail' then raise; end if;
  end;
  begin
    perform upsert_tenant('{"slug": "t4", "timezone": "Mars/Base"}', 'k');
    raise exception 'bad timezone must fail';
  exception when raise_exception then
    if sqlerrm = 'bad timezone must fail' then raise; end if;
  end;

  -- isolation: tools of one tenant cannot see or change another tenant's data
  res := find_slots(t2, 'consult', 'center');
  assert not (res ->> 'ok')::boolean, 'slugs resolve inside the tenant only';
  res := find_slots(t2, 'cleaning', 'center');
  assert res ->> 'result' like '%Other Cleaning%', res::text;
end $$;

do $$
declare
  t1   uuid := pg_temp.tenant('t1');
  t2   uuid := pg_temp.tenant('t2');
  r1   jsonb := pg_temp.say('iso-1', 'hi');
  r2   jsonb := ingest_message(pg_temp.account('t2-bot'), 'iso-2', 'iso-2', 'x1', 'hi', '{}', '{"first_name": "Bob"}');
  conv1 uuid := (r1 ->> 'conversation_id')::uuid;
  conv2 uuid := (r2 ->> 'conversation_id')::uuid;
  p    jsonb;
  day  text := to_char((now() at time zone 'UTC')::date + 1, 'YYYY-MM-DD');
begin
  assert r2 ->> 'tenant_id' = t2::text;
  perform save_client_info(t2, (r2 ->> 'client_id')::uuid, 'Bob', '0931234567');
  p := propose_action(t2, conv2, 'book', jsonb_build_object('service', 'cleaning', 'branch', 'center', 'start', day || ' 10:00'));
  assert (p ->> 'ok')::boolean, p::text;
  assert (propose_action(t1, conv2, 'book', '{}') ->> 'error') = 'Conversation not found.', 'foreign conversation';
  assert confirm_action(t1, (p ->> 'pending_id')::uuid) ->> 'error' = 'not_found', 'foreign pending action';
  assert resolve_pending(t2, conv1, (p ->> 'pending_id')::uuid, 'y') ->> 'error' = 'not_found', 'pending bound to its conversation';
  assert (save_client_info(t1, (r2 ->> 'client_id')::uuid, 'Hacker', null) ->> 'ok')::boolean
         and (select name from clients where id = (r2 ->> 'client_id')::uuid) = 'Bob', 'foreign client untouched';
  assert (select count(*) from clients where tenant_id = t1 and phone = '+380931234567') = 0;
end $$;
