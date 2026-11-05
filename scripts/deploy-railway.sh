#!/usr/bin/env bash
# OneCLI → Railway deployment.
#
# Railway's model is a project with one service per container; the topology
# (services, sources, builds, networking, volumes, database) lives in
# `.railway/railway.ts` and is applied with `railway config apply`. This script
# owns everything the IaC file deliberately does NOT:
#
#   1. branch guard + push of `tango` (Railway builds the pushed commit)
#   2. applying the IaC file (plan → review → apply)
#   3. the public domains and their target ports
#   4. the runtime variables (secrets are read back, never regenerated)
#   5. the deploy ORDER — migrations must succeed before api/web/gateway
#      start against that schema
#   6. verification of the public endpoints
#
# Secrets: BETTER_AUTH_SECRET, SECRET_ENCRYPTION_KEY and
# GATEWAY_INTERNAL_SECRET already exist in the Railway project as shared
# variables. They are NEVER written by this script — a fresh
# SECRET_ENCRYPTION_KEY would orphan every encrypted credential in the
# database. The script only reads them back to verify that every service
# that needs one references it.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

BRANCH="${RAILWAY_BRANCH:-tango}"
REPO_SLUG="${RAILWAY_REPO:-bkg-zig/bkg-cli}"
PROJECT_ID="${RAILWAY_PROJECT:-}"
ENVIRONMENT="${RAILWAY_ENVIRONMENT:-production}"
DRY_RUN=0
SKIP_PUSH=0
SKIP_IAC=0
VARIABLES_ONLY=0
CONFIRM_DESTRUCTIVE=0

# Service name → the port the image listens on (docker/*.Dockerfile).
declare -A SERVICE_PORT=(
    [bkg-one-cli]=10254
    [api]=10256
    [gateway]=10255
)

# ── CLI flags ────────────────────────────────────────────────────────────────
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=1 ;;
        --skip-push) SKIP_PUSH=1 ;;
        --skip-iac) SKIP_IAC=1 ;;
        --variables-only) VARIABLES_ONLY=1 ;;
        --confirm-destructive) CONFIRM_DESTRUCTIVE=1 ;;
        --project=*) PROJECT_ID="${arg#*=}" ;;
        -h | --help)
            cat <<EOF
Usage: $0 [--dry-run] [--skip-push] [--skip-iac] [--variables-only] [--project=ID] [--confirm-destructive]

  --dry-run               Print what would happen; change nothing.
  --skip-push             Do not push the branch (deploy the last pushed commit).
  --skip-iac              Do not apply .railway/railway.ts.
  --variables-only        Set the variables and stop — no deployment.
  --project=ID            Railway project to link (else: the already linked one).
  --confirm-destructive   Allow an IaC plan that destroys resources.

Branch:     $BRANCH
Repo:       $REPO_SLUG
Environment: $ENVIRONMENT
EOF
            exit 0
            ;;
        *)
            echo "ERROR: unknown argument: $arg" >&2
            exit 1
            ;;
    esac
done

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'
log() { echo -e "${BLUE}[railway]${NC} $*"; }
ok() { echo -e "${GREEN}[ok]${NC} $*"; }
warn() { echo -e "${YELLOW}[warn]${NC} $*"; }
err() { echo -e "${RED}[err]${NC} $*" >&2; }
die() {
    err "$*"
    exit 1
}

run() {
    if [[ "$DRY_RUN" -eq 1 ]]; then
        log "(dry-run) $*"
        return 0
    fi
    "$@"
}

# The Railway IaC SDK verifies the CLI version by exec'ing `process.env._`.
# Bash sets `_` to the last executed command, so the CLI must be invoked
# through its absolute path — otherwise the check runs `node --version` and
# the IaC file is rejected.
RAILWAY_BIN="${RAILWAY_BIN:-$(command -v railway || true)}"
[[ -n "$RAILWAY_BIN" ]] || die "Railway CLI not found (npm i -g @railway/cli)"
RAILWAY_BIN="$(cd "$(dirname "$RAILWAY_BIN")" && pwd)/$(basename "$RAILWAY_BIN")"
railway() { "$RAILWAY_BIN" "$@"; }

# ── 0. Preconditions ────────────────────────────────────────────────────────
log "=== Preconditions ==="

CURRENT_BRANCH="$(git branch --show-current)"
[[ "$CURRENT_BRANCH" == "$BRANCH" ]] ||
    die "on branch '$CURRENT_BRANCH', expected '$BRANCH'. Run: git checkout $BRANCH"

