#!/usr/bin/env bash
# One command from zero to a running system; safe to re-run (every step converges):
# .env secrets -> stack -> db migrations -> n8n owner + API key -> credentials (fixed ids from .env)
# -> workflows (n8n/workflows/*.json) -> tenants (tenants/*/tenant.json) -> knowledge base -> demo data
# -> eval dataset -> Claude Code MCP servers.
# Missing external keys are replaced by the stub (fake Telegram / LLM / Google / WhatsApp).
set -euo pipefail
cd "$(dirname "$0")/.."

N8N=http://localhost:5678
STUB=http://stub:3000

# ---------------------------------------------------------------- .env
[ -f .env ] || { cp .env.example .env; chmod 600 .env; echo "created .env"; }
set_env() {  # set_env KEY VALUE: replace the line or append it
  local tmp; tmp=$(mktemp)
  awk -v k="$1" -v v="$2" 'BEGIN{d=0} $0 ~ "^"k"=" {print k"="v; d=1; next} {print} END{if(!d) print k"="v}' .env > "$tmp"
  cat "$tmp" > .env; rm -f "$tmp"
}
env_val() { grep -E "^$1=" .env | tail -1 | cut -d= -f2- || true; }
grep -E '^[A-Z0-9_]+=' .env.example | while IFS= read -r line; do   # keys added since .env was created
  grep -q "^${line%%=*}=" .env || echo "$line" >> .env
done
for key in POSTGRES_PASSWORD APP_DB_PASSWORD GRAFANA_DB_PASSWORD NOCODB_DB_PASSWORD N8N_ENCRYPTION_KEY \
           APP_ENCRYPTION_KEY WIDGET_HMAC_SECRET ADMIN_TOKEN PLATFORM_TG_WEBHOOK_SECRET GRAFANA_ADMIN_PASSWORD NOCODB_JWT_SECRET; do
  [ -n "$(env_val $key)" ] || set_env "$key" "$(openssl rand -hex 24)"
done
[ -n "$(env_val NOCODB_ADMIN_PASSWORD)" ] || set_env NOCODB_ADMIN_PASSWORD "$(openssl rand -hex 12)Aa1!"
[ -n "$(env_val N8N_OWNER_EMAIL)" ] || set_env N8N_OWNER_EMAIL admin@greeter.local
[ -n "$(env_val N8N_OWNER_PASSWORD)" ] || set_env N8N_OWNER_PASSWORD "$(openssl rand -hex 12)Aa1"
# knowledge base search in agent.tools: the embeddings endpoint of cred-embeddings (below)
if [ -n "$(env_val OPENROUTER_API_KEY)" ]; then set_env EMBEDDINGS_API_URL https://openrouter.ai/api/v1
else set_env EMBEDDINGS_API_URL "$STUB/v1"; fi
set -a; . ./.env; set +a

# ---------------------------------------------------------------- stack + database
mkdir -p reports && chmod a+rwx reports  # n8n (eval.run) and k6 write reports from their containers
docker compose up -d --wait postgres
scripts/migrate.sh
docker compose up -d --wait
psql_app() { docker compose exec -T postgres psql -X -q -At -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d app "$@"; }

# ---------------------------------------------------------------- n8n owner, session, API key
if [ "$(curl -sf $N8N/rest/settings | jq '.data.userManagement.showSetupOnFirstLoad')" = "true" ]; then
  jq -n --arg e "$N8N_OWNER_EMAIL" --arg p "$N8N_OWNER_PASSWORD" \
    '{email: $e, password: $p, firstName: "Greeter", lastName: "Admin"}' |
    curl -sf -o /dev/null -X POST $N8N/rest/owner/setup -H 'Content-Type: application/json' -d @-
  echo "created n8n owner $N8N_OWNER_EMAIL (password in .env)"
