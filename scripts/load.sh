#!/usr/bin/env bash
# AC9 load test: VUS (default 100) concurrent Telegram dialogs x 5 messages against the loadtest tenant,
# then SQL checks (nothing unprocessed / unsent, reply latency) and reports/load-<date>.md.
# More workers: docker compose up -d --scale n8n-worker=N before running.
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; . ./.env; set +a
VUS=${VUS:-100}
q() { docker compose exec -T postgres psql -X -At -U "$POSTGRES_USER" -d app -c "$1"; }
read -r account secret <<<"$(q "select ca.id || ' ' || ca.webhook_secret from channel_accounts ca join tenants t on t.id = ca.tenant_id
                                 where t.slug = 'loadtest' and ca.channel = 'telegram'")"
[ -n "$account" ] || { echo "tenant loadtest is missing: run scripts/bootstrap.sh" >&2; exit 1; }
start=$(q "select now()")
run=$(( $(date +%s) % 100000 ))
docker compose --profile load up -d --wait stub >/dev/null
docker compose --profile load run --rm -u "$(id -u):$(id -g)" -e ACCOUNT="$account" -e SECRET="$secret" -e VUS="$VUS" -e RUN="$run" \
  k6 run --quiet /load/dialog.js
M="messages m join tenants t on t.id = m.tenant_id where t.slug = 'loadtest' and m.created_at >= '$start'"
for _ in $(seq 1 120); do  # let the pipeline drain (cron.reconcile included)
  left=$(q "select count(*) from $M and ((m.direction = 'in' and m.processed_at is null) or (m.direction = 'out' and m.sent_at is null and m.failed_at is null))")
  [ "$left" = 0 ] && break
  sleep 2
done
stats=$(q "with m as (select m.* from $M),
  lat as (select extract(epoch from r.sent_at - i.created_at) as s from m i
          cross join lateral (select o.sent_at from m o where o.conversation_id = i.conversation_id and o.id > i.id
                              and o.direction = 'out' and o.sent_at is not null order by o.id limit 1) r
          where i.direction = 'in')
  select json_build_object('clients', (select count(distinct conversation_id) from m),
    'in', (select count(*) from m where direction = 'in'), 'out', (select count(*) from m where direction = 'out'),
    'in_unprocessed', (select count(*) from m where direction = 'in' and processed_at is null),
    'out_unsent', (select count(*) from m where direction = 'out' and sent_at is null),
    'answered', (select count(*) from lat),
    'p50', (select round(percentile_cont(0.5) within group (order by s)::numeric, 2) from lat),
    'p95', (select round(percentile_cont(0.95) within group (order by s)::numeric, 2) from lat),
    'max', (select round(max(s)::numeric, 2) from lat))")
k6=reports/k6-summary.json
workers=$(docker compose ps -q n8n-worker | wc -l)
report=reports/load-$(date +%F).md
jq -r --argjson s "$stats" --arg vus "$VUS" --arg workers "$workers" --arg conc "${N8N_WORKER_CONCURRENCY:-20}" \
  --arg delay "${STUB_LLM_DELAY_MS:-1000-3000}" '
  def ok($c): if $c then "pass" else "FAIL" end;
  "# Load test \(now | strftime("%Y-%m-%d %H:%M UTC"))", "",
  "Setup: \($vus) concurrent Telegram dialogs x 5 messages (4-8 s between messages) through Caddy -> in.telegram,",
  "tenant `loadtest`: stub LLM with \($delay) ms latency, stub Telegram API; \($workers) n8n worker(s) x concurrency \($conc).", "",
  "| Metric | Value |", "| --- | --- |",
  "| Webhook requests | \(.requests) (failed: \(.failed)) |",
  "| Webhook response p95 | \(.p95_ms) ms |",
  "| Dialogs | \($s.clients) |",
  "| Inbound messages stored | \($s.in) |",
  "| Bot messages sent | \($s.out) |",
  "| Inbound not processed | \($s.in_unprocessed) |",
  "| Outbound not sent | \($s.out_unsent) |",
  "| Reply time p50 / p95 / max | \($s.p50) / \($s.p95) / \($s.max) s |", "",
  "AC9: 0 lost messages - \(ok($s.in == (($vus | tonumber) * 5) and $s.in_unprocessed == 0 and $s.out_unsent == 0)); p95 <= 6 s - \(ok($s.p95 <= 6))."
' "$k6" > "$report"
rm -f "$k6"
cat "$report"
! grep -q FAIL "$report"  # the exit code tells CI whether AC9 passed
