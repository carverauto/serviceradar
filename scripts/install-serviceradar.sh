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
VERSION="1.0.33"
RELEASE_TAG="1.0.33-pre7" # Separate tag for GitHub releases
RELEASE_URL="https://github.com/carverauto/serviceradar/releases/download/${RELEASE_TAG}"
TEMP_DIR="/tmp/serviceradar-install"
POLLER_CONFIG="/etc/serviceradar/poller.json"

# Default settings
INTERACTIVE=true
CHECKERS=""
INSTALL_ALL=false
INSTALL_CORE=false
INSTALL_POLLER=false
INSTALL_AGENT=false
UPDATE_POLLER_CONFIG=true
INSTALLED_CHECKERS=()

# Input timeout in seconds - reduce for faster installs
PROMPT_TIMEOUT=10

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

# Clean timely read function with defaults
read_with_timeout() {
    local prompt="$1"
    local default="$2"
    local var_name="$3"
    local timeout="$4"

    # Ensure timeout has a value
    timeout=${timeout:-$PROMPT_TIMEOUT}

    # If we're not interactive, use the default immediately
    if [ "$INTERACTIVE" != "true" ]; then
        eval "$var_name=$default"
        return
    }

    # Print prompt
    echo -e "$prompt \c"

    # Try to read with timeout
    read -t "$timeout" response || {
        echo
        log "Input timed out, using default: $default"
        response="$default"
    }

    # Set the variable to the response or default
    eval "$var_name=\"$response\""
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

# Validate downloaded package file
validate_package() {
    local file="$1"
    if [ ! -f "$file" ]; then
        error "Downloaded file $file does not exist"
    fi

    # Check if the file is a valid package
    if [ "$SYSTEM" = "debian" ]; then
        # Check if the file is a valid .deb package
        if ! dpkg-deb -W "$file" >/dev/null 2>&1; then
            error "Downloaded file $file is not a valid .deb package"
        fi
    else
        # For RPM, just check if file exists and has content
        if [ ! -s "$file" ]; then
            error "Downloaded file $file is empty or corrupt"
        fi
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
            --no-update-poller-config)
                UPDATE_POLLER_CONFIG=false
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
    if [ "$SYSTEM" = "debian" ]; then
        local file_name="${pkg_name}_${VERSION}${suffix}.${PKG_EXT}"
    else
        local file_name="${pkg_name}-${VERSION}${suffix}.${PKG_EXT}"
    fi
    local url="${RELEASE_URL}/${file_name}"
    local output="${TEMP_DIR}/${pkg_name}.${PKG_EXT}"

    log "Downloading ${COLOR_YELLOW}${pkg_name}${COLOR_RESET}..."
    log "URL: ${COLOR_YELLOW}${url}${COLOR_RESET}"

    # Add timeout and retry parameters for more robust downloading
    if ! curl -sSL --connect-timeout 30 --max-time 300 --retry 3 --retry-delay 2 -o "$output" "$url"; then
        error "Failed to download ${pkg_name} from $url"
    fi

    # Check if file exists and has content
    if [ ! -f "$output" ] || [ ! -s "$output" ]; then
        error "Downloaded file for ${pkg_name} is empty or does not exist"
    fi

    validate_package "$output"
}

# Install packages
install_packages() {
    local packages=("$@")
    local pkg_files=""
    for pkg in "${packages[@]}"; do
        if [ -f "${TEMP_DIR}/${pkg}.${PKG_EXT}" ]; then
            pkg_files="$pkg_files ${TEMP_DIR}/${pkg}.${PKG_EXT}"
            log "Found package file: ${TEMP_DIR}/${pkg}.${PKG_EXT}"
        else
            log "Warning: Package file not found: ${TEMP_DIR}/${pkg}.${PKG_EXT}"
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
    else
        log "No package files found to install"
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

        local choices=""
        read_with_timeout "${COLOR_CYAN}Enter choices (e.g., '1' or '2 3 4' for multiple):${COLOR_RESET}" "1" choices $PROMPT_TIMEOUT

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

        # Ask about poller config updates if poller is being installed
        if [ "$INSTALL_POLLER" = "true" ] || [ "$INSTALL_ALL" = "true" ]; then
            local update_choice=""
            read_with_timeout "${COLOR_CYAN}Would you like to automatically update the poller configuration after installing checkers? (y/n) [y]:${COLOR_RESET}" "y" update_choice $PROMPT_TIMEOUT

            if [ "$update_choice" = "n" ] || [ "$update_choice" = "N" ]; then
                UPDATE_POLLER_CONFIG=false
                log "Poller configuration updates disabled"
            else
                log "Poller configuration will be updated automatically"
            fi
        else
            # If poller is not installed, we won't update the config
            UPDATE_POLLER_CONFIG=false
        fi
    fi
}

