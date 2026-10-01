-- Operator handoff, reminders, SLA, reconciliation, widget polling, incidents, LLM usage,
-- P1 follow-ups. Functions that return channel tokens take the key as p_key (from APP_ENCRYPTION_KEY).

-- The tenant's Telegram bot, which also serves the operator supergroup: the newest active one. upsert_tenant
-- deactivates bots dropped from the clinic config, so going back from a real bot to the stub (or replacing
-- a clinic's bot) moves the operator traffic with it.
create function tenant_bot(p_tenant uuid, p_key text) returns jsonb language sql stable as $$
  select jsonb_build_object('account_id', ca.id, 'api_base', ca.api_base,
                            'token', case when ca.token_enc is not null then pgp_sym_decrypt(ca.token_enc, p_key) end)
  from channel_accounts ca where ca.tenant_id = p_tenant and ca.channel = 'telegram' and ca.active
  order by ca.created_at desc limit 1
$$;

-- ---------------------------------------------------------------- escalation

-- Everything handoff.escalate needs to post the card: operator group, bot, client, topic, history.
create function escalation_card(p_escalation_id uuid, p_key text) returns jsonb language sql stable as $$
  select jsonb_build_object(
    'escalation_id', e.id,
    'reason', e.reason,
    'tenant_id', e.tenant_id,
    'session_id', e.session_id,
    'conversation_id', e.conversation_id,
    'operator_chat_id', t.config -> 'operator' ->> 'chat_id',
    'bot', tenant_bot(e.tenant_id, p_key),
    'client_id', c.id,
    'client_name', coalesce(c.name, 'Client'),
    'client_phone', c.phone,
    -- a typed phone that another profile also carries: the operator checks who is who before sharing anything
    'possible_duplicate', not c.phone_verified and exists (select 1 from clients o where o.tenant_id = c.tenant_id
                                                            and o.phone = c.phone and o.id <> c.id and o.merged_into is null),
    'topic_id', c.operator_topic_id,
    'topic_name', left(concat_ws(' · ', coalesce(c.name, 'Client'), c.phone, ca.channel), 120),
    'channel', ca.channel,
    'history', conversation_history(e.conversation_id, 9223372036854775807, 20),
    'llm_profile', t.llm_profile,
    'models', coalesce(t.config -> 'models', '{}'))
  from escalations e
  join tenants t on t.id = e.tenant_id
  join conversations cv on cv.id = e.conversation_id
  join clients c on c.id = cv.client_id
  left join client_identities ci on ci.id = cv.last_identity_id
  left join channel_accounts ca on ca.id = ci.channel_account_id
  where e.id = p_escalation_id
$$;

-- Hand the conversation to a human: the bot goes silent until "Return to bot". A clinic without an operator
-- group (or without a bot to reach it) cannot take the conversation: the bot keeps it, the client is sent to
-- the clinic phone and handoff.escalate alerts the platform.
create function escalate(p_conversation_id uuid, p_session_id uuid, p_reason text, p_key text) returns jsonb
language plpgsql as $$
declare
  v_conv    conversations;
  v_session uuid := p_session_id;
  v_id      uuid;
  v_msg     bigint;
begin
  select * into v_conv from conversations where id = p_conversation_id for update;
  if not found then
    raise exception 'conversation % not found', p_conversation_id;
  end if;
  if v_conv.state = 'operator' then
    return jsonb_build_object('escalated', false, 'reason', 'already_with_operator');
  end if;
  if v_session is null then
    select s.id into v_session from sessions s where s.conversation_id = p_conversation_id order by s.started_at desc limit 1;
  end if;

  if not tenant_has_operator(v_conv.tenant_id) then
    insert into escalations (tenant_id, conversation_id, session_id, reason, returned_at, summary)
    values (v_conv.tenant_id, p_conversation_id, v_session, p_reason, now(), 'No operator group: the client got the clinic phone.')
    returning id into v_id;
    update conversations set not_understood_streak = 0, updated_at = now() where id = p_conversation_id;
    v_msg := enqueue_message(p_conversation_id, 'system', t('no_operator', (conversation_client(p_conversation_id)).lang,
                                                            jsonb_build_object('phones', clinic_phones(v_conv.tenant_id))));
    insert into trace_events (tenant_id, session_id, type, data)
    values (v_conv.tenant_id, v_session, 'decision',
            jsonb_build_object('route', 'escalate', 'reason', p_reason, 'escalation_id', v_id, 'operator', false));
    return jsonb_build_object('escalated', false, 'reason', 'no_operator', 'escalation_id', v_id, 'message_id', v_msg,
                              'tenant_id', v_conv.tenant_id, 'tenant_slug', (select slug from tenants where id = v_conv.tenant_id));
  end if;

  update conversations
  set state = 'operator', awaiting_operator_since = now(), sla_notified_at = null, not_understood_streak = 0, updated_at = now()
  where id = p_conversation_id;
  insert into escalations (tenant_id, conversation_id, session_id, reason)
  values (v_conv.tenant_id, p_conversation_id, v_session, p_reason)
  returning id into v_id;
  insert into trace_events (tenant_id, session_id, type, data)
  values (v_conv.tenant_id, v_session, 'decision', jsonb_build_object('route', 'escalate', 'reason', p_reason, 'escalation_id', v_id));

  return jsonb_build_object('escalated', true) || escalation_card(v_id, p_key);
end $$;

-- "Passing you to the administrator" for escalations the client did not see coming (not understood twice).
create function notify_handoff(p_conversation_id uuid) returns bigint language sql as $$
  select enqueue_message(p_conversation_id, 'system', t('handoff', (conversation_client(p_conversation_id)).lang))
$$;

-- Topic created in the operator group; keeps the first one if two raced.
create function set_client_topic(p_client_id uuid, p_topic_id bigint) returns bigint language sql as $$
  update clients set operator_topic_id = coalesce(operator_topic_id, p_topic_id) where id = p_client_id
  returning operator_topic_id
$$;

-- The saved topic is gone (deleted or closed in the group): forget it, the next card creates a new one.
-- Compare-and-reset, so a topic another execution has just created is kept.
create function reset_client_topic(p_client_id uuid, p_topic_id bigint) returns void language sql as $$
  update clients set operator_topic_id = null where id = p_client_id and operator_topic_id = p_topic_id
$$;

-- The problem behind a ref went away (a message got through, the calendar accepted the event...).
create function resolve_incidents(p_ref text) returns void language sql as $$
  update incidents set status = 'resolved', updated_at = now() where ref = p_ref and status = 'open'
$$;

create function mark_escalation_notified(p_escalation_id uuid, p_summary text) returns void language sql as $$
  select resolve_incidents('card:' || p_escalation_id);  -- the card reported as failed got through after all
  update escalations set notified_at = now(), summary = coalesce(p_summary, summary) where id = p_escalation_id;
  update clients c set summary = left(p_summary, 2000)
  from escalations e join conversations cv on cv.id = e.conversation_id
  where e.id = p_escalation_id and c.id = cv.client_id and nullif(trim(p_summary), '') is not null;
$$;

-- Where to forward client messages while the conversation is with the operator.
create function operator_route(p_conversation_id uuid, p_key text) returns jsonb language sql stable as $$
  select jsonb_build_object('operator_chat_id', t.config -> 'operator' ->> 'chat_id', 'topic_id', c.operator_topic_id,
                            'client_id', c.id, 'client_name', coalesce(c.name, 'Client'), 'bot', tenant_bot(t.id, p_key),
                            'escalation_id', (select e.id from escalations e where e.conversation_id = cv.id
                                              order by e.created_at desc limit 1))
  from conversations cv join clients c on c.id = cv.client_id join tenants t on t.id = cv.tenant_id
  where cv.id = p_conversation_id
$$;

-- A message an operator wrote in a client topic -> outbound message to the client's channel.
-- Idempotent per operator message; the operator writing also takes the conversation over.
create function operator_reply(p_account_id uuid, p_chat_id text, p_thread_id bigint, p_message_id text,
                               p_text text) returns jsonb
language plpgsql as $$
declare
  v_tenant tenants;
  v_conv   conversations;
  v_msg    bigint;
begin
  select t.* into v_tenant from channel_accounts ca join tenants t on t.id = ca.tenant_id where ca.id = p_account_id;
  if v_tenant.config -> 'operator' ->> 'chat_id' is distinct from p_chat_id then
    return jsonb_build_object('ok', false, 'error', 'not_operator_group');
  end if;
  select cv.* into v_conv from clients c join conversations cv on cv.client_id = c.id
  where c.tenant_id = v_tenant.id and c.operator_topic_id = p_thread_id;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'unknown_topic');
  end if;

  v_msg := enqueue_message(v_conv.id, 'operator', p_text, '{}', null, 'op:' || p_chat_id || ':' || p_message_id);
  if v_msg is null then
    return jsonb_build_object('ok', false, 'error', 'duplicate_or_unreachable');
  end if;
  update escalations set first_reply_at = now()
  where id = (select id from escalations where conversation_id = v_conv.id and returned_at is null
              order by created_at desc limit 1)
    and first_reply_at is null;
  update conversations
  set state = 'operator', awaiting_operator_since = null, sla_notified_at = null, updated_at = now()
  where id = v_conv.id;
  return jsonb_build_object('ok', true, 'message_id', v_msg, 'conversation_id', v_conv.id);
