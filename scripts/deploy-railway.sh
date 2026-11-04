#!/usr/bin/env bash
set -euo pipefail

# OneCLI Railway Deployment Script
# Builds and deploys OneCLI to Railway

REPO_ROOT="/srv/kirocrew/source/bkg-one-cli"
cd "$REPO_ROOT"

echo "=== OneCLI Railway Deploy ==="
echo "Repo: $REPO_ROOT"
echo "Git: $(git rev-parse --short HEAD) ($(git branch --show-current))"
echo ""

# 1. Verify we have the Eysho provider changes
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

# 2. Build images
echo ""
echo "=== 2. Building Docker images ==="
echo "Building api..."
docker compose -f docker/docker-compose.yml -f docker/docker-compose.build.yml build api

echo "Building web..."
docker compose -f docker/docker-compose.yml -f docker/docker-compose.build.yml build web

echo "Building gateway..."
docker compose -f docker/docker-compose.yml -f docker/docker-compose.build.yml build gateway

echo "Building runner..."
docker compose -f docker/docker-compose.yml -f docker/docker-compose.build.yml build runner

echo "Building ssh-terminator..."
docker compose -f docker/docker-compose.yml -f docker/docker-compose.build.yml build ssh-terminator

echo "Building channel-adapter..."
docker compose -f docker/docker-compose.yml -f docker/docker-compose.build.yml build channel-adapter

echo "All images built ✓"

# 3. Tag for Railway
echo ""
echo "=== 3. Tagging images for Railway ==="
RAILWAY_TAG="${RAILWAY_TAG:-railway-$(date +%Y%m%d-%H%M%S)}"
for img in api web gateway runner ssh-terminator channel-adapter; do
    docker tag "ghcr.io/onecli/onecli-${img}:latest" "ghcr.io/onecli/onecli-${img}:${RAILWAY_TAG}"
    echo "Tagged ghcr.io/onecli/onecli-${img}:${RAILWAY_TAG}"
done

# 4. Push to GHCR (Railway pulls from here)
echo ""
echo "=== 4. Pushing to GHCR ==="
echo "Logging in to ghcr.io..."
echo "${GHCR_TOKEN}" | docker login ghcr.io -u "${GHCR_USER}" --password-stdin

for img in api web gateway runner ssh-terminator channel-adapter; do
    echo "Pushing ghcr.io/onecli/onecli-${img}:${RAILWAY_TAG}..."
    docker push "ghcr.io/onecli/onecli-${img}:${RAILWAY_TAG}"
    docker push "ghcr.io/onecli/onecli-${img}:latest"
done
echo "All images pushed ✓"

# 5. Deploy to Railway via CLI
echo ""
echo "=== 5. Deploying to Railway ==="
if command -v railway &> /dev/null; then
    echo "Using Railway CLI..."
    
    # Set variables
    railway variables set ONECLI_VERSION="${RAILWAY_TAG}" --service api
    railway variables set ONECLI_VERSION="${RAILWAY_TAG}" --service web
    railway variables set ONECLI_VERSION="${RAILWAY_TAG}" --service gateway
    railway variables set ONECLI_VERSION="${RAILWAY_TAG}" --service runner
    railway variables set ONECLI_VERSION="${RAILWAY_TAG}" --service ssh-terminator
    railway variables set ONECLI_VERSION="${RAILWAY_TAG}" --service channel-adapter
    
    # Trigger deploy
    railway up --detach
    echo "Railway deploy triggered ✓"
else
    echo "Railway CLI not found. Manual steps:"
    echo "  1. Go to Railway dashboard"
    echo "  2. Set ONECLI_VERSION=${RAILWAY_TAG} on all services"
    echo "  3. Redeploy each service"
fi

# 6. Verify deployment
echo ""
echo "=== 6. Verification ==="
echo "Wait 60s for deploy, then run:"
echo "  curl -s https://api.cli.eysho.info/v1/health"
echo "  curl -s https://cli.eysho.info | grep OneCLI"
echo ""
echo "Expected domains:"
echo "  https://cli.eysho.info      (web)"
echo "  https://api.cli.eysho.info  (api)"
echo "  https://gw.cli.eysho.info   (gateway)"
echo ""
echo "=== Deploy complete ==="
echo "Tag: ${RAILWAY_TAG}"
echo "Commit: $(git rev-parse HEAD)"