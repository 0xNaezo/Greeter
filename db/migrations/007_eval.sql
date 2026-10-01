-- Eval harness for eval.run: a scripted client of the eval tenant talks to the real pipeline
-- through its widget account; these functions feed messages in and read the outcome back.

-- One client message. The first message of a scenario may carry a setup: client name / phone and
-- an upcoming appointment (first free slot of a service at a branch, starting in N days).
create function eval_say(p_visitor text, p_text text, p_setup jsonb default null) returns jsonb
language plpgsql as $$
declare
  v_acc    uuid := (select id from channel_accounts where channel = 'widget' and external_id = 'eval-widget');
  v_in     jsonb;
  v_tenant uuid;
  v_client clients;
  v_svc    services;
  v_branch branches;
  v_slot   record;
begin
  if v_acc is null then
    raise exception 'eval tenant is not provisioned (widget account eval-widget)';
  end if;
  v_in := ingest_message(v_acc, p_visitor, p_visitor, 'eval:' || gen_random_uuid(), p_text, '{}', '{}', null);
  if p_setup is null or jsonb_typeof(p_setup) <> 'object' then
    return v_in;
  end if;
  v_tenant := (v_in ->> 'tenant_id')::uuid;
  v_client := conversation_client((v_in ->> 'conversation_id')::uuid);
  if p_setup ? 'name' or p_setup ? 'phone' then
    perform save_client_info(v_tenant, v_client.id, p_setup ->> 'name', p_setup ->> 'phone');
  end if;
  if p_setup ? 'appointment' then
    v_svc := service_by_slug(v_tenant, p_setup -> 'appointment' ->> 'service');
    v_branch := branch_by_slug(v_tenant, p_setup -> 'appointment' ->> 'branch');
    select * into v_slot from available_slots(v_tenant, v_svc.id, v_branch.id, null,
      now() + make_interval(days => coalesce((p_setup -> 'appointment' ->> 'in_days')::int, 3)),
      now() + make_interval(days => coalesce((p_setup -> 'appointment' ->> 'in_days')::int, 3) + 14))
    order by starts_at limit 1;
    if not found then
      raise exception 'eval setup: no free slot for %', p_setup -> 'appointment';
    end if;
    insert into appointments (tenant_id, client_id, doctor_id, branch_id, service_id, period, source, price)
    values (v_tenant, v_client.id, v_slot.doctor_id, v_branch.id, v_svc.id, tstzrange(v_slot.starts_at, v_slot.ends_at), 'admin', v_svc.price);
  end if;
  return v_in;
end $$;

-- What the pipeline did with that message: replies, buttons, tools called, escalation.
create function eval_turn(p_conversation uuid, p_message_id bigint) returns jsonb language sql stable as $$
  with m as (select * from messages where id = p_message_id and conversation_id = p_conversation),
  replies as (select o.* from messages o, m where o.conversation_id = p_conversation and o.id > m.id and o.direction = 'out'),
  ev as (select te.* from trace_events te, m where te.session_id = m.session_id and te.created_at >= m.created_at)
  select jsonb_build_object(
    'reply', (select string_agg(text, E'\n' order by id) from replies),
    'buttons', coalesce((select bool_or(payload ? 'buttons') from replies), false),
    'lang', detect_lang((select string_agg(text, E'\n' order by id) from replies where author <> 'operator')),
    'tools', coalesce((select jsonb_agg(data ->> 'tool' order by id) from ev where type = 'tool'), '[]'),
    'escalate', (select coalesce(data ->> 'escalate', case when data ->> 'route' = 'urgent' then 'urgent' end)
                 from ev where type = 'decision' and (data ->> 'escalate' is not null or data ->> 'route' = 'urgent')
                 order by id desc limit 1),
    'streak', (select not_understood_streak from conversations where id = p_conversation),
    'state', (select state from conversations where id = p_conversation))
$$;

-- Outcome of a scenario for the client, and the price list replies are checked against.
create function eval_state(p_conversation uuid) returns jsonb language sql stable as $$
  select jsonb_build_object(
    'booked', (select count(*) from appointments a where a.client_id = c.id and a.status = 'booked' and a.source = 'bot'),
    'cancelled', (select count(*) from appointments a where a.client_id = c.id and a.status = 'cancelled'),
    'moved', (select count(*) from appointments a where a.client_id = c.id and a.source = 'admin' and a.status = 'booked'
              and a.updated_at > a.created_at + interval '1 second'),
    'name', c.name,
    'phone', c.phone,
    'prices', (select jsonb_agg(distinct trim_scale(s.price)) from services s where s.tenant_id = c.tenant_id and s.price is not null))
  from conversation_client(p_conversation) c
$$;

create function eval_tenant() returns jsonb language sql stable as $$
  select jsonb_build_object('slug', slug, 'llm_profile', llm_profile, 'models', coalesce(config -> 'models', '{}'))
  from tenants where slug = 'eval'
$$;
