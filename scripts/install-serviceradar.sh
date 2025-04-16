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

# Dracula color theme for terminal
COLOR_RESET="\033[0m"
COLOR_WHITE="\033[97m"
COLOR_PURPLE="\033[95m"
COLOR_CYAN="\033[96m"
COLOR_GREEN="\033[92m"
COLOR_PINK="\033[95m"
COLOR_YELLOW="\033[93m"
COLOR_RED="\033[91m"
COLOR_BOLD="\033[1m"

# Common functions
log() {
    echo -e "${COLOR_PURPLE}${COLOR_BOLD}[ServiceRadar]${COLOR_RESET} ${COLOR_WHITE}$1${COLOR_RESET}"
}
error() {
    echo -e "${COLOR_RED}${COLOR_BOLD}[ServiceRadar] ERROR:${COLOR_RESET} ${COLOR_WHITE}$1${COLOR_RESET}" >&2
    exit 1
}
header() {
    echo -e "\n${COLOR_PURPLE}${COLOR_BOLD}══════ $1 ══════${COLOR_RESET}\n"
}
info() {
    echo -e "${COLOR_CYAN}${COLOR_BOLD}[ServiceRadar]${COLOR_RESET} ${COLOR_WHITE}$1${COLOR_RESET}"
}
success() {
    echo -e "${COLOR_GREEN}${COLOR_BOLD}[ServiceRadar]${COLOR_RESET} ${COLOR_WHITE}$1${COLOR_RESET}"
}

