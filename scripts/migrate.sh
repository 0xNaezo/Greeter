#!/usr/bin/env bash
# Database "app": roles, databases, extensions, then db/migrations/*.sql in order, each once.
#   scripts/migrate.sh          apply pending migrations
#   scripts/migrate.sh --test   also build a throwaway "app_test" from scratch and run db/tests/*.sql
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; . ./.env; set +a

psql_su() { docker compose exec -T postgres psql -X -q -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" "$@"; }

# Roles and databases. Passwords go through psql variables, never into the SQL text.
psql_su -d postgres -v app_pw="$APP_DB_PASSWORD" -v grafana_pw="$GRAFANA_DB_PASSWORD" -v nocodb_pw="$NOCODB_DB_PASSWORD" <<'SQL'
select format('create role %I login', r) from unnest(array['app', 'grafana_ro', 'nocodb']) r
where not exists (select 1 from pg_roles where rolname = r) \gexec
alter role app password :'app_pw';
alter role grafana_ro password :'grafana_pw';
alter role nocodb password :'nocodb_pw';
select 'create database app owner app' where not exists (select 1 from pg_database where datname = 'app') \gexec
select 'create database nocodb owner nocodb' where not exists (select 1 from pg_database where datname = 'nocodb') \gexec
SQL

prepare_db() {  # extensions need a superuser; everything else is owned by "app"
  psql_su -d "$1" <<'SQL'
create extension if not exists pgcrypto;
create extension if not exists btree_gist;
create extension if not exists vector;
create extension if not exists "uuid-ossp";
SQL
  psql_su -d "$1" -c "revoke all on database $1 from public" -c "grant connect on database $1 to app, grafana_ro, nocodb" \
    -c "create table if not exists schema_migrations (version text primary key, applied_at timestamptz not null default now())" \
    -c "alter table schema_migrations owner to app"
}

migrate() {
  local db=$1 applied f v
  applied=$(psql_su -d "$db" -At -c "select version from schema_migrations")
  for f in db/migrations/*.sql; do
    v=$(basename "$f" .sql)
    grep -qx "$v" <<<"$applied" && continue
    { echo "set role app;"; cat "$f"; echo "insert into schema_migrations (version) values ('$v');"; } |
      psql_su -d "$db" -1
    echo "migrated $db: $v"
  done
}

prepare_db app 2>&1 | grep -v 'already exists' || true
migrate app

if [ "${1:-}" = --test ]; then
  psql_su -d postgres -c "drop database if exists app_test with (force)" -c "create database app_test owner app"
  prepare_db app_test >/dev/null 2>&1
  migrate app_test >/dev/null
  fail=0
  err=$(mktemp); trap 'rm -f "$err"' EXIT
  for f in db/tests/[0-9]*.sql; do
    # each test file runs against the shared fixture inside a transaction that is rolled back
    if { echo "begin; set role app;"; cat db/tests/_fixture.sql "$f"; echo "rollback;"; } |
        psql_su -d app_test >/dev/null 2>"$err"; then
      echo "ok   $f"
    else
      echo "FAIL $f"; sed 's/^/     /' "$err"; fail=1
    fi
  done
  psql_su -d postgres -c "drop database app_test with (force)"
  exit $fail
fi
