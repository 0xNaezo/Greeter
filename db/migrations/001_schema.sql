-- Core schema. Every tenant-owned row carries tenant_id; references between tenant tables are
-- composite (tenant_id, id) foreign keys, so a row can never point into another tenant.
-- Time is timestamptz; local time is derived from the branch (or tenant) timezone.

create table tenants (
  id          uuid primary key default gen_random_uuid(),
  slug        text not null unique check (slug ~ '^[a-z0-9][a-z0-9-]{1,39}$'),
  name        text not null,
  timezone    text not null default 'Europe/Kyiv',
  llm_profile text not null default 'openrouter' check (llm_profile in ('openrouter', 'groq', 'stub')),
  -- tone, languages, emergency_phone, operator {chat_id, sla_min}, booking {...}, calendar {...}, followups {...}
  config      jsonb not null default '{}',
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

create table channel_accounts (
  id             uuid primary key default gen_random_uuid(),
  tenant_id      uuid not null references tenants on delete cascade,
  channel        text not null check (channel in ('telegram', 'widget', 'whatsapp')),
  external_id    text not null,   -- telegram bot id, whatsapp phone_number_id, widget slug
  name           text,
  api_base       text,            -- provider base URL (the stub in dev and load tests)
  token_enc      bytea,           -- pgp_sym_encrypt(token, APP_ENCRYPTION_KEY)
  webhook_secret text not null default encode(gen_random_bytes(24), 'hex'),
  config         jsonb not null default '{}',
  active         boolean not null default true,  -- false: dropped from the clinic config, webhooks rejected
  created_at     timestamptz not null default now(),
  unique (tenant_id, id),
  unique (channel, external_id)
);

create table branches (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references tenants on delete cascade,
  slug        text not null,
  name        text not null,
  address     text,
  phone       text,
  timezone    text,               -- null = tenant timezone
  hours       jsonb not null default '{}',
  calendar_id text,
  unique (tenant_id, id),
  unique (tenant_id, slug)
);

create table doctors (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references tenants on delete cascade,
  slug        text not null,
  name        text not null,
  specialty   text,
  bio         text,
  calendar_id text,               -- takes precedence over the branch calendar
  active      boolean not null default true,
  unique (tenant_id, id),
  unique (tenant_id, slug)
);

create table services (
  id           uuid primary key default gen_random_uuid(),
  tenant_id    uuid not null references tenants on delete cascade,
  slug         text not null,
  name         text not null,
  description  text,
  price        numeric(10, 2) not null check (price >= 0),
  price_note   text,              -- e.g. "from", "per tooth"
  currency     text not null default 'UAH',
  duration_min int not null check (duration_min between 5 and 480),
  active       boolean not null default true,
  unique (tenant_id, id),
  unique (tenant_id, slug)
);

create table doctor_services (
  tenant_id  uuid not null references tenants on delete cascade,
  doctor_id  uuid not null,
  service_id uuid not null,
  primary key (tenant_id, doctor_id, service_id),
  foreign key (tenant_id, doctor_id) references doctors (tenant_id, id) on delete cascade,
  foreign key (tenant_id, service_id) references services (tenant_id, id) on delete cascade
);

-- Weekly template; ensure_shifts() materializes it into doctor_shifts for the booking horizon.
create table doctor_schedules (
  id         uuid primary key default gen_random_uuid(),
  tenant_id  uuid not null references tenants on delete cascade,
  doctor_id  uuid not null,
  branch_id  uuid not null,
  weekday    int not null check (weekday between 1 and 7),  -- ISO: 1 = Monday
  start_time time not null,
  end_time   time not null check (end_time > start_time),
  foreign key (tenant_id, doctor_id) references doctors (tenant_id, id) on delete cascade,
  foreign key (tenant_id, branch_id) references branches (tenant_id, id) on delete cascade
);

create table doctor_shifts (
  id        uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references tenants on delete cascade,
  doctor_id uuid not null,
  branch_id uuid not null,
  period    tstzrange not null check (not isempty(period) and not lower_inf(period) and not upper_inf(period)),
  unique (tenant_id, id),
  foreign key (tenant_id, doctor_id) references doctors (tenant_id, id) on delete cascade,
  foreign key (tenant_id, branch_id) references branches (tenant_id, id) on delete cascade,
  exclude using gist (doctor_id with =, period with &&)   -- a doctor is in one place at a time
);
create index doctor_shifts_branch on doctor_shifts using gist (tenant_id, branch_id, period);

-- Table of the n8n PGVector Store node (column names are the node defaults). Knowledge base only:
-- prices, services, doctors and hours come from the tables above, not from RAG.
create table kb_chunks (
  id        uuid primary key default gen_random_uuid(),
  text      text,
  metadata  jsonb,
  embedding vector,
  tenant_id uuid generated always as ((metadata ->> 'tenant_id')::uuid) stored not null
            references tenants on delete cascade
);
create index kb_chunks_tenant on kb_chunks (tenant_id);

create table clients (
  id                   uuid primary key default gen_random_uuid(),
  tenant_id            uuid not null references tenants on delete cascade,
  name                 text,
  phone                text check (phone ~ '^\+[0-9]{8,15}$'),
  phone_verified       boolean not null default false,  -- proved by the channel, not typed in the chat
  lang                 text check (lang in ('en', 'uk', 'ru')),
  summary              text,
  operator_topic_id    bigint,     -- forum topic in the operator supergroup
  merged_into          uuid,       -- P1: glued to another client by phone
  reactivation_sent_at timestamptz,
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now(),
  unique (tenant_id, id),
  foreign key (tenant_id, merged_into) references clients (tenant_id, id)
);
-- A typed phone proves nothing, so several profiles may carry it; a verified one belongs to one person (P1 glue).
create unique index clients_phone_uq on clients (tenant_id, phone) where phone is not null and merged_into is null and phone_verified;
create unique index clients_topic_uq on clients (tenant_id, operator_topic_id) where operator_topic_id is not null;

-- One row per (channel account, user). P1 phone glue re-points an identity to another client.
create table client_identities (
  id                 uuid primary key default gen_random_uuid(),
  tenant_id          uuid not null references tenants on delete cascade,
  channel_account_id uuid not null,
  external_user_id   text not null,
  chat_id            text not null,   -- where replies go (telegram chat, whatsapp wa_id, widget visitor)
  client_id          uuid not null,
  profile            jsonb not null default '{}',
  created_at         timestamptz not null default now(),
  last_seen_at       timestamptz not null default now(),
  unique (tenant_id, id),
  unique (channel_account_id, external_user_id),
  foreign key (tenant_id, channel_account_id) references channel_accounts (tenant_id, id) on delete cascade,
  foreign key (tenant_id, client_id) references clients (tenant_id, id) on delete cascade
);
create index client_identities_client on client_identities (client_id);

create table conversations (
  id                      uuid primary key default gen_random_uuid(),
  tenant_id               uuid not null references tenants on delete cascade,
  client_id               uuid not null unique,
  state                   text not null default 'bot' check (state in ('bot', 'operator')),
  last_identity_id        uuid,       -- replies go to the channel the client wrote from last
  not_understood_streak   int not null default 0,
  lease_until             timestamptz, -- one turn per conversation at a time
  lease_owner             text,
  awaiting_operator_since timestamptz,
  sla_notified_at         timestamptz,
  created_at              timestamptz not null default now(),
  updated_at              timestamptz not null default now(),
  unique (tenant_id, id),
  foreign key (tenant_id, client_id) references clients (tenant_id, id) on delete cascade,
  foreign key (tenant_id, last_identity_id) references client_identities (tenant_id, id) on delete set null (last_identity_id)
);
create index conversations_operator on conversations (awaiting_operator_since) where state = 'operator';

-- Episode for metrics: a new session starts after 12 h of silence.
create table sessions (
  id              uuid primary key default gen_random_uuid(),
  tenant_id       uuid not null references tenants on delete cascade,
  conversation_id uuid not null,
  channel         text not null,
  started_at      timestamptz not null default now(),
  last_message_at timestamptz not null default now(),
  unique (tenant_id, id),
  foreign key (tenant_id, conversation_id) references conversations (tenant_id, id) on delete cascade
);
create index sessions_conversation on sessions (conversation_id, started_at desc);
create index sessions_tenant_started on sessions (tenant_id, started_at);

create table messages (
  id                  bigint generated always as identity primary key,
  tenant_id           uuid not null references tenants on delete cascade,
  conversation_id     uuid not null,
  session_id          uuid not null,
  direction           text not null check (direction in ('in', 'out')),
  author              text not null check (author in ('client', 'bot', 'operator', 'system')),
  channel_account_id  uuid,
  identity_id         uuid,
  external_id         text,           -- inbound: provider id (dedupe); outbound: optional dedupe key
  text                text,
  payload             jsonb not null default '{}',  -- inbound: callback; outbound: buttons
  created_at          timestamptz not null default now(),
  processed_at        timestamptz,    -- inbound handled by core.process
  process_attempts    int not null default 0,
  sent_at             timestamptz,    -- outbound delivered to the channel
  send_attempts       int not null default 0,
  next_attempt_at     timestamptz,    -- outbound retry backoff after a failed delivery
  failed_at           timestamptz,    -- outbound given up
  provider_message_id text,
  check ((direction = 'in') = (author = 'client')),
  unique (tenant_id, id),
  foreign key (tenant_id, conversation_id) references conversations (tenant_id, id) on delete cascade,
  foreign key (tenant_id, session_id) references sessions (tenant_id, id) on delete cascade,
  foreign key (tenant_id, channel_account_id) references channel_accounts (tenant_id, id) on delete set null (channel_account_id),
  foreign key (tenant_id, identity_id) references client_identities (tenant_id, id) on delete set null (identity_id)
);
-- Webhook redelivery must not create a second message (AC6)
create unique index messages_in_uq on messages (channel_account_id, external_id) where direction = 'in';
create unique index messages_out_uq on messages (tenant_id, external_id) where direction = 'out' and external_id is not null;
create index messages_conversation on messages (conversation_id, id);
create index messages_session on messages (session_id, id);
create index messages_unprocessed on messages (conversation_id) where direction = 'in' and processed_at is null;
create index messages_unsent on messages (created_at) where direction = 'out' and sent_at is null and failed_at is null;
create index messages_tenant_created on messages (tenant_id, created_at);

create table appointments (
  id                   uuid primary key default gen_random_uuid(),
  tenant_id            uuid not null references tenants on delete cascade,
  client_id            uuid not null,
  doctor_id            uuid not null,
  branch_id            uuid not null,
  service_id           uuid not null,
  period               tstzrange not null check (not isempty(period) and not lower_inf(period) and not upper_inf(period)),
  status               text not null default 'booked' check (status in ('booked', 'cancelled', 'done', 'no_show')),
  source               text not null default 'bot' check (source in ('bot', 'admin', 'seed')),
  reason               text,
  price                numeric(10, 2),
  confirmed_at         timestamptz,    -- client confirmed attendance from a reminder
  gcal_calendar_id     text,           -- calendar that currently holds the event
  gcal_synced_at       timestamptz,    -- null = calendar mirror is behind
  gcal_attempts        int not null default 0,  -- failed syncs of the current version
  gcal_next_at         timestamptz,    -- retry backoff after a failed sync
  reminder_24h_sent_at timestamptz,
  reminder_2h_sent_at  timestamptz,
  followup_sent_at     timestamptz,    -- P1: review request / no-show rebooking offer
  review_score         smallint check (review_score between 1 and 5),
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now(),
  unique (tenant_id, id),
  foreign key (tenant_id, client_id) references clients (tenant_id, id) on delete cascade,
  foreign key (tenant_id, doctor_id) references doctors (tenant_id, id),
  foreign key (tenant_id, branch_id) references branches (tenant_id, id),
  foreign key (tenant_id, service_id) references services (tenant_id, id),
  -- no double booking of a doctor or a client, whoever writes the row (bot, admin grid, seed)
  constraint appointments_doctor_busy exclude using gist (doctor_id with =, period with &&) where (status = 'booked'),
  constraint appointments_client_busy exclude using gist (client_id with =, period with &&) where (status = 'booked')
);
create index appointments_client on appointments (client_id, lower(period));
create index appointments_tenant_start on appointments (tenant_id, lower(period));
create index appointments_unsynced on appointments (updated_at) where gcal_synced_at is null;

-- Changes that need confirmation: the LLM proposes, the client confirms, SQL applies.
create table pending_actions (
  id              uuid primary key default gen_random_uuid(),
  tenant_id       uuid not null references tenants on delete cascade,
  conversation_id uuid not null,
  kind            text not null check (kind in ('book', 'reschedule', 'cancel')),
  payload         jsonb not null,
  summary         text not null,
  status          text not null default 'pending' check (status in ('pending', 'confirmed', 'rejected', 'expired', 'failed')),
  result          jsonb,
  expires_at      timestamptz not null default now() + interval '30 minutes',
  created_at      timestamptz not null default now(),
  resolved_at     timestamptz,
  unique (tenant_id, id),
  foreign key (tenant_id, conversation_id) references conversations (tenant_id, id) on delete cascade
);
create index pending_actions_open on pending_actions (conversation_id) where status = 'pending';

create table escalations (
  id              uuid primary key default gen_random_uuid(),
  tenant_id       uuid not null references tenants on delete cascade,
  conversation_id uuid not null,
  session_id      uuid not null,
  reason          text not null check (reason in ('user_request', 'complaint', 'medical', 'urgent', 'not_understood', 'tool_error')),
  summary         text,
  created_at      timestamptz not null default now(),
  notified_at     timestamptz,   -- card posted to the operator topic
  first_reply_at  timestamptz,
  returned_at     timestamptz,
  unique (tenant_id, id),
  foreign key (tenant_id, conversation_id) references conversations (tenant_id, id) on delete cascade,
  foreign key (tenant_id, session_id) references sessions (tenant_id, id) on delete cascade
);
create index escalations_tenant_created on escalations (tenant_id, created_at);
create index escalations_unnotified on escalations (created_at) where notified_at is null;

-- Our trace is an index; the n8n execution behind execution_id holds full detail.
create table trace_events (
  id           bigint generated always as identity primary key,
  tenant_id    uuid not null references tenants on delete cascade,
  session_id   uuid not null,
  execution_id text,
  type         text not null check (type in ('msg_in', 'decision', 'tool', 'msg_out', 'error')),
  data         jsonb not null default '{}',
  duration_ms  int,
  created_at   timestamptz not null default now(),
  foreign key (tenant_id, session_id) references sessions (tenant_id, id) on delete cascade
);
create index trace_events_session on trace_events (session_id, id);

-- Paid-tier list prices, used for cost even on the free tier.
create table llm_prices (
  model_prefix    text primary key,
  usd_per_mtok_in  numeric(10, 4) not null,
  usd_per_mtok_out numeric(10, 4) not null
);

create table llm_usage (
  id           bigint generated always as identity primary key,
  tenant_id    uuid not null references tenants on delete cascade,
  session_id   uuid,
  execution_id text not null,
  model        text not null,
  tokens_in    int not null,
  tokens_out   int not null,
  cost_usd     numeric(12, 6) not null,
  estimated    boolean not null default false,
  created_at   timestamptz not null default now(),
  unique (execution_id, model),
  foreign key (tenant_id, session_id) references sessions (tenant_id, id) on delete set null (session_id)
);
create index llm_usage_tenant_created on llm_usage (tenant_id, created_at);

-- Platform-level, not tenant data. A failed execution is an incident that Replay can retry; a problem a
-- workflow reports itself (delivery, calendar, no operator) carries a ref, stays one open incident per ref
-- and is resolved by the code that sees the problem go away.
create table incidents (
  id                  bigint generated always as identity primary key,
  workflow            text not null,
  node                text,
  execution_id        text,
  error               text,
  url                 text,
  ref                 text,           -- e.g. send:<account>, gcal:<appointment>, no_operator:<tenant>
  replayable          boolean not null default true,
  repeats             int not null default 0,
  status              text not null default 'open' check (status in ('open', 'replaying', 'replayed', 'resolved')),
  alerted_at          timestamptz,
  replay_execution_id text,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now()
);
create unique index incidents_execution_uq on incidents (execution_id) where execution_id is not null and ref is null;
create unique index incidents_ref_open on incidents (ref) where ref is not null and status = 'open';
create index incidents_dedupe on incidents (workflow, node, alerted_at);

-- Fixed-window request counters (public web widget).
create table rate_limits (
  key          text not null,
  window_start timestamptz not null,
  hits         int not null default 1,
  primary key (key, window_start)
);

-- cron.usage: how far the executions of each workflow have been read.
create table usage_scans (
  workflow_id   text primary key,
  scanned_until timestamptz not null
);
