#!/bin/bash

# ServiceRadar Docker Image Build Script
# Build and push ServiceRadar Docker images with multi-platform support

set -euo pipefail

# Configuration
REGISTRY="ghcr.io"
IMAGE_PREFIX="ghcr.io/carverauto/serviceradar"
DEFAULT_TAG="latest"
DEFAULT_PLATFORM="linux/amd64,linux/arm64"
BUILDER_NAME="multiarch"

# Available services grouped by category
declare -A SERVICE_GROUPS=(
    ["infrastructure"]="cert-generator config-updater proton"
    ["core"]="core web poller agent"
    ["data"]="kv sync db-event-writer"
    ["observability"]="otel flowgger trapd zen"
    ["checkers"]="mapper snmp-checker rperf-client"
    ["tools"]="tools"
)

# All services list
ALL_SERVICES=""
for group in "${SERVICE_GROUPS[@]}"; do
    ALL_SERVICES="$ALL_SERVICES $group"
done

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
Usage: $0 [OPTIONS] [SERVICES...]

Build and push ServiceRadar Docker images to GitHub Container Registry (GHCR)

OPTIONS:
  -t, --tag TAG             Tag for the images (default: $DEFAULT_TAG)
  -p, --push                Push images after building (requires docker login)
  --platform PLATFORM       Target platform (default: $DEFAULT_PLATFORM)
  --platform-amd64          Build for linux/amd64 only
  --platform-arm64          Build for linux/arm64 only
  --no-cache                Build without cache
  --local                   Build for local platform only (no multi-arch)
  -g, --group GROUP         Build all services in a group
  -h, --help                Show this help

SERVICE GROUPS:
  infrastructure: cert-generator, config-updater, proton
  core:          core, web, poller, agent
  data:          kv, sync, db-event-writer
  observability: otel, flowgger, trapd, zen
  checkers:      mapper, snmp-checker, rperf-client
  tools:         tools
  all:           Build all services (default if no services specified)

SERVICES:
  You can specify individual services to build:
  cert-generator, config-updater, proton, core, web, poller, agent,
  kv, sync, db-event-writer, otel, flowgger, trapd, zen,
  mapper, snmp-checker, rperf-client, tools

EXAMPLES:
  # Build and push all images
  $0 --push

  # Build and push only rperf-client for amd64
  $0 --platform-amd64 --push rperf-client

  # Build core services group
  $0 --group core --push

  # Build specific services
  $0 --push core web agent

  # Build all images with specific tag
  $0 --tag v1.0.53 --push

  # Build locally without push (current platform only)
  $0 --local core

AUTHENTICATION:
  Before pushing, login to GHCR:
  echo \$GITHUB_TOKEN | docker login ghcr.io -u \$GITHUB_USERNAME --password-stdin

EOF
}

# Parse command line arguments
TAG="$DEFAULT_TAG"
PUSH=false
NO_CACHE=""
PLATFORM="$DEFAULT_PLATFORM"
LOCAL_BUILD=false
SERVICES_TO_BUILD=""
BUILD_ALL=true

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
        --platform-amd64)
            PLATFORM="linux/amd64"
            shift
            ;;
        --platform-arm64)
            PLATFORM="linux/arm64"
            shift
            ;;
        --no-cache)
            NO_CACHE="--no-cache"
            shift
            ;;
        --local)
            LOCAL_BUILD=true
            shift
            ;;
        -g|--group)
            GROUP="$2"
            if [[ "$GROUP" == "all" ]]; then
                SERVICES_TO_BUILD="$ALL_SERVICES"
            elif [[ -n "${SERVICE_GROUPS[$GROUP]:-}" ]]; then
                SERVICES_TO_BUILD="${SERVICE_GROUPS[$GROUP]}"
            else
                error "Unknown group: $GROUP"
                error "Available groups: ${!SERVICE_GROUPS[@]} all"
                exit 1
            fi
            BUILD_ALL=false
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        -*)
            error "Unknown option: $1"
            usage
            exit 1
            ;;
        *)
            # Assume it's a service name
            SERVICES_TO_BUILD="$SERVICES_TO_BUILD $1"
            BUILD_ALL=false
            shift
            ;;
    esac
