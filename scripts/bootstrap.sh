#!/usr/bin/env bash
# First-run setup of the local n8n: .env secrets, stack, owner account,
# public API key + MCP token, Claude Code MCP servers (n8n-mcp, built-in n8n).
# Safe to re-run: every step is skipped once done.
set -euo pipefail
cd "$(dirname "$0")/.."

N8N=http://localhost:5678

if [ ! -f .env ]; then
  sed -e "s/^POSTGRES_PASSWORD=$/POSTGRES_PASSWORD=$(openssl rand -hex 24)/" \
      -e "s/^N8N_ENCRYPTION_KEY=$/N8N_ENCRYPTION_KEY=$(openssl rand -hex 32)/" .env.example > .env
  chmod 600 .env
  echo "created .env"
fi

docker compose up -d --wait

# Owner account (local-only credentials, stored in .env)
if ! grep -q '^N8N_OWNER_EMAIL=' .env; then
  if [ "$(curl -sf $N8N/rest/settings | jq '.data.userManagement.showSetupOnFirstLoad')" != "true" ]; then
    echo "n8n owner already exists but N8N_OWNER_EMAIL/N8N_OWNER_PASSWORD are not in .env; add them and re-run" >&2
    exit 1
  fi
  printf '\n# Local n8n owner login (created by scripts/bootstrap.sh)\nN8N_OWNER_EMAIL=admin@greeter.local\nN8N_OWNER_PASSWORD=%s\n' \
    "$(openssl rand -hex 12)Aa1" >> .env
  set -a; . ./.env; set +a
  jq -n --arg e "$N8N_OWNER_EMAIL" --arg p "$N8N_OWNER_PASSWORD" \
    '{email: $e, password: $p, firstName: "Greeter", lastName: "Admin"}' |
    curl -sf -o /dev/null -X POST $N8N/rest/owner/setup -H 'Content-Type: application/json' -d @-
  echo "created n8n owner $N8N_OWNER_EMAIL (password in .env)"
fi
set -a; . ./.env; set +a

# Claude Code MCP servers, local scope: keys live in ~/.claude.json, never in the repo
if claude mcp get n8n >/dev/null 2>&1 && claude mcp get n8n-mcp >/dev/null 2>&1; then
  echo "Claude Code MCP servers n8n and n8n-mcp already registered"
  exit 0
fi

jar=$(mktemp); trap 'rm -f "$jar"' EXIT
bid=$(openssl rand -hex 16)  # n8n binds the auth cookie to a browser-id header
api() { curl -sf -b "$jar" -c "$jar" -H "browser-id: $bid" -H 'Content-Type: application/json' "$@"; }

jq -n --arg e "$N8N_OWNER_EMAIL" --arg p "$N8N_OWNER_PASSWORD" '{emailOrLdapLoginId: $e, password: $p}' |
  api -o /dev/null -X POST $N8N/rest/login -d @-

label="claude-code n8n-mcp"
for id in $(api $N8N/rest/api-keys | jq -r --arg l "$label" '.data.items[] | select(.label == $l) | .id'); do
  api -o /dev/null -X DELETE "$N8N/rest/api-keys/$id"  # drop the key from a previous run
done
scopes=$(api $N8N/rest/api-keys/scopes | jq -c '.data')
api_key=$(jq -n --arg l "$label" --argjson s "$scopes" '{label: $l, scopes: $s, expiresAt: null}' |
  api -X POST $N8N/rest/api-keys -d @- | jq -r '.data.rawApiKey')
# GET returns the token redacted once it exists; rotate always yields a full one
mcp_token=$(api -X POST $N8N/rest/mcp/api-key/rotate | jq -r '.data.apiKey')

claude mcp remove -s local n8n-mcp >/dev/null 2>&1 || true
claude mcp remove -s local n8n >/dev/null 2>&1 || true
# MCP_MODE=stdio: otherwise debug logs break the protocol.
# WEBHOOK_SECURITY_MODE=moderate: the default strict mode rejects loopback n8n URLs.
claude mcp add -s local n8n-mcp \
  --env MCP_MODE=stdio \
  --env LOG_LEVEL=error \
  --env DISABLE_CONSOLE_OUTPUT=true \
  --env N8N_API_URL=$N8N \
  --env N8N_API_KEY="$api_key" \
  --env WEBHOOK_SECURITY_MODE=moderate \
  -- npx -y n8n-mcp >/dev/null
claude mcp add -s local --transport http n8n $N8N/mcp-server/http \
  --header "Authorization: Bearer $mcp_token" >/dev/null
echo "registered MCP servers n8n-mcp and n8n (local scope); restart Claude Code to load them"
