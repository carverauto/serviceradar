#!/bin/bash

# ServiceRadar Docker Build and Push Script
# This script builds and pushes Docker images to GHCR locally without CI/CD

set -euo pipefail

# Configuration
REGISTRY="ghcr.io"
IMAGE_PREFIX="ghcr.io/carverauto/serviceradar"
DEFAULT_TAG="local"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

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

Build and push ServiceRadar Docker images to GitHub Container Registry (GHCR)

OPTIONS:
  -t, --tag TAG        Tag for the images (default: $DEFAULT_TAG)
  -p, --push           Push images after building (requires docker login)
  -a, --all            Build all images (core, proton, cert-generator)
  -c, --core           Build only core image
  -d, --proton         Build only proton image
  -g, --cert-gen       Build only cert-generator image
  --platform PLATFORM  Target platform (default: linux/amd64,linux/arm64)
  --no-cache           Build without cache
  -h, --help           Show this help

EXAMPLES:
  # Build all images locally
  $0 --all --tag v1.2.3

  # Build and push core image
  $0 --core --push --tag latest

  # Build for specific platform
  $0 --all --platform linux/amd64

AUTHENTICATION:
  Before pushing, login to GHCR:
  echo \$GITHUB_TOKEN | docker login ghcr.io -u \$GITHUB_USERNAME --password-stdin

EOF
}

# Parse command line arguments
TAG="$DEFAULT_TAG"
PUSH=false
BUILD_ALL=false
BUILD_CORE=false
BUILD_PROTON=false
BUILD_CERT_GEN=false
PLATFORM="linux/amd64,linux/arm64"
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
        -a|--all)
            BUILD_ALL=true
            shift
            ;;
        -c|--core)
            BUILD_CORE=true
            shift
            ;;
        -d|--proton)
            BUILD_PROTON=true
            shift
            ;;
        -g|--cert-gen)
            BUILD_CERT_GEN=true
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

# If no specific image is selected, build all
if [[ "$BUILD_ALL" == false && "$BUILD_CORE" == false && "$BUILD_PROTON" == false && "$BUILD_CERT_GEN" == false ]]; then
    BUILD_ALL=true
fi

# Get version info
if [[ -f "VERSION" ]]; then
    VERSION=$(cat VERSION)
else
    VERSION="dev"
fi
BUILD_ID=$(date +%Y%m%d%H%M%S)

log "Building ServiceRadar Docker images"
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
BUILDER_NAME="serviceradar-builder"
if ! docker buildx inspect "$BUILDER_NAME" >/dev/null 2>&1; then
    log "Creating buildx builder: $BUILDER_NAME"
    docker buildx create --name "$BUILDER_NAME" --use
else
    log "Using existing buildx builder: $BUILDER_NAME"
    docker buildx use "$BUILDER_NAME"
fi

# Build function
build_image() {
    local image_name="$1"
    local dockerfile="$2"
    local build_args="$3"
    
    local full_image_name="${IMAGE_PREFIX}-${image_name}:${TAG}"
    local latest_image_name="${IMAGE_PREFIX}-${image_name}:latest"
    
    log "Building $full_image_name"
    
    local push_flag=""
    if [[ "$PUSH" == true ]]; then
        push_flag="--push"
    else
        push_flag="--load"
        # For multi-platform builds without push, we need to use --load with single platform
        if [[ "$PLATFORM" == *","* ]]; then
            warn "Multi-platform builds require --push flag. Using linux/amd64 only for local load."
            PLATFORM="linux/amd64"
        fi
    fi
    
    # Build with specific tag and also tag as latest (for stable releases)
    local tags="--tag $full_image_name"
    if [[ "$TAG" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] && [[ "$PUSH" == true ]]; then
        log "Also tagging as latest (stable release detected)"
        tags="$tags --tag $latest_image_name"
    fi
    
    docker buildx build \
        --platform "$PLATFORM" \
        --file "$dockerfile" \
        $tags \
        $build_args \
        $NO_CACHE \
        $push_flag \
        .
    
    if [[ "$PUSH" == true ]]; then
        success "Built and pushed: $full_image_name"
        if [[ "$TAG" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            success "Also pushed as: $latest_image_name"
        fi
    else
        success "Built: $full_image_name"
    fi
}

# Build Core service
if [[ "$BUILD_ALL" == true || "$BUILD_CORE" == true ]]; then
    build_image "core" "docker/compose/Dockerfile.core" "--build-arg VERSION=$VERSION --build-arg BUILD_ID=$BUILD_ID"
fi

# Build Proton database
if [[ "$BUILD_ALL" == true || "$BUILD_PROTON" == true ]]; then
    build_image "proton" "docker/compose/Dockerfile.proton" ""
fi

# Build cert-generator
if [[ "$BUILD_ALL" == true || "$BUILD_CERT_GEN" == true ]]; then
    # Create Dockerfile for cert-generator (same as in CI)
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
fi

log "Build process completed!"

if [[ "$PUSH" == false ]]; then
    echo ""
    warn "Images were built locally but not pushed."
    log "To push images, run with --push flag after logging in:"
    log "  echo \$GITHUB_TOKEN | docker login ghcr.io -u \$GITHUB_USERNAME --password-stdin"
    log "  $0 --push --tag $TAG"
fi

echo ""
log "Available images:"
docker images | grep "serviceradar" | head -10