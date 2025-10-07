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
  -a, --all            Build all images
  -c, --core           Build only core image
  -d, --proton         Build only proton image
  -w, --web            Build only web image
  -g, --cert-gen       Build only cert-generator image
  --agent              Build only agent image
  --config-updater     Build only config-updater image
  --db-event-writer    Build only db-event-writer image
  --flowgger           Build only flowgger image
  --kv                 Build only kv image
  --mapper             Build only mapper image
  --nginx              Build only nginx image
  --otel               Build only otel image
  --poller             Build only poller image
  --rperf-client       Build only rperf-client image
  --snmp-checker       Build only snmp-checker image
  --sync               Build only sync image
  --tools              Build only tools image
  --trapd              Build only trapd image
  --zen                Build only zen image
  --srql               Build only srql image
  --kong-config        Build only kong-config (JWKS renderer) image
  --platform PLATFORM  Target platform (default: auto-detected based on --push)
  --force-multiplatform Force multi-platform build even without --push
  --no-cache           Build without cache
  -h, --help           Show this help

EXAMPLES:
  # Build all images locally (single platform)
  $0 --all --tag v1.2.3

  # Build and push core image (multi-platform)
  $0 --core --push --tag latest

  # Build and push all images for multi-platform
  $0 --all --push --tag latest

  # Build for specific platform
  $0 --all --platform linux/amd64
  
  # Force multi-platform build without push (for CI/CD)
  $0 --all --force-multiplatform --tag latest

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
BUILD_WEB=false
BUILD_CERT_GEN=false
BUILD_AGENT=false
BUILD_CONFIG_UPDATER=false
BUILD_DB_EVENT_WRITER=false
BUILD_FLOWGGER=false
BUILD_KV=false
BUILD_MAPPER=false
BUILD_NGINX=false
BUILD_OTEL=false
BUILD_POLLER=false
BUILD_RPERF_CLIENT=false
BUILD_SNMP_CHECKER=false
BUILD_SYNC=false
BUILD_TOOLS=false
BUILD_TRAPD=false
BUILD_ZEN=false
BUILD_SRQL=false
BUILD_KONG_CONFIG=false
PLATFORM=""  # Will be set based on push flag
NO_CACHE=""
FORCE_MULTIPLATFORM=false

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
        -w|--web)
            BUILD_WEB=true
            shift
            ;;
        -g|--cert-gen)
            BUILD_CERT_GEN=true
            shift
            ;;
        --agent)
            BUILD_AGENT=true
            shift
            ;;
        --config-updater)
            BUILD_CONFIG_UPDATER=true
            shift
            ;;
        --db-event-writer)
            BUILD_DB_EVENT_WRITER=true
            shift
            ;;
        --flowgger)
            BUILD_FLOWGGER=true
            shift
            ;;
        --kv)
            BUILD_KV=true
            shift
            ;;
        --mapper)
            BUILD_MAPPER=true
            shift
            ;;
        --nginx)
            BUILD_NGINX=true
            shift
            ;;
        --otel)
            BUILD_OTEL=true
            shift
            ;;
        --poller)
            BUILD_POLLER=true
            shift
            ;;
        --rperf-client)
            BUILD_RPERF_CLIENT=true
            shift
            ;;
        --snmp-checker)
            BUILD_SNMP_CHECKER=true
            shift
            ;;
        --srql)
            BUILD_SRQL=true
            shift
            ;;
        --sync)
            BUILD_SYNC=true
            shift
            ;;
        --tools)
            BUILD_TOOLS=true
            shift
            ;;
        --trapd)
            BUILD_TRAPD=true
            shift
            ;;
        --zen)
            BUILD_ZEN=true
            shift
            ;;
        --kong-config)
            BUILD_KONG_CONFIG=true
            shift
            ;;
        --platform)
            PLATFORM="$2"
            shift 2
            ;;
        --force-multiplatform)
            FORCE_MULTIPLATFORM=true
            shift
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
if [[ "$BUILD_ALL" == false && "$BUILD_CORE" == false && "$BUILD_PROTON" == false && "$BUILD_WEB" == false && "$BUILD_CERT_GEN" == false && \
      "$BUILD_AGENT" == false && "$BUILD_CONFIG_UPDATER" == false && "$BUILD_DB_EVENT_WRITER" == false && "$BUILD_FLOWGGER" == false && \
      "$BUILD_KV" == false && "$BUILD_MAPPER" == false && "$BUILD_NGINX" == false && "$BUILD_OTEL" == false && "$BUILD_POLLER" == false && \
      "$BUILD_RPERF_CLIENT" == false && "$BUILD_SNMP_CHECKER" == false && "$BUILD_SYNC" == false && "$BUILD_TOOLS" == false && \
      "$BUILD_TRAPD" == false && "$BUILD_ZEN" == false && "$BUILD_SRQL" == false && "$BUILD_KONG_CONFIG" == false ]]; then
    BUILD_ALL=true
