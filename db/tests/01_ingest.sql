-- ingest_message: identity -> client -> conversation -> session -> message; webhook redelivery (AC6)
do $$
declare
  acc uuid := pg_temp.account('t1-bot');
  r1  jsonb;
  r2  jsonb;
  r3  jsonb;
begin
  r1 := ingest_message(acc, 'u1', 'u1', 'upd-1', 'Hello', '{}', '{"first_name": "Ivan", "language_code": "uk"}', 'exec-1');
  assert (r1 ->> 'is_new')::boolean, 'first delivery is new';
  assert (select name from clients where id = (r1 ->> 'client_id')::uuid) = 'Ivan', 'name from the profile';
  assert (select lang from clients where id = (r1 ->> 'client_id')::uuid) = 'en', 'language from the text wins over the profile';

  r2 := ingest_message(acc, 'u1', 'u1', 'upd-1', 'Hello', '{}', '{}');
  assert not (r2 ->> 'is_new')::boolean, 'redelivery is not new';
  assert (select count(*) from messages where channel_account_id = acc) = 1, 'redelivery adds no message';
  assert (select count(*) from clients where tenant_id = pg_temp.tenant('t1')) = 1, 'redelivery adds no client';

  r3 := ingest_message(acc, 'u1', 'u1', 'upd-2', 'Это второе сообщение', '{}', '{}');
  assert r3 ->> 'conversation_id' = r1 ->> 'conversation_id', 'same conversation';
  assert r3 ->> 'session_id' = r1 ->> 'session_id', 'same session within 12 h';
  assert (select lang from clients where id = (r1 ->> 'client_id')::uuid) = 'ru', 'language follows the client';

  update sessions set last_message_at = now() - interval '13 hours' where id = (r1 ->> 'session_id')::uuid;
  r3 := ingest_message(acc, 'u1', 'u1', 'upd-3', 'After a pause', '{}', '{}');
  assert r3 ->> 'session_id' <> r1 ->> 'session_id', 'new session after 12 h of silence';
  assert r3 ->> 'conversation_id' = r1 ->> 'conversation_id', 'conversation outlives sessions';

  -- same provider id on another channel account is another message
  r2 := ingest_message(pg_temp.account('t1-widget'), 'visitor-1', 'visitor-1', 'upd-1', 'Hi from the site', '{}', '{}');
  assert (r2 ->> 'is_new')::boolean, 'provider ids are scoped by channel account';
  assert r2 ->> 'client_id' <> r1 ->> 'client_id', 'another identity is another client until glued by phone';

  assert (select count(*) from trace_events where session_id = (r1 ->> 'session_id')::uuid and type = 'msg_in') = 2,
    'msg_in trace per new message';

  begin
    perform ingest_message(gen_random_uuid(), 'u', 'u', 'x', 'y');
    raise exception 'unknown channel account must fail';
  exception when raise_exception then
    if sqlerrm like 'unknown channel account must fail' then raise; end if;
  end;
end $$;

-- helpers
do $$
begin
  assert detect_lang('Hello there') = 'en';
  assert detect_lang('Добрий день, скільки коштує') = 'uk';
  assert detect_lang('Здравствуйте, сколько стоит чистка?') = 'ru';
  assert detect_lang('Хочу записаться к врачу') = 'ru';
  assert detect_lang('Хочу записатися до лікаря') = 'uk';
  assert detect_lang('так') is null, 'ambiguous cyrillic';
  assert detect_lang('+380501234567') is null;

  assert normalize_phone('+38 (050) 123-45-67') = '+380501234567';
  assert normalize_phone('0501234567') = '+380501234567';
  assert normalize_phone('380501234567') = '+380501234567';
  assert normalize_phone('00491701234567') = '+491701234567';
  assert normalize_phone('12345') is null;

  assert is_action_callback('pa:' || gen_random_uuid() || ':y');
  assert is_action_callback('ap:' || gen_random_uuid() || ':x');
  assert not is_action_callback('ap:' || gen_random_uuid() || ':r'), 'reschedule goes to the agent';
  assert not is_action_callback('pa:' || repeat('-', 36) || ':y'), 'only a real uuid (it is cast later)';
  assert octet_length('pa:' || gen_random_uuid() || ':y') <= 64, 'telegram callback_data limit';

  assert fmt_when('2026-10-02 07:00+00', 'Europe/Kyiv', 'en') = 'Fri 02.10 10:00';
  assert fmt_when('2026-10-02 07:00+00', 'Europe/Kyiv', 'uk') = 'Пт 02.10 10:00';
  assert t('booked', 'uk', '{"service": "X"}') like '%X%';
  assert t('booked', 'de') = t('booked', 'en'), 'unknown language falls back to English';
end $$;
