-- escalation and operator, SLA, reminders, delivery, reconciliation, widget, incidents, usage
do $$
declare
  t1    uuid := pg_temp.tenant('t1');
  acc   uuid := pg_temp.account('t1-bot');
  r     jsonb;
  conv  uuid;
  res   jsonb;
  card  jsonb;
  inc   jsonb;
  msg   bigint;
  appt  uuid;
  p     jsonb;
  day   text := to_char((now() at time zone 'Europe/Kyiv')::date + 1, 'YYYY-MM-DD');
begin
  r := pg_temp.say('u1', 'I want to talk to a human');
  conv := (r ->> 'conversation_id')::uuid;

  -- the token is stored encrypted and comes back only with the key
  assert (select token_enc is not null and position('secret' in encode(token_enc, 'escape')) = 0
          from channel_accounts where id = acc), 'token encrypted at rest';
  assert tenant_bot(t1, 'test-key') ->> 'token' = '123:secret';

  card := escalate(conv, (r ->> 'session_id')::uuid, 'user_request', 'test-key');
  assert (card ->> 'escalated')::boolean, card::text;
  assert card ->> 'operator_chat_id' = '-1001' and card -> 'bot' ->> 'token' = '123:secret';
  assert card ->> 'topic_id' is null and card ->> 'history' like '%talk to a human%';
  assert (select state from conversations where id = conv) = 'operator';
  assert not (escalate(conv, null, 'complaint', 'test-key') ->> 'escalated')::boolean, 'no double escalation';
  assert set_client_topic((card ->> 'client_id')::uuid, 77) = 77;
  assert set_client_topic((card ->> 'client_id')::uuid, 78) = 77, 'first topic wins';
  inc := record_incident('handoff.escalate', 'Post card', '90', 'Telegram 502', null, 'card:' || (card ->> 'escalation_id'), false);
  perform mark_escalation_notified((card ->> 'escalation_id')::uuid, 'Wants a human.');
  assert (select status from incidents where id = (inc ->> 'incident_id')::bigint) = 'resolved', 'a posted card closes its incident';
  assert (select summary from clients where id = (card ->> 'client_id')::uuid) = 'Wants a human.', 'summary kept for later sessions';
  assert operator_route(conv, 'test-key') ->> 'topic_id' = '77';

  -- operator answers in the topic -> message to the client, once
  res := operator_reply(acc, '-1001', 77, '555', 'Hello, this is Anna');
  assert (res ->> 'ok')::boolean, res::text;
  msg := (res ->> 'message_id')::bigint;
  assert (select author = 'operator' and direction = 'out' from messages where id = msg);
  assert not (operator_reply(acc, '-1001', 77, '555', 'Hello, this is Anna') ->> 'ok')::boolean, 'operator message deduplicated';
  assert operator_reply(acc, '-999', 77, '556', 'x') ->> 'error' = 'not_operator_group';
  assert operator_reply(acc, '-1001', 12345, '557', 'x') ->> 'error' = 'unknown_topic';
  assert (select first_reply_at is not null from escalations where id = (card ->> 'escalation_id')::uuid);

  -- delivery: failures retry with backoff, the channel account problem is one incident until a message gets through
  res := outbound_message(msg, 'test-key');
  assert res ->> 'channel' = 'telegram' and res ->> 'chat_id' = 'u1' and res ->> 'token' = '123:secret', res::text;
  res := mark_sent(msg, false, null, 'HTTP 502');
  assert not (res ->> 'failed')::boolean and not (res ->> 'report')::boolean, 'transient failure keeps retrying';
  assert msg in (select message_id from reconcile_outbound()) is false, 'too fresh for reconcile';
  update messages set created_at = now() - interval '1 minute' where id = msg;
  assert msg not in (select message_id from reconcile_outbound()), 'the retry waits for its backoff';
  assert (select next_attempt_at between now() + interval '29 seconds' and now() + interval '31 seconds' from messages where id = msg);
  res := mark_sent(msg, false, null, 'HTTP 429 retry after 120', false, 120);
  assert (select next_attempt_at >= now() + interval '120 seconds' from messages where id = msg), 'retry_after is respected';
  update messages set next_attempt_at = now() - interval '1 second' where id = msg;
  assert msg in (select message_id from reconcile_outbound()), 'unsent message is reconciled';
  res := mark_sent(msg, false, null, 'HTTP 401 Unauthorized', false, null, true);
  assert (res ->> 'report')::boolean and res ->> 'ref' = 'send:' || acc and not (res ->> 'failed')::boolean, res::text;
  assert (record_incident('out.send', 'Telegram sendMessage', 'x1', '401', null, res ->> 'ref', false) ->> 'alert')::boolean;
  inc := record_incident('out.send', 'Telegram sendMessage', 'x2', '401 again', null, res ->> 'ref', false);
  assert not (inc ->> 'alert')::boolean and (select repeats from incidents where id = (inc ->> 'incident_id')::bigint) = 1,
    'one open incident per account';
  update messages set next_attempt_at = null where id = msg;
  assert (mark_sent(msg, true, '999') ->> 'ok')::boolean;
  assert (select status from incidents where id = (inc ->> 'incident_id')::bigint) = 'resolved', 'a delivery resolves it';
  assert outbound_message(msg, 'test-key') is null, 'sent once';
  assert msg not in (select message_id from reconcile_outbound());
  assert (select count(*) from trace_events where type = 'msg_out' and data ->> 'message_id' = msg::text) = 1;
  msg := enqueue_message(conv, 'bot', 'will fail');
  res := mark_sent(msg, false, null, 'HTTP 403 blocked', true);
  assert (res ->> 'failed')::boolean and not (res ->> 'report')::boolean, 'a blocked recipient stops retries quietly';
  msg := enqueue_message(conv, 'bot', 'will give up');
  update messages set send_attempts = 11 where id = msg;
  res := mark_sent(msg, false, null, 'HTTP 502');
  assert (res ->> 'failed')::boolean and (res ->> 'report')::boolean, 'the last retry gives up and reports';

  -- SLA: operator silent for longer than sla_min
  perform pg_temp.say('u1', 'anyone there?');
  update conversations set awaiting_operator_since = now() - interval '11 minutes' where id = conv;
  res := claim_sla_breaches('test-key');
  assert jsonb_array_length(res) = 1 and (res -> 0 ->> 'waited_min')::int = 11, res::text;
  assert res -> 0 ->> 'topic_id' = '77' and (res -> 0 ->> 'message_id') is not null;
  assert jsonb_array_length(claim_sla_breaches('test-key')) = 0, 'one ping per wait';

  -- back to the bot
  res := return_to_bot(acc, '-1001', conv);
  assert (res ->> 'ok')::boolean and res ->> 'message_id' is not null, res::text;
  assert (select state from conversations where id = conv) = 'bot';
  assert (select returned_at is not null from escalations where id = (card ->> 'escalation_id')::uuid);
  assert (return_to_bot(acc, '-1001', conv) ->> 'already')::boolean;

  -- reminders: 24 h one with three buttons, not right after booking, once
  perform save_client_info(t1, (r ->> 'client_id')::uuid, 'Ivan', '0501234567');
  p := propose_action(t1, conv, 'book', jsonb_build_object('service', 'cleaning', 'branch', 'center',
         'start', to_char((now() + interval '20 hours') at time zone 'Europe/Kyiv', 'YYYY-MM-DD HH24:00')));
  assert (p ->> 'ok')::boolean, p::text;
  appt := (confirm_action(t1, (p ->> 'pending_id')::uuid) ->> 'appointment_id')::uuid;
  assert jsonb_array_length(claim_reminders()) = 0, 'no reminder right after booking';
  update appointments set updated_at = now() - interval '2 hours' where id = appt;
  res := claim_reminders();
  assert jsonb_array_length(res) = 1 and res -> 0 ->> 'kind' = '24h', res::text;
  assert (select jsonb_array_length(payload -> 'buttons' -> 0) from messages where id = (res -> 0 ->> 'message_id')::bigint) = 3;
  assert (select text from messages where id = (res -> 0 ->> 'message_id')::bigint) like 'Reminder: Cleaning with Dr A tomorrow%';
  assert jsonb_array_length(claim_reminders()) = 0, 'claimed once';
  update appointments set period = tstzrange(now() + interval '90 minutes', now() + interval '150 minutes') where id = appt;
  update appointments set updated_at = now() - interval '2 hours' where id = appt;
  res := claim_reminders();
  assert jsonb_array_length(res) = 1 and res -> 0 ->> 'kind' = '2h', 'moved appointment gets its reminders again';
  assert (select jsonb_array_length(payload -> 'buttons' -> 0) from messages where id = (res -> 0 ->> 'message_id')::bigint) = 3,
    'the 2 h reminder has the buttons too';

  -- calendar mirror: reconcile finds it, the version check guards concurrent edits
  update appointments set updated_at = now() - interval '1 minute' where id = appt;
  assert appt in (select appointment_id from reconcile_appointments());
  res := gcal_job(appt);
  assert res ->> 'event_id' = replace(appt::text, '-', '') and res ->> 'status' = 'booked', res::text;
  assert res -> 'event' -> 'start' ->> 'timeZone' = 'Europe/Kyiv';
  assert mark_gcal_synced(appt, now() - interval '1 day', 'cal') is null, 'stale version does not mark';
  -- a failing sync backs off and reports once, on the third failure; a later success closes the incident
  assert not (mark_gcal_failed(appt, (res ->> 'version')::timestamptz, '403') ->> 'report')::boolean;
  assert appt not in (select appointment_id from reconcile_appointments()), 'retried after its backoff';
  assert not (mark_gcal_failed(appt, (res ->> 'version')::timestamptz, '403') ->> 'report')::boolean;
  inc := mark_gcal_failed(appt, (res ->> 'version')::timestamptz, '403 Forbidden');
  assert (inc ->> 'report')::boolean and inc ->> 'ref' = 'gcal:' || appt and inc ->> 'error' like '%3 times%403 Forbidden', inc::text;
  assert (select gcal_next_at between now() + interval '3 minutes' and now() + interval '5 minutes' from appointments where id = appt);
  inc := record_incident('int.gcal', 'Sync failed', 'g1', inc ->> 'error', null, inc ->> 'ref', false);
  update appointments set gcal_next_at = now() - interval '1 second' where id = appt;
  assert appt in (select appointment_id from reconcile_appointments());
  assert mark_gcal_synced(appt, (res ->> 'version')::timestamptz, 'cal');
  assert (select gcal_attempts = 0 from appointments where id = appt);
  assert (select status from incidents where id = (inc ->> 'incident_id')::bigint) = 'resolved';
  assert appt not in (select appointment_id from reconcile_appointments());

  -- lost turns: unprocessed inbound without a live lease
  perform pg_temp.say('u1', 'lost message');
  update messages set created_at = now() - interval '1 minute' where conversation_id = conv and processed_at is null;
  assert conv in (select conversation_id from reconcile_conversations());
  update conversations set lease_until = now() + interval '1 minute' where id = conv;
  assert conv not in (select conversation_id from reconcile_conversations()), 'a live lease is left alone';

  -- incidents: every failure recorded, one alert per workflow/node per 10 minutes
  res := record_incident('core.turn', 'Agent', '101', 'boom', 'http://x');
  assert (res ->> 'alert')::boolean;
  res := record_incident('core.turn', 'Agent', '102', 'boom', 'http://x');
  assert not (res ->> 'alert')::boolean and (res ->> 'open_last_10m')::int = 2;
  assert (record_incident('core.turn', 'Other', '103', 'boom', null) ->> 'alert')::boolean;
  -- Replay: claimed once; replayed only when the retried execution succeeds
  inc := replay_claim((res ->> 'incident_id')::bigint);
  assert (inc ->> 'claimed')::boolean and inc ->> 'execution_id' = '102', inc::text;
  assert replay_claim((res ->> 'incident_id')::bigint) ->> 'text' like 'Nothing to replay: incident #% is replaying', 'double click';
  assert finish_replay((res ->> 'incident_id')::bigint, '201', 'error', null) ->> 'text' like 'Replay of incident #% failed: execution 201 ended with error.%';
  assert (select status from incidents where id = (res ->> 'incident_id')::bigint) = 'open';
  perform replay_claim((res ->> 'incident_id')::bigint);
  assert finish_replay((res ->> 'incident_id')::bigint, '202', 'success', null) ->> 'text' like '🔁 Incident #% replayed as execution 202';
  assert (select status from incidents where id = (res ->> 'incident_id')::bigint) = 'replayed';
  inc := record_incident('int.gcal', 'Sync failed', '104', 'reported', null, 'gcal:x', false);
  assert not (replay_claim((inc ->> 'incident_id')::bigint) ->> 'claimed')::boolean, 'reported problems are not replayed';

  -- a clinic without an operator (no group or no bot): no silent handoff, the client gets the clinic phone
  update channel_accounts set active = false where id = acc;
  assert tenant_bot(t1, 'test-key') is null and not tenant_has_operator(t1);
  res := escalate(conv, null, 'user_request', 'test-key');
  assert not (res ->> 'escalated')::boolean and res ->> 'reason' = 'no_operator', res::text;
  assert (select state from conversations where id = conv) = 'bot';
  assert (select text from messages where id = (res ->> 'message_id')::bigint) like 'Our administrators cannot answer%+380440000000%';
  assert (select returned_at is not null and notified_at is null from escalations where id = (res ->> 'escalation_id')::uuid);
  update escalations set created_at = now() - interval '2 minutes' where id = (res ->> 'escalation_id')::uuid;
  assert (res ->> 'escalation_id')::uuid not in (select escalation_id from reconcile_escalations()), 'no card to retry';
  -- a pending card of a clinic that lost its operator is not retried into the void (begin_turn hands the chat back)
  insert into escalations (tenant_id, conversation_id, session_id, reason, created_at)
  values (t1, conv, (r ->> 'session_id')::uuid, 'complaint', now() - interval '2 minutes');
  assert not exists (select 1 from reconcile_escalations() x join escalations e on e.id = x.escalation_id
                     where e.reason = 'complaint'), 'no card retries without an operator group';
  update channel_accounts set active = true where id = acc;
  assert exists (select 1 from reconcile_escalations() x join escalations e on e.id = x.escalation_id where e.reason = 'complaint');
  update escalations set returned_at = now() where reason = 'complaint' and returned_at is null;

  -- usage: idempotent, priced by model prefix
  assert record_llm_usage(jsonb_build_array(jsonb_build_object('tenant_id', t1, 'session_id', r ->> 'session_id',
           'execution_id', '301', 'model', 'openai/gpt-4.1-mini', 'tokens_in', 1000000, 'tokens_out', 1000000))) = 1;
  assert record_llm_usage(jsonb_build_array(jsonb_build_object('tenant_id', t1, 'execution_id', '301',
           'model', 'openai/gpt-4.1-mini', 'tokens_in', 1, 'tokens_out', 1))) = 0, 'idempotent';
  assert (select cost_usd from llm_usage where execution_id = '301') = 2.00, 'priced by model id';
  -- scan marks: a first scan looks back a day, the next one from the last scan minus the overlap
  assert (select since < now() - interval '1 day' from usage_scan_start(array['core-turn']));
  perform record_llm_usage('[]', jsonb_build_array(jsonb_build_object('workflow_id', 'core-turn', 'until', now())));
  assert (select since = now() - interval '15 minutes' from usage_scan_start(array['core-turn']));
