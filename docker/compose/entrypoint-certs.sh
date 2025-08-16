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

set -e

CERT_DIR="/certs"
DAYS_VALID=3650

# Check if basic certificates exist - but allow individual certificate generation
if [ -f "$CERT_DIR/root.pem" ] && [ -f "$CERT_DIR/core.pem" ] && [ -f "$CERT_DIR/proton.pem" ] && [ -f "$CERT_DIR/nats.pem" ] && [ -f "$CERT_DIR/kv.pem" ]; then
    echo "All certificates already exist, nothing to generate"
    exit 0
fi

echo "Generating missing mTLS certificates..."

# Create certificate directory
mkdir -p "$CERT_DIR"
cd "$CERT_DIR"

# Create serviceradar user and group if they don't exist (for consistency)
addgroup -S serviceradar 2>/dev/null || true
adduser -S -G serviceradar -s /bin/false -h /nonexistent serviceradar 2>/dev/null || true

# Generate Root CA only if it doesn't exist
if [ ! -f "$CERT_DIR/root.pem" ]; then
    echo "Generating Root CA..."
    openssl genrsa -out root-key.pem 4096
    openssl req -new -x509 -sha256 -key root-key.pem -out root.pem \
        -days $DAYS_VALID -subj "/C=US/ST=CA/L=San Francisco/O=ServiceRadar/OU=Docker/CN=ServiceRadar Root CA"
    
    # Set standard permissions for Root CA (readable by all)
    chmod 644 root.pem root-key.pem
    echo "Root CA generated successfully!"
else
    echo "Root CA already exists, skipping"
fi

# Function to generate certificate
generate_cert() {
    local component=$1
    local cn=$2
    local san=$3
    
    # Skip if certificate already exists
    if [ -f "$component.pem" ]; then
        echo "Certificate for $component already exists, skipping"
        return
    fi
    
    echo "Generating certificate for $component..."
    
    # Generate private key
    openssl genrsa -out "$component-key.pem" 2048
    
    # Create config with SAN
    cat > "$component.conf" <<EOF
[req]
distinguished_name = req_distinguished_name
req_extensions = v3_req
prompt = no

[req_distinguished_name]
C = US
ST = CA
L = San Francisco
O = ServiceRadar
OU = Docker
CN = $cn

[v3_req]
keyUsage = keyEncipherment, dataEncipherment, digitalSignature
extendedKeyUsage = serverAuth, clientAuth
subjectAltName = $san
EOF
    
    # Generate CSR
    openssl req -new -sha256 -key "$component-key.pem" \
        -out "$component.csr" -config "$component.conf"
    
    # Sign certificate
    openssl x509 -req -in "$component.csr" -CA root.pem \
        -CAkey root-key.pem -CAcreateserial -out "$component.pem" \
        -days $DAYS_VALID -sha256 -extensions v3_req -extfile "$component.conf"
    
    # Clean up
    rm "$component.csr" "$component.conf"
    
    # Set standard permissions (readable by all)
    chmod 644 "$component.pem" "$component-key.pem"
}

# Generate certificates for components (using NATS-compatible Common Names)
generate_cert "core" "core.serviceradar" "DNS:core,DNS:serviceradar-core,DNS:localhost,IP:127.0.0.1,IP:172.28.0.3"
generate_cert "proton" "proton.serviceradar" "DNS:proton,DNS:serviceradar-proton,DNS:localhost,IP:127.0.0.1,IP:172.28.0.2"
generate_cert "nats" "nats.serviceradar" "DNS:nats,DNS:serviceradar-nats,DNS:localhost,IP:127.0.0.1,IP:172.28.0.4"
generate_cert "kv" "kv.serviceradar" "DNS:kv,DNS:serviceradar-kv,DNS:localhost,IP:127.0.0.1,IP:172.28.0.5"

# Copy core certificate for Proton to use
cp core.pem proton-core.pem
cp core-key.pem proton-core-key.pem

# Set standard permissions on copied certificates
chmod 644 proton-core.pem proton-core-key.pem

echo "Certificates generated successfully!"
ls -la *.pem