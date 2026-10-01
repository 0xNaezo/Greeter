#!/usr/bin/env bash
# Static rules for n8n/workflows/*.json (plan §9). Prints violations, exits 1 if any.
# Tenant isolation itself lives in the SQL functions and is covered by db/tests (migrate.sh --test).
set -euo pipefail
cd "$(dirname "$0")/.."
ids=$(jq -s 'map(.id)' n8n/workflows/*.json)
out=$(for f in n8n/workflows/*.json; do jq -r --arg f "${f##*/}" --argjson ids "$ids" '
  def tables: "tenants|channel_accounts|branches|doctors|services|doctor_services|doctor_schedules|doctor_shifts|kb_chunks|clients|client_identities|conversations|sessions|messages|appointments|pending_actions|escalations|trace_events|llm_usage|incidents";
  def raw_sql: test("\\b(insert\\s+into|delete\\s+from|update\\s+(" + tables + ")|(from|join)\\s+(" + tables + "))\\b"; "i");
  (.nodes | map(select(.type != "n8n-nodes-base.stickyNote")) | length) as $n
  | (if .id != "ops-error" and .settings.errorWorkflow != "ops-error" then "error workflow must be ops-error" else empty end),
    (if $n > 40 then "\($n) nodes: split into sub-workflows" else empty end),
    (.nodes[] | . as $node
      | (if .type == "n8n-nodes-base.postgres" and ((.parameters.query // "") | raw_sql) then "\(.name): call a SQL function, not tables" else empty end),
        (if (.type == "n8n-nodes-base.httpRequest" or .type == "n8n-nodes-base.telegram") and .retryOnFail != true
            and ((.notes // "") | startswith("no retry:") | not) then "\(.name): enable Retry On Fail (or explain in a \"no retry:\" note)" else empty end),
        (if tostring | test("\\$fromAI\\(\\s*[\"\\x27][^\"\\x27]*(tenant|client|conversation|session|account)"; "i") then "\(.name): ids come from the turn context, never $fromAI" else empty end),
        ((.credentials // {}) | to_entries[] | select(.value.id | startswith("cred-") | not) | "\($node.name): credential \(.value.name) is not provisioned by bootstrap"),
        (if (.type == "n8n-nodes-base.executeWorkflow" or .type == "@n8n/n8n-nodes-langchain.toolWorkflow")
            and ((.parameters.workflowId.value // "") | IN($ids[]) | not) then "\(.name): unknown sub-workflow \(.parameters.workflowId.value)" else empty end),
        (if tostring | test("AIza[0-9A-Za-z_-]{30}|sk-or-v1-[0-9a-f]{20}|gsk_[0-9A-Za-z]{20}|[0-9]{8,10}:AA[0-9A-Za-z_-]{30}|PRIVATE KEY-----") then "\(.name): hardcoded secret" else empty end))
  | "\($f): \(.)"' "$f"; done)
[ -z "$out" ] || { echo "$out" >&2; exit 1; }
echo "workflows: $(ls n8n/workflows/*.json | wc -l) checked"
