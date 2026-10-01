-- Demo history for the dashboard: 220 clients, ~6 months of sessions with messages, bookings,
-- escalations, visits (done / no-show / cancelled), reviews and LLM usage, plus upcoming
-- appointments. Seed conversations have no channel identity, so nothing is ever sent to them.
do $$
declare
  t        uuid := (select id from tenants where slug = 'demo');
  first_en text[] := array['Olena', 'Andrii', 'Iryna', 'Taras', 'Sofia', 'Dmytro', 'Kateryna', 'Oleksii', 'Anna', 'Maksym',
                            'Yulia', 'Serhii', 'Natalia', 'Viktor', 'Oksana', 'Ivan', 'Mariia', 'Pavlo', 'Tetiana', 'Roman',
                            'Daria', 'Artem', 'Alina', 'Bohdan', 'Vira', 'Denys', 'Svitlana', 'Yurii', 'Larysa', 'Mykola'];
  last_en  text[] := array['Shevchenko', 'Kovalenko', 'Bondarenko', 'Tkachenko', 'Kravchenko', 'Oliinyk', 'Shevchuk', 'Polishchuk',
                            'Lysenko', 'Moroz', 'Marchenko', 'Rudenko', 'Savchenko', 'Petrenko', 'Klymenko', 'Pavlenko',
                            'Melnyk', 'Boiko', 'Tkachuk', 'Levchenko'];
  client_q text[] := array['Hi! How much is a professional cleaning?', 'Do you work on Saturday?', 'I would like to book a check-up',
                            'Can I see Dr. Kovalenko this week?', 'How much does whitening cost?', 'I need a filling, when are you free?',
                            'Where is your Podil clinic?', 'Do you treat children?', 'I want to reschedule my visit',
                            'Is an implant consultation paid?', 'Скільки коштує чистка зубів?', 'Хочу записатися на огляд',
                            'Сколько стоит пломба?', 'Можно записаться на завтра?', 'My tooth hurts a bit when I drink cold water'];
  bot_a    text[] := array['Professional cleaning is 1800 UAH and takes about an hour. Shall I find a time?',
                            'Yes, Lumina Center is open on Saturday 10:00-16:00.', 'Sure! Which branch is more convenient, Center or Podil?',
                            'Here are the nearest free times: Tue 10:00, Wed 12:30, Thu 15:00.', 'Please confirm the booking with the button below.',
                            'Done! You are booked. See you!', 'Our Podil clinic is at 7 Kostiantynivska St, open Mon-Fri 08:00-19:00.'];
  channels text[] := array['telegram', 'telegram', 'telegram', 'widget', 'whatsapp'];
  reasons  text[] := array['user_request', 'user_request', 'complaint', 'medical', 'not_understood', 'urgent', 'tool_error'];
  svc      record;
  doc      record;
  c        uuid;
  conv     uuid;
  sess     uuid;
  i        int;
  k        int;
  n_msgs   int;
  ts       timestamptz;
  msg_at   timestamptz;
  visit    timestamptz;
  booked   boolean;
  st       text;
  lang     text;