if [[ -n "$(git status --porcelain)" ]]; then
    warn "working tree is dirty — Railway builds the PUSHED commit; uncommitted"
    warn "changes are not deployed. Commit or stash them."
fi

node -e "require.resolve('railway/iac', { paths: ['$REPO_ROOT/.railway'] })" >/dev/null 2>&1 ||
    die "the Railway IaC SDK is missing. Run: npm install --prefix .railway railway@$(npm view railway version 2>/dev/null)"

if [[ -n "$PROJECT_ID" ]]; then
    log "linking project $PROJECT_ID"
    run railway link --project "$PROJECT_ID" --environment "$ENVIRONMENT"
fi

if ! railway status >/dev/null 2>&1; then
    die "no Railway project linked. Run: railway link --project <id> --environment $ENVIRONMENT"
fi
ok "linked: $(railway status 2>&1 | awk '/^Project:/{p=$2} /^Environment:/{e=$2} END{print p" / "e}')"

# The service names in this script are the names in the Railway project — the
# web dashboard is `bkg-one-cli`, not `web`. A typo used to die silently in
# the middle of the variable pass, so every name is checked up front.
RAILWAY_SERVICE_NAMES="$(railway service list --json 2>/dev/null |
    python3 -c 'import json,sys
try:
    data = json.load(sys.stdin)
except Exception:
    raise SystemExit(0)
items = data if isinstance(data, list) else data.get("services", [])
for item in items:
    if isinstance(item, dict) and item.get("name"):
        print(item["name"])')"
for svc in api bkg-one-cli gateway migrations; do
    grep -qx "$svc" <<<"$RAILWAY_SERVICE_NAMES" ||
        die "the Railway project has no service '$svc' (have: $(tr '\n' ' ' <<<"$RAILWAY_SERVICE_NAMES"))"
done
ok "services: $(tr '\n' ' ' <<<"$RAILWAY_SERVICE_NAMES")"

# ── 1. Push the branch ──────────────────────────────────────────────────────
log ""
log "=== Pushing $BRANCH ==="
if [[ "$SKIP_PUSH" -eq 1 ]]; then
    warn "skipping push (--skip-push)"
elif [[ "$DRY_RUN" -eq 1 ]]; then
    log "(dry-run) would push $BRANCH to origin/$BRANCH"
elif [[ -n "$(git status --porcelain)" ]]; then
    warn "skipping push (dirty tree) — deploying the last pushed commit"
else
    git push origin "$BRANCH:$BRANCH"
    ok "pushed $(git rev-parse --short HEAD) to origin/$BRANCH"
fi

# ── 2. IaC: the service topology ────────────────────────────────────────────
log ""
log "=== Railway IaC (.railway/railway.ts) ==="
if [[ "$SKIP_IAC" -eq 1 ]]; then
    warn "skipping IaC apply (--skip-iac)"
else
    PLAN_OUT="$(railway config plan 2>&1)" || die "railway config plan failed:\n$PLAN_OUT"
    echo "$PLAN_OUT"
    # "Plan: 0 to add, 6 to change, 0 to destroy" — only a non-zero destroy
    # count needs a human.
    destroy_count="$(awk '/^Plan:/ { for (i = 1; i <= NF; i++) if ($i == "destroy") print $(i - 2) }' <<<"$PLAN_OUT")"
    if [[ "${destroy_count:-0}" != "0" ]]; then
        if [[ "$CONFIRM_DESTRUCTIVE" -eq 1 ]]; then
            warn "plan destroys $destroy_count resource(s) — applying because --confirm-destructive was given"
        else
            die "the plan destroys $destroy_count resource(s). Review it and re-run with --confirm-destructive"
        fi
    fi
    if grep -q "to add, 0 to change, 0 to destroy" <<<"$PLAN_OUT"; then
        ok "topology already matches the IaC file"
    else
        run railway config apply --yes
        ok "IaC applied"
    fi
fi

# ── 3. Domains ──────────────────────────────────────────────────────────────
# One public domain per service; the target port must match the port the
# image listens on, otherwise Railway's edge answers 502 (and the browser
# reports "Failed to fetch").
log ""
log "=== Domains ==="

domain_of() {
    local service="$1"
    railway domain list --service "$service" --json 2>/dev/null |
        python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)
domains = data.get("domains", []) if isinstance(data, dict) else data
for d in domains:
    if d.get("type") == "service" and d.get("domain"):
        print(d["domain"])
        break
