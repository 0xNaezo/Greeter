-- Reporting layer for Grafana. The grafana_ro role reads only this schema; the views run with the
-- owner's rights, so the base tables stay closed to it.
create schema dash;

create view dash.tenants as select id, slug, name from tenants;
create view dash.branches as select tenant_id, id, slug, name from branches;

-- One row per dialog session: activity, outcome (booked during the session), handoff, LLM cost.
create view dash.sessions as
select s.id, s.tenant_id, s.conversation_id, s.channel, s.started_at, s.last_message_at,
       (select count(*) from messages m where m.session_id = s.id and m.direction = 'in') as messages_in,
       (select count(*) from messages m where m.session_id = s.id and m.direction = 'out') as messages_out,
       exists (select 1 from escalations e where e.session_id = s.id) as escalated,
       exists (select 1 from conversations cv
               join clients c on c.id = cv.client_id
               join appointments a on a.client_id = coalesce(c.merged_into, c.id)
               where cv.id = s.conversation_id and a.source <> 'admin'
                 and a.created_at between s.started_at and s.last_message_at + interval '10 minutes') as booked,
       coalesce((select sum(u.cost_usd) from llm_usage u where u.session_id = s.id), 0) as llm_cost_usd
from sessions s;

create view dash.appointments as
select a.id, a.tenant_id, a.branch_id, b.name as branch, d.name as doctor, s.name as service, a.status, a.source,
       a.created_at, lower(a.period) as starts_at, a.price, a.review_score, a.confirmed_at is not null as confirmed,
       a.gcal_synced_at is not null as in_calendar, c.name as client, c.phone
from appointments a
join branches b on b.id = a.branch_id
join doctors d on d.id = a.doctor_id
join services s on s.id = a.service_id
join clients c on c.id = a.client_id;

create view dash.escalations as
select e.id, e.tenant_id, e.session_id, e.reason, e.created_at, e.notified_at, e.first_reply_at, e.returned_at,
       extract(epoch from e.first_reply_at - e.created_at) / 60 as reply_min
from escalations e;

-- Client message -> first bot answer after it (batched messages share the answer). Answers later than
-- 10 minutes are handoff/operator time, not bot latency.
create view dash.response_times as
select m.tenant_id, m.session_id, m.created_at as at, extract(epoch from r.sent_at - m.created_at) as seconds
from messages m
cross join lateral (
  select o.sent_at from messages o
  where o.conversation_id = m.conversation_id and o.id > m.id and o.direction = 'out'
    and o.author in ('bot', 'system') and o.sent_at is not null
  order by o.id limit 1) r
where m.direction = 'in' and r.sent_at < m.created_at + interval '10 minutes';

create view dash.llm_usage as
select tenant_id, session_id, created_at, model, tokens_in, tokens_out, cost_usd, estimated from llm_usage;

create view dash.clients as
select c.tenant_id, c.id, c.name, c.phone, c.lang, c.created_at,
       (select string_agg(distinct ca.channel, ', ') from client_identities ci
        join channel_accounts ca on ca.id = ci.channel_account_id where ci.client_id = c.id) as channels,
       count(a.id) filter (where a.status = 'done') as visits,
       count(a.id) filter (where a.status = 'no_show') as no_shows,
       max(lower(a.period)) filter (where a.status = 'done') as last_visit,
       min(lower(a.period)) filter (where a.status = 'booked' and lower(a.period) > now()) as next_visit
from clients c
left join appointments a on a.client_id = c.id
where c.merged_into is null
group by c.id;

create view dash.trace as
select tenant_id, session_id, created_at as at, type, coalesce(data ->> 'text', data::text) as detail,
       duration_ms, execution_id
from trace_events;

create view dash.incidents as
select id, workflow, node, status, created_at, execution_id, url, left(error, 300) as error from incidents;

grant usage on schema dash to grafana_ro;
grant select on all tables in schema dash to grafana_ro;