done

# If no services specified, build all
if [[ "$BUILD_ALL" == true ]]; then
    SERVICES_TO_BUILD="$ALL_SERVICES"
fi

# Get version info
if [[ -f "VERSION" ]]; then
    VERSION=$(cat VERSION)
else
    VERSION="dev"
fi
BUILD_ID=$(date +%Y%m%d%H%M%S)

# Display build configuration
log "ServiceRadar Docker Image Build"
log "Version: $VERSION"
log "Build ID: $BUILD_ID"
log "Tag: $TAG"
log "Platform: $PLATFORM"
log "Push: $PUSH"
log "Services to build: $(echo $SERVICES_TO_BUILD | tr ' ' '\n' | wc -l) service(s)"

# Check if we're in the right directory
if [[ ! -f "go.mod" ]] || [[ ! -d "docker/compose" ]]; then
    error "Please run this script from the ServiceRadar root directory"
    exit 1
fi

# Setup build environment based on local vs multi-arch
if [[ "$LOCAL_BUILD" == true ]]; then
    log "Using local Docker build (no buildx)"
    BUILD_COMMAND="docker build"
    PLATFORM_FLAG=""
else
    # Check Docker buildx
    if ! docker buildx version >/dev/null 2>&1; then
        error "Docker buildx is required for multi-platform builds"
        error "Use --local flag for local platform builds or install Docker buildx"
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
    
    BUILD_COMMAND="docker buildx build"
    PLATFORM_FLAG="--platform $PLATFORM"
fi

# Build function
build_image() {
    local image_name="$1"
    local dockerfile="$2"
    local build_args="$3"
    
    local full_image_name="${IMAGE_PREFIX}-${image_name}:${TAG}"
    
    log "Building $full_image_name"
    
    if [[ "$LOCAL_BUILD" == true ]]; then
        # Local build
        docker build \
            --file "$dockerfile" \
            --tag "$full_image_name" \
            $build_args \
            $NO_CACHE \
            .
        
        if [[ "$PUSH" == true ]]; then
            log "Pushing $full_image_name..."
            docker push "$full_image_name"
        fi
    else
        # Multi-arch build with buildx
        local push_flag=""
        local build_platform="$PLATFORM"
        
        if [[ "$PUSH" == true ]]; then
            push_flag="--push"
        else
            push_flag="--load"
            # For multi-platform builds without push, we need to use single platform
            if [[ "$PLATFORM" == *","* ]]; then
                warn "Multi-platform builds require --push flag. Using linux/amd64 only for local load."
                build_platform="linux/amd64"
            fi
        fi
        
        docker buildx build \
            --platform "$build_platform" \
            --file "$dockerfile" \
            --tag "$full_image_name" \
            $build_args \
            $NO_CACHE \
            $push_flag \
            .
    fi
    
    if [[ "$PUSH" == true ]]; then
        success "Built and pushed: $full_image_name"
        if [[ "$PLATFORM" == *","* ]]; then
            log "  Platforms: $(echo $PLATFORM | sed 's/linux\///g' | sed 's/,/, /g')"
        fi
    else
        success "Built: $full_image_name"
    fi
}

log "Starting build process..."

# Define service configurations
declare -A SERVICE_DOCKERFILES=(
    ["cert-generator"]="docker/compose/Dockerfile.cert-generator:DYNAMIC"
    ["config-updater"]="docker/compose/Dockerfile.config-updater"
    ["proton"]="docker/compose/Dockerfile.proton"
    ["core"]="docker/compose/Dockerfile.core"
    ["web"]="docker/compose/Dockerfile.web"
    ["poller"]="docker/compose/Dockerfile.poller"
    ["agent"]="docker/compose/Dockerfile.agent"
    ["kv"]="docker/compose/Dockerfile.kv"
    ["sync"]="docker/compose/Dockerfile.sync"
    ["db-event-writer"]="docker/compose/Dockerfile.db-event-writer"
    ["otel"]="docker/compose/Dockerfile.otel"
    ["flowgger"]="docker/compose/Dockerfile.flowgger"
    ["trapd"]="docker/compose/Dockerfile.trapd"
    ["zen"]="docker/compose/Dockerfile.zen"
    ["mapper"]="docker/compose/Dockerfile.mapper"
    ["snmp-checker"]="docker/compose/Dockerfile.snmp-checker"
    ["rperf-client"]="docker/compose/Dockerfile.rperf-client"
    ["tools"]="docker/compose/Dockerfile.tools"
)

