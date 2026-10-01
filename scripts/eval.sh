#!/usr/bin/env bash
# Run the agent evaluation as an n8n test run (history: eval.run -> Evaluations tab), wait for it,
# then write reports/eval-<date>.md. Real LLM keys make it meaningful (a few hundred model calls).
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; . ./.env; set +a
N8N=http://localhost:5678/api/v1
api() { curl -sf -H "X-N8N-API-KEY: $N8N_API_KEY" -H 'Content-Type: application/json' "$@"; }
scripts/sync-evals.sh
# the public API refuses to start test runs on the community plan; the editor's endpoint does it
jar=$(mktemp); trap 'rm -f "$jar"' EXIT; bid=$(openssl rand -hex 16)
rest() { curl -sf -b "$jar" -c "$jar" -H "browser-id: $bid" -H 'Content-Type: application/json' "$@"; }
jq -n --arg e "$N8N_OWNER_EMAIL" --arg p "$N8N_OWNER_PASSWORD" '{emailOrLdapLoginId: $e, password: $p}' |
  rest -o /dev/null -X POST http://localhost:5678/rest/login -d @-
run=$(rest -X POST http://localhost:5678/rest/workflows/eval-run/test-runs/new | jq -r .testRunId)
echo "test run $run started"
while :; do
  status=$(api "$N8N/workflows/eval-run/test-runs/$run" | jq -r .status)
  case "$status" in new|running) sleep 10 ;; *) break ;; esac
done
echo "test run $run: $status"
curl -sf -X POST http://localhost:5678/webhook/admin/eval-report -H "X-Admin-Token: $ADMIN_TOKEN" | jq .