# Display a Unicode box banner
display_banner() {
    local title="ServiceRadar Installer v${VERSION}"
    local subtitle="https://serviceradar.cloud"
    local title_width=$((${#title} + 4))
    local subtitle_width=$((${#subtitle} + 4))
    local box_width=$((title_width > subtitle_width ? title_width : subtitle_width))

    echo -e "${COLOR_PINK}╔$(printf '═%.0s' $(seq 1 $box_width))╗${COLOR_RESET}"
    echo -e "${COLOR_PINK}║${COLOR_RESET}$(printf '%*s' $(( (box_width - ${#title}) / 2 )) '')${COLOR_PURPLE}${COLOR_BOLD}${title}${COLOR_RESET}$(printf '%*s' $(( (box_width - ${#title}) / 2 )) '')${COLOR_PINK}║${COLOR_RESET}"
    echo -e "${COLOR_PINK}╚$(printf '═%.0s' $(seq 1 $box_width))╝${COLOR_RESET}"
    echo -e "$(printf '%*s' $(( (box_width - ${#subtitle}) / 2 )) '')${COLOR_PURPLE}${COLOR_BOLD}${subtitle}${COLOR_RESET}\n"
}

# Check and install curl
check_curl() {
    header "Checking Prerequisites"
    if ! command -v curl >/dev/null 2>&1; then
        log "curl is not installed. Installing curl..."
        if [ "$SYSTEM" = "debian" ]; then
            apt-get update
            apt-get install -y curl || error "Failed to install curl"
        else
            $PKG_MANAGER install -y curl || error "Failed to install curl"
        fi
        success "curl installed successfully!"
    else
        log "curl is already installed."
    fi
}

# Validate downloaded .deb file
validate_deb() {
    local file="$1"
    if [ ! -f "$file" ]; then
        error "Downloaded file $file does not exist"
    fi
    # Check if the file is a valid .deb package
    if ! dpkg-deb -W "$file" >/dev/null 2>&1; then
        error "Downloaded file $file is not a valid .deb package"
    fi
}

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
        error "No supported package manager found. Requires apt (Debian/Ubuntu) or dnf/yum (RHEL/CentOS/Fedora)."
    fi
    log "Detected system: $SYSTEM ($PKG_MANAGER)"
}

# Install dependencies based on selected components
install_dependencies() {
    header "Installing Dependencies"
    log "Preparing system for Service [ServiceRadar] installation..."
    if [ "$SYSTEM" = "debian" ]; then
        apt-get update
        if [ "$INSTALL_ALL" = "true" ] || [ "$INSTALL_CORE" = "true" ]; then
            log "Setting up Node.js and Nginx for web components..."
            curl -fsSL https://deb.nodesource.com/setup_20.x | bash - || error "Failed to set up Node.js repository"
            apt-get install -y systemd nginx nodejs || error "Failed to install Node.js, Nginx, or systemd"
        fi
        if [ "$INSTALL_ALL" = "true" ] || [ "$INSTALL_AGENT" = "true" ]; then
            log "Installing libcap2-bin for agent..."
            apt-get install -y libcap2-bin || error "Failed to install libcap2-bin"
        fi
        if [ "$INSTALL_ALL" = "true" ] || [ "$INSTALL_POLLER" = "true" ] || [ "$INSTALL_CORE" = "true" ]; then
            log "Ensuring systemd is installed..."
            apt-get install -y systemd || error "Failed to install systemd"
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
        if [ "$INSTALL_ALL" = "true" ] || [ "$INSTALL_CORE" = "true" ]; then
            log "Setting up Node.js and Nginx for web components..."
            $PKG_MANAGER module enable -y nodejs:20
            $PKG_MANAGER install -y systemd nginx nodejs
        fi
        if [ "$INSTALL_ALL" = "true" ] || [ "$INSTALL_AGENT" = "true" ]; then
            log "Installing libcap and related packages for agent..."
            $PKG_MANAGER install -y libcap systemd-devel gcc
        fi
        if [ "$INSTALL_ALL" = "true" ] || [ "$INSTALL_POLLER" = "true" ] || [ "$INSTALL_CORE" = "true" ]; then
            log "Ensuring systemd is installed..."
            $PKG_MANAGER install -y systemd
        fi
    fi
    success "Dependencies installed successfully!"
}

# Download a package
download_package() {
    local pkg_name="$1"
    local suffix="$2"
    # Use underscore instead of hyphen for Debian packages
    local file_name="${pkg_name}_${VERSION}${suffix}.${PKG_EXT}"
    local url="${RELEASE_URL}/${file_name}"
    local output="${TEMP_DIR}/${pkg_name}.${PKG_EXT}"
    log "Downloading ${COLOR_YELLOW}${pkg_name}${COLOR_RESET}..."
    curl -sSL -o "$output" "$url" || error "Failed to download ${pkg_name} from $url"
    validate_deb "$output"
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
        log "Installing packages: ${COLOR_YELLOW}${packages[*]}${COLOR_RESET}"
        if [ "$SYSTEM" = "debian" ]; then
            apt install -y $pkg_files || error "Failed to install packages"
        else
            $PKG_MANAGER install -y $pkg_files || error "Failed to install packages"
        fi
        success "Packages installed successfully!"
    fi
}

# Prompt for installation scenario (interactive mode only)
prompt_scenario() {
    if [ "$INTERACTIVE" = "true" ]; then
        header "Select Components to Install"
        echo -e "${COLOR_CYAN}Please choose the components you want to install (you can select multiple):${COLOR_RESET}"
        echo -e "${COLOR_WHITE}  1) All-in-One (all components)${COLOR_RESET}"
        echo -e "${COLOR_WHITE}  2) Core + Web UI (core, web, nats, kv, sync)${COLOR_RESET}"
        echo -e "${COLOR_WHITE}  3) Poller (poller)${COLOR_RESET}"
        echo -e "${COLOR_WHITE}  4) Agent (agent)${COLOR_RESET}"
        echo -e "${COLOR_CYAN}Enter choices (e.g., '1' or '2 3 4' for multiple):${COLOR_RESET} \c"
        read choices
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
        echo
    fi
}

# Check if a checker should be installed
should_install_checker() {
    local checker="$1"
    if [ "$INTERACTIVE" = "true" ]; then
        echo -e "${COLOR_CYAN}Install optional checker ${COLOR_YELLOW}${checker}${COLOR_CYAN}? (y/n) [n]:${COLOR_RESET} \c"
        read choice
        if [ "$choice" = "y" ] || [ "$choice" = "Y" ]; then
            echo "yes"
        else
            echo "no"
        fi
    else
        if echo "$CHECKERS" | grep -q -E "(^|,)$checker(,|$)"; then
            echo "yes"
        else
            echo "no"
        fi
    fi
}

# Update core.json with new admin password bcrypt hash
update_core_config() {
    if [ "$INSTALL_CORE" != "true" ]; then
        return
    fi

    header "Configuring Admin Password"
    local config_file="/etc/serviceradar/core.json"
    local password=""

    if [ "$INTERACTIVE" = "true" ]; then
        echo -e "${COLOR_CYAN}Enter new admin password (leave blank for random generation):${COLOR_RESET} \c"
        read -s password
        echo
        if [ -z "$password" ]; then
            password=$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 16)
            info "Generated random password: ${COLOR_YELLOW}${password}${COLOR_RESET}"
        fi
    else
        # Non-interactive mode: check for environment variable or generate random
        password="${SERVICERADAR_ADMIN_PASSWORD:-}"
        if [ -z "$password" ]; then
            password=$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 16)
            info "Generated random password: ${COLOR_YELLOW}${password}${COLOR_RESET}"
        fi
    fi

    # Generate bcrypt hash using serviceradar
    log "Generating bcrypt hash for admin password..."
    local bcrypt_hash
    bcrypt_hash=$(echo "$password" | serviceradar 2>/dev/null) || error "Failed to generate bcrypt hash using serviceradar"
    success "Bcrypt hash generated successfully!"

    # Update core.json using serviceradar (assuming we'll add this functionality)
    log "Updating ${config_file} with new admin password hash..."
    serviceradar update-config --file "$config_file" --admin-hash "$bcrypt_hash" || error "Failed to update ${config_file}"
    success "Configuration file updated successfully!"
}

# Main installation logic
main() {
    display_banner
    parse_args "$@"
    detect_system
    check_curl

    if [ "$INSTALL_ALL" = "false" ] && [ "$INSTALL_CORE" = "false" ] && [ "$INSTALL_POLLER" = "false" ] && [ "$INSTALL_AGENT" = "false" ]; then
        if [ "$INTERACTIVE" = "true" ]; then
            prompt_scenario
        else
            error "No installation scenario specified. Use --all, --core, --poller, or --agent."
        fi
    fi

    if [ "$INSTALL_ALL" = "true" ]; then
        INSTALL_CORE=true
        INSTALL_POLLER=true
        INSTALL_AGENT=true
    fi

    if [ "$INSTALL_CORE" = "false" ] && [ "$INSTALL_POLLER" = "false" ] && [ "$INSTALL_AGENT" = "false" ]; then
        error "No components selected to install."
    fi

    mkdir -p "$TEMP_DIR"
    install_dependencies

    core_packages=("serviceradar-core" "serviceradar-web" "serviceradar-nats" "serviceradar-kv" "serviceradar-sync" "serviceradar-cli")
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

    header "Installing Main Components"
    for pkg in "${packages_to_install[@]}"; do
        if [ "$SYSTEM" = "rhel" ]; then
            if [ "$pkg" = "serviceradar-core" ] || [ "$pkg" = "serviceradar-kv" ] || [ "$pkg" = "serviceradar-nats" ] || [ "$pkg" = "serviceradar-agent" ] || [ "$pkg" = "serviceradar-poller" ] || [ "$pkg" = "serviceradar-sync" ]; then
                download_package "$pkg" "-1.el9.x86_64"
            else
                download_package "$pkg" "-1.el9.x86_64"
            fi
        else
            download_package "$pkg" ""
        fi
    done
    install_packages "${packages_to_install[@]}"

    header "Installing Optional Checkers"
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
                download_package "$checker" ""
            fi
            checker_packages+=("$checker")
        fi
    done

    if [ ${#checker_packages[@]} -eq 0 ]; then
        log "No optional checkers selected."
    else
        install_packages "${checker_packages[@]}"
    fi

    # Update core.json with new admin password
    update_core_config

    header "Cleaning Up"
    log "Removing temporary files..."
    rm -rf "$TEMP_DIR"
    success "Cleanup completed!"

    header "Installation Complete"
    success "[ServiceRadar] installation completed successfully!"
    if [ "$INSTALL_CORE" = "true" ]; then
        info "Web UI: ${COLOR_YELLOW}http://your-server-ip/${COLOR_RESET}"
        info "Core API: ${COLOR_YELLOW}http://your-server-ip:8090/${COLOR_RESET}"
    fi
    info "Check service status: ${COLOR_YELLOW}systemctl status serviceradar-*${COLOR_RESET}"
    info "View logs: ${COLOR_YELLOW}journalctl -u serviceradar-<component>.service${COLOR_RESET}"
    echo
}

main "$@"
