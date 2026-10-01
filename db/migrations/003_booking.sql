-- Prompt context, slots and the two-step change flow: the LLM proposes (pending_actions),
-- the client confirms with a button or in words, SQL applies. Tools address things by slug
-- (services, branches, doctors) and by ref A1, A2... (the client's upcoming appointments).

-- The client a conversation acts for; follows a P1 merge done earlier in the same turn.
create function conversation_client(p_conversation uuid) returns clients language sql stable as $$
  select c.* from conversations cv
  join clients m on m.id = cv.client_id
  join clients c on c.id = coalesce(m.merged_into, m.id)
  where cv.id = p_conversation
$$;

create function money_text(p_price numeric, p_currency text) returns text language sql immutable as $$
  select trim_scale(p_price)::text || ' ' || coalesce(p_currency, '')
$$;

-- {"mon": "09:00-20:00", "sun": null} -> "Mon 09:00-20:00, ..., Sun closed"
create function hours_text(p_hours jsonb) returns text language sql immutable as $$
  select string_agg(initcap(d) || ' ' || coalesce(nullif(p_hours ->> d, ''), 'closed'), ', ' order by n)
  from unnest(array['mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun']) with ordinality as x(d, n)
$$;

-- Structured tenant data goes to the system prompt whole: it is small and must be exact (no RAG).
create function tenant_prompt(p_tenant uuid) returns text language sql stable as $$
  select concat_ws(E'\n',
    'Clinic: ' || t.name || '. Timezone: ' || t.timezone || '.',
    t.config ->> 'about',
    'Tone of voice: ' || (t.config ->> 'tone'),
    'Emergency phone: ' || coalesce(t.config ->> 'emergency_phone', '112') || '.',
    '',
    'Branches (slug: name, address, phone, opening hours):',
    (select string_agg(format('- %s: %s, %s, tel %s. Hours: %s', b.slug, b.name, coalesce(b.address, '-'),
                              coalesce(b.phone, '-'), hours_text(b.hours)), E'\n' order by b.slug)
     from branches b where b.tenant_id = t.id),
    '',
    'Services (slug: name, price, duration). These are the only services and prices:',
    (select string_agg(format('- %s: %s, %s%s, %s min.%s', s.slug, s.name, coalesce(s.price_note || ' ', ''),
                              money_text(s.price, s.currency), s.duration_min,
                              coalesce(' ' || s.description, '')), E'\n' order by s.name)
     from services s where s.tenant_id = t.id and s.active),
    '',
    'Doctors (slug: name, specialty; services; schedule):',
    (select string_agg(format('- %s: %s, %s. Services: %s. Works: %s', d.slug, d.name, coalesce(d.specialty, '-'),
                              coalesce((select string_agg(s.slug, ', ' order by s.slug)
                                        from doctor_services ds join services s on s.tenant_id = ds.tenant_id and s.id = ds.service_id
                                        where ds.tenant_id = d.tenant_id and ds.doctor_id = d.id and s.active), '-'),
                              coalesce((select string_agg(x.txt, '; ' order by x.branch)
                                        from (select b.slug as branch, b.slug || ' ' || string_agg(
                                                       initcap((array['mon','tue','wed','thu','fri','sat','sun'])[ds2.weekday])
                                                       || ' ' || to_char(ds2.start_time, 'HH24:MI') || '-' || to_char(ds2.end_time, 'HH24:MI'),
                                                       ', ' order by ds2.weekday) as txt
                                              from doctor_schedules ds2 join branches b on b.tenant_id = ds2.tenant_id and b.id = ds2.branch_id
                                              where ds2.tenant_id = d.tenant_id and ds2.doctor_id = d.id
                                              group by b.slug) x), '-')
                              ) || coalesce('. ' || d.bio, ''), E'\n' order by d.name)
     from doctors d where d.tenant_id = t.id and d.active))
  from tenants t where t.id = p_tenant
$$;

-- The client's upcoming booked appointments, numbered A1, A2... by start time.
create function client_upcoming(p_client uuid)
returns table (ref text, id uuid, tenant_id uuid, period tstzrange, service text, service_slug text, doctor text,
               branch text, address text, tz text, confirmed boolean)
language sql stable as $$
  select 'A' || row_number() over (order by lower(a.period), a.id), a.id, a.tenant_id, a.period, s.name, s.slug,
         d.name, b.name, b.address, tenant_tz(a.tenant_id, a.branch_id), a.confirmed_at is not null
  from appointments a
  join services s on s.tenant_id = a.tenant_id and s.id = a.service_id
  join doctors d on d.tenant_id = a.tenant_id and d.id = a.doctor_id
  join branches b on b.tenant_id = a.tenant_id and b.id = a.branch_id
  where a.client_id = p_client and a.status = 'booked' and lower(a.period) > now()
$$;

create function client_prompt(p_client uuid, p_conversation uuid) returns text language sql stable as $$
  select concat_ws(E'\n',
    format('Client: name %s, phone %s.', coalesce(c.name, 'unknown'), coalesce(c.phone, 'unknown')),
    'Notes from earlier conversations: ' || c.summary,
    'Upcoming appointments (use the ref to reschedule or cancel):',
    coalesce((select string_agg(format('- %s: %s, %s, %s, %s%s', u.ref, fmt_when(lower(u.period), u.tz, 'en'),
                                       u.service, u.doctor, u.branch,
                                       case when u.confirmed then ' (client confirmed attendance)' else '' end),
                                E'\n' order by u.ref)
              from client_upcoming(c.id) u), '- none'),
    'Past visits:',
    coalesce((select string_agg(x.line, E'\n')
              from (select format('- %s: %s (%s)', to_char(lower(a.period) at time zone tenant_tz(a.tenant_id, a.branch_id), 'YYYY-MM-DD'),
                                  s.name, a.status) as line
                    from appointments a join services s on s.tenant_id = a.tenant_id and s.id = a.service_id
                    where a.client_id = c.id and lower(a.period) <= now()
                    order by lower(a.period) desc limit 3) x), '- none'),
    coalesce('Open proposal waiting for the client''s confirmation (buttons were shown): ' ||
             (select pa.summary from pending_actions pa
              where pa.conversation_id = p_conversation and pa.status = 'pending' and pa.expires_at > now()
              order by pa.created_at desc limit 1)
             || '. If the client agrees in words, call confirm_action.',
             'No open proposals.'))
  from clients c where c.id = p_client
$$;

-- Free start times: doctor shifts at the branch minus booked appointments, on the tenant's slot grid.
create function available_slots(
  p_tenant uuid, p_service uuid, p_branch uuid, p_doctor uuid, p_from timestamptz, p_to timestamptz,
  p_ignore_appointment uuid default null
) returns table (doctor_id uuid, starts_at timestamptz, ends_at timestamptz)
language sql stable as $$
  with cfg as (
    select make_interval(mins => s.duration_min) as dur,
           make_interval(mins => coalesce((t.config -> 'booking' ->> 'slot_step_min')::int, 30)) as step,
           greatest(p_from, now() + make_interval(mins => coalesce((t.config -> 'booking' ->> 'lead_min')::int, 60))) as from_ts
    from services s join tenants t on t.id = s.tenant_id
    where s.tenant_id = p_tenant and s.id = p_service and s.active
  )
  select distinct on (g.ts) d.id, g.ts, g.ts + cfg.dur
  from cfg
  join doctor_services ds on ds.tenant_id = p_tenant and ds.service_id = p_service
  join doctors d on d.tenant_id = p_tenant and d.id = ds.doctor_id and d.active and (p_doctor is null or d.id = p_doctor)
  join doctor_shifts sh on sh.tenant_id = p_tenant and sh.doctor_id = d.id and sh.branch_id = p_branch
                       and sh.period && tstzrange(cfg.from_ts, p_to)
  cross join lateral generate_series(lower(sh.period), upper(sh.period) - cfg.dur, cfg.step) g(ts)
  where g.ts >= cfg.from_ts and g.ts < p_to
    and not exists (select 1 from appointments a
                    where a.tenant_id = p_tenant and a.doctor_id = d.id and a.status = 'booked'
                      and a.period && tstzrange(g.ts, g.ts + cfg.dur)
                      and a.id is distinct from p_ignore_appointment)
  order by g.ts, d.name
$$;

-- slug -> row helpers for tools; unknown slugs return null
create function service_by_slug(p_tenant uuid, p_slug text) returns services language sql stable as $$
  select * from services where tenant_id = p_tenant and slug = lower(trim(p_slug)) and active
$$;
create function branch_by_slug(p_tenant uuid, p_slug text) returns branches language sql stable as $$
  select * from branches where tenant_id = p_tenant and slug = lower(trim(p_slug))
$$;
create function doctor_by_slug(p_tenant uuid, p_slug text) returns doctors language sql stable as $$
  select * from doctors where tenant_id = p_tenant and slug = lower(trim(p_slug)) and active
$$;

create function slugs_hint(p_tenant uuid, p_what text) returns text language sql stable as $$
  select 'Known ' || p_what || ': ' || coalesce(case p_what
    when 'services' then (select string_agg(slug, ', ' order by slug) from services where tenant_id = p_tenant and active)
    when 'branches' then (select string_agg(slug, ', ' order by slug) from branches where tenant_id = p_tenant)
    when 'doctors' then (select string_agg(slug, ', ' order by slug) from doctors where tenant_id = p_tenant and active)
  end, '-') || '.'
$$;

-- Tool find_slots. Dates are local 'YYYY-MM-DD'; default: the next 7 days. At most 8 evenly
-- spread start times per day keep the answer short.
create function find_slots(p_tenant uuid, p_service text, p_branch text, p_doctor text default null,
                           p_date_from text default null, p_date_to text default null) returns jsonb
language plpgsql stable as $$
declare
  v_service services := service_by_slug(p_tenant, p_service);
  v_branch  branches := branch_by_slug(p_tenant, p_branch);
  v_doctor  doctors;
  v_tz      text;
  v_from    date;
  v_to      date;
  v_text    text;
begin
  if v_service.id is null then
    return jsonb_build_object('ok', false, 'error', format('Unknown service "%s". %s', p_service, slugs_hint(p_tenant, 'services')));
  end if;
  if v_branch.id is null then
    return jsonb_build_object('ok', false, 'error', format('Unknown branch "%s". %s', p_branch, slugs_hint(p_tenant, 'branches')));
  end if;
  if nullif(trim(p_doctor), '') is not null then
    v_doctor := doctor_by_slug(p_tenant, p_doctor);
    if v_doctor.id is null then
      return jsonb_build_object('ok', false, 'error', format('Unknown doctor "%s". %s', p_doctor, slugs_hint(p_tenant, 'doctors')));
    end if;
    if not exists (select 1 from doctor_services where tenant_id = p_tenant and doctor_id = v_doctor.id and service_id = v_service.id) then
      return jsonb_build_object('ok', false, 'error', format('%s does not provide %s.', v_doctor.name, v_service.name));
    end if;
  end if;

  v_tz := tenant_tz(p_tenant, v_branch.id);
  begin
    v_from := coalesce(nullif(trim(p_date_from), '')::date, (now() at time zone v_tz)::date);
    v_to := coalesce(nullif(trim(p_date_to), '')::date, v_from + 6);
  exception when others then
    return jsonb_build_object('ok', false, 'error', 'Dates must be YYYY-MM-DD.');
  end;
  v_to := least(greatest(v_to, v_from), v_from + 27);

  select string_agg(day_line, E'\n' order by day) into v_text
  from (
    select day, to_char(day, 'YYYY-MM-DD') || ' ' || to_char(day, 'Dy') || ': '
                || string_agg(to_char(local_ts, 'HH24:MI') || ' ' || doctor_slug, ', ' order by local_ts) as day_line
    from (
      select s.starts_at at time zone v_tz as local_ts, (s.starts_at at time zone v_tz)::date as day, d.slug as doctor_slug,
             row_number() over (partition by (s.starts_at at time zone v_tz)::date order by s.starts_at) as rn,
             count(*) over (partition by (s.starts_at at time zone v_tz)::date) as cnt
      from available_slots(p_tenant, v_service.id, v_branch.id, v_doctor.id,
                           v_from::timestamp at time zone v_tz, (v_to + 1)::timestamp at time zone v_tz) s
      join doctors d on d.tenant_id = p_tenant and d.id = s.doctor_id
    ) x
    where (rn - 1) % greatest(1, ceil(cnt / 8.0)::int) = 0
    group by day
  ) days;

  if v_text is null then
    return jsonb_build_object('ok', true, 'result',
      format('No free time for %s at %s between %s and %s. Try other dates, another branch or doctor.',
             v_service.name, v_branch.name, v_from, v_to));
  end if;
  return jsonb_build_object('ok', true, 'result',
    format(E'Free start times for %s (%s min, %s) at %s, local time, format "time doctor":\n%s\n'
           'Offer a few options. To book, call propose_booking with start "YYYY-MM-DD HH:MM" and the doctor.',
           v_service.name, v_service.duration_min, money_text(v_service.price, v_service.currency), v_branch.name, v_text));
end $$;

-- Tools propose_booking / propose_reschedule / propose_cancel: validate, then store a pending
-- action (the older open one expires). Nothing changes until the client confirms.
create function propose_action(p_tenant uuid, p_conversation uuid, p_kind text, p_args jsonb) returns jsonb
language plpgsql as $$
declare
  v_conv    conversations;
  v_client  clients;
  v_service services;
  v_branch  branches;
  v_doctor  doctors;
  v_appt    record;
  v_appt_id uuid;
  v_tz      text;
  v_start   timestamptz;
  v_slot    record;
  v_payload jsonb;
  v_summary text;
  v_id      uuid;
begin
  select * into v_conv from conversations where tenant_id = p_tenant and id = p_conversation;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'Conversation not found.');
  end if;
  v_client := conversation_client(p_conversation);

  if p_kind in ('reschedule', 'cancel') then
    select * into v_appt from client_upcoming(v_client.id) u where u.ref = upper(trim(p_args ->> 'appointment'));
    if not found then
      return jsonb_build_object('ok', false, 'error',
        format('No upcoming appointment "%s". Use a ref from the client''s upcoming appointments list.', p_args ->> 'appointment'));
    end if;
    v_appt_id := v_appt.id;
  end if;

  if p_kind = 'cancel' then
    v_payload := jsonb_build_object('appointment_id', v_appt.id);
    v_summary := format('Cancel %s: %s, %s, %s', v_appt.ref, fmt_when(lower(v_appt.period), v_appt.tz, 'en'), v_appt.service, v_appt.doctor);
  else
    if v_client.name is null or v_client.phone is null then
      return jsonb_build_object('ok', false, 'error',
        'Missing client name or phone. Ask for them and save them with save_client_info before proposing.');
    end if;

    if p_kind = 'book' then
      v_service := service_by_slug(p_tenant, p_args ->> 'service');
      v_branch := branch_by_slug(p_tenant, p_args ->> 'branch');
      if v_service.id is null then
        return jsonb_build_object('ok', false, 'error', format('Unknown service "%s". %s', p_args ->> 'service', slugs_hint(p_tenant, 'services')));
      end if;
      if v_branch.id is null then
        return jsonb_build_object('ok', false, 'error', format('Unknown branch "%s". %s', p_args ->> 'branch', slugs_hint(p_tenant, 'branches')));
      end if;
    else  -- reschedule keeps service and branch
      select s.* into v_service from appointments a join services s on s.tenant_id = a.tenant_id and s.id = a.service_id where a.id = v_appt_id;
      select b.* into v_branch from appointments a join branches b on b.tenant_id = a.tenant_id and b.id = a.branch_id where a.id = v_appt_id;
    end if;

    if nullif(trim(p_args ->> 'doctor'), '') is not null then
      v_doctor := doctor_by_slug(p_tenant, p_args ->> 'doctor');
      if v_doctor.id is null then
        return jsonb_build_object('ok', false, 'error', format('Unknown doctor "%s". %s', p_args ->> 'doctor', slugs_hint(p_tenant, 'doctors')));
      end if;
    end if;

    v_tz := tenant_tz(p_tenant, v_branch.id);
    begin
      v_start := (trim(p_args ->> 'start'))::timestamp at time zone v_tz;
    exception when others then
      return jsonb_build_object('ok', false, 'error', 'start must be local time "YYYY-MM-DD HH:MM".');
    end;
    if v_start is null then
      return jsonb_build_object('ok', false, 'error', 'start must be local time "YYYY-MM-DD HH:MM".');
    end if;

    select * into v_slot from available_slots(p_tenant, v_service.id, v_branch.id, v_doctor.id, v_start, v_start + interval '1 second',
                                              v_appt_id)
    where starts_at = v_start limit 1;
    if not found then
      return jsonb_build_object('ok', false, 'error',
        format('%s is not a free slot for %s at %s%s. Call find_slots and offer times from its answer.',
               to_char(v_start at time zone v_tz, 'YYYY-MM-DD HH24:MI'), v_service.name, v_branch.name,
               coalesce(' with ' || v_doctor.name, '')));
    end if;
    select * into v_doctor from doctors where tenant_id = p_tenant and id = v_slot.doctor_id;

    v_payload := jsonb_build_object('service_id', v_service.id, 'branch_id', v_branch.id, 'doctor_id', v_doctor.id,
                                    'starts_at', v_slot.starts_at, 'ends_at', v_slot.ends_at,
                                    'price', v_service.price, 'reason', left(p_args ->> 'reason', 300),
                                    'appointment_id', v_appt_id);
    if p_kind = 'book' then
      v_summary := format('Book %s (%s, %s min) with %s at %s, %s, on %s', v_service.name,
                          money_text(v_service.price, v_service.currency), v_service.duration_min, v_doctor.name,
                          v_branch.name, coalesce(v_branch.address, ''), fmt_when(v_slot.starts_at, v_tz, 'en'));
    else  -- record fields may only be touched once the record is assigned
      v_summary := format('Move %s (%s, %s) to %s with %s', v_appt.ref, v_service.name, fmt_when(lower(v_appt.period), v_tz, 'en'),
                          fmt_when(v_slot.starts_at, v_tz, 'en'), v_doctor.name);
    end if;
  end if;

  update pending_actions set status = 'expired', resolved_at = now()
  where conversation_id = p_conversation and status = 'pending';
  insert into pending_actions (tenant_id, conversation_id, kind, payload, summary)
  values (p_tenant, p_conversation, p_kind, v_payload, v_summary)
  returning id into v_id;

  return jsonb_build_object('ok', true, 'pending_id', v_id, 'result',
    'Proposed: ' || v_summary || '. The client now sees Confirm / Cancel buttons under your reply. '
    'Ask them to confirm; do not say it is done.');