# Check if a checker should be installed (uses predefined answers for common checkers)
should_install_checker() {
    local checker="$1"
    local default_yes_checkers="serviceradar-sysmon-checker serviceradar-snmp-checker"

    # Auto-yes for certain checkers to speed up the process
    if echo "$default_yes_checkers" | grep -q -w "$checker"; then
        default_answer="y"
    else
        default_answer="n"
    fi

    if [ "$INTERACTIVE" = "true" ]; then
        local choice=""
        read_with_timeout "${COLOR_CYAN}Install optional checker ${COLOR_YELLOW}${checker}${COLOR_CYAN}? (y/n) [$default_answer]:${COLOR_RESET}" "$default_answer" choice $PROMPT_TIMEOUT

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

# Update the poller configuration to enable a specific checker
update_poller_config_for_checker() {
    local checker_type="$1"

    if [ "$UPDATE_POLLER_CONFIG" != "true" ]; then
        return
    fi

    if [ ! -f "$POLLER_CONFIG" ]; then
        log "Poller configuration file not found at $POLLER_CONFIG, skipping update"
        return
    fi

    header "Updating Poller Configuration"
    log "Enabling ${COLOR_YELLOW}${checker_type}${COLOR_RESET} in poller configuration..."

    # Use the CLI tool to update the poller configuration
    if /usr/local/bin/serviceradar update-poller --file="$POLLER_CONFIG" --type="$checker_type"; then
        success "Successfully updated poller configuration for $checker_type"
    else
        log "Failed to update poller configuration for $checker_type"
    fi
}

# Update core.json with new admin password bcrypt hash
update_core_config() {
    if [ "$INSTALL_CORE" != "true" ] && [ "$INSTALL_ALL" != "true" ]; then
        return
    fi

    header "Configuring Admin Password"
    local config_file="/etc/serviceradar/core.json"
    local password=""

    if [ "$INTERACTIVE" = "true" ]; then
        echo -e "${COLOR_CYAN}Enter new admin password (leave blank for random generation):${COLOR_RESET} \c"
        read -s -t $PROMPT_TIMEOUT password || {
            echo
            log "No input received, generating random password"
            password=""
        }
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
    bcrypt_hash=$(echo "$password" | /usr/local/bin/serviceradar 2>/dev/null) || error "Failed to generate bcrypt hash using serviceradar"
    log "Generated bcrypt hash"
    success "Bcrypt hash generated successfully!"

    # Update core.json using serviceradar CLI
    log "Updating ${config_file} with new admin password hash..."
    /usr/local/bin/serviceradar update-config --file "$config_file" --admin-hash "$bcrypt_hash" || error "Failed to update ${config_file}"
    systemctl restart serviceradar-core
    success "Configuration file updated successfully!"
}

# Enable all standard checkers in poller config
enable_all_checkers() {
    if [ "$UPDATE_POLLER_CONFIG" != "true" ]; then
        return
    fi

    if [ ! -f "$POLLER_CONFIG" ]; then
        log "Poller configuration file not found at $POLLER_CONFIG"
        return
    fi

    header "Enabling All Checkers in Poller Configuration"
    log "Configuring poller to use all installed checkers..."

    # Enable all checkers using the CLI tool
    if /usr/local/bin/serviceradar update-poller --file="$POLLER_CONFIG" --enable-all; then
        success "Successfully enabled all checkers in poller configuration"
    else
        log "Failed to enable all checkers in poller configuration"
    fi
}

# Main installation logic
main() {
    display_banner

    # Check if running in a terminal with input support
    if ! [ -t 0 ]; then
        # No TTY, force non-interactive mode
        INTERACTIVE=false
        log "No TTY detected, forcing non-interactive mode"
    fi

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

    # Fast path for checker installation
    header "Installing Optional Checkers"
    checkers=("serviceradar-rperf" "serviceradar-rperf-checker" "serviceradar-snmp-checker" "serviceradar-dusk-checker" "serviceradar-sysmon-checker")
    checker_packages=()

    # First, determine which checkers to install (collect all answers upfront)
    declare -A checker_decisions
    for checker in "${checkers[@]}"; do
        log "Checking if ${COLOR_YELLOW}${checker}${COLOR_RESET} should be installed..."
        available="yes"

        # Check if checker is available for this configuration
        if [ "$checker" = "serviceradar-dusk-checker" ] && [ "$SYSTEM" != "debian" ]; then
            available="no"
        fi
        if [ "$INSTALL_CORE" = "false" ] && [ "$checker" = "serviceradar-dusk-checker" ]; then
            available="no"
        fi
        if [ "$INSTALL_POLLER" = "false" ] && [ "$INSTALL_AGENT" = "false" ] && { [ "$checker" = "serviceradar-rperf" ] || [ "$checker" = "serviceradar-rperf-checker" ] || [ "$checker" = "serviceradar-snmp-checker" ]; }; then
            available="no"
        fi

        if [ "$available" = "yes" ]; then
            # Get user decision or use command line flags
            if [ "$(should_install_checker "$checker")" = "yes" ]; then
                checker_decisions[$checker]="yes"
            else
                checker_decisions[$checker]="no"
                log "Skipping ${COLOR_YELLOW}${checker}${COLOR_RESET} installation."
            fi
        else
            checker_decisions[$checker]="no"
            log "Skipping ${COLOR_YELLOW}${checker}${COLOR_RESET} installation (not available for current config)."
        fi
    done

    # Now download and prepare packages that need to be installed
    for checker in "${checkers[@]}"; do
        if [ "${checker_decisions[$checker]}" = "yes" ]; then
            log "Preparing ${COLOR_YELLOW}${checker}${COLOR_RESET} for installation..."
            if [ "$checker" = "serviceradar-rperf" ] || [ "$checker" = "serviceradar-rperf-checker" ]; then
                download_package "$checker" "-1.el9.x86_64"
            else
                download_package "$checker" ""
            fi
            checker_packages+=("$checker")

            # Save checker type for later poller config update
            # Strip "serviceradar-" prefix and "-checker" suffix
            CHECKER_TYPE=$(echo "$checker" | sed -E 's/^serviceradar-//;s/-checker$//')
            INSTALLED_CHECKERS+=("$CHECKER_TYPE")
        fi
    done

    # Install all selected checkers in a single batch
    if [ ${#checker_packages[@]} -eq 0 ]; then
        log "No optional checkers selected."
    else
        log "Installing optional checkers: ${COLOR_YELLOW}${checker_packages[*]}${COLOR_RESET}"
        install_packages "${checker_packages[@]}"

        # Update poller config for each installed checker
        if [ "$UPDATE_POLLER_CONFIG" = "true" ]; then
            for checker_type in "${INSTALLED_CHECKERS[@]}"; do
                update_poller_config_for_checker "$checker_type"
            done
        fi
    fi

    # Update core.json with new admin password
    update_core_config

    # If all checkers were installed and we're updating poller config, use enable-all
    if [ ${#INSTALLED_CHECKERS[@]} -ge 3 ] && [ "$UPDATE_POLLER_CONFIG" = "true" ]; then
        enable_all_checkers
    fi

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

    if [ "$INSTALL_POLLER" = "true" ] && [ ${#INSTALLED_CHECKERS[@]} -gt 0 ] && [ "$UPDATE_POLLER_CONFIG" = "false" ]; then
        info "${COLOR_YELLOW}Note:${COLOR_RESET} You installed checkers but disabled automatic poller configuration."
        info "To manually enable the checkers in your poller configuration, run:"
        for checker_type in "${INSTALLED_CHECKERS[@]}"; do
            info "  ${COLOR_YELLOW}serviceradar update-poller --file=${POLLER_CONFIG} --type=${checker_type}${COLOR_RESET}"
        done
    fi

    info "Check service status: ${COLOR_YELLOW}systemctl status serviceradar-*${COLOR_RESET}"
    info "View logs: ${COLOR_YELLOW}journalctl -u serviceradar-<component>.service${COLOR_RESET}"
    echo
}

main "$@"