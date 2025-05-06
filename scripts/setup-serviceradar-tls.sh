#!/bin/bash

# setup-serviceradar-tls.sh - Generate mTLS certificates for ServiceRadar and Proton
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

set -e

# Color codes for output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color
BOLD='\033[1m'

# Default paths
PROTON_CERT_DIR="/etc/proton-server"
SR_CERT_DIR="/etc/serviceradar/certs"
WORK_DIR="/tmp/serviceradar-tls"
DAYS_VALID=3650
INTERACTIVE=true

# Function to display help message
show_help() {
    echo -e "${BOLD}ServiceRadar TLS Certificate Generator${NC}"
    echo "Generates certificates for secure communication between ServiceRadar and Proton"
    echo
    echo "Usage: $0 [options]"
    echo
    echo "Options:"
    echo "  -h, --help                 Show this help message"
    echo "  -i, --ip IP1[,IP2,...]     IP addresses for the certificates"
    echo "                             (default: local IP and 127.0.0.1)"
    echo "  -c, --cert-dir DIR         Where to store ServiceRadar certificates"
    echo "                             (default: $SR_CERT_DIR)"
    echo "  -p, --proton-dir DIR       Where to store Proton certificates"
    echo "                             (default: $PROTON_CERT_DIR)"
    echo "  -a, --add-ips              Add IPs to existing certificates"
    echo "  --non-interactive          Run in non-interactive mode (use 127.0.0.1)"
    echo
    echo "Examples:"
    echo "  $0                         # Use default settings"
    echo "  $0 --ip 192.168.1.10       # Specify a single IP"
    echo "  $0 --ip 192.168.1.10,10.0.0.5  # Specify multiple IPs"
    echo "  $0 --add-ips --ip 10.0.0.5     # Add an IP to existing certificates"
    echo "  $0 --non-interactive           # Use localhost (all-in-one install)"
}

# Function to log messages
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Function to get local IP address
get_local_ip() {
    # Try to find a non-loopback IPv4 address
    local_ip=$(ip -4 addr show scope global 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -n 1)
    if [ -z "$local_ip" ]; then
        # Fallback to hostname
        local_ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    fi
    if [ -z "$local_ip" ]; then
        # If still no IP, use localhost
        local_ip="127.0.0.1"
    fi
    echo "$local_ip"
}

