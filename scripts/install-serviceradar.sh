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
# Installs ServiceRadar components with integrated mTLS setup for Proton database

set -e

# Configuration
VERSION="1.0.51"
RELEASE_TAG="1.0.51"
RELEASE_URL="https://github.com/carverauto/serviceradar/releases/download/${RELEASE_TAG}"
TEMP_DIR="/tmp/serviceradar-install"
POLLER_CONFIG="/etc/serviceradar/poller.json"
PROTON_CERT_DIR="/etc/proton-server"
SR_CERT_DIR="/etc/serviceradar/certs"
DAYS_VALID=3650

# Default settings
INTERACTIVE=true
CHECKERS=""
INSTALL_ALL=false
INSTALL_CORE=false
INSTALL_POLLER=false
INSTALL_AGENT=false
UPDATE_POLLER_CONFIG=true
SKIP_CHECKER_PROMPTS=false
INSTALLED_CHECKERS=()
SERVICE_IPS=""
ADD_IPS=false

# Input timeout in seconds
PROMPT_TIMEOUT=15

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

    timeout=${timeout:-$PROMPT_TIMEOUT}

    if [ "$INTERACTIVE" != "true" ]; then
        eval "$var_name=$default"
        return
    fi

    echo -e "$prompt \c"
    read -t "$timeout" response || {
        echo
        log "Input timed out, using default: $default"
        response="$default"
    }
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

    if [ "$SYSTEM" = "debian" ]; then
        if ! dpkg-deb -W "$file" > /tmp/dpkg-deb.log 2>&1; then
            error "Downloaded file $file is not a valid .deb package. Error: $(cat /tmp/dpkg-deb.log)"
        fi
    else
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
            --skip-checker-prompts)
                SKIP_CHECKER_PROMPTS=true
                shift
                ;;
            --ip=*)
                SERVICE_IPS=$(echo "$1" | cut -d'=' -f2)
                shift
                ;;
            --add-ips)
                ADD_IPS=true
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
    log "Preparing system for ServiceRadar installation..."
    if [ "$SYSTEM" = "debian" ]; then
        apt-get update
        if [ "$INSTALL_ALL" = "true" ] || [ "$INSTALL_CORE" = "true" ]; then
            log "Setting up Node.js and Nginx for web components..."
            curl -fsSL https://deb.nodesource.com/setup_20.x | bash - || error "Failed to set up Node.js repository"
            apt-get install -y systemd nginx nodejs jq || error "Failed to install Node.js, Nginx, systemd, or jq"
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
            $PKG_MANAGER install -y systemd nginx nodejs jq || error "Failed to install dependencies"
        fi
        if [ "$INSTALL_ALL" = "true" ] || [ "$INSTALL_AGENT" = "true" ]; then
            log "Installing libcap and related packages for agent..."
            $PKG_MANAGER install -y libcap systemd-devel gcc || error "Failed to install libcap or related packages"
        fi
        if [ "$INSTALL_ALL" = "true" ] || [ "$INSTALL_POLLER" = "true" ] || [ "$INSTALL_CORE" = "true" ]; then
            log "Ensuring systemd is installed..."
            $PKG_MANAGER install -y systemd || error "Failed to install systemd"
        fi
    fi
    success "Dependencies installed successfully!"
}

