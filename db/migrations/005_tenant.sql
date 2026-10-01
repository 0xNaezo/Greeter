-- Clinic onboarding from config (tenants/<slug>/tenant.json) and the shift calendar.

-- Materialize weekly doctor schedules into shifts for the next p_days days. Idempotent:
-- existing shifts win through the exclusion constraint.
create function ensure_shifts(p_days int default 28, p_tenant uuid default null) returns int
language sql as $$
  with ins as (
    insert into doctor_shifts (tenant_id, doctor_id, branch_id, period)
    select s.tenant_id, s.doctor_id, s.branch_id,
           tstzrange((d.day + s.start_time) at time zone z.tz, (d.day + s.end_time) at time zone z.tz)
    from doctor_schedules s
    join doctors doc on doc.tenant_id = s.tenant_id and doc.id = s.doctor_id and doc.active
    cross join lateral (select tenant_tz(s.tenant_id, s.branch_id) as tz) z
    cross join lateral (select g::date as day
                        from generate_series((now() at time zone z.tz)::date, (now() at time zone z.tz)::date + p_days,
                                             interval '1 day') g) d
    where extract(isodow from d.day) = s.weekday
      and (p_tenant is null or s.tenant_id = p_tenant)
      and (d.day + s.end_time) at time zone z.tz > now()
    on conflict do nothing
    returning 1
  )
  select count(*)::int from ins
$$;

-- Create or update a clinic from its config document. Doctors and services missing from the
-- document are deactivated (appointments keep referencing them); future shifts are rebuilt from
-- the schedules. Channel tokens are stored encrypted with p_key. Channel accounts missing from the
-- document are deactivated too, for the channel kinds it lists.
create function upsert_tenant(p_doc jsonb, p_key text) returns jsonb language plpgsql as $$
declare
  v_id       uuid;
  v_tz       text := coalesce(p_doc ->> 'timezone', 'Europe/Kyiv');
  v_old_chat text := (select config -> 'operator' ->> 'chat_id' from tenants where slug = p_doc ->> 'slug');
  v_channels jsonb;
  c          jsonb;