end $$;

-- Apply a pending action. Idempotent: a second confirm returns the first result. A slot taken
-- in the meantime surfaces as slot_taken via the exclusion constraint.
create function confirm_action(p_tenant uuid, p_pending_id uuid) returns jsonb language plpgsql as $$
declare
  v_pa      pending_actions;
  v_client  clients;
  v_appt    appointments;
  v_lang    text;
  v_args    jsonb;
  v_result  jsonb;
begin
  select * into v_pa from pending_actions where tenant_id = p_tenant and id = p_pending_id for update;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'not_found');
  end if;
  v_client := conversation_client(v_pa.conversation_id);
  v_lang := v_client.lang;

  if v_pa.status = 'confirmed' then
    return v_pa.result || jsonb_build_object('already', true);
  end if;
  if v_pa.status <> 'pending' then
    return jsonb_build_object('ok', false, 'error', v_pa.status,
                              'reply', t(case when v_pa.status = 'failed' then 'slot_taken' else 'expired' end, v_lang));
  end if;
  if v_pa.expires_at < now() or (v_pa.kind <> 'cancel' and (v_pa.payload ->> 'starts_at')::timestamptz <= now()) then
    update pending_actions set status = 'expired', resolved_at = now() where id = v_pa.id;
    return jsonb_build_object('ok', false, 'error', 'expired', 'reply', t('expired', v_lang));
  end if;

  begin
    case v_pa.kind
      when 'book' then
        insert into appointments (tenant_id, client_id, doctor_id, branch_id, service_id, period, reason, price)
        values (p_tenant, v_client.id, (v_pa.payload ->> 'doctor_id')::uuid, (v_pa.payload ->> 'branch_id')::uuid,
                (v_pa.payload ->> 'service_id')::uuid,
                tstzrange((v_pa.payload ->> 'starts_at')::timestamptz, (v_pa.payload ->> 'ends_at')::timestamptz),
                v_pa.payload ->> 'reason', (v_pa.payload ->> 'price')::numeric)
        returning * into v_appt;
      when 'reschedule' then
        update appointments
        set period = tstzrange((v_pa.payload ->> 'starts_at')::timestamptz, (v_pa.payload ->> 'ends_at')::timestamptz),
            doctor_id = (v_pa.payload ->> 'doctor_id')::uuid
        where tenant_id = p_tenant and id = (v_pa.payload ->> 'appointment_id')::uuid
          and client_id = v_client.id and status = 'booked'
        returning * into v_appt;
      when 'cancel' then
        update appointments set status = 'cancelled'
        where tenant_id = p_tenant and id = (v_pa.payload ->> 'appointment_id')::uuid
          and client_id = v_client.id and status = 'booked'
        returning * into v_appt;
    end case;
  exception when exclusion_violation then
    update pending_actions set status = 'failed', resolved_at = now(), result = '{"error": "slot_taken"}' where id = v_pa.id;
    return jsonb_build_object('ok', false, 'error', 'slot_taken', 'reply', t('slot_taken', v_lang));
  end;

  if v_appt.id is null then
    update pending_actions set status = 'failed', resolved_at = now(), result = '{"error": "not_found"}' where id = v_pa.id;
    return jsonb_build_object('ok', false, 'error', 'not_found', 'reply', t('not_found', v_lang));
  end if;

  select jsonb_build_object('service', s.name, 'doctor', d.name, 'branch', b.name, 'address', coalesce(b.address, ''),
                            'when', fmt_when(lower(v_appt.period), tenant_tz(p_tenant, b.id), v_lang))
  into v_args
  from services s, doctors d, branches b
  where s.id = v_appt.service_id and d.id = v_appt.doctor_id and b.id = v_appt.branch_id;

  v_result := jsonb_build_object(
    'ok', true, 'kind', v_pa.kind, 'appointment_id', v_appt.id,
    'reply', t(case v_pa.kind when 'book' then 'booked' when 'reschedule' then 'rescheduled' else 'cancelled' end, v_lang, v_args),
    'result', case v_pa.kind when 'book' then 'Booked: ' when 'reschedule' then 'Moved: ' else 'Cancelled: ' end || v_pa.summary);
  update pending_actions set status = 'confirmed', resolved_at = now(), result = v_result where id = v_pa.id;
  return v_result;