begin
  perform setseed(0.42);
  for i in 1..220 loop
    lang := (array['uk', 'uk', 'uk', 'ru', 'en'])[1 + floor(random() * 5)::int];
    insert into clients (tenant_id, name, phone, lang, created_at)
    values (t, first_en[1 + floor(random() * array_length(first_en, 1))::int] || ' ' || last_en[1 + floor(random() * array_length(last_en, 1))::int],
            '+38050' || lpad((1000000 + i * 3571)::text, 7, '0'), lang, now() - make_interval(days => 180 + floor(random() * 540)::int))
    returning id into c;
    insert into conversations (tenant_id, client_id, created_at) values (t, c, now() - interval '200 days') returning id into conv;

    -- 1-12 sessions over the last 180 days
    for k in 1..(1 + floor(random() * random() * 12)::int) loop
      ts := now() - make_interval(days => floor(random() * 180)::int, hours => floor(random() * 11)::int, mins => floor(random() * 60)::int);
      ts := date_trunc('day', ts at time zone 'Europe/Kyiv') at time zone 'Europe/Kyiv' + make_interval(hours => 8 + floor(random() * 13)::int, mins => floor(random() * 60)::int);
      insert into sessions (tenant_id, conversation_id, channel, started_at, last_message_at)
      values (t, conv, channels[1 + floor(random() * 5)::int], ts, ts) returning id into sess;

      n_msgs := 1 + floor(random() * 4)::int;
      msg_at := ts;
      for j in 1..n_msgs loop
        insert into messages (tenant_id, conversation_id, session_id, direction, author, text, created_at, processed_at)
        values (t, conv, sess, 'in', 'client', client_q[1 + floor(random() * array_length(client_q, 1))::int], msg_at, msg_at);
        msg_at := msg_at + make_interval(secs => 1.2 + random() * 3 + case when random() < 0.04 then 4 else 0 end);
        insert into messages (tenant_id, conversation_id, session_id, direction, author, text, created_at, sent_at, send_attempts)
        values (t, conv, sess, 'out', 'bot', bot_a[1 + floor(random() * array_length(bot_a, 1))::int], msg_at - interval '0.3 seconds', msg_at, 1);
        insert into llm_usage (tenant_id, session_id, execution_id, model, tokens_in, tokens_out, cost_usd, created_at)
        values (t, sess, 'seed-' || sess || '-' || j, 'openai/gpt-4.1-mini', 1800 + floor(random() * 2500)::int, 40 + floor(random() * 160)::int, 0, msg_at);
        msg_at := msg_at + make_interval(secs => 20 + random() * 300);
      end loop;
      update sessions set last_message_at = msg_at where id = sess;

      if random() < 0.12 then
        insert into escalations (tenant_id, conversation_id, session_id, reason, created_at, notified_at, first_reply_at, returned_at, summary)
        values (t, conv, sess, reasons[1 + floor(random() * array_length(reasons, 1))::int], msg_at, msg_at + interval '3 seconds',
                case when random() < 0.9 then msg_at + make_interval(mins => 1 + floor(random() * 25)::int) end,
                msg_at + make_interval(mins => 30 + floor(random() * 120)::int), 'Seeded escalation.');
      end if;

      booked := random() < 0.38;
      if booked then
        select * into svc from services where tenant_id = t and active order by random() limit 1;
        select d.*, s.branch_id, s.weekday, s.start_time into doc
        from doctor_schedules s join doctors d on d.id = s.doctor_id join doctor_services ds on ds.doctor_id = d.id and ds.service_id = svc.id
        where s.tenant_id = t order by random() limit 1;
        if found then
          visit := ((ts at time zone 'Europe/Kyiv')::date + 1 + floor(random() * 14)::int + doc.start_time
                    + make_interval(hours => floor(random() * 4)::int)) at time zone 'Europe/Kyiv';
          st := case when visit > now() then 'booked'
                     when random() < 0.08 then 'no_show' when random() < 0.12 then 'cancelled' else 'done' end;
          insert into appointments (tenant_id, client_id, doctor_id, branch_id, service_id, period, status, source, price,
                                    created_at, updated_at, gcal_synced_at, reminder_24h_sent_at, reminder_2h_sent_at, followup_sent_at, review_score)
          values (t, c, doc.id, doc.branch_id, svc.id, tstzrange(visit, visit + make_interval(mins => svc.duration_min)), st, 'seed', svc.price,
                  ts, ts, case when visit < now() then visit end, case when visit < now() then visit - interval '24 hours' end,
                  case when visit < now() then visit - interval '2 hours' end, case when visit < now() then visit + interval '3 hours' end,
                  case when st = 'done' and random() < 0.45 then (array[5, 5, 5, 4, 4, 3, 2])[1 + floor(random() * 7)::int] end)
          on conflict do nothing;
        end if;
      end if;
    end loop;
  end loop;
  -- seeded usage priced like live usage
  update llm_usage u set cost_usd = u.tokens_in * p.usd_per_mtok_in / 1e6 + u.tokens_out * p.usd_per_mtok_out / 1e6
  from llm_prices p where u.execution_id like 'seed-%' and p.model_prefix = 'gpt-4.1-mini';
end $$;