# Define which services need build args
declare -A SERVICE_BUILD_ARGS=(
    ["config-updater"]="--build-arg VERSION=$VERSION --build-arg BUILD_ID=$BUILD_ID"
    ["core"]="--build-arg VERSION=$VERSION --build-arg BUILD_ID=$BUILD_ID"
    ["web"]="--build-arg VERSION=$VERSION --build-arg BUILD_ID=$BUILD_ID"
    ["poller"]="--build-arg VERSION=$VERSION --build-arg BUILD_ID=$BUILD_ID"
    ["agent"]="--build-arg VERSION=$VERSION --build-arg BUILD_ID=$BUILD_ID"
    ["kv"]="--build-arg VERSION=$VERSION --build-arg BUILD_ID=$BUILD_ID"
    ["sync"]="--build-arg VERSION=$VERSION --build-arg BUILD_ID=$BUILD_ID"
    ["db-event-writer"]="--build-arg VERSION=$VERSION --build-arg BUILD_ID=$BUILD_ID"
    ["mapper"]="--build-arg VERSION=$VERSION --build-arg BUILD_ID=$BUILD_ID"
    ["snmp-checker"]="--build-arg VERSION=$VERSION --build-arg BUILD_ID=$BUILD_ID"
)

# Function to build cert-generator with dynamic Dockerfile
build_cert_generator() {
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
}

# Build selected services
BUILT_COUNT=0
FAILED_SERVICES=""

for service in $SERVICES_TO_BUILD; do
    # Check if service exists
    if [[ ! -n "${SERVICE_DOCKERFILES[$service]:-}" ]]; then
        warn "Unknown service: $service (skipping)"
        continue
    fi
    
    # Get dockerfile and build args
    dockerfile_info="${SERVICE_DOCKERFILES[$service]}"
    build_args="${SERVICE_BUILD_ARGS[$service]:-}"
    
    # Handle special cases
    if [[ "$service" == "cert-generator" ]]; then
        build_cert_generator
    else
        dockerfile="${dockerfile_info%:*}"  # Remove :DYNAMIC if present
        
        # Check if Dockerfile exists
        if [[ ! -f "$dockerfile" ]]; then
            error "Dockerfile not found: $dockerfile for service $service"
            FAILED_SERVICES="$FAILED_SERVICES $service"
            continue
        fi
        
        build_image "$service" "$dockerfile" "$build_args"
    fi
    
    if [[ $? -eq 0 ]]; then
        ((BUILT_COUNT++))
    else
        FAILED_SERVICES="$FAILED_SERVICES $service"
    fi
done

# Summary
echo ""
if [[ -n "$FAILED_SERVICES" ]]; then
    error "Failed to build services:$FAILED_SERVICES"
    success "Successfully built $BUILT_COUNT service(s)"
    exit 1
else
    success "Successfully built $BUILT_COUNT service(s)!"
fi

if [[ "$PUSH" == false ]]; then
    echo ""
    warn "Images were built locally but not pushed."
    log "To push images, run with --push flag after logging in:"
    log "  echo \$GITHUB_TOKEN | docker login ghcr.io -u \$GITHUB_USERNAME --password-stdin"
    log "  $0 --push --tag $TAG"
fi

echo ""
if [[ "$PUSH" == true ]]; then
    # When pushing multi-arch images with buildx, nothing is loaded locally.
    # Avoid failing the script due to grep returning 1 with pipefail enabled.
    log "Images were pushed to $REGISTRY; skipping local image list."
else
    log "ServiceRadar images created:"
    docker images | grep "serviceradar" | head -20 || true
fi
