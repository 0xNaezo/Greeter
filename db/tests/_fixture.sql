-- Shared fixture, prepended to every test file (scripts/migrate.sh --test); the whole file is
-- rolled back afterwards. Doctors work around the clock so tests do not depend on the time of day.
select upsert_tenant($${
  "slug": "t1", "name": "Test Clinic", "timezone": "Europe/Kyiv", "llm_profile": "stub",
  "config": {"emergency_phone": "+380440000000", "operator": {"chat_id": "-1001", "sla_min": 10},
             "booking": {"slot_step_min": 30, "lead_min": 60, "horizon_days": 7},
             "followups": {"reactivation": {"enabled": true, "after_months": 6, "daily_limit": 2}}},
  "branches": [
    {"slug": "center", "name": "Center", "address": "1 Main St", "hours": {"mon": "00:00-24:00"}},
    {"slug": "podil", "name": "Podil", "address": "2 River St"}],
  "services": [
    {"slug": "cleaning", "name": "Cleaning", "price": 1500, "duration_min": 60},
    {"slug": "consult", "name": "Consultation", "price": 500, "duration_min": 30}],
  "doctors": [
    {"slug": "dr-a", "name": "Dr A", "services": ["cleaning", "consult"],
     "schedule": [{"branch": "center", "days": ["mon", "tue", "wed", "thu", "fri", "sat", "sun"], "from": "00:00", "to": "23:59"}]},
    {"slug": "dr-b", "name": "Dr B", "services": ["consult"],
     "schedule": [{"branch": "podil", "days": ["mon", "tue", "wed", "thu", "fri", "sat", "sun"], "from": "00:00", "to": "23:59"}]}],
  "channels": [
    {"channel": "telegram", "external_id": "t1-bot", "api_base": "http://stub:3000/telegram", "token": "123:secret"},
    {"channel": "widget", "external_id": "t1-widget"}]
}$$::jsonb, 'test-key');

select upsert_tenant($${
  "slug": "t2", "name": "Other Clinic", "timezone": "UTC",
  "branches": [{"slug": "center", "name": "Other Center"}],
  "services": [{"slug": "cleaning", "name": "Other Cleaning", "price": 900, "duration_min": 60}],
  "doctors": [{"slug": "dr-a", "name": "Other Dr", "services": ["cleaning"],
               "schedule": [{"branch": "center", "days": ["mon", "tue", "wed", "thu", "fri", "sat", "sun"], "from": "00:00", "to": "23:59"}]}],
  "channels": [{"channel": "telegram", "external_id": "t2-bot", "token": "456:other"}]
}$$::jsonb, 'test-key');

create function pg_temp.tenant(p_slug text) returns uuid language sql as $$ select id from tenants where slug = p_slug $$;
create function pg_temp.account(p_external_id text) returns uuid language sql as $$
  select id from channel_accounts where external_id = p_external_id $$;
-- a new client writes; returns the ingest result
create function pg_temp.say(p_user text, p_text text, p_account text default 't1-bot', p_callback text default null)
returns jsonb language sql as $$
  select ingest_message(pg_temp.account(p_account), p_user, p_user, md5(random()::text), p_text,
                        case when p_callback is not null then jsonb_build_object('callback', p_callback) else '{}' end,
                        '{"first_name": "Ivan"}')
$$;
-- message ids of a turn context
create function pg_temp.ids(ctx jsonb) returns bigint[] language sql as $$
  select array_agg(x::bigint) from jsonb_array_elements_text(ctx -> 'message_ids') x $$;