# Function to validate IPs
validate_ips() {
    local ips=$1
    IFS=',' read -ra IP_ARRAY <<< "$ips"

    for ip in "${IP_ARRAY[@]}"; do
        if ! [[ $ip =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            log_error "Invalid IP address format: $ip"
            return 1
        fi
    done
    return 0
}

# Function to create certificate directories
create_cert_dirs() {
    log_info "Creating certificate directories..."
    mkdir -p "$SR_CERT_DIR"
    mkdir -p "$PROTON_CERT_DIR"
    mkdir -p "$WORK_DIR"
}

# Function to generate root CA
generate_root_ca() {
    log_info "Generating root CA certificate..."

    # Check if root CA already exists
    if [ -f "$SR_CERT_DIR/root.pem" ] && [ ! "$ADD_IPS" = true ]; then
        log_warning "Root CA already exists at $SR_CERT_DIR/root.pem"
        log_warning "If you want to create new certificates, remove existing ones first"
        log_warning "or use --add-ips to add IPs to existing certificates"
        exit 1
    fi

    # Generate new root CA if it doesn't exist or we're not in add-ips mode
    if [ ! -f "$SR_CERT_DIR/root.pem" ] || [ ! -f "$WORK_DIR/root-key.pem" ]; then
        openssl ecparam -name prime256v1 -genkey -out "$WORK_DIR/root-key.pem"
        openssl req -x509 -new -nodes -key "$WORK_DIR/root-key.pem" -sha256 -days "$DAYS_VALID" \
            -out "$WORK_DIR/root.pem" -subj "/C=US/ST=CA/L=San Francisco/O=ServiceRadar/OU=Operations/CN=ServiceRadar CA"

        # Copy root CA to final locations
        cp "$WORK_DIR/root.pem" "$SR_CERT_DIR/root.pem"
        cp "$WORK_DIR/root.pem" "$PROTON_CERT_DIR/ca-cert.pem"

        log_success "Root CA generated and installed"
    else
        # In add-ips mode, copy existing root CA to work dir
        cp "$SR_CERT_DIR/root.pem" "$WORK_DIR/root.pem"
        if [ -f "$SR_CERT_DIR/root-key.pem" ]; then
            cp "$SR_CERT_DIR/root-key.pem" "$WORK_DIR/root-key.pem"
        else
            log_warning "Root CA key not found at expected location, attempting to use core-key.pem"
            cp "$SR_CERT_DIR/core-key.pem" "$WORK_DIR/root-key.pem"
        fi
        log_info "Using existing root CA"
    fi
}

# Function to generate a Subject Alternative Name (SAN) configuration
generate_san_config() {
    local cn=$1
    local ips=$2

    # Convert comma-separated IPs to the format needed for SAN
    local san_list=""
    IFS=',' read -ra IP_ARRAY <<< "$ips"
    for ip in "${IP_ARRAY[@]}"; do
        if [ -z "$san_list" ]; then
            san_list="IP:$ip"
        else
            san_list="$san_list,IP:$ip"
        fi
    done

    cat > "$WORK_DIR/$cn-san.cnf" << EOF
[req]
distinguished_name = req_distinguished_name
req_extensions = v3_req
prompt = no

[req_distinguished_name]
C = US
ST = CA
L = San Francisco
O = ServiceRadar
OU = Operations
CN = $cn.serviceradar

[v3_req]
basicConstraints = CA:FALSE
keyUsage = digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth,clientAuth
subjectAltName = $san_list
EOF

    log_info "Generated SAN configuration with IPs: $ips"
}

# Function to generate service certificate
generate_service_cert() {
    local service=$1
    local ips=$2

    log_info "Generating certificate for $service..."

    # Generate SAN configuration
    generate_san_config "$service" "$ips"

    # Generate key and certificate
    openssl ecparam -name prime256v1 -genkey -out "$WORK_DIR/$service-key.pem"
    openssl req -new -key "$WORK_DIR/$service-key.pem" -out "$WORK_DIR/$service.csr" -config "$WORK_DIR/$service-san.cnf"
    openssl x509 -req -in "$WORK_DIR/$service.csr" -CA "$WORK_DIR/root.pem" -CAkey "$WORK_DIR/root-key.pem" \
        -CAcreateserial -out "$WORK_DIR/$service.pem" -days "$DAYS_VALID" -sha256 \
        -extfile "$WORK_DIR/$service-san.cnf" -extensions v3_req

    # Verify certificate
    openssl verify -CAfile "$WORK_DIR/root.pem" "$WORK_DIR/$service.pem" > /dev/null || {
        log_error "Certificate verification failed"
        exit 1
    }

    # Show certificate info
    log_info "Certificate details:"
    openssl x509 -in "$WORK_DIR/$service.pem" -text -noout | grep -E "Subject:|Issuer:|X509v3 Subject Alternative Name:" | head -3

    log_success "$service certificate generated successfully"
}

# Function to install certificates
install_certificates() {
    log_info "Installing certificates..."

    # Install ServiceRadar certificates
    cp "$WORK_DIR/core.pem" "$SR_CERT_DIR/core.pem"
    cp "$WORK_DIR/core-key.pem" "$SR_CERT_DIR/core-key.pem"

    # Install Proton certificates
    cp "$WORK_DIR/core.pem" "$PROTON_CERT_DIR/root.pem"
    cp "$WORK_DIR/core-key.pem" "$PROTON_CERT_DIR/core-key.pem"

    # Set correct permissions
    chmod 644 "$SR_CERT_DIR/root.pem" "$SR_CERT_DIR/core.pem" "$PROTON_CERT_DIR/ca-cert.pem" "$PROTON_CERT_DIR/root.pem"
    chmod 600 "$SR_CERT_DIR/core-key.pem" "$PROTON_CERT_DIR/core-key.pem"

    # Set correct ownership if possible
    if getent passwd proton > /dev/null; then
        chown proton:proton "$PROTON_CERT_DIR/ca-cert.pem" "$PROTON_CERT_DIR/root.pem" "$PROTON_CERT_DIR/core-key.pem"
    fi

    if getent passwd serviceradar > /dev/null; then
        chown serviceradar:serviceradar "$SR_CERT_DIR/root.pem" "$SR_CERT_DIR/core.pem" "$SR_CERT_DIR/core-key.pem"
    fi

    log_success "Certificates installed"
}

# Function to extract IPs from an existing certificate
extract_existing_ips() {
    local cert_file="$1"

    if [ ! -f "$cert_file" ]; then
        log_error "Certificate file not found: $cert_file"
        return 1
    fi

    # Extract SANs from certificate
    local sans=$(openssl x509 -in "$cert_file" -text -noout | grep -A 1 "Subject Alternative Name" | tail -1)

    # Extract IP addresses
    local existing_ips=$(echo "$sans" | grep -oP 'IP Address:\K[0-9.]+' | tr '\n' ',' | sed 's/,$//')

    echo "$existing_ips"
}

# Function to merge IPs
merge_ips() {
    local existing_ips="$1"
    local new_ips="$2"

    # Combine existing and new IPs
    local combined_ips="${existing_ips},${new_ips}"

    # Remove duplicates
    local unique_ips=$(echo "$combined_ips" | tr ',' '\n' | sort -u | tr '\n' ',' | sed 's/,$//')

    echo "$unique_ips"
}

# Function to add IPs to existing certificates
add_ips_to_certs() {
    log_info "Adding IPs to existing certificates..."

    if [ ! -f "$SR_CERT_DIR/core.pem" ]; then
        log_error "No existing certificates found. Run without --add-ips first."
        exit 1
    fi

    # Extract existing IPs
    local existing_ips=$(extract_existing_ips "$SR_CERT_DIR/core.pem")
    log_info "Existing IPs in certificate: $existing_ips"

    # Merge with new IPs
    local all_ips=$(merge_ips "$existing_ips" "$SERVICE_IPS")
    log_info "Combined IPs for new certificate: $all_ips"

    # Copy existing certificates to work dir
    cp "$SR_CERT_DIR/root.pem" "$WORK_DIR/root.pem"

    # Try to find the root key or use the core key as a fallback
    if [ -f "$SR_CERT_DIR/root-key.pem" ]; then
        cp "$SR_CERT_DIR/root-key.pem" "$WORK_DIR/root-key.pem"
    else
        cp "$SR_CERT_DIR/core-key.pem" "$WORK_DIR/root-key.pem"
        log_warning "Root CA key not found, using core-key.pem as a fallback"
    fi

    # Regenerate certificates with combined IPs
    SERVICE_IPS="$all_ips"

    # Generate new certificates with all IPs
    generate_service_cert "core" "$SERVICE_IPS"

    # Install the new certificates
    install_certificates

    log_success "IPs added to certificates"
}

# Function to display post-installation instructions
show_post_install_info() {
    local ips
    IFS=',' read -ra IPS <<< "$SERVICE_IPS"
    local first_ip="${IPS[0]}"

    echo
    echo -e "${BOLD}TLS Certificate Setup Complete${NC}"
    echo
    echo -e "Certificates have been installed with the following IPs:"
    for ip in "${IPS[@]}"; do
        echo -e "  - ${BLUE}$ip${NC}"
    done
    echo
    echo -e "${BOLD}Certificate locations:${NC}"
    echo -e "  - ServiceRadar: ${BLUE}$SR_CERT_DIR/root.pem, $SR_CERT_DIR/core.pem, $SR_CERT_DIR/core-key.pem${NC}"
    echo -e "  - Proton: ${BLUE}$PROTON_CERT_DIR/ca-cert.pem, $PROTON_CERT_DIR/root.pem, $PROTON_CERT_DIR/core-key.pem${NC}"
    echo
    echo -e "${BOLD}Next steps:${NC}"
    echo "1. Verify the Proton connection:"
    echo "   proton-client --host $first_ip --port 9440 --secure \\"
    echo "     --certificate-file $SR_CERT_DIR/core.pem \\"
    echo "     --private-key-file $SR_CERT_DIR/core-key.pem -q \"SELECT 1\""
    echo
    echo "2. If you need to add more IPs later, run:"
    echo "   $0 --add-ips --ip new.ip.address"
    echo
    echo "3. To restart services with new certificates:"
    echo "   systemctl restart serviceradar-proton serviceradar-core"
    echo
}

# Parse command-line arguments
ADD_IPS=false
SERVICE_IPS=""

while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            show_help
            exit 0
            ;;
        -i|--ip)
            SERVICE_IPS="$2"
            shift 2
            ;;
        -c|--cert-dir)
            SR_CERT_DIR="$2"
            shift 2
            ;;
        -p|--proton-dir)
            PROTON_CERT_DIR="$2"
            shift 2
            ;;
        -a|--add-ips)
            ADD_IPS=true
            shift
            ;;
        --non-interactive)
            INTERACTIVE=false
            shift
            ;;
        *)
            log_error "Unknown option: $1"
            show_help
            exit 1
            ;;
    esac
