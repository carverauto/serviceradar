#!/bin/bash

# ServiceRadar Complete Image Build and Push Script
# Builds all ServiceRadar Docker images with multi-platform support

set -euo pipefail

# Configuration
REGISTRY="ghcr.io"
IMAGE_PREFIX="ghcr.io/carverauto/serviceradar"
DEFAULT_TAG="latest"
PLATFORM="linux/amd64,linux/arm64"
BUILDER_NAME="${BUILDX_BUILDER:-multiarch}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Helper functions
log() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

# Usage function
usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Build and push ALL ServiceRadar Docker images to GitHub Container Registry (GHCR)

OPTIONS:
  -t, --tag TAG        Tag for the images (default: $DEFAULT_TAG)
  -p, --push           Push images after building (requires docker login)
  --platform PLATFORM Target platform (default: $PLATFORM)
  --no-cache           Build without cache
  -h, --help           Show this help

SERVICES BUILT:
  Infrastructure: cert-generator, config-updater, proton
  Core Services: core, web, poller, agent
  Data Services: kv, sync, db-event-writer
  Observability: otel, flowgger, trapd, zen
  Checkers: mapper, snmp-checker, rperf-client

EXAMPLES:
  # Build all images and push with latest tag
  $0 --push

  # Build all images with specific tag
  $0 --tag v1.0.53 --push

  # Build without cache
  $0 --no-cache --push

AUTHENTICATION:
  Before pushing, login to GHCR:
  echo \$GITHUB_TOKEN | docker login ghcr.io -u \$GITHUB_USERNAME --password-stdin

EOF
}

# Parse command line arguments
TAG="$DEFAULT_TAG"
PUSH=false
NO_CACHE=""

while [[ $# -gt 0 ]]; do
    case $1 in
        -t|--tag)
            TAG="$2"
            shift 2
            ;;
        -p|--push)
            PUSH=true
            shift
            ;;
        --platform)
            PLATFORM="$2"
            shift 2
            ;;
        --no-cache)
            NO_CACHE="--no-cache"
            shift
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

# Get version info
if [[ -f "VERSION" ]]; then
    VERSION=$(cat VERSION)
else
    VERSION="dev"
fi
BUILD_ID=$(date +%Y%m%d%H%M%S)

log "Building ALL ServiceRadar Docker images"
log "Version: $VERSION"
log "Build ID: $BUILD_ID"
log "Tag: $TAG"
log "Platform: $PLATFORM"
log "Push: $PUSH"

# Check if we're in the right directory
if [[ ! -f "go.mod" ]] || [[ ! -d "docker/compose" ]]; then
    error "Please run this script from the ServiceRadar root directory"
    exit 1
fi

# Check Docker buildx
if ! docker buildx version >/dev/null 2>&1; then
    error "Docker buildx is required for multi-platform builds"
    exit 1
fi

# Setup buildx builder if needed
if ! docker buildx inspect "$BUILDER_NAME" >/dev/null 2>&1; then
    log "Creating buildx builder: $BUILDER_NAME"
    docker buildx create --name "$BUILDER_NAME" --use --bootstrap
else
    log "Using existing buildx builder: $BUILDER_NAME"
    docker buildx use "$BUILDER_NAME"
fi

# Ensure the builder has access to docker credentials
log "Ensuring buildx builder has access to credentials..."
docker buildx inspect --bootstrap

# Build function
build_image() {
    local image_name="$1"
    local dockerfile="$2"
    local build_args="$3"
    
    local full_image_name="${IMAGE_PREFIX}-${image_name}:${TAG}"
    
    log "Building $full_image_name ($dockerfile)"
    
    local push_flag=""
    if [[ "$PUSH" == true ]]; then
        push_flag="--push"
    else
        push_flag="--load"
        # For multi-platform builds without push, we need to use single platform
        if [[ "$PLATFORM" == *","* ]]; then
            warn "Multi-platform builds require --push flag. Using linux/amd64 only for local load."
            local build_platform="linux/amd64"
        else
            local build_platform="$PLATFORM"
        fi
    fi
    
    docker buildx build \
        --platform "${build_platform:-$PLATFORM}" \
        --file "$dockerfile" \
        --tag "$full_image_name" \
        $build_args \
        $NO_CACHE \
        $push_flag \
        .
    
    if [[ "$PUSH" == true ]]; then
        success "Built and pushed: $full_image_name"
    else
        success "Built: $full_image_name"
    fi
}