end $$;

-- widget: poll delivers and marks sent
do $$
declare
  w   uuid := pg_temp.account('t1-widget');
  r   jsonb;
  out jsonb;
  m   bigint;
  i   int;
begin
  r := ingest_message(w, 'visitor-9', 'visitor-9', 'client-msg-1', 'Hi from the site', '{}', '{}');
  m := enqueue_message((r ->> 'conversation_id')::uuid, 'bot', 'Hello! How can I help?');
  assert m not in (select message_id from reconcile_outbound()), 'widget messages are not pushed';
  out := widget_poll(w, 'visitor-9', 0);
  assert jsonb_array_length(out) = 1 and out -> 0 ->> 'text' = 'Hello! How can I help?', out::text;
  assert (select sent_at is not null from messages where id = m);
  assert jsonb_array_length(widget_poll(w, 'visitor-9', m)) = 0, 'cursor';
  assert jsonb_array_length(widget_poll(w, 'someone-else', 0)) = 0, 'a visitor sees only their messages';

  -- the public endpoint: malformed input is refused, sessions and messages are rate limited
  assert widget_gate(w, 'poll', '1.2.3.4', 'visitor-9', '{"after": "NaN"}') = 'bad_request';
  assert widget_gate(w, 'poll', '1.2.3.4', 'visitor-9', '{"after": 12}') = 'ok';
  assert widget_gate(w, 'poll', '1.2.3.4', 'visitor-9', '"text"') = 'bad_request';
  assert widget_gate(w, 'send', '1.2.3.4', 'visitor-9', jsonb_build_object('id', repeat('x', 65))) = 'bad_request';
  assert widget_gate(w, 'send', '1.2.3.4', 'visitor-9', jsonb_build_object('callback', 'pa:' || repeat('-', 36) || ':y')) = 'bad_request';
  assert widget_gate(w, 'send', '1.2.3.4', 'visitor-9', jsonb_build_object('callback', 'ap:' || gen_random_uuid() || ':r')) = 'ok';
  for i in 2..20 loop
    assert widget_gate(w, 'send', '1.2.3.4', 'visitor-9', '{}') = 'ok';
  end loop;
  assert widget_gate(w, 'send', '1.2.3.4', 'visitor-9', '{}') = 'too_many', 'per visitor';
  assert widget_gate(w, 'send', '1.2.3.4', 'visitor-10', '{}') = 'ok';
  for i in 1..20 loop
    perform widget_gate(w, 'session', '5.6.7.8', null, '{}');
  end loop;
  assert widget_gate(w, 'session', '5.6.7.8', null, '{}') = 'too_many', 'sessions per IP';
  assert widget_gate(w, 'session', '5.6.7.9', null, '{}') = 'ok';
end $$;
