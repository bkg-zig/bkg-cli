#!/usr/bin/env bash
set -euo pipefail

# OneCLI Railway Deploy Script
# Builds images from source, pushes to GHCR, and deploys to Railway
# Auto-generates and sets all required secrets

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

echo "=== OneCLI Railway Deploy ==="
echo "Repo: $REPO_ROOT"
echo "Git: $(git rev-parse --short HEAD) ($(git branch --show-current))"
echo ""

# Check Railway CLI
if ! command -v railway &> /dev/null; then
    echo "ERROR: Railway CLI not found. Install with: npm i -g @railway/cli"
    exit 1
fi

# Check GHCR credentials
if [[ -z "${GHCR_TOKEN:-}" || -z "${GHCR_USER:-}" ]]; then
    echo "ERROR: GHCR_TOKEN and GHCR_USER must be set"
    echo "  export GHCR_USER=your-github-username"
    echo "  export GHCR_TOKEN=your-github-token (with write:packages scope)"
    exit 1
fi

# 1. Verify Eysho provider
echo "=== 1. Verifying Eysho provider ==="
if ! grep -q '"eysho"' packages/api/src/llm/types.ts; then
    echo "ERROR: Eysho provider not in types.ts"
    exit 1
fi
if [[ ! -f packages/api/src/llm/eysho.ts ]]; then
    echo "ERROR: packages/api/src/llm/eysho.ts missing"
    exit 1
fi
echo "Eysho provider code verified ✓"

# 2. Generate all secrets
echo ""
echo "=== 2. Generating secrets ==="
BETTER_AUTH_SECRET=$(openssl rand -base64 32)
SECRET_ENCRYPTION_KEY=$(openssl rand -base64 32)
GATEWAY_INTERNAL_SECRET=$(openssl rand -base64 32)
RUNNER_TOKEN="rnr_$(openssl rand -hex 32)"
RUNNER_SESSION_KEY="k1.$(openssl rand -hex 32)"
CHANNEL_ADAPTER_TOKEN="cha_$(openssl rand -hex 32)"
SSH_TERMINATOR_SECRET="ssh_$(openssl rand -hex 32)"

# Generate SSH keys
echo "Generating SSH keys..."
ssh-keygen -t ed25519 -f /tmp/terminator -N "" -C "onecli-ssh-terminator" >/dev/null 2>&1
TERMINATOR_HOST_KEY=$(cat /tmp/terminator | sed ':a;N;s/\n/\\n/g;ta')
TERMINATOR_CA_PUBLIC_KEY=$(cat /tmp/terminator.pub)

echo "Secrets generated ✓"

# 3. Set secrets in Railway
echo ""
echo "=== 3. Setting secrets in Railway ==="
railway variables set BETTER_AUTH_SECRET="${BETTER_AUTH_SECRET}"
railway variables set SECRET_ENCRYPTION_KEY="${SECRET_ENCRYPTION_KEY}"
railway variables set GATEWAY_INTERNAL_SECRET="${GATEWAY_INTERNAL_SECRET}"
railway variables set RUNNER_TOKEN="${RUNNER_TOKEN}"
railway variables set RUNNER_SESSION_KEY="${RUNNER_SESSION_KEY}"
railway variables set CHANNEL_ADAPTER_TOKEN="${CHANNEL_ADAPTER_TOKEN}"
railway variables set SSH_TERMINATOR_SECRET="${SSH_TERMINATOR_SECRET}"
railway variables set TERMINATOR_HOST_KEY="${TERMINATOR_HOST_KEY}"
railway variables set TERMINATOR_CA_PUBLIC_KEY="${TERMINATOR_CA_PUBLIC_KEY}"

# Domain configuration
railway variables set ONECLI_EXTERNAL_URL="https://cli.eysho.info"
railway variables set APP_URL="https://cli.eysho.info"
railway variables set API_URL="https://api.cli.eysho.info"
railway variables set GATEWAY_API_URL="https://gw.cli.eysho.info"
railway variables set ONECLI_TRUSTED_ORIGINS="https://cli.eysho.info"
railway variables set BETTER_AUTH_COOKIE_DOMAIN="cli.eysho.info"
railway variables set GATEWAY_ALLOW_PRIVATE_DESTINATIONS="true"

echo "All secrets set in Railway ✓"

# 4. Build images from source
echo ""
echo "=== 4. Building Docker images from source ==="
for svc in api web gateway runner ssh-terminator channel-adapter migrations; do
    echo "Building $svc..."
    docker compose -f docker/docker-compose.yml -f docker/docker-compose.build.yml build "$svc"
done
echo "All images built ✓"

# 5. Tag and push to GHCR
echo ""
echo "=== 5. Tagging and pushing to GHCR ==="
RAILWAY_TAG="${RAILWAY_TAG:-railway-$(date +%Y%m%d-%H%M%S)}"
railway variables set ONECLI_VERSION="${RAILWAY_TAG}"

echo "${GHCR_TOKEN}" | docker login ghcr.io -u "${GHCR_USER}" --password-stdin

for img in api web gateway runner ssh-terminator channel-adapter migrations; do
    docker tag "ghcr.io/onecli/onecli-${img}:latest" "ghcr.io/onecli/onecli-${img}:${RAILWAY_TAG}"
    echo "Pushing ghcr.io/onecli/onecli-${img}:${RAILWAY_TAG}..."
    docker push "ghcr.io/onecli/onecli-${img}:${RAILWAY_TAG}"
    docker push "ghcr.io/onecli/onecli-${img}:latest"
done
echo "All images pushed ✓"

# 6. Deploy to Railway
echo ""
echo "=== 6. Deploying to Railway ==="
railway up --detach
echo "Railway deploy triggered ✓"

# 7. Verification
echo ""
echo "=== 7. Verification ==="
echo "Wait 60-120s for deploy, then verify:"
echo "  curl -s https://api.cli.eysho.info/v1/health"
echo "  curl -s https://cli.eysho.info | grep -i onecli"
echo "  curl -s https://gw.cli.eysho.info/health"
echo ""
echo "Expected domains:"
echo "  https://cli.eysho.info      (web)"
echo "  https://api.cli.eysho.info  (api)"
echo "  https://gw.cli.eysho.info   (gateway)"
echo ""
echo "=== Deploy complete ==="
echo "Tag: ${RAILWAY_TAG}"
echo "Commit: $(git rev-parse HEAD)"
echo ""
echo "Secrets saved to /tmp/onecli-secrets-$(date +%s).txt for backup"
cat > /tmp/onecli-secrets-$(date +%s).txt <<EOF
BETTER_AUTH_SECRET=${BETTER_AUTH_SECRET}
SECRET_ENCRYPTION_KEY=${SECRET_ENCRYPTION_KEY}
GATEWAY_INTERNAL_SECRET=${GATEWAY_INTERNAL_SECRET}
RUNNER_TOKEN=${RUNNER_TOKEN}
RUNNER_SESSION_KEY=${RUNNER_SESSION_KEY}
CHANNEL_ADAPTER_TOKEN=${CHANNEL_ADAPTER_TOKEN}
SSH_TERMINATOR_SECRET=${SSH_TERMINATOR_SECRET}
TERMINATOR_HOST_KEY=${TERMINATOR_HOST_KEY}
TERMINATOR_CA_PUBLIC_KEY=${TERMINATOR_CA_PUBLIC_KEY}
EOF