end $$;

-- Operator button rb:<conversation>: the bot takes over again.
create function return_to_bot(p_account_id uuid, p_chat_id text, p_conversation_id uuid) returns jsonb
language plpgsql as $$
declare
  v_tenant tenants;
  v_conv   conversations;
  v_lang   text;
  v_msg    bigint;
begin
  select t.* into v_tenant from channel_accounts ca join tenants t on t.id = ca.tenant_id where ca.id = p_account_id;
  if v_tenant.config -> 'operator' ->> 'chat_id' is distinct from p_chat_id then
    return jsonb_build_object('ok', false, 'error', 'not_operator_group');
  end if;
  select * into v_conv from conversations where tenant_id = v_tenant.id and id = p_conversation_id for update;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'unknown_conversation');
  end if;
  if v_conv.state = 'bot' then
    return jsonb_build_object('ok', true, 'already', true);
  end if;
  update conversations
  set state = 'bot', awaiting_operator_since = null, sla_notified_at = null, not_understood_streak = 0, updated_at = now()
  where id = v_conv.id;
  update escalations set returned_at = now() where conversation_id = v_conv.id and returned_at is null;
  v_lang := (conversation_client(v_conv.id)).lang;
  v_msg := enqueue_message(v_conv.id, 'system', t('back_to_bot', v_lang));
  return jsonb_build_object('ok', true, 'message_id', v_msg);