# Download a package
download_package() {
    local pkg_name="$1"
    local suffix="$2"
    local deb_version="${VERSION/-pre2/}"  # Strip -pre2 for Debian package filenames
    local file_name
    if [ "$SYSTEM" = "debian" ]; then
        file_name="${pkg_name}_${deb_version}${suffix}.${PKG_EXT}"
    else
        file_name="${pkg_name}-${VERSION}${suffix}.${PKG_EXT}"
    fi
    local url="${RELEASE_URL}/${file_name}"
    local output="${TEMP_DIR}/${pkg_name}.${PKG_EXT}"

    log "Downloading ${COLOR_YELLOW}${pkg_name}${COLOR_RESET}..."
    log "DEBUG: Constructed filename: ${COLOR_YELLOW}${file_name}${COLOR_RESET}"
    log "DEBUG: Download URL: ${COLOR_YELLOW}${url}${COLOR_RESET}"
    log "DEBUG: curl command: curl -sSL --connect-timeout 30 --max-time 300 --retry 3 --retry-delay 2 -o \"$output\" \"$url\""

    if ! curl -sSL --connect-timeout 30 --max-time 300 --retry 3 --retry-delay 2 -o "$output" "$url"; then
        error "Failed to download ${pkg_name} from $url"
    fi

    if [ ! -f "$output" ] || [ ! -s "$output" ]; then
        error "Downloaded file for ${pkg_name} is empty or does not exist"
    fi

    log "DEBUG: Downloaded file size: $(stat -c %s "$output") bytes"
    log "DEBUG: File contents preview: $(head -c 20 "$output" | tr -dc '[:print:]')"

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

install_single_package() {
    local pkg="$1"
    local suffix="$2"
    local deb_version="${VERSION/-pre2/}"  # Strip -pre2 for Debian package filenames
    local file_name
    if [ "$SYSTEM" = "debian" ]; then
        file_name="${pkg}_${deb_version}${suffix}.${PKG_EXT}"
    else
        file_name="${pkg}-${VERSION}${suffix}.${PKG_EXT}"
    fi
    local url="${RELEASE_URL}/${file_name}"
    local output="${TEMP_DIR}/${pkg}.${PKG_EXT}"

    log "Downloading ${COLOR_YELLOW}${pkg}${COLOR_RESET}..."
    log "DEBUG: Constructed filename: ${COLOR_YELLOW}${file_name}${COLOR_RESET}"
    log "DEBUG: Download URL: ${COLOR_YELLOW}${url}${COLOR_RESET}"
    log "DEBUG: curl command: curl -sSL --connect-timeout 30 --max-time 300 --retry 3 --retry-delay 2 -o \"$output\" \"$url\""

    if ! curl -sSL --connect-timeout 30 --max-time 300 --retry 3 --retry-delay 2 -o "$output" "$url"; then
        error "Failed to download ${pkg} from $url"
    fi

    log "DEBUG: Downloaded file size: $(stat -c %s "$output") bytes"
    log "DEBUG: File contents preview: $(head -c 20 "$output" | tr -dc '[:print:]')"

    validate_package "$output"

    log "Installing ${COLOR_YELLOW}${pkg}${COLOR_RESET}..."
    if [ "$SYSTEM" = "debian" ]; then
        apt install -y "$output" || error "Failed to install ${pkg}"
    else
        $PKG_MANAGER install -y "$output" || error "Failed to install ${pkg}"
    fi
    success "${pkg} installed successfully!"
}

# Get local IP address
get_local_ip() {
    local_ip=$(ip -4 addr show scope global 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -n 1)
    if [ -z "$local_ip" ]; then
        local_ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    fi
    if [ -z "$local_ip" ]; then
        local_ip="127.0.0.1"
    fi
    echo "$local_ip"
}

# Validate IPs
validate_ips() {
    local ips=$1
    IFS=',' read -ra IP_ARRAY <<< "$ips"

    for ip in "${IP_ARRAY[@]}"; do
        if ! [[ $ip =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            error "Invalid IP address format: $ip"
        fi
    done
}

# Create certificate directories
create_cert_dirs() {
    log "Creating certificate directories..."
    mkdir -p "$SR_CERT_DIR"
    mkdir -p "$PROTON_CERT_DIR"
    mkdir -p "/tmp/serviceradar-tls"
    chmod 750 "$SR_CERT_DIR" "$PROTON_CERT_DIR"
}

# Setup mTLS certificates using serviceradar CLI
setup_mtls_certificates() {
    log "Checking for existing certificates..."

    # Determine components to generate certificates for based on shared config
    local components="core,proton"

    if [ "$INSTALL_ALL" = "true" ] || [ "$INSTALL_CORE" = "true" ]; then
        components="$components,web,nats,kv,sync"
    fi

    # If NATS Edge mode is selected, we need a separate cert for the leaf node connection.
    # The serviceradar CLI should generate this with a CN of 'serviceradar-edge'.
    if [ "$NATS_MODE" = "2" ]; then
        log "Adding nats-leaf to certificate generation for Edge mode."
        components="$components,nats-leaf"
    fi

    if [ "$INSTALL_ALL" = "true" ] || [ "$INSTALL_POLLER" = "true" ]; then
        components="$components,poller"
    fi
    if [ "$INSTALL_ALL" = "true" ] || [ "$INSTALL_AGENT" = "true" ]; then
        components="$components,agent"
    fi
    for checker in "${INSTALLED_CHECKERS[@]}"; do
        case "$checker" in
            sysmon) components="$components,sysmon" ;;
            snmp) components="$components,snmp" ;;
            rperf-checker) components="$components,rperf-checker" ;;
            dusk) components="$components,dusk-checker" ;;
        esac
    done

    # Create certificate directories
    create_cert_dirs

    # Generate certificates for all components
    local cli_args="--cert-dir $SR_CERT_DIR --proton-dir $PROTON_CERT_DIR"
    if [ "$INTERACTIVE" = "false" ]; then
        cli_args="$cli_args --non-interactive"
    fi
    if [ -n "$SERVICE_IPS" ]; then
        cli_args="$cli_args --ip $SERVICE_IPS"
    fi
    if [ "$ADD_IPS" = "true" ]; then
        cli_args="$cli_args --add-ips"
    fi
    cli_args="$cli_args --component $components"

    log "Generating mTLS certificates for components: $components"
    log "Running: /usr/local/bin/serviceradar generate-tls $cli_args"
    if ! /usr/local/bin/serviceradar generate-tls $cli_args; then
        error "Failed to generate mTLS certificates using serviceradar CLI"
    fi

    # Additional verification and file permissions/ownership
    if [ -f "$SR_CERT_DIR/root.pem" ] && [ ! -f "$PROTON_CERT_DIR/root.pem" ]; then
        log "Copying root CA certificate to Proton directory..."
        cp "$SR_CERT_DIR/root.pem" "$PROTON_CERT_DIR/root.pem" || error "Failed to copy root.pem"
        chmod 644 "$PROTON_CERT_DIR/root.pem" || error "Failed to set permissions on root.pem"
    fi

    if [ -f "$SR_CERT_DIR/core.pem" ] && [ ! -f "$PROTON_CERT_DIR/core.pem" ]; then
        log "Copying core certificate to Proton directory..."
        cp "$SR_CERT_DIR/core.pem" "$PROTON_CERT_DIR/core.pem" || error "Failed to copy core.pem"
        cp "$SR_CERT_DIR/core-key.pem" "$PROTON_CERT_DIR/core-key.pem" || error "Failed to copy core-key.pem"
        chmod 644 "$PROTON_CERT_DIR/core.pem" || error "Failed to set permissions on core.pem"
        chmod 600 "$PROTON_CERT_DIR/core-key.pem" || error "Failed to set permissions on core-key.pem"
    fi

    # Set proper ownership
    chown serviceradar:serviceradar "$SR_CERT_DIR"/*.pem 2>/dev/null || true
    chown serviceradar:serviceradar "$SR_CERT_DIR"/*-key.pem 2>/dev/null || true
    chown proton:proton "$PROTON_CERT_DIR"/*.pem 2>/dev/null || true
    chown proton:proton "$PROTON_CERT_DIR"/*-key.pem 2>/dev/null || true
    chmod 644 "$SR_CERT_DIR"/*.pem 2>/dev/null || true
    chmod 600 "$SR_CERT_DIR"/*-key.pem 2>/dev/null || true
    chmod 644 "$PROTON_CERT_DIR"/*.pem 2>/dev/null || true
    chmod 600 "$PROTON_CERT_DIR"/*-key.pem 2>/dev/null || true

    success "mTLS certificates generated and installed successfully"
}

# Show post-installation instructions for mTLS
show_post_install_info() {
    local ips
    IFS=',' read -ra IPS <<< "$SERVICE_IPS"
    local first_ip="${IPS[0]}"

    echo
    echo -e "${COLOR_BOLD}TLS Certificate Setup Complete${COLOR_RESET}"
    echo
    echo -e "Certificates have been installed with the following IPs:"
    for ip in "${IPS[@]}"; do
        echo -e "  - ${COLOR_CYAN}$ip${COLOR_RESET}"
    done
    echo
    echo -e "${COLOR_BOLD}Certificate locations:${COLOR_RESET}"

    local components=()
    if [ "$INSTALL_ALL" = "true" ] || [ "$INSTALL_CORE" = "true" ]; then
        components+=("core" "proton" "nats" "kv" "sync" "web")
    fi
    if [ "$INSTALL_ALL" = "true" ] || [ "$INSTALL_POLLER" = "true" ]; then
        components+=("poller")
    fi
    if [ "$INSTALL_ALL" = "true" ] || [ "$INSTALL_AGENT" = "true" ]; then
        components+=("agent")
    fi
    for checker in "${INSTALLED_CHECKERS[@]}"; do
        case "$checker" in
            sysmon) components+=("sysmon") ;;
            snmp) components+=("snmp") ;;
            rperf-checker) components+=("rperf-checker") ;;
            dusk) components+=("dusk-checker") ;;
        esac
    done
    components=($(echo "${components[@]}" | tr ' ' '\n' | sort -u | tr '\n' ' '))

    for component in "${components[@]}"; do
        local cert_name="$component"
        local cert_dir="$SR_CERT_DIR"
        case "$component" in
            proton)
                cert_name="core"
                cert_dir="$PROTON_CERT_DIR"
                ;;
            nats)
                cert_name="nats-server"
                ;;
            dusk-checker)
                cert_name="checkers"
                ;;
            sysmon)
                cert_name="sysmon"
                ;;
            snmp)
                cert_name="snmp"
                ;;
            rperf-checker)
                cert_name="rperf-checker"
                ;;
            rperf)
                continue
                ;;
        esac
        # Only show certificates that exist
        if [ -f "$cert_dir/$cert_name.pem" ] && [ -f "$cert_dir/$cert_name-key.pem" ]; then
            echo -e "  - $component: ${COLOR_CYAN}$cert_dir/$cert_name.pem, $cert_dir/$cert_name-key.pem${COLOR_RESET}"
        else
            log "DEBUG: Skipping $component in post-install info: Certificate files $cert_dir/$cert_name.pem or $cert_dir/$cert_name-key.pem not found"
        fi
    done
    echo
    echo -e "${COLOR_BOLD}Next steps:${COLOR_RESET}"
    echo "1. If you need to add more IPs later, run:"
    echo "   $0 --add-ips --ip new.ip.address"
    echo
    echo "2. To restart services with new certificates:"
    echo "   systemctl restart serviceradar-*"
    echo
}

# Prompt for installation scenario
prompt_scenario() {
    if [ "$INTERACTIVE" = "true" ]; then
        header "Select Components to Install"
        echo -e "${COLOR_CYAN}Please choose the components you want to install (you can select multiple):${COLOR_RESET}"
        echo -e "${COLOR_WHITE}  1) All-in-One (all components)${COLOR_RESET}"
        echo -e "${COLOR_WHITE}  2) Core + Web UI (core+proton, web, nats, kv, sync)${COLOR_RESET}"
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

        if [ "$INSTALL_POLLER" = "true" ] || [ "$INSTALL_ALL" = "true" ]; then
            local update_choice=""
            read_with_timeout "${COLOR_CYAN}Would you like to automatically update the poller configuration after installing checkers? (y/n) [y]:${COLOR_RESET}" "y" update_choice $PROMPT_TIMEOUT

            if [ "$update_choice" = "n" ] || [ "$update_choice" = "N" ]; then
                UPDATE_POLLER_CONFIG=false
                log "Poller configuration updates disabled"
            else
                log "Poller configuration will be updated automatically"
            fi

            local skip_choice=""
            read_with_timeout "${COLOR_CYAN}Skip individual checker prompts and use recommended defaults? (y/n) [n]:${COLOR_RESET}" "n" skip_choice $PROMPT_TIMEOUT

            if [ "$skip_choice" = "y" ] || [ "$skip_choice" = "Y" ]; then
                SKIP_CHECKER_PROMPTS=true
                log "Using recommended checker defaults (sysmon and snmp will be installed)"
            fi
        else
            UPDATE_POLLER_CONFIG=false
        fi

        # Prompt for IP addresses
        local ip_choice=""
        read_with_timeout "${COLOR_CYAN}Enter IP addresses for mTLS certificates (comma-separated, leave blank for auto-detect):${COLOR_RESET}" "" ip_choice $PROMPT_TIMEOUT
        if [ -n "$ip_choice" ]; then
            SERVICE_IPS="$ip_choice"
            validate_ips "$SERVICE_IPS"
        fi
    fi
}

# Update the poller configuration
update_poller_config_for_checker() {
    local checker_type="$1"

    if [ "$UPDATE_POLLER_CONFIG" != "true" ]; then
        return
    fi

    if [ ! -f "$POLLER_CONFIG" ]; then
        log "Poller configuration file not found at $POLLER_CONFIG, skipping update"
        return
    fi

    log "Enabling ${COLOR_YELLOW}${checker_type}${COLOR_RESET} in poller configuration..."

    if /usr/local/bin/serviceradar update-poller --file="$POLLER_CONFIG" --type="$checker_type"; then
        success "Successfully updated poller configuration for $checker_type"
    else
        log "Failed to update poller configuration for $checker_type"
    fi
}

# Enable all standard checkers
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

    if /usr/local/bin/serviceradar update-poller --file="$POLLER_CONFIG" --enable-all; then
        success "Successfully enabled all checkers in poller configuration"
    else
        log "Failed to enable all checkers in poller configuration"
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
        password="${SERVICERADAR_ADMIN_PASSWORD:-}"
        if [ -z "$password" ]; then
            password=$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 16)
            info "Generated random password: ${COLOR_YELLOW}${password}${COLOR_RESET}"
        fi
    fi

    log "Generating bcrypt hash for admin password..."
    local bcrypt_hash
    bcrypt_hash=$(echo "$password" | /usr/local/bin/serviceradar 2>/dev/null) || error "Failed to generate bcrypt hash using serviceradar"
    log "Generated bcrypt hash"
    success "Bcrypt hash generated successfully!"

    log "Updating ${config_file} with new admin password hash..."
    /usr/local/bin/serviceradar update-config --file "$config_file" --admin-hash "$bcrypt_hash" || error "Failed to update ${config_file}"
    systemctl restart serviceradar-core
    success "Configuration file updated successfully!"
}

# Install optional checkers
install_optional_checkers() {
    header "Installing Optional Checkers"

    local INSTALL_SYSMON=false
    local INSTALL_SNMP=false
    local INSTALL_RPERF=false
    local INSTALL_RPERF_CHECKER=false
    local INSTALL_DUSK=false

    if [ "$SKIP_CHECKER_PROMPTS" = "true" ] || [ "$INTERACTIVE" != "true" ]; then
        INSTALL_SYSMON=true
        INSTALL_SNMP=true

        if [ -n "$CHECKERS" ]; then
            echo "$CHECKERS" | grep -q "sysmon" && INSTALL_SYSMON=true || INSTALL_SYSMON=false
            echo "$CHECKERS" | grep -q "snmp" && INSTALL_SNMP=true || INSTALL_SNMP=false
            echo "$CHECKERS" | grep -q "rperf" && INSTALL_RPERF=true
            echo "$CHECKERS" | grep -q "rperf-checker" && INSTALL_RPERF_CHECKER=true
            echo "$CHECKERS" | grep -q "dusk" && INSTALL_DUSK=true
        fi

        log "Using predefined checker selection (skipping prompts)"
    else
        echo
        echo -e "${COLOR_CYAN}${COLOR_BOLD}Select optional checkers to install:${COLOR_RESET}"
        echo

        echo -ne "${COLOR_CYAN}Install ${COLOR_YELLOW}System Monitor (sysmon)${COLOR_CYAN}? (y/n) [y]: ${COLOR_RESET}"
        read -t $PROMPT_TIMEOUT sysmon_choice || { echo; log "No input received, defaulting to yes"; sysmon_choice="y"; }
        [ "$sysmon_choice" = "n" ] || [ "$sysmon_choice" = "N" ] || INSTALL_SYSMON=true
        echo

        echo -ne "${COLOR_CYAN}Install ${COLOR_YELLOW}SNMP Network Monitor (snmp)${COLOR_CYAN}? (y/n) [y]: ${COLOR_RESET}"
        read -t $PROMPT_TIMEOUT snmp_choice || { echo; log "No input received, defaulting to yes"; snmp_choice="y"; }
        [ "$snmp_choice" = "n" ] || [ "$snmp_choice" = "N" ] || INSTALL_SNMP=true
        echo

        echo -ne "${COLOR_CYAN}Install ${COLOR_YELLOW}Performance Testing Server (rperf)${COLOR_CYAN}? (y/n) [n]: ${COLOR_RESET}"
        read -t $PROMPT_TIMEOUT rperf_choice || { echo; log "No input received, defaulting to no"; rperf_choice="n"; }
        [ "$rperf_choice" = "y" ] || [ "$rperf_choice" = "Y" ] && INSTALL_RPERF=true
        echo

        echo -ne "${COLOR_CYAN}Install ${COLOR_YELLOW}Network Performance Checker (rperf-checker)${COLOR_CYAN}? (y/n) [n]: ${COLOR_RESET}"
        read -t $PROMPT_TIMEOUT rperf_checker_choice || { echo; log "No input received, defaulting to no"; rperf_checker_choice="n"; }
        [ "$rperf_checker_choice" = "y" ] || [ "$rperf_checker_choice" = "Y" ] && INSTALL_RPERF_CHECKER=true
        echo

        echo -ne "${COLOR_CYAN}Install ${COLOR_YELLOW}Dusk Node monitoring Checker (crypto)${COLOR_CYAN}? (y/n) [n]: ${COLOR_RESET}"
        read -t $PROMPT_TIMEOUT dusk_choice || { echo; log "No input received, defaulting to no"; dusk_choice="n"; }
        [ "$dusk_choice" = "y" ] || [ "$dusk_choice" = "Y" ] && INSTALL_DUSK=true
        echo
    fi

    echo
    log "Installing these optional checkers:"
    local checker_count=0

    if [ "$INSTALL_SYSMON" = "true" ]; then
        log "  - System Monitor (sysmon)"
        checker_count=$((checker_count + 1))
    fi

    if [ "$INSTALL_SNMP" = "true" ]; then
        log "  - SNMP Network Monitor (snmp)"
        checker_count=$((checker_count + 1))
    fi

    if [ "$INSTALL_RPERF" = "true" ]; then
        log "  - Performance Testing Server (rperf)"
        checker_count=$((checker_count + 1))
    fi

    if [ "$INSTALL_RPERF_CHECKER" = "true" ]; then
        log "  - Network Performance Checker (rperf-checker)"
        checker_count=$((checker_count + 1))
    fi

    if [ "$INSTALL_DUSK" = "true" ]; then
        log "  - Time-based Event Checker (dusk)"
        checker_count=$((checker_count + 1))
    fi

    if [ $checker_count -eq 0 ]; then
        log "No optional checkers selected."
        return
    fi

    echo

    checker_packages=()
    INSTALLED_CHECKERS=()

    if [ "$INSTALL_SYSMON" = "true" ]; then
        checker_packages+=("serviceradar-sysmon-checker")
        INSTALLED_CHECKERS+=("sysmon")
    fi

    if [ "$INSTALL_SNMP" = "true" ]; then
        checker_packages+=("serviceradar-snmp-checker")
        INSTALLED_CHECKERS+=("snmp")
    fi

    if [ "$INSTALL_RPERF" = "true" ]; then
        checker_packages+=("serviceradar-rperf")
        INSTALLED_CHECKERS+=("rperf")
    fi

    if [ "$INSTALL_RPERF_CHECKER" = "true" ]; then
        checker_packages+=("serviceradar-rperf-checker")
        INSTALLED_CHECKERS+=("rperf-checker")
    fi

    if [ "$INSTALL_DUSK" = "true" ]; then
        checker_packages+=("serviceradar-dusk-checker")
        INSTALLED_CHECKERS+=("dusk")
    fi

    for pkg in "${checker_packages[@]}"; do
        if [ "$SYSTEM" = "rhel" ] && { [ "$pkg" = "serviceradar-rperf" ] || [ "$pkg" = "serviceradar-rperf-checker" ]; }; then
            download_package "$pkg" "-1.el9.x86_64"
        else
            download_package "$pkg" ""
        fi
    done

    install_packages "${checker_packages[@]}"

    if [ "$UPDATE_POLLER_CONFIG" = "true" ] && [ ${#INSTALLED_CHECKERS[@]} -gt 0 ]; then
        header "Updating Poller Configuration"

        if [ ${#INSTALLED_CHECKERS[@]} -ge 3 ]; then
            enable_all_checkers
        else
            for checker_type in "${INSTALLED_CHECKERS[@]}"; do
                update_poller_config_for_checker "$checker_type"
            done
        fi
    fi
}

update_configs_for_mtls() {
    log "Updating configuration files to enable mTLS..."

    local configs=(
        "/etc/serviceradar/checkers/dusk.json"
        "/etc/serviceradar/checkers/snmp.json"
        "/etc/serviceradar/checkers/sysmon.json"
    )

    for config in "${configs[@]}"; do
        if [ -f "$config" ]; then
            log "Enabling mTLS in $config..."
            jq '.security.mode = "mtls" | .security.server_name = "127.0.0.1"' "$config" > "$config.tmp" && mv "$config.tmp" "$config"
            chown serviceradar:serviceradar "$config"
            chmod 644 "$config"
        fi
    done

    success "Configuration files updated for mTLS"
}

prompt_nats_mode() {
    # Check if NATS is being installed to avoid unnecessary prompts
    if ! [[ " ${packages_to_install[*]} " =~ " serviceradar-nats " ]]; then
        return
    fi

    if [ "$INTERACTIVE" = "true" ]; then
        header "Select NATS Server Mode"
        echo -e "${COLOR_CYAN}Please choose the NATS server deployment mode:${COLOR_RESET}"
        echo -e "${COLOR_WHITE}  1) Standalone (Default: single server for all-in-one installs)${COLOR_RESET}"
        echo -e "${COLOR_WHITE}  2) Edge (Leaf Node that connects to a Cloud NATS server)${COLOR_RESET}"
        echo -e "${COLOR_WHITE}  3) Cloud (Accepts connections from Edge Leaf Nodes)${COLOR_RESET}"

        read_with_timeout "${COLOR_CYAN}Enter choice [1]:${COLOR_RESET}" "1" NATS_MODE
    else
        NATS_MODE=${NATS_MODE:-"1"} # Default to standalone in non-interactive
    fi
}

configure_nats() {
    # Check if NATS was installed
    if ! command -v nats-server >/dev/null 2>&1 || [ -z "$NATS_MODE" ]; then
        return
    fi

    header "Configuring NATS Server"
    local template_dir="/etc/nats/templates"
    local target_conf="/etc/nats/nats-server.conf"
    local selected_template=""

    case "$NATS_MODE" in
        1)
            log "Setting up NATS in Standalone mode."
            selected_template="nats-standalone.conf"
            ;;
        2)
            log "Setting up NATS in Edge (Leaf Node) mode."
            selected_template="nats-leaf.conf"
            if [ "$INTERACTIVE" = "true" ]; then
                local cloud_host
                read_with_timeout "${COLOR_CYAN}Enter the public DNS or IP of your Cloud NATS server:${COLOR_RESET}" "" cloud_host
                if [ -z "$cloud_host" ]; then
                    error "Cloud NATS server address is required for Edge mode."
                fi
                cp "${template_dir}/${selected_template}" "${target_conf}"
                # Use a different delimiter for sed to avoid issues with slashes in URLs/IPs
                sed -i "s|cloud-nats.yourdomain.com|${cloud_host}|g" "${target_conf}"
            else
                cp "${template_dir}/${selected_template}" "${target_conf}"
                log "${COLOR_YELLOW}WARNING: NATS Edge mode requires the cloud server address. You must manually edit ${target_conf} and set the correct 'url'.${COLOR_RESET}"
            fi
            ;;
        3)
            log "Setting up NATS in Cloud mode."
            selected_template="nats-cloud.conf"
            ;;
        *)
            error "Invalid NATS mode selected."
            ;;
    esac

    if [ "$NATS_MODE" != "2" ]; then
       if [ -f "${template_dir}/${selected_template}" ]; then
            cp "${template_dir}/${selected_template}" "${target_conf}"
        else
            error "NATS template file ${template_dir}/${selected_template} not found!"
        fi
    fi

    chown nats:serviceradar "${target_conf}"
    chmod 640 "${target_conf}"
    success "NATS configuration set to use ${selected_template}."
}

# Main installation logic
main() {
    display_banner

    if ! [ -t 0 ]; then
        INTERACTIVE=false
        log "No TTY detected, forcing non-interactive mode"
    fi

    parse_args "$@"
    detect_system
    check_curl

    if [ "$INSTALL_ALL" = "true" ]; then
        INSTALL_CORE=true
        INSTALL_POLLER=true
        INSTALL_AGENT=true
    fi

    if [ "$INSTALL_CORE" = "false" ] && [ "$INSTALL_POLLER" = "false" ] && [ "$INSTALL_AGENT" = "false" ]; then
        if [ "$INTERACTIVE" = "true" ]; then
            prompt_scenario
        else
            error "No installation scenario specified. Use --all, --core, --poller, or --agent."
        fi
    fi

    # Set up IPs for mTLS
    if [ -z "$SERVICE_IPS" ]; then
        if [ "$INTERACTIVE" = "false" ]; then
            SERVICE_IPS="127.0.0.1"
            log "Non-interactive mode: Using localhost (127.0.0.1) for certificates"
        else
            local_ip=$(get_local_ip)
            SERVICE_IPS="${local_ip},127.0.0.1"
            log "Auto-detected IP addresses: $SERVICE_IPS"
        fi
    else
        validate_ips "$SERVICE_IPS"
        if ! [[ $SERVICE_IPS == *"127.0.0.1"* ]]; then
            SERVICE_IPS="${SERVICE_IPS},127.0.0.1"
        fi
    fi

    mkdir -p "$TEMP_DIR"
    install_dependencies

    # Install serviceradar-cli for all scenarios
    header "Installing ServiceRadar CLI"
    if [ "$SYSTEM" = "rhel" ]; then
        install_single_package "serviceradar-cli" "-1.el9.x86_64"
    else
        install_single_package "serviceradar-cli" ""
    fi

    prompt_nats_mode

    # Install main components
    core_packages=("serviceradar-core" "serviceradar-proton" "serviceradar-web" "serviceradar-nats" "serviceradar-kv" "serviceradar-sync")
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
            if [ "$pkg" = "serviceradar-core" ] || [ "$pkg" = "serviceradar-kv" ] || [ "$pkg" = "serviceradar-nats" ] || [ "$pkg" = "serviceradar-agent" ] || [ "$pkg" = "serviceradar-poller" ] || [ "$pkg" = "serviceradar-sync" ] || [ "$pkg" = "serviceradar-proton" ]; then
                download_package "$pkg" "-1.el9.x86_64"
            else
                download_package "$pkg" "-1.el9.x86_64"
            fi
        else
            download_package "$pkg" ""
        fi
    done
    install_packages "${packages_to_install[@]}"

    # Install optional checkers
    install_optional_checkers

    # Setup mTLS certificates after checkers are installed
    header "Setting up mTLS Certificates"
    setup_mtls_certificates
    update_configs_for_mtls
    show_post_install_info

    update_core_config

    header "Cleaning Up"
    log "Removing temporary files..."
    rm -rf "$TEMP_DIR"
    success "Cleanup completed!"

    header "Installation Complete"
    success "[ServiceRadar] installation completed successfully!"
    if [ "$INSTALL_CORE" = "true" ]; then
        local_ip=$(get_local_ip)
        info "Web UI: ${COLOR_YELLOW}http://${local_ip}/${COLOR_RESET}"
        info "Core API: ${COLOR_YELLOW}http://${local_ip}/swagger${COLOR_RESET}"
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