done

# Get local IP if not specified
if [ -z "$SERVICE_IPS" ]; then
    # For all-in-one installations, 127.0.0.1 is enough
    if [ "$INTERACTIVE" = "false" ]; then
        SERVICE_IPS="127.0.0.1"
        log_info "Non-interactive mode: Using localhost (127.0.0.1) for certificates"
    else
        # For interactive mode, try to auto-detect external IP too
        local_ip=$(get_local_ip)
        SERVICE_IPS="${local_ip},127.0.0.1"
        log_info "Auto-detected IP addresses: $SERVICE_IPS"
    fi
else
    # Validate the IPs
    if ! validate_ips "$SERVICE_IPS"; then
        log_error "Invalid IP address format"
        exit 1
    fi
    # Ensure 127.0.0.1 is included
    if ! [[ $SERVICE_IPS == *"127.0.0.1"* ]]; then
        SERVICE_IPS="${SERVICE_IPS},127.0.0.1"
    fi
fi

# Main execution
log_info "Starting TLS certificate setup for ServiceRadar and Proton"
create_cert_dirs

if [ "$ADD_IPS" = true ]; then
    add_ips_to_certs
else
    generate_root_ca
    generate_service_cert "core" "$SERVICE_IPS"
    install_certificates
fi

show_post_install_info
log_success "TLS certificate setup complete!"