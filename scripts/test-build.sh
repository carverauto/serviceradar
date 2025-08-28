#!/bin/bash

# Test script for the consolidated build system
set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

log() { echo -e "${BLUE}[TEST]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }
success() { echo -e "${GREEN}[PASS]${NC} $1"; }

echo "ServiceRadar Build System Test"
echo "=============================="
echo ""

# Test 1: Check script exists and is executable
log "Checking build script..."
if [[ -x "scripts/build-images.sh" ]]; then
    success "Build script exists and is executable"
else
    error "Build script not found or not executable"
    exit 1
fi

# Test 2: Show help
log "Testing help output..."
./scripts/build-images.sh --help > /dev/null 2>&1
if [[ $? -eq 0 ]]; then
    success "Help command works"
else
    error "Help command failed"
fi

# Test 3: List available services
log "Available services and groups:"
echo ""
./scripts/build-images.sh --help | grep -A 20 "SERVICE GROUPS:"
echo ""

# Test 4: Check Docker buildx
log "Checking Docker buildx..."
if docker buildx version >/dev/null 2>&1; then
    success "Docker buildx is available"
    docker buildx version
else
    error "Docker buildx not available (required for multi-arch builds)"
    echo "  Install Docker Desktop or use --local flag for single-arch builds"
fi

# Test 5: Example commands
echo ""
log "Example build commands:"
echo ""
echo "  # Build and push rperf-client for amd64:"
echo "  ./scripts/build-images.sh --platform-amd64 --push rperf-client"
echo ""
echo "  # Build all checkers (including rperf-client):"
echo "  ./scripts/build-images.sh --group checkers --push"
echo ""
echo "  # Build specific services:"
echo "  ./scripts/build-images.sh --push core web rperf-client"
echo ""
echo "  # Build all services:"
echo "  ./scripts/build-images.sh --push"
echo ""
echo "  # Build for local testing (no push):"
echo "  ./scripts/build-images.sh --local rperf-client"
echo ""

success "Build system test completed!"