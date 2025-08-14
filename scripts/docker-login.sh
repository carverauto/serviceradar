#!/bin/bash

# Docker Login Helper for GHCR
# Helps authenticate with GitHub Container Registry

set -euo pipefail

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Authenticate with GitHub Container Registry (GHCR) for pushing Docker images

OPTIONS:
  -u, --username USERNAME    GitHub username
  -t, --token TOKEN         GitHub Personal Access Token
  -h, --help               Show this help

SETUP:
1. Create a GitHub Personal Access Token with 'write:packages' scope:
   https://github.com/settings/tokens/new

2. Set environment variables (recommended):
   export GITHUB_USERNAME="your-username"
   export GITHUB_TOKEN="your-token"

3. Or pass them as arguments:
   $0 --username your-username --token your-token

EXAMPLES:
  # Using environment variables
  $0

  # Using arguments
  $0 -u myusername -t ghp_xxxxxxxxxxxx

EOF
}

USERNAME="${GITHUB_USERNAME:-}"
TOKEN="${GITHUB_TOKEN:-}"

while [[ $# -gt 0 ]]; do
    case $1 in
        -u|--username)
            USERNAME="$2"
            shift 2
            ;;
        -t|--token)
            TOKEN="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            error "Unknown option: $1"
            usage
            exit 1
            ;;
    esac
done

# Check if already logged in
if docker system info 2>/dev/null | grep -q "ghcr.io"; then
    log "Already logged in to GHCR"
    docker system info | grep -A5 "Registry:"
    exit 0
fi

# Validate inputs
if [[ -z "$USERNAME" ]]; then
    error "GitHub username is required"
    echo "Set GITHUB_USERNAME environment variable or use --username flag"
    exit 1
fi

if [[ -z "$TOKEN" ]]; then
    error "GitHub token is required"
    echo "Set GITHUB_TOKEN environment variable or use --token flag"
    echo ""
    warn "To create a token:"
    echo "1. Go to https://github.com/settings/tokens/new"
    echo "2. Select 'write:packages' scope"
    echo "3. Copy the generated token"
    exit 1
fi

# Validate token format
if [[ ! "$TOKEN" =~ ^(ghp_|github_pat_) ]]; then
    warn "Token doesn't look like a GitHub Personal Access Token"
    warn "Expected format: ghp_xxxxxxxxxxxx or github_pat_xxxxxxxxxxxx"
fi

log "Logging in to GitHub Container Registry..."
log "Username: $USERNAME"
log "Registry: ghcr.io"

# Login to GHCR
if echo "$TOKEN" | docker login ghcr.io -u "$USERNAME" --password-stdin; then
    log "Successfully logged in to ghcr.io"
    log "You can now push images with: ./scripts/build-and-push-docker.sh --push"
else
    error "Failed to login to ghcr.io"
    echo ""
    warn "Common issues:"
    echo "- Token doesn't have 'write:packages' scope"
    echo "- Token is expired"
    echo "- Username is incorrect"
    echo "- Two-factor authentication is blocking token usage"
    exit 1
fi