end $$;

-- cron.operator_sla: operator silent for N minutes -> holding message to the client + ping in the topic.
create function claim_sla_breaches(p_key text) returns jsonb language plpgsql as $$
declare
  r      record;
  v_out  jsonb := '[]';
  v_msg  bigint;
begin
  for r in
    update conversations c set sla_notified_at = now()
    from tenants t
    where t.id = c.tenant_id and c.state = 'operator' and c.sla_notified_at is null and tenant_has_operator(t.id)
      and c.awaiting_operator_since < now() - make_interval(mins => coalesce((t.config -> 'operator' ->> 'sla_min')::int, 10))
    returning c.id, c.tenant_id, c.awaiting_operator_since
  loop
    v_msg := enqueue_message(r.id, 'system', t('operator_wait', (conversation_client(r.id)).lang));
    v_out := v_out || jsonb_build_array(operator_route(r.id, p_key) || jsonb_build_object(
      'conversation_id', r.id, 'message_id', v_msg,
      'waited_min', floor(extract(epoch from now() - r.awaiting_operator_since) / 60)::int));
  end loop;
  return v_out;
end $$;

-- ---------------------------------------------------------------- reminders

-- cron.reminders: claim due reminders and queue them with buttons in one transaction; out.send
-- (and cron.reconcile for failures) delivers. 24 h reminder 3-24 h before, 2 h reminder in the
-- last 2 h; nothing right after booking (the confirmation is enough).
create function claim_reminders(p_limit int default 100) returns jsonb language plpgsql as $$
declare
  r     record;
  v_out jsonb := '[]';
  v_msg bigint;
  v_lang text;
  v_args jsonb;
begin
  for r in
    with due as (
      select a.id, case when lower(a.period) - now() <= interval '2 hours' then '2h' else '24h' end as kind
      from appointments a
      where a.status = 'booked' and lower(a.period) > now() and a.updated_at < now() - interval '30 minutes'
        and ((a.reminder_2h_sent_at is null and lower(a.period) - now() <= interval '2 hours')
          or (a.reminder_24h_sent_at is null and a.reminder_2h_sent_at is null
              and lower(a.period) - now() between interval '3 hours' and interval '24 hours'))
      order by lower(a.period)
      limit p_limit
      for update skip locked
    )
    update appointments a
    set reminder_2h_sent_at = case when due.kind = '2h' then now() else a.reminder_2h_sent_at end,
        reminder_24h_sent_at = coalesce(a.reminder_24h_sent_at, now())
    from due where a.id = due.id
    returning a.*, due.kind
  loop
    select jsonb_build_object('service', s.name, 'doctor', d.name, 'branch', b.name, 'address', coalesce(b.address, ''),
                              'when', case when r.kind = '2h' then to_char(lower(r.period) at time zone tenant_tz(r.tenant_id, r.branch_id), 'HH24:MI')
                                           else fmt_when(lower(r.period), tenant_tz(r.tenant_id, r.branch_id), c.lang) end,
                              'conversation_id', cv.id, 'lang', c.lang)
    into v_args
    from clients c
    join services s on s.id = r.service_id
    join doctors d on d.id = r.doctor_id
    join branches b on b.id = r.branch_id
    left join conversations cv on cv.client_id = c.id
    where c.id = r.client_id;
    v_lang := v_args ->> 'lang';

    v_msg := null;
    if v_args ->> 'conversation_id' is not null then
      v_msg := enqueue_message((v_args ->> 'conversation_id')::uuid, 'system',
        t(case when r.kind = '2h' then 'reminder_2h' else 'reminder_24h' end, v_lang, v_args),
        jsonb_build_object('buttons', jsonb_build_array(jsonb_build_array(
          jsonb_build_object('text', t('btn.attend', v_lang), 'data', 'ap:' || r.id || ':c'),
          jsonb_build_object('text', t('btn.reschedule', v_lang), 'data', 'ap:' || r.id || ':r'),
          jsonb_build_object('text', t('btn.cancel', v_lang), 'data', 'ap:' || r.id || ':x')))),
        null, 'rem' || r.kind || ':' || r.id || ':' || lower(r.period));
    end if;
    if v_msg is not null then
      v_out := v_out || jsonb_build_array(jsonb_build_object('message_id', v_msg, 'appointment_id', r.id, 'kind', r.kind));
    end if;
  end loop;
  return v_out;