end $$;

-- Button pa:<id>:y|n. The pending action must belong to this conversation.
create function resolve_pending(p_tenant uuid, p_conversation uuid, p_pending_id uuid, p_decision text) returns jsonb
language plpgsql as $$
declare
  v_pa   pending_actions;
  v_lang text;
begin
  select * into v_pa from pending_actions where tenant_id = p_tenant and id = p_pending_id and conversation_id = p_conversation;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'not_found', 'reply', t('expired', null));
  end if;
  if p_decision = 'y' then
    return confirm_action(p_tenant, p_pending_id);
  end if;
  v_lang := (conversation_client(p_conversation)).lang;
  if v_pa.status <> 'pending' then
    return jsonb_build_object('ok', false, 'error', v_pa.status,
                              'reply', t(case when v_pa.status = 'confirmed' then 'already_done' else 'expired' end, v_lang));
  end if;
  update pending_actions set status = 'rejected', resolved_at = now() where id = p_pending_id;
  return jsonb_build_object('ok', true, 'kind', 'rejected', 'reply', t('rejected', v_lang));
end $$;

-- Tool confirm_action: the client agreed in words. Only a proposal the client could see counts: it must be
-- older than the client messages this turn answers (they stay unprocessed until finish_turn), so neither the
-- model within one turn nor a "yes" sent before the proposal was shown can confirm it.
create function confirm_open_action(p_tenant uuid, p_conversation uuid, p_turn_started_at timestamptz) returns jsonb
language plpgsql as $$
declare
  v_id uuid;
  v_before timestamptz := least(p_turn_started_at,
    (select min(created_at) from messages
     where conversation_id = p_conversation and direction = 'in' and processed_at is null));