'
}

ensure_domain() {
    local service="$1" port="$2" domain
    domain="$(domain_of "$service")"
    if [[ -z "$domain" ]]; then
        if [[ "$DRY_RUN" -eq 1 ]]; then
            log "(dry-run) would create a Railway domain for $service" >&2
            echo "<${service}-domain>"
            return 0
        fi
        log "creating a Railway domain for $service" >&2
        domain="$(railway domain --service "$service" --json 2>/dev/null |
            python3 -c 'import json,sys; print(json.load(sys.stdin).get("domain","").replace("https://",""))')"
        [[ -n "$domain" ]] || die "could not create a domain for $service"
    fi
    local current
    current="$(railway domain list --service "$service" --json 2>/dev/null |
        python3 -c '
import json, sys
data = json.load(sys.stdin)
domains = data.get("domains", []) if isinstance(data, dict) else data
for d in domains:
    if d.get("domain") == sys.argv[1]:
        print(d.get("targetPort") or "")
        break
' "$domain")"
    if [[ "$current" != "$port" ]]; then
        log "pointing $domain at port $port (was ${current:-unset})" >&2
        run railway domain update "$domain" --port "$port" --service "$service" >&2
    fi
    ok "$service → https://$domain:$port" >&2
    echo "$domain"
}

WEB_DOMAIN="$(ensure_domain bkg-one-cli "${SERVICE_PORT[bkg-one-cli]}")"
API_DOMAIN="$(ensure_domain api "${SERVICE_PORT[api]}")"
GATEWAY_DOMAIN="$(ensure_domain gateway "${SERVICE_PORT[gateway]}")"

WEB_URL="https://$WEB_DOMAIN"
API_URL="https://$API_DOMAIN"
GATEWAY_URL="https://$GATEWAY_DOMAIN"

# ── 4. Variables ────────────────────────────────────────────────────────────
# Secrets are NOT set here: the project already carries BETTER_AUTH_SECRET,
# SECRET_ENCRYPTION_KEY and GATEWAY_INTERNAL_SECRET as shared variables, and
# the services reference them. The script verifies the reference instead.
log ""
log "=== Variables ==="

var_get() {
    local service="$1" name="$2"
    railway variable list --service "$service" --kv 2>/dev/null |
        awk -F= -v key="$name" '$1 == key { sub(/^[^=]*=/, ""); print; exit }'
}

var_set() {
    local service="$1" name="$2" value="$3"
    local current
    current="$(var_get "$service" "$name")"
    if [[ "$current" == "$value" ]]; then
        ok "  $service/$name already correct"
        return 0
    fi
    if [[ "$DRY_RUN" -eq 1 ]]; then
        log "(dry-run) railway variable set $name=… --service $service"
        return 0
    fi
    if ! railway variable set "$name=$value" --service "$service" --skip-deploys; then
        die "could not set $service/$name"
    fi
    ok "  $service/$name set"
}

var_delete() {
    local service="$1" name="$2" reason="${3:-}"
    if [[ -z "$(var_get "$service" "$name")" ]]; then
        ok "  $service/$name not set (nothing to delete)"
        return 0
    fi
    if [[ -n "$reason" ]]; then
        warn "  deleting $service/$name ($reason)"
    else
        warn "  deleting $service/$name"
    fi
    if [[ "$DRY_RUN" -eq 1 ]]; then
        log "(dry-run) railway variable delete $name --service $service"
        return 0
    fi
    # A shared variable cannot be deleted through a service scope — the
    # warning says so, the deploy continues.
    railway variable delete "$name" --service "$service" ||
        warn "  could not delete $service/$name (shared variable?) — check it in the Railway dashboard"
}

require_secret_ref() {
    local service="$1" name="$2" current
    current="$(var_get "$service" "$name")"
    if [[ -z "$current" ]]; then
        die "$service is missing $name — set the shared variable in the Railway project first"
    fi
    ok "  $service/$name references the shared secret"
}

# Shared wiring every service needs.
set_vars_common() {
    local service="$1"
    var_set "$service" ONECLI_EXTERNAL_URL "$WEB_URL"
    var_set "$service" APP_URL "$WEB_URL"
    var_set "$service" ONECLI_BIND_HOST "0.0.0.0"
    var_set "$service" ONECLI_APP_PORT "${SERVICE_PORT[bkg-one-cli]}"
}

