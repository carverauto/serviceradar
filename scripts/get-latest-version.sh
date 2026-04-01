#!/bin/bash

# Get the latest ServiceRadar version from various sources
# This script determines the appropriate version tag to use

set -euo pipefail

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() {
    echo -e "${BLUE}[INFO]${NC} $1" >&2
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1" >&2
}

# Function to get latest git tag
get_git_tag() {
    if git describe --tags --abbrev=0 2>/dev/null; then
        return 0
    fi
    return 1
}

# Function to get version from VERSION file
get_version_file() {
    if [[ -f "VERSION" ]]; then
        cat VERSION
        return 0
    fi
    return 1
}

# Function to get latest registry tag using skopeo
get_registry_latest() {
    local repo="${OCI_VERSION_REPOSITORY:-registry.carverauto.dev/serviceradar/serviceradar-core-elx}"

    if command -v skopeo >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
        local latest_tag
        latest_tag=$(skopeo list-tags "docker://${repo}" 2>/dev/null | \
            jq -r '.Tags[]? // empty' | \
            grep -E '^v?[0-9]+\.[0-9]+\.[0-9]+([-.][0-9A-Za-z.-]+)?$' | \
            sort -V | tail -n1)

        if [[ -n "$latest_tag" ]]; then
            echo "${latest_tag#v}"
            return 0
        fi
    fi
    return 1
}

# Function to check if image exists in registry
check_image_exists() {
    local image="$1"
    if docker manifest inspect "$image" >/dev/null 2>&1; then
        return 0
    fi
    return 1
}

check_version_image_exists() {
    local repo="${OCI_VERSION_REPOSITORY:-registry.carverauto.dev/serviceradar/serviceradar-core-elx}"
    local version="$1"
    check_image_exists "${repo}:v${version}" || check_image_exists "${repo}:${version}"
}

# Main logic
main() {
    local version=""
    
    # Method 1: Check if we're in a git repo and get latest tag
    if version=$(get_git_tag); then
        # Remove 'v' prefix if present
        version=${version#v}
        log "Found git tag: $version"
        
        # Verify the image exists
        if check_version_image_exists "$version"; then
            echo "$version"
            return 0
        else
            warn "Git tag $version found but image doesn't exist in registry"
        fi
    fi
    
    # Method 2: Check VERSION file
    if version=$(get_version_file); then
        log "Found VERSION file: $version"
        
        # Verify the image exists
        if check_version_image_exists "$version"; then
            echo "$version"
            return 0
        else
            warn "VERSION file $version found but image doesn't exist in registry"
        fi
    fi
    
    # Method 3: Try to get latest from the OCI registry
    if version=$(get_registry_latest); then
        log "Found latest registry version: $version"
        echo "$version"
        return 0
    fi
    
    # Method 4: Fallback to a known stable version
    local fallback="1.0.53"
    warn "Could not determine latest version, falling back to $fallback"
    echo "$fallback"
}

main "$@"
