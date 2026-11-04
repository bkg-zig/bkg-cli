#!/usr/bin/env bash
set -euo pipefail

# OneCLI Local Build Script
# Builds all images from source with the current code

REPO_ROOT="/srv/kirocrew/source/bkg-cli"
cd "$REPO_ROOT"

echo "=== OneCLI Local Build ==="
echo "Commit: $(git rev-parse --short HEAD)"
echo "Branch: $(git branch --show-current)"
echo ""

# Build all services
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

# Tag with timestamp
TAG="local-$(date +%Y%m%d-%H%M%S)"
for img in api web gateway runner ssh-terminator channel-adapter; do
    docker tag "ghcr.io/onecli/onecli-${img}:latest" "ghcr.io/onecli/onecli-${img}:${TAG}"
done

echo ""
echo "=== Build complete ==="
echo "Images tagged with: ${TAG}"
echo ""
echo "To deploy to /srv/bkg/services/onecli:"
echo "  cd /srv/bkg/services/onecli"
echo "  sed -i 's|ONECLI_VERSION=.*|ONECLI_VERSION=${TAG}|' .env"
echo "  docker compose pull"
echo "  docker compose up -d"
echo ""
echo "To verify Eysho provider in built image:"
echo "  docker run --rm ghcr.io/onecli/onecli-api:${TAG} grep -r eysho /app/apps/api-server/dist"