#!/usr/bin/env bash
# evals/scenarios.json -> n8n Data Table "eval_scenarios" (rows replaced), and bind eval.run's evaluation
# nodes to that table (n8n gives data tables random ids; the repo JSON carries the placeholder "eval_scenarios").
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; . ./.env; set +a
N8N=http://localhost:5678/api/v1
api() { curl -sf -H "X-N8N-API-KEY: $N8N_API_KEY" -H 'Content-Type: application/json' "$@"; }

id=$(api "$N8N/data-tables?limit=100" | jq -r '.data[] | select(.name == "eval_scenarios") | .id' | head -1)
if [ -z "$id" ]; then
  id=$(jq -n '{name: "eval_scenarios", columns: ([
      "scenario", "category", "turns", "expect", "setup", "result", "details"] | map({name: ., type: "string"}))}' |
    api -X POST "$N8N/data-tables" -d @- | jq -r .id)
fi
api -X DELETE "$N8N/data-tables/$id/rows/clear" >/dev/null
jq '{data: map({scenario: .id, category, turns: (.turns | tojson), expect: (.expect | tojson),
                setup: (if .setup then (.setup | tojson) else "" end), result: "", details: ""}), returnType: "count"}' \
  evals/scenarios.json | api -X POST "$N8N/data-tables/$id/rows" -d @- >/dev/null

wf=$(api "$N8N/workflows/eval-run")
if [ "$(jq --arg id "$id" '[.nodes[] | select(.parameters.dataTableId.mode == "id") | .parameters.dataTableId.value != $id] | any' <<<"$wf")" = true ]; then
  jq --arg id "$id" '{name, nodes: (.nodes | map(if .parameters.dataTableId.mode == "id" then .parameters.dataTableId.value = $id else . end)),
                      connections, settings}' <<<"$wf" | api -X PUT "$N8N/workflows/eval-run" -d @- >/dev/null
  api -X POST "$N8N/workflows/eval-run/publish" >/dev/null
fi
echo "eval scenarios: $(jq length evals/scenarios.json) synced to data table $id"
