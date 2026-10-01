#!/usr/bin/env bash
# Workflows edited in the n8n UI -> n8n/workflows/<name>.json (the source of truth), then check them.
# Nodes reference credentials by id only, so no secret leaves n8n. Archived workflows are skipped.
set -euo pipefail
cd "$(dirname "$0")/.."
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
docker compose exec -T n8n sh -c \
  'd=$(mktemp -d) && n8n export:workflow --all --separate --output="$d" >/dev/null && tar -C "$d" -cf - . && rm -rf "$d"' |
  tar -C "$tmp" -xf -
n=0
for f in "$tmp"/*.json; do
  [ "$(jq -r '.isArchived // false' "$f")" = false ] || continue
  # data table ids differ per instance: evaluation nodes go back to the placeholder bound by sync-evals.sh
  jq '.nodes |= map(if .parameters.dataTableId.mode == "id" then .parameters.dataTableId.value = "eval_scenarios" else . end)
      | {id, name, nodes, connections, settings, pinData: {}, active: false, meta: {publish: (.meta.publish // true)}}
      + (if .description then {description} else {} end)' "$f" > "n8n/workflows/$(jq -r .name "$f").json"
  n=$((n + 1))
done
echo "exported $n workflows to n8n/workflows"
scripts/check-workflows.sh
