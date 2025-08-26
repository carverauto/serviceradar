#!/usr/bin/env bash

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
  -a, --all            Build ALL images (18+ services)
  -c, --core           Build only core image
  -d, --proton         Build only proton image
  -g, --cert-gen       Build only cert-generator image
  -s, --service NAME   Build specific service by name (e.g., --service web)
  --list-services      List all available services
  --platform PLATFORM  Target platform (default: linux/amd64,linux/arm64)
  --no-cache           Build without cache
  -h, --help           Show this help

SERVICES BUILT WITH --all:
  Infrastructure: proton, config-updater, nginx, cert-generator
  Core Services: core, web, agent, poller, sync, kv, db-event-writer
  SNMP/Network: mapper, snmp-checker
  Monitoring: otel, flowgger, trapd, zen, rperf-client
  Testing: faker (Armis API emulator)

EXAMPLES:
  # Build all images locally
  $0 --all --tag v1.2.3

  # Build and push all images with latest tag
  $0 --all --push --tag latest

  # Build only core service
  $0 --core --push --tag latest

  # Build for specific platform
  $0 --all --platform linux/amd64

AUTHENTICATION:
  Before pushing, login to GHCR:
  echo \$GITHUB_TOKEN | docker login ghcr.io -u \$GITHUB_USERNAME --password-stdin

EOF
}

# Define all available services first (needed for --list-services)
declare -A SERVICES=(
    ["core"]="docker/compose/Dockerfile.core:"
    ["proton"]="docker/compose/Dockerfile.proton:"
    ["web"]="docker/compose/Dockerfile.web:"
    ["agent"]="docker/compose/Dockerfile.agent:"
    ["poller"]="docker/compose/Dockerfile.poller:"
    ["sync"]="docker/compose/Dockerfile.sync:"
    ["kv"]="docker/compose/Dockerfile.kv:"
    ["db-event-writer"]="docker/compose/Dockerfile.db-event-writer:"
    ["mapper"]="docker/compose/Dockerfile.mapper:"
    ["snmp-checker"]="docker/compose/Dockerfile.snmp-checker:"
    ["otel"]="docker/compose/Dockerfile.otel:"
    ["flowgger"]="docker/compose/Dockerfile.flowgger:"
    ["trapd"]="docker/compose/Dockerfile.trapd:"
    ["zen"]="docker/compose/Dockerfile.zen:"
    ["rperf-client"]="docker/compose/Dockerfile.rperf-client:"
    ["nginx"]="docker/compose/Dockerfile.nginx:"
    ["config-updater"]="docker/compose/Dockerfile.config-updater:"
    ["faker"]="cmd/faker/Dockerfile:"
)

# Parse command line arguments
TAG="$DEFAULT_TAG"
PUSH=false
BUILD_ALL=false
BUILD_CORE=false
BUILD_PROTON=false
BUILD_CERT_GEN=false
BUILD_SPECIFIC=""
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
        -s|--service)
            BUILD_SPECIFIC="$2"
            shift 2
            ;;
        --list-services)
            echo "Available services:"
            {
                echo "cert-generator (generated)"
                printf '%s\n' "${!SERVICES[@]}"
            } | sort | sed 's/^/  /'
            exit 0
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

# Validate specific service if provided
if [[ -n "$BUILD_SPECIFIC" ]]; then
    if [[ "$BUILD_SPECIFIC" == "cert-generator" ]]; then
        BUILD_CERT_GEN=true
    elif [[ -z "${SERVICES[$BUILD_SPECIFIC]}" ]]; then
        error "Unknown service: $BUILD_SPECIFIC"
        echo "Available services:"
        echo "  cert-generator"
        for service in "${!SERVICES[@]}"; do
            echo "  $service"
        done | sort
        exit 1
    fi
fi

# If no specific image is selected, build all
if [[ "$BUILD_ALL" == false && "$BUILD_CORE" == false && "$BUILD_PROTON" == false && "$BUILD_CERT_GEN" == false && -z "$BUILD_SPECIFIC" ]]; then
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