fi
jar=$(mktemp); tmpdir=$(mktemp -d); trap 'rm -rf "$jar" "$tmpdir"' EXIT
bid=$(openssl rand -hex 16)  # n8n binds the auth cookie to a browser-id header
rest() { curl -sf -b "$jar" -c "$jar" -H "browser-id: $bid" -H 'Content-Type: application/json' "$@"; }
jq -n --arg e "$N8N_OWNER_EMAIL" --arg p "$N8N_OWNER_PASSWORD" '{emailOrLdapLoginId: $e, password: $p}' |
  rest -o /dev/null -X POST $N8N/rest/login -d @-
new_api_key() {  # new_api_key LABEL -> raw key; drops keys with the same label first
  local id
  for id in $(rest $N8N/rest/api-keys | jq -r --arg l "$1" '.data.items[] | select(.label == $l) | .id'); do
    rest -o /dev/null -X DELETE "$N8N/rest/api-keys/$id"
  done
  jq -n --arg l "$1" --argjson s "$(rest $N8N/rest/api-keys/scopes | jq -c '.data')" '{label: $l, scopes: $s, expiresAt: null}' |
    rest -X POST $N8N/rest/api-keys -d @- | jq -r '.data.rawApiKey'
}
api() { curl -sf -H "X-N8N-API-KEY: $N8N_API_KEY" -H 'Content-Type: application/json' "$@"; }
if [ -z "${N8N_API_KEY:-}" ] || ! api "$N8N/api/v1/workflows?limit=1" >/dev/null; then
  N8N_API_KEY=$(new_api_key "greeter-runtime")
  set_env N8N_API_KEY "$N8N_API_KEY"
  echo "created n8n API key (N8N_API_KEY in .env)"
fi

# ---------------------------------------------------------------- credentials (fixed ids)
sa_key=${GOOGLE_SA_PRIVATE_KEY:-}
[ -n "$sa_key" ] || sa_key=$(openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 2>/dev/null)  # stub signs anything
jq -n \
  --arg app_pw "$APP_DB_PASSWORD" --arg openrouter "${OPENROUTER_API_KEY:-}" --arg groq "${GROQ_API_KEY:-}" \
  --arg n8n_key "$N8N_API_KEY" --arg tg "${PLATFORM_TG_BOT_TOKEN:-}" --arg sa "$sa_key" \
  --arg widget "$WIDGET_HMAC_SECRET" --arg wa "${WA_APP_SECRET:-}" --arg admin "$ADMIN_TOKEN" --arg stub "$STUB" \
  --arg platform_secret "$PLATFORM_TG_WEBHOOK_SECRET" '
  def cred($id; $name; $type; $data): {id: $id, name: $name, type: $type, data: $data};
  [
    cred("cred-pg-app"; "Postgres app"; "postgres";
         {host: "postgres", port: 5432, database: "app", user: "app", password: $app_pw, ssl: "disable", maxConnections: 30}),
    cred("cred-openrouter"; "OpenRouter"; "openRouterApi";
         {apiKey: (if $openrouter == "" then "unset" else $openrouter end), url: "https://openrouter.ai/api/v1"}),
    # Groq through its OpenAI-compatible API: the OpenAI chat node has a request timeout, the Groq node has none
    cred("cred-groq-openai"; "Groq (OpenAI-compatible)"; "openAiApi";
         {apiKey: (if $groq == "" then "unset" else $groq end), url: "https://api.groq.com/openai/v1"}),
    cred("cred-llm-stub"; "Stub LLM (OpenAI-compatible)"; "openAiApi"; {apiKey: "stub", url: ($stub + "/v1")}),
    # knowledge base embeddings for the whole installation: OpenRouter (OpenAI-compatible API) or the stub
    cred("cred-embeddings"; "Embeddings"; "openAiApi";
         (if $openrouter == "" then {apiKey: "stub", url: ($stub + "/v1")}
          else {apiKey: $openrouter, url: "https://openrouter.ai/api/v1"} end)),
    cred("cred-n8n-api"; "n8n API"; "n8nApi"; {apiKey: $n8n_key, baseUrl: "http://n8n:5678/api/v1"}),
    cred("cred-tg-platform"; "Platform bot"; "telegramApi";
         (if $tg == "" then {accessToken: "0:platform-stub", baseUrl: ($stub + "/telegram")}
          else {accessToken: $tg, baseUrl: "https://api.telegram.org"} end)),
    cred("cred-google-sa"; "Google service account key"; "jwtAuth";
         {keyType: "pemKey", privateKey: ($sa | gsub("\\\\n"; "\n")), publicKey: "", algorithm: "RS256"}),
    cred("cred-widget-hmac"; "Widget session HMAC"; "crypto"; {hmacSecret: $widget}),
    cred("cred-wa-app-secret"; "WhatsApp app secret"; "crypto"; {hmacSecret: (if $wa == "" then "stub-wa-secret" else $wa end)}),
    cred("cred-admin-token"; "Admin webhook token"; "httpHeaderAuth"; {name: "X-Admin-Token", value: $admin}),
    cred("cred-platform-webhook"; "Platform bot webhook secret"; "httpHeaderAuth";
         {name: "X-Telegram-Bot-Api-Secret-Token", value: $platform_secret})
  ]' > "$tmpdir/credentials.json"
