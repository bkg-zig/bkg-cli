#!/usr/bin/env bash
set -euo pipefail

# OneCLI Railway Secrets Generator
# Run this once, save the output, and add to Railway project variables

echo "=== OneCLI Railway Secrets Generator ==="
echo ""
echo "Copy these values to Railway: Project → Settings → Variables"
echo ""

# Core secrets
BETTER_AUTH_SECRET=$(openssl rand -base64 32)
SECRET_ENCRYPTION_KEY=$(openssl rand -base64 32)
GATEWAY_INTERNAL_SECRET=$(openssl rand -base64 32)

echo "# Core secrets (required)"
echo "BETTER_AUTH_SECRET=${BETTER_AUTH_SECRET}"
echo "SECRET_ENCRYPTION_KEY=${SECRET_ENCRYPTION_KEY}"
echo "GATEWAY_INTERNAL_SECRET=${GATEWAY_INTERNAL_SECRET}"
echo ""

# Runner / SSH / Channels
RUNNER_TOKEN="rnr_$(openssl rand -hex 32)"
RUNNER_SESSION_KEY="k1.$(openssl rand -hex 32)"
CHANNEL_ADAPTER_TOKEN="cha_$(openssl rand -hex 32)"
SSH_TERMINATOR_SECRET="ssh_$(openssl rand -hex 32)"

echo "# Runner / SSH / Channels (required)"
echo "RUNNER_TOKEN=${RUNNER_TOKEN}"
echo "RUNNER_SESSION_KEY=${RUNNER_SESSION_KEY}"
echo "CHANNEL_ADAPTER_TOKEN=${CHANNEL_ADAPTER_TOKEN}"
echo "SSH_TERMINATOR_SECRET=${SSH_TERMINATOR_SECRET}"
echo ""

# SSH Keys
echo "# SSH Keys (required - generate once)"
echo "# Run this command to generate:"
echo "ssh-keygen -t ed25519 -f /tmp/terminator -N \"\" -C \"onecli-ssh-terminator\""
echo ""
echo "# Then copy the private key (including headers) as TERMINATOR_HOST_KEY:"
echo "# TERMINATOR_HOST_KEY=\"$(cat /tmp/terminator 2>/dev/null | sed ':a;N;s/\n/\\n/g;ta' || echo 'GENERATE_WITH_COMMAND_ABOVE')\""
echo ""
echo "# And the public key as TERMINATOR_CA_PUBLIC_KEY:"
echo "# TERMINATOR_CA_PUBLIC_KEY=\"$(cat /tmp/terminator.pub 2>/dev/null || echo 'GENERATE_WITH_COMMAND_ABOVE')\""
echo ""

echo "=== Domain Configuration ==="
echo "Update these to your actual domains:"
echo "ONECLI_EXTERNAL_URL=https://cli.eysho.info"
echo "APP_URL=https://cli.eysho.info"
echo "API_URL=https://api.cli.eysho.info"
echo "GATEWAY_API_URL=https://gw.cli.eysho.info"
echo "ONECLI_TRUSTED_ORIGINS=https://cli.eysho.info"
echo "BETTER_AUTH_COOKIE_DOMAIN=cli.eysho.info"
echo ""

echo "=== Quick Railway CLI Setup ==="
echo "# After adding variables to Railway dashboard, deploy with:"
echo "railway up"
echo ""
echo "# Or use the deploy script:"
echo "./scripts/deploy-railway.sh"