begin
  if coalesce(p_doc ->> 'slug', '') !~ '^[a-z0-9][a-z0-9-]{1,39}$' then
    raise exception 'tenant slug must match ^[a-z0-9][a-z0-9-]{1,39}$, got "%"', p_doc ->> 'slug';
  end if;
  if not exists (select 1 from pg_timezone_names where name = v_tz) then
    raise exception 'unknown timezone "%"', v_tz;
  end if;

  insert into tenants (slug, name, timezone, llm_profile, config)
  values (p_doc ->> 'slug', coalesce(p_doc ->> 'name', p_doc ->> 'slug'), v_tz,
          coalesce(p_doc ->> 'llm_profile', 'openrouter'), coalesce(p_doc -> 'config', '{}'))
  on conflict (slug) do update
  set name = excluded.name, timezone = excluded.timezone, llm_profile = excluded.llm_profile, config = excluded.config
  returning id into v_id;

  insert into branches (tenant_id, slug, name, address, phone, timezone, hours, calendar_id)
  select v_id, b ->> 'slug', b ->> 'name', b ->> 'address', b ->> 'phone', b ->> 'timezone',
         coalesce(b -> 'hours', '{}'), nullif(b ->> 'calendar_id', '')
  from jsonb_array_elements(coalesce(p_doc -> 'branches', '[]')) b
  on conflict (tenant_id, slug) do update
  set name = excluded.name, address = excluded.address, phone = excluded.phone, timezone = excluded.timezone,
      hours = excluded.hours, calendar_id = excluded.calendar_id;

  insert into services (tenant_id, slug, name, description, price, price_note, currency, duration_min, active)
  select v_id, s ->> 'slug', s ->> 'name', s ->> 'description', (s ->> 'price')::numeric, s ->> 'price_note',
         coalesce(s ->> 'currency', 'UAH'), (s ->> 'duration_min')::int, true
  from jsonb_array_elements(coalesce(p_doc -> 'services', '[]')) s
  on conflict (tenant_id, slug) do update
  set name = excluded.name, description = excluded.description, price = excluded.price, price_note = excluded.price_note,
      currency = excluded.currency, duration_min = excluded.duration_min, active = true;
  update services set active = false
  where tenant_id = v_id and slug not in (select s ->> 'slug' from jsonb_array_elements(coalesce(p_doc -> 'services', '[]')) s);

  insert into doctors (tenant_id, slug, name, specialty, bio, calendar_id, active)
  select v_id, d ->> 'slug', d ->> 'name', d ->> 'specialty', d ->> 'bio', nullif(d ->> 'calendar_id', ''), true
  from jsonb_array_elements(coalesce(p_doc -> 'doctors', '[]')) d
  on conflict (tenant_id, slug) do update
  set name = excluded.name, specialty = excluded.specialty, bio = excluded.bio, calendar_id = excluded.calendar_id, active = true;
  update doctors set active = false
  where tenant_id = v_id and slug not in (select d ->> 'slug' from jsonb_array_elements(coalesce(p_doc -> 'doctors', '[]')) d);

  delete from doctor_services where tenant_id = v_id;
  insert into doctor_services (tenant_id, doctor_id, service_id)
  select v_id, doc.id, svc.id
  from jsonb_array_elements(coalesce(p_doc -> 'doctors', '[]')) d
  cross join jsonb_array_elements_text(coalesce(d -> 'services', '[]')) s(slug)
  join doctors doc on doc.tenant_id = v_id and doc.slug = d ->> 'slug'
  join services svc on svc.tenant_id = v_id and svc.slug = s.slug;

  delete from doctor_schedules where tenant_id = v_id;
  insert into doctor_schedules (tenant_id, doctor_id, branch_id, weekday, start_time, end_time)
  select v_id, doc.id, br.id, array_position(array['mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun'], lower(day)),
         (w ->> 'from')::time, (w ->> 'to')::time
  from jsonb_array_elements(coalesce(p_doc -> 'doctors', '[]')) d
  cross join jsonb_array_elements(coalesce(d -> 'schedule', '[]')) w
  cross join jsonb_array_elements_text(w -> 'days') day
  join doctors doc on doc.tenant_id = v_id and doc.slug = d ->> 'slug'
  join branches br on br.tenant_id = v_id and br.slug = w ->> 'branch';

  delete from doctor_shifts where tenant_id = v_id and lower(period) > now();
  perform ensure_shifts(coalesce((p_doc -> 'config' -> 'booking' ->> 'horizon_days')::int, 28), v_id);

  for c in select * from jsonb_array_elements(coalesce(p_doc -> 'channels', '[]')) loop
    if exists (select 1 from channel_accounts
               where channel = c ->> 'channel' and external_id = c ->> 'external_id' and tenant_id <> v_id) then
      raise exception '% account % belongs to another tenant', c ->> 'channel', c ->> 'external_id';
    end if;
    insert into channel_accounts (tenant_id, channel, external_id, name, api_base, token_enc, config)
    values (v_id, c ->> 'channel', c ->> 'external_id', c ->> 'name', c ->> 'api_base',
            case when nullif(c ->> 'token', '') is not null then pgp_sym_encrypt(c ->> 'token', p_key) end,
            coalesce(c -> 'config', '{}'))
    on conflict (channel, external_id) do update
    set name = excluded.name, api_base = excluded.api_base, config = excluded.config,
        token_enc = coalesce(excluded.token_enc, channel_accounts.token_enc);
  end loop;

  -- an account dropped from the config (the stub again instead of a real bot, a clinic's replaced bot) stops
  -- serving; kinds the document does not list are kept, so a form upload without a bot token keeps the bot
  update channel_accounts ca
  set active = exists (select 1 from jsonb_array_elements(coalesce(p_doc -> 'channels', '[]')) d
                       where d ->> 'channel' = ca.channel and d ->> 'external_id' = ca.external_id)
  where ca.tenant_id = v_id
    and ca.channel in (select d ->> 'channel' from jsonb_array_elements(coalesce(p_doc -> 'channels', '[]')) d);
  -- topics belong to the operator group: a new group starts without them
  if v_old_chat is distinct from p_doc -> 'config' -> 'operator' ->> 'chat_id' then
    update clients set operator_topic_id = null where tenant_id = v_id and operator_topic_id is not null;
  end if;
  if tenant_has_operator(v_id) then
    perform resolve_incidents('no_operator:' || v_id);
  end if;

  select jsonb_agg(jsonb_build_object('id', id, 'channel', channel, 'external_id', external_id, 'api_base', api_base,
                                      'webhook_secret', webhook_secret, 'has_token', token_enc is not null) order by channel, created_at)
  into v_channels
  from channel_accounts where tenant_id = v_id and active;

  return jsonb_build_object(
    'tenant_id', v_id,
    'slug', p_doc ->> 'slug',
    'channels', coalesce(v_channels, '[]'),
    'branches', (select count(*) from branches where tenant_id = v_id),
    'services', (select count(*) from services where tenant_id = v_id and active),
    'doctors', (select count(*) from doctors where tenant_id = v_id and active),
    'shifts', (select count(*) from doctor_shifts where tenant_id = v_id and upper(period) > now()));
end $$;

create function tenant_id_by_slug(p_slug text) returns uuid language sql stable as $$
  select id from tenants where slug = p_slug
$$;

-- Tool search_kb: the tenant's chunks nearest to the query embedding (cosine distance, as the PGVector node).
create function kb_search(p_tenant uuid, p_embedding text, p_limit int default 4) returns jsonb language sql stable as $$
  select coalesce(jsonb_agg(jsonb_build_object('article', x.metadata ->> 'article', 'text', x.text) order by x.distance), '[]')
  from (select k.metadata, k.text, k.embedding <=> p_embedding::vector as distance
        from kb_chunks k where k.tenant_id = p_tenant
        order by 3 limit p_limit) x
$$;

-- Replace a tenant's knowledge base after a re-index: drop chunks of earlier index runs.
create function kb_prune(p_tenant uuid, p_batch text) returns int language sql as $$
  with del as (
    delete from kb_chunks where tenant_id = p_tenant and metadata ->> 'batch' is distinct from p_batch returning 1
  )
  select count(*)::int from del
$$;
