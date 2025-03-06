#!/bin/bash

# Copyright 2025 Carver Automation Corporation.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# buildServiceradar.sh - Build and optionally install ServiceRadar components
set -e  # Exit on any error

# Default settings
VERSION=${VERSION:-1.0.22}
BUILD_TAGS=${BUILD_TAGS:-""}
BUILD_ALL=false
INSTALL=false
TARGET_HOST=""
COMPONENTS=()

# Display usage information
usage() {
    echo "Usage: $0 [options] [components]"
    echo
    echo "Options:"
    echo "  -h, --help                Show this help message"
    echo "  -v, --version VERSION     Set version number (default: $VERSION)"
    echo "  -t, --tags TAGS           Set build tags"
    echo "  -a, --all                 Build all components"
    echo "  -i, --install             Install packages after building"
    echo "  --host HOST               Install to remote host (requires SSH access)"
    echo
    echo "Components:"
    echo "  core                      Build core API service"
    echo "  web                       Build web UI"
    echo "  poller                    Build poller service"
    echo "  agent                     Build agent service"
    echo "  dusk-checker              Build dusk checker"
    echo "  snmp-checker              Build SNMP checker"
    echo
    echo "Examples:"
    echo "  $0 --all                  Build all components"
    echo "  $0 core web              Build core and web components"
    echo "  $0 --all --install        Build and install all components locally"
    echo "  $0 core web --install --host user@server  Build and install on remote host"
    echo
    exit 1
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            usage
            ;;
        -v|--version)
            VERSION="$2"
            shift 2
            ;;
        -t|--tags)
            BUILD_TAGS="$2"
            shift 2
            ;;
        -a|--all)
            BUILD_ALL=true
            shift
            ;;
        -i|--install)
            INSTALL=true
            shift
            ;;
        --host)
            TARGET_HOST="$2"
            shift 2
            ;;
        core|web|poller|agent|dusk-checker|snmp-checker)
            COMPONENTS+=("$1")
            shift
            ;;
        *)
            echo "Unknown option: $1"
            usage
            ;;
    esac
done

# Check if we should build all components
if [ "$BUILD_ALL" = true ]; then
    COMPONENTS=("core" "web" "poller" "agent" "dusk-checker" "snmp-checker")
fi

# If no components specified, show usage
if [ ${#COMPONENTS[@]} -eq 0 ]; then
    echo "Error: No components specified for building"
    usage
fi

# Export variables for sub-scripts
export VERSION
export BUILD_TAGS

# Function to build a component
build_component() {
    local component=$1
    echo "========================================="
    echo "Building $component component (version $VERSION)"
    echo "========================================="
    
    case $component in
        core)
            ./scripts/setup-deb-core.sh
            ;;
        web)
            ./scripts/setup-deb-web.sh
            ;;
        poller)
            ./scripts/setup-deb-poller.sh
            ;;
        agent)
            ./scripts/setup-deb-agent.sh
            ;;
        dusk-checker)
            ./scripts/setup-deb-dusk-checker.sh
            ;;
        snmp-checker)
            ./scripts/setup-deb-snmp-checker.sh
            ;;
        *)
            echo "Unknown component: $component"
            return 1
            ;;
    esac
    
    echo "Build of $component completed successfully"
    return 0
}

# Function to install packages
install_packages() {
    local install_cmd="sudo dpkg -i"
    local prefix="./release-artifacts/"
    local packages=()
    
    # Build list of package files
    for component in "${COMPONENTS[@]}"; do
        local package_name
        
        case $component in
            core)
                package_name="serviceradar-core${VERSION}.deb"
                ;;
            web)
                package_name="serviceradar-web_${VERSION}.deb"
                ;;
            poller)
                package_name="serviceradar-poller_${VERSION}.deb"
                ;;
            agent)
                package_name="serviceradar-agent_${VERSION}.deb"
                ;;
            dusk-checker)
                package_name="serviceradar-dusk-checker_${VERSION}.deb"
                ;;
            snmp-checker)
                package_name="serviceradar-snmp-checker_${VERSION}.deb"
                ;;
            *)
                echo "Unknown component for installation: $component"
                continue
                ;;
        esac
        
        # Add package to the list if it exists
        if [ -f "${prefix}${package_name}" ]; then
            packages+=("${prefix}${package_name}")
        else
            echo "Warning: Package file not found: ${prefix}${package_name}"
        fi
    done
    
    # If no packages to install, return
    if [ ${#packages[@]} -eq 0 ]; then
        echo "No packages found for installation"
        return 1
    fi
    
    # Install locally or remotely
    if [ -z "$TARGET_HOST" ]; then
        echo "Installing packages locally..."
        $install_cmd "${packages[@]}"
    else
        echo "Installing packages on $TARGET_HOST..."
        
        # Create temp directory on remote host
        ssh "$TARGET_HOST" "mkdir -p ~/serviceradar-tmp"
        
        # Copy packages to remote host
        for package in "${packages[@]}"; do
            echo "Copying $package to $TARGET_HOST..."
            scp "$package" "$TARGET_HOST:~/serviceradar-tmp/"
        done
        
        # Install packages on remote host
        ssh "$TARGET_HOST" "sudo dpkg -i ~/serviceradar-tmp/*.deb && rm -rf ~/serviceradar-tmp"
    fi
    
    echo "Installation completed successfully"
    return 0
}

# Create release-artifacts directory if it doesn't exist
mkdir -p ./release-artifacts

# Build each component
for component in "${COMPONENTS[@]}"; do
    build_component "$component" || exit 1
done

# Install packages if requested
if [ "$INSTALL" = true ]; then
    install_packages || exit 1
fi

echo "All operations completed successfully!"