set_vars_common api
var_set api PORT "${SERVICE_PORT[api]}"
# No API_URL / GATEWAY_API_URL: on Railway the browser must talk to the
# dashboard's OWN origin (the web proxies /v1 + /auth + /gw), otherwise the
# session cookie is a third-party cookie that SameSite=Lax never sends.
var_delete api API_URL "the browser talks to the dashboard's own origin"
var_delete api GATEWAY_API_URL "the gateway is proxied under /gw"
var_set api ONECLI_TRUSTED_ORIGINS "$WEB_URL"
var_set api ONECLI_API_PORT "${SERVICE_PORT[api]}"
var_set api ONECLI_GATEWAY_PORT "${SERVICE_PORT[gateway]}"
var_set api GATEWAY_INTERNAL_URL "http://gateway.railway.internal:${SERVICE_PORT[gateway]}"
var_set api API_INTERNAL_URL "http://api.railway.internal:${SERVICE_PORT[api]}"
var_set api INTERNAL_API_URL "http://api.railway.internal:${SERVICE_PORT[api]}"
var_set api ONECLI_AGENT_PROXY_ADDRESS "gateway.railway.internal:${SERVICE_PORT[gateway]}"
var_delete api BETTER_AUTH_COOKIE_DOMAIN "host-only cookie on the dashboard's host"
require_secret_ref api BETTER_AUTH_SECRET
require_secret_ref api SECRET_ENCRYPTION_KEY
require_secret_ref api GATEWAY_INTERNAL_SECRET

set_vars_common bkg-one-cli
var_set bkg-one-cli PORT "${SERVICE_PORT[bkg-one-cli]}"
# Single origin: the dashboard's domain serves /v1 + /auth (the api) and
# /gw/* (the gateway). The upstreams are the internal Railway addresses —
# the browser never leaves the web's origin, and the session cookie belongs
# to ONE host (the dashboard's), which is what the server-rendered pages
# need.
var_set bkg-one-cli ONECLI_SINGLE_ORIGIN_PROXY "1"
var_set bkg-one-cli INTERNAL_API_URL "http://api.railway.internal:${SERVICE_PORT[api]}"
var_set bkg-one-cli API_INTERNAL_URL "http://api.railway.internal:${SERVICE_PORT[api]}"
var_set bkg-one-cli GATEWAY_INTERNAL_URL "http://gateway.railway.internal:${SERVICE_PORT[gateway]}"
var_delete bkg-one-cli API_URL "single origin: the web proxies /v1"
var_delete bkg-one-cli GATEWAY_API_URL "single origin: the web proxies /gw"
var_set bkg-one-cli ONECLI_TRUSTED_ORIGINS "$WEB_URL"
var_set bkg-one-cli ONECLI_API_PORT "${SERVICE_PORT[api]}"
var_set bkg-one-cli ONECLI_GATEWAY_PORT "${SERVICE_PORT[gateway]}"
var_delete bkg-one-cli BETTER_AUTH_COOKIE_DOMAIN "host-only cookie on the dashboard's host"
require_secret_ref bkg-one-cli BETTER_AUTH_SECRET
require_secret_ref bkg-one-cli SECRET_ENCRYPTION_KEY

set_vars_common gateway
var_set gateway PORT "${SERVICE_PORT[gateway]}"
var_set gateway INTERNAL_API_URL "http://api.railway.internal:${SERVICE_PORT[api]}"
var_set gateway API_INTERNAL_URL "http://api.railway.internal:${SERVICE_PORT[api]}"
var_delete gateway API_URL "the gateway calls the api over the private network"
var_delete gateway GATEWAY_API_URL "the gateway is reached over the private network"
var_set gateway GATEWAY_ALLOW_PRIVATE_DESTINATIONS "true"
# The gateway image runs as the unprivileged user `onecli`; a Railway volume
# is mounted root-owned, so the CA directory would not be writable. Railway's
# documented switch for that is RAILWAY_RUN_UID=0 (the container then runs as
# root — the gateway itself drops no privileges, but the platform volume is
# the only thing it writes to).
var_set gateway RAILWAY_RUN_UID "0"
var_delete gateway BETTER_AUTH_COOKIE_DOMAIN "host-only cookie on the dashboard's host"
require_secret_ref gateway SECRET_ENCRYPTION_KEY
require_secret_ref gateway GATEWAY_INTERNAL_SECRET

var_set migrations PORT "10256"