fi

# Set platform based on push flag and options
if [[ -z "$PLATFORM" ]]; then
    if [[ "$PUSH" == true ]] || [[ "$FORCE_MULTIPLATFORM" == true ]]; then
        PLATFORM="linux/amd64,linux/arm64"
        log "Auto-detected platform: Multi-platform ($PLATFORM)"
    else
        PLATFORM="linux/amd64"
        log "Auto-detected platform: Single platform ($PLATFORM) for local build"
    fi
else
    log "Using specified platform: $PLATFORM"
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
    docker buildx create --name "$BUILDER_NAME" --use --driver docker-container
else
    log "Using existing buildx builder: $BUILDER_NAME"
    docker buildx use "$BUILDER_NAME"
fi

# Bootstrap builder for multi-platform support if needed
if [[ "$PLATFORM" == *","* ]]; then
    log "Bootstrapping builder for multi-platform support..."
    docker buildx inspect --bootstrap "$BUILDER_NAME" >/dev/null 2>&1
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
    local build_platform="$PLATFORM"
    
    if [[ "$PUSH" == true ]]; then
        push_flag="--push"
    elif [[ "$FORCE_MULTIPLATFORM" == true ]]; then
        # Multi-platform build without push - just build and cache
        push_flag=""
        log "Building multi-platform image without local load (use --push to push to registry)"
    else
        push_flag="--load"
        # For local load, we can only use single platform
        if [[ "$PLATFORM" == *","* ]]; then
            build_platform="linux/amd64"
            warn "Multi-platform images cannot be loaded locally. Using $build_platform for local load."
            warn "Use --push to build and push multi-platform, or --force-multiplatform to build without load."
        fi
    fi
    
    # Build with specific tag and also tag as latest (for stable releases)
    local tags="--tag $full_image_name"
    if [[ "$TAG" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] && [[ "$PUSH" == true ]]; then
        log "Also tagging as latest (stable release detected)"
        tags="$tags --tag $latest_image_name"
    fi
    
    # Split build_args for proper expansion
    local build_cmd=(docker buildx build)
    build_cmd+=(--platform "$build_platform")
    build_cmd+=(--file "$dockerfile")
    
    # Add tags
    if [[ -n "$tags" ]]; then
        read -ra tag_array <<< "$tags"
        for tag in "${tag_array[@]}"; do
            build_cmd+=("$tag")
        done
    fi
    
    # Add build args
    if [[ -n "$build_args" ]]; then
        read -ra arg_array <<< "$build_args"
        for arg in "${arg_array[@]}"; do
            build_cmd+=("$arg")
        done
    fi
    
    # Add other flags
    if [[ -n "$NO_CACHE" ]]; then
        build_cmd+=("$NO_CACHE")
    fi
    
    if [[ -n "$push_flag" ]]; then
        build_cmd+=("$push_flag")
    fi
    
    build_cmd+=(.)
    
    # Execute the build command
    "${build_cmd[@]}"
    
    if [[ "$PUSH" == true ]]; then
        success "Built and pushed: $full_image_name ($build_platform)"
        if [[ "$TAG" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            success "Also pushed as: $latest_image_name"
        fi
    elif [[ "$FORCE_MULTIPLATFORM" == true ]]; then
        success "Built (cached): $full_image_name ($build_platform)"
    else
        success "Built and loaded: $full_image_name ($build_platform)"
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

# Build Web service
if [[ "$BUILD_ALL" == true || "$BUILD_WEB" == true ]]; then
    build_image "web" "docker/compose/Dockerfile.web" "--build-arg VERSION=$VERSION"
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

# Build Agent service
if [[ "$BUILD_ALL" == true || "$BUILD_AGENT" == true ]]; then
    build_image "agent" "docker/compose/Dockerfile.agent" "--build-arg VERSION=$VERSION --build-arg BUILD_ID=$BUILD_ID"
fi

# Build Config Updater service
if [[ "$BUILD_ALL" == true || "$BUILD_CONFIG_UPDATER" == true ]]; then
    build_image "config-updater" "docker/compose/Dockerfile.config-updater" "--build-arg VERSION=$VERSION --build-arg BUILD_ID=$BUILD_ID"
fi

# Build DB Event Writer service
if [[ "$BUILD_ALL" == true || "$BUILD_DB_EVENT_WRITER" == true ]]; then
    build_image "db-event-writer" "docker/compose/Dockerfile.db-event-writer" "--build-arg VERSION=$VERSION --build-arg BUILD_ID=$BUILD_ID"
fi

# Build Flowgger service
if [[ "$BUILD_ALL" == true || "$BUILD_FLOWGGER" == true ]]; then
    build_image "flowgger" "docker/compose/Dockerfile.flowgger" "--build-arg VERSION=$VERSION --build-arg BUILD_ID=$BUILD_ID"
fi

# Build KV service
if [[ "$BUILD_ALL" == true || "$BUILD_KV" == true ]]; then
    build_image "kv" "docker/compose/Dockerfile.kv" "--build-arg VERSION=$VERSION --build-arg BUILD_ID=$BUILD_ID"
fi

# Build Mapper service
if [[ "$BUILD_ALL" == true || "$BUILD_MAPPER" == true ]]; then
    build_image "mapper" "docker/compose/Dockerfile.mapper" "--build-arg VERSION=$VERSION --build-arg BUILD_ID=$BUILD_ID"
fi

# Build Nginx service
if [[ "$BUILD_ALL" == true || "$BUILD_NGINX" == true ]]; then
    build_image "nginx" "docker/compose/Dockerfile.nginx" ""
fi

# Build OTEL service
if [[ "$BUILD_ALL" == true || "$BUILD_OTEL" == true ]]; then
    build_image "otel" "docker/compose/Dockerfile.otel" "--build-arg VERSION=$VERSION --build-arg BUILD_ID=$BUILD_ID"
fi

# Build Poller service
if [[ "$BUILD_ALL" == true || "$BUILD_POLLER" == true ]]; then
    build_image "poller" "docker/compose/Dockerfile.poller" "--build-arg VERSION=$VERSION --build-arg BUILD_ID=$BUILD_ID"
fi

# Build RPerf Client service
if [[ "$BUILD_ALL" == true || "$BUILD_RPERF_CLIENT" == true ]]; then
    build_image "rperf-client" "docker/compose/Dockerfile.rperf-client" "--build-arg VERSION=$VERSION --build-arg BUILD_ID=$BUILD_ID"
fi

# Build SNMP Checker service
if [[ "$BUILD_ALL" == true || "$BUILD_SNMP_CHECKER" == true ]]; then
    build_image "snmp-checker" "docker/compose/Dockerfile.snmp-checker" "--build-arg VERSION=$VERSION --build-arg BUILD_ID=$BUILD_ID"
fi

# Build Sync service
if [[ "$BUILD_ALL" == true || "$BUILD_SYNC" == true ]]; then
    build_image "sync" "docker/compose/Dockerfile.sync" "--build-arg VERSION=$VERSION --build-arg BUILD_ID=$BUILD_ID"
fi

# Build SRQL service
if [[ "$BUILD_ALL" == true || "$BUILD_SRQL" == true ]]; then
    build_image "srql" "docker/compose/Dockerfile.srql" "--build-arg VERSION=$VERSION --build-arg BUILD_ID=$BUILD_ID"
fi

# Build Tools service
if [[ "$BUILD_ALL" == true || "$BUILD_TOOLS" == true ]]; then
    build_image "tools" "docker/compose/Dockerfile.tools" "--build-arg VERSION=$VERSION --build-arg BUILD_ID=$BUILD_ID"
fi

# Build Trapd service
if [[ "$BUILD_ALL" == true || "$BUILD_TRAPD" == true ]]; then
    build_image "trapd" "docker/compose/Dockerfile.trapd" "--build-arg VERSION=$VERSION --build-arg BUILD_ID=$BUILD_ID"
fi

# Build Zen service
if [[ "$BUILD_ALL" == true || "$BUILD_ZEN" == true ]]; then
    build_image "zen" "docker/compose/Dockerfile.zen" "--build-arg VERSION=$VERSION --build-arg BUILD_ID=$BUILD_ID"
fi

# Build kong-config (JWKS renderer) image
if [[ "$BUILD_ALL" == true || "$BUILD_KONG_CONFIG" == true ]]; then
    build_image "kong-config" "docker/compose/Dockerfile.jwks2kong" ""
fi

log "Build process completed!"

if [[ "$PUSH" == false ]]; then
    echo ""
    if [[ "$FORCE_MULTIPLATFORM" == true ]]; then
        warn "Multi-platform images were built and cached but not pushed or loaded locally."
        log "Images are stored in buildx cache and can be pushed later with:"
        log "  $0 --push --tag $TAG"
    else
        warn "Images were built locally but not pushed."
        log "To push multi-platform images, run with --push flag after logging in:"
        log "  echo \$GITHUB_TOKEN | docker login ghcr.io -u \$GITHUB_USERNAME --password-stdin"
        log "  $0 --push --tag $TAG"
    fi
fi

echo ""
if [[ "$PUSH" == true ]]; then
    log "Images were pushed to $REGISTRY; skipping local image list."
else
    log "Available images:"
    docker images | grep "serviceradar" | head -10 || true
fi
