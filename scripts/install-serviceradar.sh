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

# install-serviceradar.sh
# Installs ServiceRadar components based on specified scenarios

set -e

# Configuration
VERSION="1.0.31"
RELEASE_URL="https://github.com/carverauto/serviceradar/releases/download/${VERSION}"
TEMP_DIR="/tmp/serviceradar-install"

# Default settings
INTERACTIVE=true
CHECKERS=""
INSTALL_ALL=false
INSTALL_CORE=false
INSTALL_POLLER=false
INSTALL_AGENT=false

# Common functions
log() { echo "[ServiceRadar] $1"; }
error() { echo "[ServiceRadar] ERROR: $1" >&2; exit 1; }

# Parse command-line arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --non-interactive)
                INTERACTIVE=false
                shift
                ;;
            --checkers=*)
                CHECKERS=$(echo "$1" | cut -d'=' -f2)
                shift
                ;;
            --all)
                INSTALL_ALL=true
                shift
                ;;
            --core)
                INSTALL_CORE=true
                shift
                ;;
            --poller)
                INSTALL_POLLER=true
                shift
                ;;
            --agent)
                INSTALL_AGENT=true
                shift
                ;;
            *)
                error "Unknown argument: $1"
                ;;
        esac
    done
}

# Detect system and set package manager
detect_system() {
    if command -v apt-get >/dev/null 2>&1; then
        SYSTEM="debian"
        PKG_MANAGER="apt"
        PKG_EXT="deb"
    elif command -v dnf >/dev/null 2>&1; then
        SYSTEM="rhel"
        PKG_MANAGER="dnf"
        PKG_EXT="rpm"
    elif command -v yum >/dev/null 2>&1; then
        SYSTEM="rhel"
        PKG_MANAGER="yum"
        PKG_EXT="rpm"
    else
        error "Unsupported system. Requires apt (Debian/Ubuntu) or dnf/yum (RHEL/CentOS/Fedora)."
    fi
    log "Detected system: $SYSTEM ($PKG_MANAGER)"
}

# Install dependencies based on selected components
install_dependencies() {
    log "Installing dependencies..."
    if [ "$SYSTEM" = "debian" ]; then
        apt-get update
        # Install Node.js and Nginx if web component is included
        if [ "$INSTALL_ALL" = "true" ] || [ "$INSTALL_CORE" = "true" ]; then
            curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
            apt-get install -y systemd nginx nodejs
        fi
        # Install libcap2-bin for agent
        if [ "$INSTALL_ALL" = "true" ] || [ "$INSTALL_AGENT" = "true" ]; then
            apt-get install -y libcap2-bin
        fi
        # Always install systemd (for poller or other components)
        if [ "$INSTALL_ALL" = "true" ] || [ "$INSTALL_POLLER" = "true" ] || [ "$INSTALL_CORE" = "true" ]; then
            apt-get install -y systemd
        fi
    else
        $PKG_MANAGER install -y https://dl.fedoraproject.org/pub/epel/epel-release-latest-9.noarch.rpm
        if grep -q "Oracle Linux" /etc/os-release; then
            if command -v /usr/bin/crb >/dev/null 2>&1; then
                /usr/bin/crb enable
            else
                $PKG_MANAGER config-manager --set-enabled ol9_codeready_builder || true
            fi
        fi
        # Install Node.js and Nginx if web component is included
        if [ "$INSTALL_ALL" = "true" ] || [ "$INSTALL_CORE" = "true" ]; then
            $PKG_MANAGER module enable -y nodejs:20
            $PKG_MANAGER install -y systemd nginx nodejs
        fi
        # Install libcap and related for agent
        if [ "$INSTALL_ALL" = "true" ] || [ "$INSTALL_AGENT" = "true" ]; then
            $PKG_MANAGER install -y libcap systemd-devel gcc
        fi
        # Always install systemd (for poller or other components)
        if [ "$INSTALL_ALL" = "true" ] || [ "$INSTALL_POLLER" = "true" ] || [ "$INSTALL_CORE" = "true" ]; then
            $PKG_MANAGER install -y systemd
        fi
    fi
}

# Download a package
download_package() {
    local pkg_name="$1"
    local suffix="$2"
    local url="${RELEASE_URL}/${pkg_name}-${VERSION}${suffix}.${PKG_EXT}"
    local output="${TEMP_DIR}/${pkg_name}.${PKG_EXT}"
    log "Downloading $pkg_name..."
    curl -sSL -o "$output" "$url" || error "Failed to download $pkg_name from $url"
}

# Install packages
install_packages() {
    local packages=("$@")
    local pkg_files=""
    for pkg in "${packages[@]}"; do
        if [ -f "${TEMP_DIR}/${pkg}.${PKG_EXT}" ]; then
            pkg_files="$pkg_files ${TEMP_DIR}/${pkg}.${PKG_EXT}"
        fi
    done
    if [ -n "$pkg_files" ]; then
        log "Installing packages: ${packages[*]}"
        if [ "$SYSTEM" = "debian" ]; then
            apt install -y $pkg_files || error "Failed to install packages"
        else
            $PKG_MANAGER install -y $pkg_files || error "Failed to install packages"
        fi
    fi
}

# Prompt for installation scenario (interactive mode only)
prompt_scenario() {
    if [ "$INTERACTIVE" = "true" ]; then
        echo "[ServiceRadar] Select components to install (you can select multiple):"
        echo "1) All-in-One (all components)"
        echo "2) Core + Web UI (core, web, nats, kv, sync)"
        echo "3) Poller (poller)"
        echo "4) Agent (agent)"
        read -p "Enter choices (e.g., '1' or '2 3 4' for multiple): " choices
        for choice in $choices; do
            case "$choice" in
                1)
                    INSTALL_ALL=true
                    ;;
                2)
                    INSTALL_CORE=true
                    ;;
                3)
                    INSTALL_POLLER=true
                    ;;
                4)
                    INSTALL_AGENT=true
                    ;;
                *)
                    error "Invalid choice: $choice. Please select 1, 2, 3, or 4."
                    ;;
            esac
        done
    fi
}