# DATABASE_URL is the managed Postgres of this project. Railway hands it out
# as the reference `${{Postgres.DATABASE_URL}}` (the CLI resolves it to the
# real URL when it reads the variable back), so the script never writes a
# database password itself — it only sets the reference when a service has
# none at all.
for svc in migrations api bkg-one-cli gateway; do
    current="$(var_get "$svc" DATABASE_URL)"
    if [[ -z "$current" ]]; then
        var_set "$svc" DATABASE_URL '${{Postgres.DATABASE_URL}}'
    else
        ok "  $svc/DATABASE_URL points at the managed Postgres (kept)"
    fi
done

if [[ "$VARIABLES_ONLY" -eq 1 ]]; then
    log ""
    ok "variables set — stopping before the deployment (--variables-only)"
    exit 0
fi

# ── 5. Deploy ───────────────────────────────────────────────────────────────
# The order is load-bearing: api/web/gateway read the schema at boot, so the
# migration job has to finish successfully first.
log ""
log "=== Deploying ==="

deployment_status() {
    local service="$1" previous="${2:-}"
    railway deployment list --service "$service" --limit 5 --json 2>/dev/null |
        python3 -c '
import json, sys
previous = sys.argv[1]
try:
    data = json.load(sys.stdin)
except Exception:
    print("UNKNOWN")
    sys.exit(0)
items = data if isinstance(data, list) else data.get("deployments", [])
# The newest deployment that is not the one we saw before the redeploy —
# otherwise an old SUCCESS would be mistaken for the new one.
for item in items:
    if not isinstance(item, dict):
        continue
    if previous and item.get("id") == previous:
        break
    print(item.get("status") or "UNKNOWN")
    break
else:
    print("PENDING")
' "$previous"
}

wait_for_deployment() {
    local service="$1" previous="${2:-}" timeout="${3:-900}" waited=0 status
    while ((waited < timeout)); do
        status="$(deployment_status "$service" "$previous")"
        case "$status" in
            SUCCESS)
                ok "$service deployed successfully"
                return 0
                ;;
            FAILED | CRASHED | REMOVED)
                die "$service deployment $status — inspect: railway logs --service $service --build"
                ;;
        esac
        sleep 10
        waited=$((waited + 10))
        if ((waited % 60 == 0)); then
            log "$service deployment status: $status (${waited}s)"
        fi
    done
    die "$service deployment did not finish within ${timeout}s (last status: $status)"
}

deploy_service() {
    local service="$1"
    local previous
    previous="$(railway deployment list --service "$service" --limit 1 --json 2>/dev/null |
        python3 -c 'import json,sys
try:
    data = json.load(sys.stdin)
except Exception:
    print(""); raise SystemExit(0)
items = data if isinstance(data, list) else data.get("deployments", [])
print(items[0].get("id", "") if items and isinstance(items[0], dict) else "")')"
    log "deploying $service from source ($BRANCH)"
    run railway service redeploy --service "$service" --from-source --yes
    echo "$previous"
}

deploy_service migrations > /tmp/onecli-deploy-prev-migrations
if [[ "$DRY_RUN" -eq 0 ]]; then
    wait_for_deployment migrations "$(cat /tmp/onecli-deploy-prev-migrations)" 1800
fi

for svc in api bkg-one-cli gateway; do
    deploy_service "$svc" > "/tmp/onecli-deploy-prev-$svc"
done

if [[ "$DRY_RUN" -eq 0 ]]; then
    for svc in api bkg-one-cli gateway; do
        # The gateway image compiles the Rust workspace from scratch on
        # Railway — that build is the long pole, hence the generous budget.
        wait_for_deployment "$svc" "$(cat "/tmp/onecli-deploy-prev-$svc")" 2400
    done
fi

# ── 6. Verify ───────────────────────────────────────────────────────────────
log ""
log "=== Verification ==="
if [[ "$DRY_RUN" -eq 0 ]]; then
    curl -fsS --max-time 20 "$API_URL/v1/health" && echo || warn "api health check failed: $API_URL/v1/health"
    curl -fsS --max-time 20 "$GATEWAY_URL/healthz" && echo || warn "gateway health check failed: $GATEWAY_URL/healthz"
    curl -fsS --max-time 20 "$WEB_URL/healthz" && echo || warn "web health check failed: $WEB_URL/healthz"
fi

cat <<EOF

=== Railway deployment finished ===

  dashboard  $WEB_URL
  api        $API_URL
  gateway    $GATEWAY_URL
  branch     $BRANCH @ $(git rev-parse --short HEAD)

EOF