# Count and show services to be built
if [[ "$BUILD_ALL" == true ]]; then
    service_count=$((${#SERVICES[@]} + 1)) # +1 for cert-generator
    log "Will build $service_count services: ${!SERVICES[@]} cert-generator"
else
    services_to_build=""
    if [[ "$BUILD_CORE" == true ]]; then services_to_build="$services_to_build core"; fi
    if [[ "$BUILD_PROTON" == true ]]; then services_to_build="$services_to_build proton"; fi
    if [[ "$BUILD_CERT_GEN" == true ]]; then services_to_build="$services_to_build cert-generator"; fi
    log "Will build specific services:$services_to_build"
fi

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

# Global variables for tracking build success
declare -a SUCCESSFUL_BUILDS=()
declare -a FAILED_BUILDS=()

# Build function
build_image() {
    local image_name="$1"
    local dockerfile="$2"
    local build_args="$3"
    
    local full_image_name="${IMAGE_PREFIX}-${image_name}:${TAG}"
    local latest_image_name="${IMAGE_PREFIX}-${image_name}:latest"
    
    log "Building $full_image_name"
    
    # Check if dockerfile exists
    if [[ ! -f "$dockerfile" ]]; then
        error "Dockerfile not found: $dockerfile"
        return 1
    fi
    
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
    if [[ "$TAG" == "latest" ]] || [[ "$PUSH" == true ]]; then
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
    local build_exit_code=$?
    if [ $build_exit_code -ne 0 ]; then
        error "Failed to build $image_name (exit code: $build_exit_code)"
        FAILED_BUILDS+=("$image_name")
        return 1
    fi
    
    # Track successful build
    SUCCESSFUL_BUILDS+=("$image_name")
    
    if [[ "$PUSH" == true ]]; then
        success "Built and pushed: $full_image_name"
        if [[ "$TAG" == "latest" ]]; then
            success "Also pushed as: $latest_image_name"
        fi
    else
        success "Built: $full_image_name"
    fi
}

# Update build args with actual version values
update_services_with_version() {
    SERVICES["core"]="docker/compose/Dockerfile.core:--build-arg VERSION=$VERSION --build-arg BUILD_ID=$BUILD_ID"
    SERVICES["web"]="docker/compose/Dockerfile.web:--build-arg VERSION=$VERSION --build-arg BUILD_ID=$BUILD_ID"
    SERVICES["agent"]="docker/compose/Dockerfile.agent:--build-arg VERSION=$VERSION --build-arg BUILD_ID=$BUILD_ID"
    SERVICES["poller"]="docker/compose/Dockerfile.poller:--build-arg VERSION=$VERSION --build-arg BUILD_ID=$BUILD_ID"
    SERVICES["sync"]="docker/compose/Dockerfile.sync:--build-arg VERSION=$VERSION --build-arg BUILD_ID=$BUILD_ID"
    SERVICES["kv"]="docker/compose/Dockerfile.kv:--build-arg VERSION=$VERSION --build-arg BUILD_ID=$BUILD_ID"
    SERVICES["db-event-writer"]="docker/compose/Dockerfile.db-event-writer:--build-arg VERSION=$VERSION --build-arg BUILD_ID=$BUILD_ID"
    SERVICES["mapper"]="docker/compose/Dockerfile.mapper:--build-arg VERSION=$VERSION --build-arg BUILD_ID=$BUILD_ID"
    SERVICES["snmp-checker"]="docker/compose/Dockerfile.snmp-checker:--build-arg VERSION=$VERSION --build-arg BUILD_ID=$BUILD_ID"
}

# Call the function to update services with actual version values
update_services_with_version

# Build cert-generator first (special case - needs to create Dockerfile)
if [[ "$BUILD_ALL" == true || "$BUILD_CERT_GEN" == true ]]; then
    # Create Dockerfile for cert-generator if it doesn't exist
    if [[ ! -f "docker/compose/Dockerfile.cert-generator" ]]; then
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
    fi
    
    build_image "cert-generator" "docker/compose/Dockerfile.cert-generator" ""
fi

# Build selected or all services
if [[ "$BUILD_ALL" == true ]]; then
    log "Building all ServiceRadar images..."
    
    # Build in dependency order
    # 1. Infrastructure services first
    for service in proton config-updater nginx; do
        if [[ -n "${SERVICES[$service]}" ]]; then
            IFS=':' read -r dockerfile build_args <<< "${SERVICES[$service]}"
            build_image "$service" "$dockerfile" "$build_args" || warn "Failed to build $service, continuing..."
        fi
    done
    
    # 2. Core services
    for service in core web agent poller sync kv db-event-writer mapper snmp-checker; do
        if [[ -n "${SERVICES[$service]}" ]]; then
            IFS=':' read -r dockerfile build_args <<< "${SERVICES[$service]}"
            build_image "$service" "$dockerfile" "$build_args" || warn "Failed to build $service, continuing..."
        fi
    done
    
    # 3. Monitoring and utility services
    for service in otel flowgger trapd zen rperf-client faker; do
        if [[ -n "${SERVICES[$service]}" ]]; then
            IFS=':' read -r dockerfile build_args <<< "${SERVICES[$service]}"
            build_image "$service" "$dockerfile" "$build_args" || warn "Failed to build $service, continuing..."
        fi
    done
else
    # Build individual services if requested
    if [[ "$BUILD_CORE" == true ]]; then
        IFS=':' read -r dockerfile build_args <<< "${SERVICES[core]}"
        build_image "core" "$dockerfile" "$build_args"
    fi
    
    if [[ "$BUILD_PROTON" == true ]]; then
        IFS=':' read -r dockerfile build_args <<< "${SERVICES[proton]}"
        build_image "proton" "$dockerfile" "$build_args"
    fi
    
    # Build specific service if requested
    if [[ -n "$BUILD_SPECIFIC" && "$BUILD_SPECIFIC" != "cert-generator" ]]; then
        IFS=':' read -r dockerfile build_args <<< "${SERVICES[$BUILD_SPECIFIC]}"
        build_image "$BUILD_SPECIFIC" "$dockerfile" "$build_args"
    fi
fi

# Cleanup function
cleanup() {
    # Remove temporary Dockerfile if it was created
    if [[ -f "docker/compose/Dockerfile.cert-generator" ]] && [[ "$BUILD_ALL" == true || "$BUILD_CERT_GEN" == true ]]; then
        rm -f docker/compose/Dockerfile.cert-generator
    fi
}

# Set trap for cleanup on exit
trap cleanup EXIT

log "Build process completed!"

# Count successful builds using our tracking arrays  
success_count=${#SUCCESSFUL_BUILDS[@]}
failed_count=${#FAILED_BUILDS[@]}
total_attempted=$((success_count + failed_count))

# Calculate expected total based on what we tried to build
total_expected=0
if [[ "$BUILD_ALL" == true ]]; then
    total_expected=$((${#SERVICES[@]} + 1)) # +1 for cert-generator
else
    if [[ "$BUILD_CORE" == true ]]; then ((total_expected++)); fi
    if [[ "$BUILD_PROTON" == true ]]; then ((total_expected++)); fi  
    if [[ "$BUILD_CERT_GEN" == true ]]; then ((total_expected++)); fi
    if [[ -n "$BUILD_SPECIFIC" ]]; then ((total_expected++)); fi
fi

echo ""
if [[ $success_count -eq $total_expected ]]; then
    success "Successfully built $success_count/$total_expected images! 🎉"
    if [[ ${#SUCCESSFUL_BUILDS[@]} -gt 0 ]]; then
        log "Built services: ${SUCCESSFUL_BUILDS[*]}"
    fi
else
    warn "Built $success_count/$total_expected images ($(($total_expected - $success_count)) failed)"
    if [[ ${#SUCCESSFUL_BUILDS[@]} -gt 0 ]]; then
        log "Successfully built: ${SUCCESSFUL_BUILDS[*]}"
    fi
    if [[ ${#FAILED_BUILDS[@]} -gt 0 ]]; then
        error "Failed to build: ${FAILED_BUILDS[*]}"
    fi
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
    log "Images pushed to registry with tag: $TAG"
    if [[ ${#SUCCESSFUL_BUILDS[@]} -gt 0 ]]; then
        for service in "${SUCCESSFUL_BUILDS[@]}"; do
            echo "  - ${IMAGE_PREFIX}-${service}:${TAG}"
        done
    fi
else
    log "Recently built ServiceRadar images:"
    docker images | grep "serviceradar" | grep "$TAG" | head -20
fi