end $$;

-- ---------------------------------------------------------------- reconciliation (read-only)

-- Inbound messages nobody is working on (worker died, sub-workflow failed).
create function reconcile_conversations(p_limit int default 50) returns table (conversation_id uuid)
language sql stable as $$
  select m.conversation_id
  from messages m join conversations c on c.id = m.conversation_id
  where m.direction = 'in' and m.processed_at is null and m.created_at < now() - interval '20 seconds'
    and (c.lease_until is null or c.lease_until < now())
  group by m.conversation_id
  order by min(m.id)
  limit p_limit
$$;

-- Outbound messages not delivered yet whose retry is due (mark_sent backoff). Widget messages are delivered by
-- polling, not pushed.
create function reconcile_outbound(p_limit int default 100) returns table (message_id bigint)
language sql stable as $$
  select m.id
  from messages m join channel_accounts ca on ca.id = m.channel_account_id
  where m.direction = 'out' and m.sent_at is null and m.failed_at is null and ca.channel <> 'widget'
    and coalesce(m.next_attempt_at, m.created_at + interval '30 seconds') <= now()
  order by m.id
  limit p_limit
$$;

-- Appointments whose calendar mirror is behind and due for a try (future ones only, mark_gcal_failed backoff).
create function reconcile_appointments(p_limit int default 50) returns table (appointment_id uuid)
language sql stable as $$
  select a.id
  from appointments a
  where a.gcal_synced_at is null and upper(a.period) > now() and a.updated_at < now() - interval '30 seconds'
    and (a.gcal_next_at is null or a.gcal_next_at <= now())
  order by a.updated_at
  limit p_limit
$$;

-- Escalations whose card never reached the operator group (not the ones without an operator).
create function reconcile_escalations(p_limit int default 20) returns table (escalation_id uuid)
language sql stable as $$
  select e.id from escalations e
  where e.notified_at is null and e.returned_at is null and tenant_has_operator(e.tenant_id)
    and e.created_at < now() - interval '60 seconds' and e.created_at > now() - interval '1 day'
  order by e.created_at
  limit p_limit
$$;

-- ---------------------------------------------------------------- calendar mirror