log "Starting build process for all ServiceRadar services..."

# Infrastructure Images
log "=== Building Infrastructure Images ==="

# Build cert-generator (creates Dockerfile dynamically like build-and-push-docker.sh)
log "Creating Dockerfile for cert-generator"
cat > docker/compose/Dockerfile.cert-generator << 'EOF'
FROM alpine:latest

# Install OpenSSL
RUN apk add --no-cache openssl

# Copy certificate generation script
COPY docker/compose/entrypoint-certs.sh /entrypoint-certs.sh
RUN chmod +x /entrypoint-certs.sh

# Set working directory
WORKDIR /certs

ENTRYPOINT ["/bin/sh", "/entrypoint-certs.sh"]
EOF

build_image "cert-generator" "docker/compose/Dockerfile.cert-generator" ""

# Clean up temporary Dockerfile
rm -f docker/compose/Dockerfile.cert-generator

build_image "config-updater" "docker/compose/Dockerfile.config-updater" "--build-arg VERSION=$VERSION --build-arg BUILD_ID=$BUILD_ID"
build_image "proton" "docker/compose/Dockerfile.proton" ""

# Core Services
log "=== Building Core Services ==="
build_image "core" "docker/compose/Dockerfile.core" "--build-arg VERSION=$VERSION --build-arg BUILD_ID=$BUILD_ID"
build_image "web" "docker/compose/Dockerfile.web" "--build-arg VERSION=$VERSION --build-arg BUILD_ID=$BUILD_ID"
build_image "poller" "docker/compose/Dockerfile.poller" "--build-arg VERSION=$VERSION --build-arg BUILD_ID=$BUILD_ID"
build_image "agent" "docker/compose/Dockerfile.agent" "--build-arg VERSION=$VERSION --build-arg BUILD_ID=$BUILD_ID"

# Data Services
log "=== Building Data Services ==="
build_image "kv" "docker/compose/Dockerfile.kv" "--build-arg VERSION=$VERSION --build-arg BUILD_ID=$BUILD_ID"
build_image "sync" "docker/compose/Dockerfile.sync" "--build-arg VERSION=$VERSION --build-arg BUILD_ID=$BUILD_ID"
build_image "db-event-writer" "docker/compose/Dockerfile.db-event-writer" "--build-arg VERSION=$VERSION --build-arg BUILD_ID=$BUILD_ID"

# Observability Services (Rust)
log "=== Building Observability Services (Rust) ==="
build_image "otel" "docker/compose/Dockerfile.otel" ""
build_image "flowgger" "docker/compose/Dockerfile.flowgger" ""
build_image "trapd" "docker/compose/Dockerfile.trapd" ""
build_image "zen" "docker/compose/Dockerfile.zen" ""

# Checker Services
log "=== Building Checker Services ==="
build_image "mapper" "docker/compose/Dockerfile.mapper" "--build-arg VERSION=$VERSION --build-arg BUILD_ID=$BUILD_ID"
build_image "snmp-checker" "docker/compose/Dockerfile.snmp-checker" "--build-arg VERSION=$VERSION --build-arg BUILD_ID=$BUILD_ID"
build_image "rperf-client" "docker/compose/Dockerfile.rperf-client" ""

success "ALL ServiceRadar images built successfully!"

if [[ "$PUSH" == false ]]; then
    echo ""
    warn "Images were built locally but not pushed."
    log "To push images, run with --push flag after logging in:"
    log "  echo \$GITHUB_TOKEN | docker login ghcr.io -u \$GITHUB_USERNAME --password-stdin"
    log "  $0 --push --tag $TAG"
fi

echo ""
log "ServiceRadar images created:"
docker images | grep "serviceradar" | head -20