begin
  select id into v_id from pending_actions
  where tenant_id = p_tenant and conversation_id = p_conversation and status = 'pending'
    and created_at < v_before and expires_at > now()
  order by created_at desc limit 1;
  if v_id is null then
    return jsonb_build_object('ok', false, 'error',
      'Nothing to confirm: there is no open proposal from an earlier message. Propose first and let the client confirm.');
  end if;
  return confirm_action(p_tenant, v_id);
end $$;

-- Reminder buttons ap:<appt>:c (I'll come) and ap:<appt>:x (cancel -> asks for confirmation).
create function appointment_action(p_tenant uuid, p_conversation uuid, p_appointment uuid, p_action text) returns jsonb
language plpgsql as $$
declare
  v_client clients;
  v_u      record;
  v_prop   jsonb;
begin
  v_client := conversation_client(p_conversation);
  if v_client.tenant_id is distinct from p_tenant then
    return jsonb_build_object('ok', false, 'error', 'not_found', 'reply', t('not_found', null));
  end if;
  select * into v_u from client_upcoming(v_client.id) u where u.id = p_appointment;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'not_found', 'reply', t('not_found', v_client.lang));
  end if;
  if p_action = 'c' then
    update appointments set confirmed_at = now() where id = p_appointment;
    return jsonb_build_object('ok', true, 'kind', 'attend',
                              'reply', t('attend_ok', v_client.lang, jsonb_build_object('when', fmt_when(lower(v_u.period), v_u.tz, v_client.lang))));
  end if;
  v_prop := propose_action(p_tenant, p_conversation, 'cancel', jsonb_build_object('appointment', v_u.ref));
  if not (v_prop ->> 'ok')::boolean then
    return v_prop || jsonb_build_object('reply', t('not_found', v_client.lang));
  end if;
  return jsonb_build_object('ok', true, 'kind', 'cancel_ask', 'pending_id', v_prop ->> 'pending_id',
                            'reply', t('cancel_ask', v_client.lang,
                                       jsonb_build_object('service', v_u.service, 'when', fmt_when(lower(v_u.period), v_u.tz, v_client.lang))));
