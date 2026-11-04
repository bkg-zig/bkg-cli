#!/usr/bin/env bash
set -euo pipefail

# bkg-cli upstream sync script
# Usage: ./scripts/sync-upstream.sh [mango|tango|both]
#
# Branch strategy:
#   mango  = upstream/main (onecli/onecli) - NEVER commit directly here
#   tango  = your customizations (bkg-zig/bkg-cli) - YOUR work lives here
#
# Workflow:
#   1. Run this script to pull upstream into mango
#   2. Merge mango into tango (your changes preserved)
#   3. Resolve any conflicts (your tango changes win)
#   4. Push both branches

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

UPSTREAM_REMOTE="upstream"
UPSTREAM_BRANCH="main"
MANGO_BRANCH="mango"
TANGO_BRANCH="tango"
ORIGIN_REMOTE="origin"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() { echo -e "${BLUE}[sync]${NC} $*"; }
ok() { echo -e "${GREEN}[ok]${NC} $*"; }
warn() { echo -e "${YELLOW}[warn]${NC} $*"; }
err() { echo -e "${RED}[err]${NC} $*"; }

usage() {
    cat <<EOF
Usage: $0 [mango|tango|both]

  mango   - Update mango branch from upstream (onecli/onecli)
  tango   - Merge mango into tango (your custom branch)
  both    - Do both (default)

Branch strategy:
  mango  = mirror of upstream/main (onecli/onecli)
  tango  = your customizations (bkg-zig/bkg-cli)

Safe workflow:
  1. $0 mango     # pulls upstream into mango
  2. $0 tango     # merges mango into tango, your changes preserved
  3. git push origin mango tango

Never commit directly to mango. All your work goes on tango.
EOF
}

update_mango() {
    log "Updating mango from upstream..."
    
    # Fetch upstream
    git fetch "$UPSTREAM_REMOTE" "$UPSTREAM_BRANCH"
    
    # Checkout mango
    git checkout "$MANGO_BRANCH"
    
    # Fast-forward or merge (preserves mango as pure upstream mirror)
    if git merge-base --is-ancestor "$MANGO_BRANCH" "$UPSTREAM_REMOTE/$UPSTREAM_BRANCH"; then
        log "Fast-forwarding mango to upstream..."
        git merge --ff-only "$UPSTREAM_REMOTE/$UPSTREAM_BRANCH"
    else
        warn "mango has diverged from upstream. Merging (creates merge commit)..."
        git merge "$UPSTREAM_REMOTE/$UPSTREAM_BRANCH" -m "sync: merge upstream/main into mango"
    fi
    
    ok "mango updated to $(git rev-parse --short HEAD)"
}

merge_into_tango() {
    log "Merging mango into tango..."
    
    # Ensure we're on tango
    git checkout "$TANGO_BRANCH"
    
    # Merge mango into tango
    # --no-ff keeps merge commit showing the sync
    # Your tango changes take precedence on conflicts
    if git merge "$MANGO_BRANCH" -m "sync: merge mango into tango"; then
        ok "Merged mango into tango cleanly"
    else
        warn "Merge conflicts detected. Resolve them, then:"
        echo "  git add -A"
        echo "  git commit -m 'sync: resolve conflicts from mango merge'"
        echo "  $0 tango  # (will continue from here)"
        exit 1
    fi
    
    ok "tango now at $(git rev-parse --short HEAD)"
}

push_both() {
    log "Pushing both branches to origin..."
    git push "$ORIGIN_REMOTE" "$MANGO_BRANCH" "$TANGO_BRANCH"
    ok "Pushed mango and tango to origin"
}

main() {
    local cmd="${1:-both}"
    
    case "$cmd" in
        mango)
            update_mango
            ;;
        tango)
            merge_into_tango
            ;;
        both)
            update_mango
            merge_into_tango
            ;;
        -h|--help|help)
            usage
            exit 0
            ;;
        *)
            err "Unknown command: $cmd"
            usage
            exit 1
            ;;
    esac
    
    echo ""
    log "Current state:"
    git log --oneline -1 "$MANGO_BRANCH" | sed 's/^/  mango:  /'
    git log --oneline -1 "$TANGO_BRANCH" | sed 's/^/  tango:  /'
    echo ""
    ok "Done! Next: git push origin mango tango"
}

main "$@"