docker compose exec -T n8n sh -c 'f=$(mktemp) && cat > "$f" && n8n import:credentials --input="$f" >/dev/null; rc=$?; rm -f "$f"; exit $rc' \
  < "$tmpdir/credentials.json"
echo "credentials: $(jq length "$tmpdir/credentials.json") imported"

# ---------------------------------------------------------------- workflows
if compgen -G "n8n/workflows/*.json" >/dev/null; then
  scripts/check-workflows.sh
  tar -C n8n/workflows -cf - . |
    docker compose exec -T n8n sh -c 'd=$(mktemp -d) && tar -C "$d" -xf - && n8n import:workflow --separate --input="$d" >/dev/null; rc=$?; rm -rf "$d"; exit $rc'
  # n8n publishes a workflow only after the sub-workflows it calls: repeat passes until nothing moves
  pending=$(for f in n8n/workflows/*.json; do [ "$(jq -r ".meta.publish // true" "$f")" = true ] && jq -r .id "$f"; done | xargs)
  while [ -n "$pending" ]; do
    left=""; errors=""
    for id in $pending; do
      out=$(curl -s -w '\n%{http_code}' -X POST -H "X-N8N-API-KEY: $N8N_API_KEY" "$N8N/api/v1/workflows/$id/publish")
      [ "$(tail -1 <<<"$out")" = 200 ] && continue
      left="$left $id"; errors="$errors\n  $id: $(head -1 <<<"$out" | jq -r '.message // .' 2>/dev/null)"
    done
    left=${left# }
    if [ "$left" = "$pending" ]; then printf "publish failed:%b\n" "$errors" >&2; exit 1; fi
    pending=$left
  done
  echo "workflows: $(ls n8n/workflows/*.json | wc -l) imported and published"
fi

# ---------------------------------------------------------------- tenants
# tenant.json + secrets from .env. A clinic key that is not set yet becomes a stub endpoint.
render_tenant() {
  local doc base
  doc=$(jq -c . "$1")
  base=$(jq -r '.extends // empty' <<<"$doc")
  [ -z "$base" ] || doc=$(jq -c --slurpfile b "tenants/$base/tenant.json" '($b[0] * .) | del(.extends)' <<<"$doc")
  jq -c --arg stub "$STUB" '
    def env($k): if $k == null then "" else ($ENV[$k] // "") end;
    (.env // {}) as $m
    | .llm_profile = (if .llm_profile == "stub" then "stub"
                      elif env("OPENROUTER_API_KEY") != "" and .llm_profile != "groq" then "openrouter"
                      elif env("GROQ_API_KEY") != "" then "groq"
                      elif env("OPENROUTER_API_KEY") != "" then "openrouter"
                      else "stub" end)
    | .config.operator.chat_id = ([env($m.operator_chat_id), .config.operator.chat_id, "-1001000000001"] | map(select(. != null and . != "")) | first)
    | if ($m | length) == 0 then . else
        (if env("GOOGLE_SA_PRIVATE_KEY") == ""
         then .config.calendar = {api_base: ($stub + "/google/calendar/v3"), token_uri: ($stub + "/google/token")}
              | .branches |= map(.calendar_id = "stub-" + .slug)
         else .branches |= map(.calendar_id = env($m.calendars[.slug])) end)
      end
    | .channels += (
        (if $m.telegram_token == null then []
         elif env($m.telegram_token) != "" then [{channel: "telegram", external_id: (env($m.telegram_token) | split(":")[0]),
                                                  token: env($m.telegram_token), api_base: "https://api.telegram.org"}]
         else [{channel: "telegram", external_id: (.slug + "-stub-bot"), name: "@stub_bot", token: "0:stub", api_base: ($stub + "/telegram")}] end)
        + (if $m.whatsapp_phone_number_id == null then []
           elif env($m.whatsapp_phone_number_id) != "" then [{channel: "whatsapp", external_id: env($m.whatsapp_phone_number_id),
                                                             token: env($m.whatsapp_token), api_base: "https://graph.facebook.com/v21.0"}]
           else [{channel: "whatsapp", external_id: (.slug + "-stub-wa"), token: "stub", api_base: ($stub + "/whatsapp")}] end))
    | del(.env)' <<<"$doc"
}

public_url=${WEBHOOK_URL:-}
for f in tenants/*/tenant.json; do
  slug=$(basename "$(dirname "$f")")
  doc=$(render_tenant "$f")
  res=$(psql_app -v doc="$doc" -v key="$APP_ENCRYPTION_KEY" <<<"select upsert_tenant(:'doc'::jsonb, :'key')")
  echo "tenant $slug: $(jq -c '{llm: $d.llm_profile, branches, services, doctors, shifts, channels: [.channels[] | .channel]}' --argjson d "$doc" <<<"$res")"
  # Telegram webhooks for real bots, when n8n has a public https URL. A failure (stale tunnel URL, bad token,
  # no network) is a warning: the rest of bootstrap still runs.
  jq -c '.channels[] | select(.channel == "telegram" and (.api_base | startswith("https://")))' <<<"$res" | while read -r ch; do
    ext=$(jq -r .external_id <<<"$ch")
    token=$(jq -r --arg e "$ext" '.channels[] | select(.channel == "telegram" and .external_id == $e) | .token // empty' <<<"$doc")
    if [ -z "$token" ]; then
      echo "  WARN telegram bot $ext: no token in .env, webhook not set" >&2
    elif [[ "$public_url" == https://* ]]; then
      resp=$(curl -sS --max-time 20 "$(jq -r .api_base <<<"$ch")/bot$token/setWebhook" \
        -d "url=${public_url%/}/webhook/tg/$(jq -r .id <<<"$ch")" -d "secret_token=$(jq -r .webhook_secret <<<"$ch")" \
        --data-urlencode 'allowed_updates=["message","callback_query"]' 2>&1) || true
      if [ "$(jq -r '.ok // false' <<<"$resp" 2>/dev/null)" = true ]; then
        echo "  telegram webhook set for bot $ext"
      else
        echo "  WARN telegram webhook for bot $ext not set: $resp" >&2
      fi
    else
      echo "  telegram bot $ext: set WEBHOOK_URL to a public https URL and re-run to register its webhook"
    fi
  done
done

# platform bot: Replay buttons of error alerts come back through /webhook/ops/tg. The demo clinic bot may double
# as the platform bot: then its own webhook stays and in.telegram hands the Replay buttons to ops.replay.
if [ -n "${PLATFORM_TG_BOT_TOKEN:-}" ] && [ "$PLATFORM_TG_BOT_TOKEN" = "${DEMO_TG_BOT_TOKEN:-}" ]; then
  echo "platform bot = demo clinic bot: Replay buttons arrive through the clinic webhook"
elif [ -n "${PLATFORM_TG_BOT_TOKEN:-}" ]; then
  if [[ "$public_url" == https://* ]]; then
    resp=$(curl -sS --max-time 20 "https://api.telegram.org/bot$PLATFORM_TG_BOT_TOKEN/setWebhook" -d "url=${public_url%/}/webhook/ops/tg" \
      -d "secret_token=$PLATFORM_TG_WEBHOOK_SECRET" --data-urlencode 'allowed_updates=["callback_query"]' 2>&1) || true
    if [ "$(jq -r '.ok // false' <<<"$resp" 2>/dev/null)" = true ]; then
      echo "platform bot webhook set"
    else
      echo "WARN platform bot webhook not set: $resp" >&2
    fi
  else
    echo "platform bot: set WEBHOOK_URL to a public https URL and re-run to enable Replay buttons"
  fi
fi

# ---------------------------------------------------------------- knowledge base, demo data, eval dataset
if curl -s -o /dev/null -w '%{http_code}' -X POST "$N8N/webhook/admin/reindex" | grep -qv 404; then
  for dir in tenants/*/; do
    [ -f "$dir/tenant.json" ] || continue  # tenants/examples: onboarding form samples
    slug=$(basename "$dir")
    kb=$dir/kb; base=$(jq -r '.extends // empty' "$dir/tenant.json"); [ -d "$kb" ] || kb=tenants/$base/kb
    [ -d "$kb" ] || continue
    jq -n --arg slug "$slug" '{tenant: $slug, articles: [inputs]}' \
      < <(for a in "$kb"/*.md; do jq -Rs --arg n "$(basename "$a" .md)" '{name: $n, text: .}' "$a"; done) |
      curl -sf -X POST "$N8N/webhook/admin/reindex" -H "X-Admin-Token: $ADMIN_TOKEN" -H 'Content-Type: application/json' -d @- |
      jq -r --arg s "$slug" '"knowledge base " + $s + ": " + (.chunks | tostring) + " chunks"' ||
      echo "knowledge base $slug: indexing failed, see admin.reindex executions (OpenRouter key without credit?)" >&2
  done
fi
if [ -d db/seed ] && [ "$(psql_app -c "select count(*) from appointments a join tenants t on t.id = a.tenant_id where t.slug = 'demo' and a.source = 'seed'")" = 0 ]; then
  for f in db/seed/*.sql; do { echo "set role app;"; cat "$f"; } | psql_app -1 >/dev/null; done
  echo "demo data seeded"
fi
if [ -f evals/scenarios.json ] && [ -x scripts/sync-evals.sh ]; then
  scripts/sync-evals.sh
fi

# ---------------------------------------------------------------- NocoDB (P1): admin grids on the app database
NC=http://localhost:8081
until curl -sf "$NC/api/v1/health" >/dev/null; do sleep 2; done
nc_token=$(jq -n --arg e "$N8N_OWNER_EMAIL" --arg p "$NOCODB_ADMIN_PASSWORD" '{email: $e, password: $p}' |
  curl -sf -X POST "$NC/api/v1/auth/user/signin" -H 'Content-Type: application/json' -d @- | jq -r .token)
if ! curl -sf "$NC/api/v2/meta/bases" -H "xc-auth: $nc_token" | jq -e '.list[] | select(.title == "Clinic admin")' >/dev/null; then
  jq -n --arg pw "$NOCODB_DB_PASSWORD" '{title: "Clinic admin", external: true, sources: [{alias: "app", type: "pg",
      inflection_column: "none", inflection_table: "none",
      config: {client: "pg", connection: {host: "postgres", port: 5432, user: "nocodb", password: $pw, database: "app"},
               searchPath: ["public"]}}]}' |
    curl -sf -o /dev/null -X POST "$NC/api/v2/meta/bases" -H "xc-auth: $nc_token" -H 'Content-Type: application/json' -d @-
  echo "nocodb: base \"Clinic admin\" connected to the app database"
fi

# ---------------------------------------------------------------- Grafana: public link to the demo dashboard
# (no anonymous access; a shared dashboard runs only its own queries)
G=http://localhost:3000/grafana/api
until curl -sf "$G/health" >/dev/null; do sleep 2; done
dash_token=$(curl -s -u "admin:$GRAFANA_ADMIN_PASSWORD" "$G/dashboards/uid/greeter-demo/public-dashboards" | jq -r '.accessToken // empty')
[ -n "$dash_token" ] || dash_token=$(curl -sf -u "admin:$GRAFANA_ADMIN_PASSWORD" -X POST -H 'Content-Type: application/json' \
  "$G/dashboards/uid/greeter-demo/public-dashboards" -d '{"isEnabled": true, "share": "public", "timeSelectionEnabled": true}' | jq -r .accessToken)
public_dashboard="public-dashboards/$dash_token"

# ---------------------------------------------------------------- demo page settings (web/config.js)
widget_id=$(psql_app -c "select ca.id from channel_accounts ca join tenants t on t.id = ca.tenant_id
                         where t.slug = 'demo' and ca.channel = 'widget' limit 1")
tg_url=null
if [ -n "${DEMO_TG_BOT_TOKEN:-}" ]; then
  tg_user=$(curl -sf "https://api.telegram.org/bot$DEMO_TG_BOT_TOKEN/getMe" | jq -r '.result.username // empty' || true)
  [ -z "$tg_user" ] || tg_url="\"https://t.me/$tg_user\""
fi
printf '// generated by scripts/bootstrap.sh\nwindow.GREETER = { widget: "/webhook/widget/%s", dashboard: "/grafana/%s", telegram: %s };\n' \
  "$widget_id" "$public_dashboard" "$tg_url" > web/config.js

# ---------------------------------------------------------------- Claude Code MCP servers (local scope)
if command -v claude >/dev/null && ! { claude mcp get n8n >/dev/null 2>&1 && claude mcp get n8n-mcp >/dev/null 2>&1; }; then
  mcp_key=$(new_api_key "claude-code n8n-mcp")
  mcp_token=$(rest -X POST $N8N/rest/mcp/api-key/rotate | jq -r '.data.apiKey')  # GET returns it redacted
  claude mcp remove -s local n8n-mcp >/dev/null 2>&1 || true
  claude mcp remove -s local n8n >/dev/null 2>&1 || true
  # MCP_MODE=stdio: otherwise debug logs break the protocol. WEBHOOK_SECURITY_MODE=moderate: allow loopback n8n URLs.
  claude mcp add -s local n8n-mcp --env MCP_MODE=stdio --env LOG_LEVEL=error --env DISABLE_CONSOLE_OUTPUT=true \
    --env N8N_API_URL=$N8N --env N8N_API_KEY="$mcp_key" --env WEBHOOK_SECURITY_MODE=moderate -- npx -y n8n-mcp >/dev/null
  claude mcp add -s local --transport http n8n $N8N/mcp-server/http --header "Authorization: Bearer $mcp_token" >/dev/null
  echo "registered MCP servers n8n-mcp and n8n (local scope); restart Claude Code to load them"
fi

cat <<EOF

Ready.
  n8n        http://localhost:5678   ($N8N_OWNER_EMAIL / password in .env)
  demo page  http://localhost:${CADDY_HTTP_PORT:-8080}
  grafana    http://localhost:${CADDY_HTTP_PORT:-8080}/grafana   (admin / GRAFANA_ADMIN_PASSWORD)
  dashboard  http://localhost:${CADDY_HTTP_PORT:-8080}/grafana/$public_dashboard   (public demo link)
  nocodb     http://localhost:8081   ($N8N_OWNER_EMAIL / NOCODB_ADMIN_PASSWORD)
EOF