end $$;

-- P1: glue a client to the one who proved the same phone. Identities, appointments and open
-- proposals move; the old conversation history stays where it is.
create function merge_clients(p_tenant uuid, p_from uuid, p_into uuid) returns void language plpgsql as $$
begin
  update client_identities set client_id = p_into where tenant_id = p_tenant and client_id = p_from;
  update appointments set client_id = p_into where tenant_id = p_tenant and client_id = p_from;
  update clients c set name = coalesce(c.name, f.name), lang = coalesce(f.lang, c.lang)
  from clients f where c.tenant_id = p_tenant and c.id = p_into and f.id = p_from;
  update clients set merged_into = p_into, phone = null, phone_verified = false where tenant_id = p_tenant and id = p_from;
end $$;

-- ingest_message: the channel proved that this client owns p_phone (WhatsApp sender, own Telegram contact).
-- Another profile that proved the same number is the same person: glue into it. Returns the client to use.
create function glue_verified_phone(p_tenant uuid, p_client uuid, p_phone text) returns uuid language plpgsql as $$
declare
  v_phone text := normalize_phone(p_phone);
  v_other uuid;
begin
  if v_phone is null then
    return p_client;
  end if;
  select id into v_other from clients
  where tenant_id = p_tenant and phone = v_phone and phone_verified and merged_into is null and id <> p_client;
  if v_other is not null then
    perform merge_clients(p_tenant, p_client, v_other);
    return v_other;
  end if;
  update clients set phone = v_phone, phone_verified = true
  where tenant_id = p_tenant and id = p_client and (phone is distinct from v_phone or not phone_verified);
  return p_client;
end $$;

-- Tool save_client_info. A phone typed in the chat proves nothing: it is stored on this client only, even when
-- another profile has it (never glued, never reported to the model); the operator card flags the duplicate.
create function save_client_info(p_tenant uuid, p_client uuid, p_name text, p_phone text) returns jsonb
language plpgsql as $$
declare
  v_phone text;
begin
  if nullif(trim(p_phone), '') is not null then
    v_phone := normalize_phone(p_phone);
    if v_phone is null then
      return jsonb_build_object('ok', false, 'error', 'Invalid phone number, ask the client to check it (e.g. +380501234567).');
    end if;
  end if;
  update clients
  set name = coalesce(nullif(trim(p_name), ''), name), phone = coalesce(v_phone, phone),
      phone_verified = phone_verified and (v_phone is null or v_phone = phone)
  where tenant_id = p_tenant and id = p_client;
  return jsonb_build_object('ok', true, 'result', 'Saved.');
end $$;