# Check if a checker should be installed
should_install_checker() {
    local checker="$1"
    if [ "$INTERACTIVE" = "true" ]; then
        read -p "[ServiceRadar] Install optional checker $checker? (y/n) [n]: " choice
        if [ "$choice" = "y" ] || [ "$choice" = "Y" ]; then
            echo "yes"
        else
            echo "no"
        fi
    else
        # Non-interactive: Check if the checker is in the --checkers list
        if echo "$CHECKERS" | grep -q -E "(^|,)$checker(,|$)"; then
            echo "yes"
        else
            echo "no"
        fi
    fi
}

# Main installation logic
main() {
    log "Starting ServiceRadar installation (version ${VERSION})..."

    # Parse arguments
    parse_args "$@"

    # If no scenario is specified, prompt (interactive mode) or fail (non-interactive)
    if [ "$INSTALL_ALL" = "false" ] && [ "$INSTALL_CORE" = "false" ] && [ "$INSTALL_POLLER" = "false" ] && [ "$INSTALL_AGENT" = "false" ]; then
        if [ "$INTERACTIVE" = "true" ]; then
            prompt_scenario
        else
            error "No installation scenario specified. Use --all, --core, --poller, or --agent."
        fi
    fi

    # If --all is specified, override other flags
    if [ "$INSTALL_ALL" = "true" ]; then
        INSTALL_CORE=true
        INSTALL_POLLER=true
        INSTALL_AGENT=true
    fi

    # Validate that at least one component is selected
    if [ "$INSTALL_CORE" = "false" ] && [ "$INSTALL_POLLER" = "false" ] && [ "$INSTALL_AGENT" = "false" ]; then
        error "No components selected to install."
    fi

    # Detect system
    detect_system

    # Create temporary directory
    mkdir -p "$TEMP_DIR"

    # Install dependencies
    install_dependencies

    # Determine packages to install
    core_packages=("serviceradar-core" "serviceradar-web" "serviceradar-nats" "serviceradar-kv" "serviceradar-sync")
    poller_packages=("serviceradar-poller")
    agent_packages=("serviceradar-agent")
    packages_to_install=()

    if [ "$INSTALL_CORE" = "true" ]; then
        packages_to_install+=("${core_packages[@]}")
    fi
    if [ "$INSTALL_POLLER" = "true" ]; then
        packages_to_install+=("${poller_packages[@]}")
    fi
    if [ "$INSTALL_AGENT" = "true" ]; then
        packages_to_install+=("${agent_packages[@]}")
    fi

    # Download and install main packages
    for pkg in "${packages_to_install[@]}"; do
        if [ "$SYSTEM" = "rhel" ]; then
            if [ "$pkg" = "serviceradar-core" ] || [ "$pkg" = "serviceradar-kv" ] || [ "$pkg" = "serviceradar-nats" ] || [ "$pkg" = "serviceradar-agent" ] || [ "$pkg" = "serviceradar-poller" ]; then
                download_package "$pkg" "-1.el9.x86_64"
            else
                download_package "$pkg" "-1.el9.x86_64"
            fi
        else
            download_package "$pkg"
        fi
    done
    install_packages "${packages_to_install[@]}"

    # Optional checkers
    checkers=("serviceradar-rperf" "serviceradar-rperf-checker" "serviceradar-snmp-checker" "serviceradar-dusk-checker")
    checker_packages=()
    for checker in "${checkers[@]}"; do
        available="yes"
        if [ "$checker" = "serviceradar-dusk-checker" ] && [ "$SYSTEM" != "debian" ]; then
            available="no"
        fi
        if [ "$checker" = "serviceradar-rperf" ] || [ "$checker" = "serviceradar-rperf-checker" ]; then
            if [ "$SYSTEM" != "rhel" ]; then
                available="no"
            fi
        fi
        # Skip checkers not relevant to the selected scenario
        if [ "$INSTALL_CORE" = "false" ] && [ "$checker" = "serviceradar-dusk-checker" ]; then
            available="no"
        fi
        if [ "$INSTALL_POLLER" = "false" ] && [ "$INSTALL_AGENT" = "false" ] && { [ "$checker" = "serviceradar-rperf" ] || [ "$checker" = "serviceradar-rperf-checker" ] || [ "$checker" = "serviceradar-snmp-checker" ]; }; then
            available="no"
        fi
        if [ "$available" = "yes" ] && [ "$(should_install_checker "$checker")" = "yes" ]; then
            if [ "$checker" = "serviceradar-rperf" ] || [ "$checker" = "serviceradar-rperf-checker" ]; then
                download_package "$checker" "-1.el9.x86_64"
            else
                download_package "$checker"
            fi
            checker_packages+=("$checker")
        fi
    done

    # Install optional checkers
    install_packages "${checker_packages[@]}"

    # Cleanup
    rm -rf "$TEMP_DIR"

    # Success message
    log "ServiceRadar installation completed successfully!"
    if [ "$INSTALL_CORE" = "true" ]; then
        log "Web UI: http://your-server-ip/"
        log "Core API: http://your-server-ip:8090/"
    fi

    log "Check service status: systemctl status serviceradar-*"
    log "View logs: journalctl -u serviceradar-<component>.service"
}

# Run main
main "$@"