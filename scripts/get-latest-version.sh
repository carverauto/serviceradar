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

# Function to get latest GHCR tag using GitHub API
get_ghcr_latest() {
    local package_name="$1"
    local url="https://api.github.com/orgs/carverauto/packages/container/serviceradar-${package_name}/versions"
    
    # Try to get the latest version from GHCR
    if command -v curl >/dev/null 2>&1; then
        local latest_tag=$(curl -s "$url" 2>/dev/null | \
            jq -r '.[0].metadata.container.tags[]? // empty' 2>/dev/null | \
            grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | \
            head -1)
        
        if [[ -n "$latest_tag" ]]; then
            echo "$latest_tag"
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

# Main logic
main() {
    local version=""
    
    # Method 1: Check if we're in a git repo and get latest tag
    if version=$(get_git_tag); then
        # Remove 'v' prefix if present
        version=${version#v}
        log "Found git tag: $version"
        
        # Verify the image exists
        if check_image_exists "ghcr.io/carverauto/serviceradar-core:$version"; then
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
        if check_image_exists "ghcr.io/carverauto/serviceradar-core:$version"; then
            echo "$version"
            return 0
        else
            warn "VERSION file $version found but image doesn't exist in registry"
        fi
    fi
    
    # Method 3: Try to get latest from GHCR API
    if version=$(get_ghcr_latest "core"); then
        log "Found latest GHCR version: $version"
        echo "$version"
        return 0
    fi
    
    # Method 4: Fallback to a known stable version
    local fallback="1.0.53"
    warn "Could not determine latest version, falling back to $fallback"
    echo "$fallback"
}

main "$@"