-- int.gcal input: target calendar, event body, current version (updated_at).
create function gcal_job(p_appointment_id uuid) returns jsonb language sql stable as $$
  select jsonb_build_object(
    'appointment_id', a.id,
    'tenant_id', a.tenant_id,
    'version', a.updated_at,
    'status', a.status,
    'event_id', replace(a.id::text, '-', ''),
    'calendar_id', coalesce(d.calendar_id, b.calendar_id),
    'old_calendar_id', a.gcal_calendar_id,
    'api_base', coalesce(t.config -> 'calendar' ->> 'api_base', 'https://www.googleapis.com/calendar/v3'),
    'token_uri', coalesce(t.config -> 'calendar' ->> 'token_uri', 'https://oauth2.googleapis.com/token'),
    'event', jsonb_build_object(
      'summary', s.name || ' · ' || coalesce(c.name, 'Client'),
      'description', concat_ws(E'\n', 'Client: ' || coalesce(c.name, '-') || coalesce(', ' || c.phone, ''),
                               'Doctor: ' || d.name, 'Reason: ' || a.reason, 'Booked via AI Front Desk'),
      'location', concat_ws(', ', b.name, b.address),
      'start', jsonb_build_object('dateTime', to_char(lower(a.period) at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
                                  'timeZone', tenant_tz(a.tenant_id, a.branch_id)),
      'end', jsonb_build_object('dateTime', to_char(upper(a.period) at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
                                'timeZone', tenant_tz(a.tenant_id, a.branch_id))))
  from appointments a
  join tenants t on t.id = a.tenant_id
  join doctors d on d.tenant_id = a.tenant_id and d.id = a.doctor_id
  join branches b on b.tenant_id = a.tenant_id and b.id = a.branch_id
  join services s on s.tenant_id = a.tenant_id and s.id = a.service_id
  join clients c on c.tenant_id = a.tenant_id and c.id = a.client_id
  where a.id = p_appointment_id
$$;

-- Marks the mirror current only if the appointment did not change while we were syncing, and closes the
-- incident of earlier failed syncs.
create function mark_gcal_synced(p_appointment_id uuid, p_version timestamptz, p_calendar_id text) returns boolean
language plpgsql as $$
begin
  update appointments set gcal_synced_at = now(), gcal_calendar_id = p_calendar_id, gcal_attempts = 0, gcal_next_at = null
  where id = p_appointment_id and updated_at = p_version;
  if not found then
    return null;
  end if;
  perform resolve_incidents('gcal:' || p_appointment_id);
  return true;
end $$;

-- A sync of this version failed (no access to the calendar, Google down): retry with backoff, 1 min doubling
-- up to 1 h, while the appointment is ahead. The third failure in a row asks int.gcal for one incident.
create function mark_gcal_failed(p_appointment_id uuid, p_version timestamptz, p_error text) returns jsonb
language plpgsql as $$
declare
  v_attempts int;
begin
  update appointments
  set gcal_attempts = gcal_attempts + 1,
      gcal_next_at = now() + least(interval '1 hour', interval '1 minute' * power(2, gcal_attempts))
  where id = p_appointment_id and updated_at = p_version
  returning gcal_attempts into v_attempts;
  return jsonb_build_object('attempts', v_attempts, 'report', v_attempts = 3, 'ref', 'gcal:' || p_appointment_id,
                            'error', format('Google Calendar sync failed %s times for appointment %s: %s',
                                            v_attempts, p_appointment_id, left(p_error, 300)));
end $$;

-- ---------------------------------------------------------------- web widget

-- Delivery for the widget = the visitor's browser polls; returned messages count as sent.
create function widget_poll(p_account_id uuid, p_visitor text, p_after_id bigint) returns jsonb
language plpgsql as $$
declare
  v_out jsonb;
begin
  with ident as (
    select ci.id, ci.client_id from client_identities ci
    where ci.channel_account_id = p_account_id and ci.external_user_id = p_visitor
  ), msgs as (
    update messages m set sent_at = coalesce(m.sent_at, now()), send_attempts = m.send_attempts + 1
    from ident
    where m.direction = 'out' and m.conversation_id = (select cv.id from conversations cv
                                                       join clients c on c.id = cv.client_id
                                                       where cv.client_id = ident.client_id)
      and m.channel_account_id = p_account_id and m.id > coalesce(p_after_id, 0) and m.failed_at is null
    returning m.id, m.author, m.text, m.payload, m.created_at
  )
  select coalesce(jsonb_agg(jsonb_build_object('id', id, 'author', author, 'text', text,
                                               'buttons', coalesce(payload -> 'buttons', '[]'), 'at', created_at) order by id), '[]')
  into v_out from msgs;
  return v_out;
end $$;

-- Fixed-window counter: true while p_key stays within p_limit hits per p_window_sec.
create function rate_hit(p_key text, p_limit int, p_window_sec int) returns boolean language plpgsql as $$
declare
  v_hits int;
begin
  insert into rate_limits (key, window_start)
  values (p_key, to_timestamp(floor(extract(epoch from now()) / p_window_sec) * p_window_sec))
  on conflict (key, window_start) do update set hits = rate_limits.hits + 1
  returning hits into v_hits;
  if random() < 0.01 then
    delete from rate_limits where window_start < now() - interval '1 day';
  end if;
  return v_hits <= p_limit;
end $$;

-- The public widget endpoint before anything else runs: 'bad_request' for malformed input, 'too_many' over
-- the limits (every message is a paid LLM turn), else 'ok'. Polls cost no LLM and are not counted.
create function widget_gate(p_account uuid, p_action text, p_ip text, p_visitor text, p_body jsonb) returns text
language plpgsql as $$
begin
  if jsonb_typeof(p_body) is distinct from 'object' then
    return 'bad_request';
  end if;
  if p_action = 'send' and (length(coalesce(p_body ->> 'id', '')) > 64
      or coalesce(p_body ->> 'callback', 'pa:00000000-0000-0000-0000-000000000000:y')
         !~ '^(pa:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}:[yn]|ap:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}:[cxrb]|rv:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}:[1-5])$') then
    return 'bad_request';
  end if;
  if p_action = 'poll' and coalesce(p_body ->> 'after', '0') !~ '^[0-9]{1,15}$' then
    return 'bad_request';
  end if;
  if p_action = 'session' then
    if not rate_hit('widget-session:' || p_account || ':' || coalesce(p_ip, ''), 20, 600) then
      return 'too_many';
    end if;
  elsif p_action = 'send' then
    if not rate_hit('widget-ip:' || p_account || ':' || coalesce(p_ip, ''), 60, 600)
       or not rate_hit('widget-visitor:' || p_account || ':' || coalesce(p_visitor, ''), 20, 600) then
      return 'too_many';
    end if;
  end if;
  return 'ok';
end $$;

-- ---------------------------------------------------------------- incidents and usage

-- ops.error: every failure and every reported problem is recorded; one alert per workflow/node per 10 minutes.
-- A reported problem with a ref (send:<account>, gcal:<appointment>, no_operator:<tenant>) stays one open
-- incident: repeats only count until resolve_incidents(ref) closes it. Only failed executions can be replayed.
create function record_incident(p_workflow text, p_node text, p_execution_id text, p_error text, p_url text,
                                p_ref text default null, p_replayable boolean default true) returns jsonb
language plpgsql as $$
declare
  v_alert boolean := not exists (select 1 from incidents
                                 where workflow = p_workflow and node is not distinct from p_node
                                   and alerted_at > now() - interval '10 minutes');
  v_id         bigint;
  v_replayable boolean;
  v_new        boolean;
begin
  if p_ref is null then
    insert into incidents (workflow, node, execution_id, error, url, replayable, alerted_at)
    values (p_workflow, p_node, p_execution_id, left(p_error, 2000), p_url, p_replayable and p_execution_id is not null,
            case when v_alert then now() end)
    on conflict (execution_id) where execution_id is not null and ref is null do update set error = excluded.error
    returning id, replayable, xmax = 0 into v_id, v_replayable, v_new;
  else
    insert into incidents (workflow, node, execution_id, error, url, ref, replayable, alerted_at)
    values (p_workflow, p_node, p_execution_id, left(p_error, 2000), p_url, p_ref, false, case when v_alert then now() end)
    on conflict (ref) where ref is not null and status = 'open'
    do update set error = excluded.error, repeats = incidents.repeats + 1, updated_at = now()
    returning id, replayable, xmax = 0 into v_id, v_replayable, v_new;
  end if;
  return jsonb_build_object('incident_id', v_id, 'alert', v_alert and v_new, 'replayable', v_replayable,
    'workflow', p_workflow, 'node', p_node, 'execution_id', p_execution_id, 'error', left(p_error, 2000),
    'open_last_10m', (select count(*) from incidents where workflow = p_workflow and created_at > now() - interval '10 minutes'));
end $$;

-- ops.replay, Replay button: take the incident, so a double click or two admins replay it once.
create function replay_claim(p_incident_id bigint) returns jsonb language plpgsql as $$
declare
  v incidents;
begin
  update incidents set status = 'replaying', updated_at = now()
  where id = p_incident_id and replayable
    and (status = 'open' or (status = 'replaying' and updated_at < now() - interval '5 minutes'))
  returning * into v;
  if found then
    return jsonb_build_object('claimed', true, 'incident_id', v.id, 'execution_id', v.execution_id);
  end if;
  select * into v from incidents where id = p_incident_id;
  return jsonb_build_object('claimed', false, 'incident_id', p_incident_id,
    'text', 'Nothing to replay: incident #' || p_incident_id || ' is '
            || case when v.id is null then 'unknown' when not v.replayable then 'retried automatically' else v.status end);
end $$;

-- Outcome of the retried execution: replayed only if it succeeded, otherwise the incident is open again.
create function finish_replay(p_incident_id bigint, p_replay_execution_id text, p_status text, p_error text) returns jsonb
language plpgsql as $$
begin
  update incidents
  set status = case when p_status = 'success' then 'replayed' else 'open' end,
      replay_execution_id = coalesce(p_replay_execution_id, replay_execution_id), updated_at = now()
  where id = p_incident_id;
  return jsonb_build_object('text', case
    when p_status = 'success' then '🔁 Incident #' || p_incident_id || ' replayed as execution ' || p_replay_execution_id
    else 'Replay of incident #' || p_incident_id || ' failed: '
         || left(coalesce(case when p_replay_execution_id is not null then 'execution ' || p_replay_execution_id || ' ended with ' || coalesce(p_status, 'unknown status') end,
                          p_error, 'unknown error'), 150)
         || '. The incident stays open.' end);
end $$;

-- cron.usage reads executions started since the last scan; the 15 minute overlap catches executions that were
-- still running then (record_llm_usage skips rows it already has). A first scan looks back one day.
create function usage_scan_start(p_workflows text[]) returns table (workflow_id text, since timestamptz, until timestamptz)
language sql stable as $$
  select w, coalesce(s.scanned_until, now() - interval '1 day') - interval '15 minutes', now()
  from unnest(p_workflows) w left join usage_scans s on s.workflow_id = w
$$;

-- cron.usage: token counts pulled from core.turn executions. Idempotent per (execution, model).
-- p_scans [{workflow_id, until}] moves the scan marks forward in the same transaction.
create function record_llm_usage(p_rows jsonb, p_scans jsonb default '[]') returns int language sql as $$
  insert into usage_scans (workflow_id, scanned_until)
  select s ->> 'workflow_id', (s ->> 'until')::timestamptz from jsonb_array_elements(coalesce(p_scans, '[]')) s
  on conflict (workflow_id) do update set scanned_until = greatest(usage_scans.scanned_until, excluded.scanned_until);
  with ins as (
    insert into llm_usage (tenant_id, session_id, execution_id, model, tokens_in, tokens_out, cost_usd, estimated)
    select (r ->> 'tenant_id')::uuid, (r ->> 'session_id')::uuid, r ->> 'execution_id', r ->> 'model',
           (r ->> 'tokens_in')::int, (r ->> 'tokens_out')::int,
           coalesce((select (r ->> 'tokens_in')::int * p.usd_per_mtok_in / 1e6 + (r ->> 'tokens_out')::int * p.usd_per_mtok_out / 1e6
                     from llm_prices p where (r ->> 'model') ilike '%' || p.model_prefix || '%'
                     order by length(p.model_prefix) desc limit 1), 0),
           coalesce((r ->> 'estimated')::boolean, false)
    from jsonb_array_elements(p_rows) r
    where exists (select 1 from tenants t where t.id = (r ->> 'tenant_id')::uuid)
    on conflict (execution_id, model) do nothing
    returning 1
  )
  select count(*)::int from ins
$$;

-- Matched as a substring of the model id, longest first ("openai/gpt-4.1-mini" -> "gpt-4.1-mini").
insert into llm_prices (model_prefix, usd_per_mtok_in, usd_per_mtok_out) values
  ('gpt-4.1-mini', 0.40, 1.60),
  ('gpt-4.1-nano', 0.10, 0.40),
  ('gpt-4o-mini', 0.15, 0.60),
  ('text-embedding-3-small', 0.02, 0),
  ('gemini-2.5-flash-lite', 0.10, 0.40),
  ('gemini-2.5-flash', 0.30, 2.50),
  ('gemini-2.5-pro', 1.25, 10.00),
  ('llama-3.3-70b', 0.59, 0.79),
  ('llama-3.1-8b', 0.05, 0.08),
  ('gpt-oss-120b', 0.15, 0.75),
  ('gpt-oss-20b', 0.075, 0.30),
  ('stub', 0.40, 1.60);   -- load tests: priced like the default model

-- ---------------------------------------------------------------- P1 follow-ups

-- Appointments that ended 3 h ago without a no-show mark count as attended.
create function complete_past_appointments() returns int language sql as $$
  with done as (
    update appointments set status = 'done'
    where status = 'booked' and upper(period) < now() - interval '3 hours'
    returning 1
  )
  select count(*)::int from done
$$;

-- Review request after a visit, rebooking offer after a no-show. Queued with buttons.
create function claim_followups(p_limit int default 100) returns jsonb language plpgsql as $$
declare
  r     record;
  v_out jsonb := '[]';
  v_msg bigint;
begin
  for r in
    with due as (
      select a.id from appointments a join tenants t on t.id = a.tenant_id
      where a.followup_sent_at is null
        and upper(a.period) between now() - interval '3 days' and now() - interval '3 hours'
        and ((a.status = 'done' and coalesce((t.config -> 'followups' ->> 'review')::boolean, true))
          or (a.status = 'no_show' and coalesce((t.config -> 'followups' ->> 'no_show')::boolean, true)))
      order by upper(a.period)
      limit p_limit
      for update of a skip locked
    )
    update appointments a set followup_sent_at = now() from due where a.id = due.id
    returning a.id, a.tenant_id, a.client_id, a.status, a.period, a.service_id, a.doctor_id, a.branch_id
  loop
    select enqueue_message(cv.id, 'system',
             t(case when r.status = 'done' then 'review_ask' else 'noshow' end, c.lang,
               jsonb_build_object('service', s.name, 'doctor', d.name, 'branch', b.name,
                                  'when', fmt_when(lower(r.period), tenant_tz(r.tenant_id, r.branch_id), c.lang))),
             case when r.status = 'done' then jsonb_build_object('buttons', jsonb_build_array(
                    (select jsonb_agg(jsonb_build_object('text', repeat('⭐', n), 'data', 'rv:' || r.id || ':' || n) order by n)
                     from generate_series(1, 5) n)))
                  else jsonb_build_object('buttons', jsonb_build_array(jsonb_build_array(
                    jsonb_build_object('text', t('btn.rebook', c.lang), 'data', 'ap:' || r.id || ':b')))) end,
             null, 'fu:' || r.id)
    into v_msg
    from clients c
    join conversations cv on cv.client_id = c.id
    join services s on s.id = r.service_id
    join doctors d on d.id = r.doctor_id
    join branches b on b.id = r.branch_id
    where c.id = r.client_id;
    if v_msg is not null then
      v_out := v_out || jsonb_build_array(jsonb_build_object('message_id', v_msg, 'appointment_id', r.id, 'kind', r.status));
    end if;
  end loop;
  return v_out;
end $$;

-- Button rv:<appt>:<score>. A low score goes to the operator as a complaint.
create function record_review(p_tenant uuid, p_conversation uuid, p_appointment uuid, p_score int) returns jsonb
language plpgsql as $$
declare
  v_client clients := conversation_client(p_conversation);
begin
  update appointments set review_score = p_score
  where tenant_id = p_tenant and id = p_appointment and client_id = v_client.id and status = 'done';
  if not found then
    return jsonb_build_object('ok', false, 'error', 'not_found', 'reply', t('not_found', v_client.lang));
  end if;
  return jsonb_build_object('ok', true, 'kind', 'review', 'escalate', case when p_score <= 2 then 'complaint' end,
                            'reply', t(case when p_score <= 2 then 'review_sorry' else 'review_thanks' end, v_client.lang));
end $$;

-- Reactivation: clients without a visit for N months get one personal message, with a daily cap
-- per tenant. Only clients reachable in a messenger.
create function claim_reactivation() returns jsonb language plpgsql as $$
declare
  r     record;
  v_out jsonb := '[]';
  v_msg bigint;
begin
  for r in
    with cfg as (
      select t.id as tenant_id,
             coalesce((t.config -> 'followups' -> 'reactivation' ->> 'after_months')::int, 6) as months,
             greatest(0, coalesce((t.config -> 'followups' -> 'reactivation' ->> 'daily_limit')::int, 20)
               - (select count(*) from clients c where c.tenant_id = t.id
                  and c.reactivation_sent_at > date_trunc('day', now() at time zone t.timezone) at time zone t.timezone)) as quota
      from tenants t
      where coalesce((t.config -> 'followups' -> 'reactivation' ->> 'enabled')::boolean, false)
    ), last_visit as (
      select a.client_id, max(upper(a.period)) as at,
             (array_agg(a.service_id order by upper(a.period) desc))[1] as service_id
      from appointments a where a.status = 'done' group by a.client_id
    ), due as (
      select c.id as client_id, c.tenant_id, lv.at, lv.service_id,
             row_number() over (partition by c.tenant_id order by lv.at) as n, cfg.quota
      from clients c
      join cfg on cfg.tenant_id = c.tenant_id
      join last_visit lv on lv.client_id = c.id
      join conversations cv on cv.client_id = c.id and cv.last_identity_id is not null and cv.state = 'bot'
      where c.merged_into is null
        and lv.at < now() - make_interval(months => cfg.months)
        and (c.reactivation_sent_at is null or c.reactivation_sent_at < now() - make_interval(months => cfg.months))
        and not exists (select 1 from appointments f where f.client_id = c.id and f.status = 'booked' and lower(f.period) > now())
    )
    select * from due where n <= quota
  loop
    update clients set reactivation_sent_at = now() where id = r.client_id;
    select enqueue_message(cv.id, 'system',
             t('reactivation', c.lang, jsonb_build_object('name', coalesce(', ' || split_part(c.name, ' ', 1), ''),
                                                           'service', s.name,
                                                           'date', to_char(r.at at time zone tenant_tz(r.tenant_id), 'DD.MM.YYYY'))),
             '{}', null, 'react:' || c.id || ':' || to_char(now(), 'YYYY-MM-DD'))
    into v_msg
    from clients c join conversations cv on cv.client_id = c.id join services s on s.id = r.service_id
    where c.id = r.client_id;
    if v_msg is not null then
      v_out := v_out || jsonb_build_array(jsonb_build_object('message_id', v_msg, 'client_id', r.client_id));
    end if;
  end loop;
  return v_out;
end $$;
