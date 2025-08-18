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

# Configuration
CERT_DIR="${CERT_DIR:-./docker/compose/certs}"
DAYS_VALID=3650
COUNTRY="US"
STATE="CA"
LOCALITY="San Francisco"
ORGANIZATION="ServiceRadar"
ORG_UNIT="Docker"

# Create certificate directory
mkdir -p "$CERT_DIR"

# Create serviceradar user and group if they don't exist
groupadd -f serviceradar || true
useradd -r -g serviceradar -s /bin/false -d /nonexistent serviceradar 2>/dev/null || true

# Set proper ownership on cert directory
chown serviceradar:serviceradar "$CERT_DIR"
chmod 755 "$CERT_DIR"

# Generate Root CA
if [ ! -f "$CERT_DIR/root.pem" ]; then
    echo "Generating Root CA..."
    openssl genrsa -out "$CERT_DIR/root-key.pem" 4096
    openssl req -new -x509 -sha256 -key "$CERT_DIR/root-key.pem" -out "$CERT_DIR/root.pem" \
        -days $DAYS_VALID -subj "/C=$COUNTRY/ST=$STATE/L=$LOCALITY/O=$ORGANIZATION/OU=$ORG_UNIT/CN=ServiceRadar Root CA"
    
    # Set permissions and ownership for root CA
    chown serviceradar:serviceradar "$CERT_DIR/root.pem" "$CERT_DIR/root-key.pem"
    chmod 644 "$CERT_DIR/root.pem"
    chmod 640 "$CERT_DIR/root-key.pem"
    
    echo "Root CA generated."
else
    echo "Root CA already exists."
fi

# Function to generate certificate for a component
generate_cert() {
    local component=$1
    local cn=$2
    local san=$3
    
    if [ -f "$CERT_DIR/$component.pem" ]; then
        echo "Certificate for $component already exists, skipping."
        return
    fi
    
    echo "Generating certificate for $component..."
    
    # Generate private key
    openssl genrsa -out "$CERT_DIR/$component-key.pem" 2048
    
    # Create config file with SAN
    cat > "$CERT_DIR/$component.conf" <<EOF
[req]
distinguished_name = req_distinguished_name
req_extensions = v3_req
prompt = no

[req_distinguished_name]
C = $COUNTRY
ST = $STATE
L = $LOCALITY
O = $ORGANIZATION
OU = $ORG_UNIT
CN = $cn

[v3_req]
keyUsage = keyEncipherment, dataEncipherment, digitalSignature
extendedKeyUsage = serverAuth, clientAuth
subjectAltName = $san
EOF
    
    # Generate CSR
    openssl req -new -sha256 -key "$CERT_DIR/$component-key.pem" \
        -out "$CERT_DIR/$component.csr" -config "$CERT_DIR/$component.conf"
    
    # Sign certificate
    openssl x509 -req -in "$CERT_DIR/$component.csr" -CA "$CERT_DIR/root.pem" \
        -CAkey "$CERT_DIR/root-key.pem" -CAcreateserial -out "$CERT_DIR/$component.pem" \
        -days $DAYS_VALID -sha256 -extensions v3_req -extfile "$CERT_DIR/$component.conf"
    
    # Clean up
    rm "$CERT_DIR/$component.csr" "$CERT_DIR/$component.conf"
    
    # Set permissions and ownership
    chown serviceradar:serviceradar "$CERT_DIR/$component.pem"
    chown serviceradar:serviceradar "$CERT_DIR/$component-key.pem"
    chmod 644 "$CERT_DIR/$component.pem"
    chmod 640 "$CERT_DIR/$component-key.pem"
    
    echo "Certificate for $component generated."
}

# Generate certificates for each component
# Using <service>.serviceradar naming convention consistently
generate_cert "core" "core.serviceradar" "DNS:core,DNS:core.serviceradar,DNS:localhost,IP:127.0.0.1,IP:172.28.0.3"
generate_cert "proton" "proton.serviceradar" "DNS:proton,DNS:proton.serviceradar,DNS:localhost,IP:127.0.0.1,IP:172.28.0.2"
generate_cert "nats" "nats.serviceradar" "DNS:nats,DNS:nats.serviceradar,DNS:localhost,IP:127.0.0.1,IP:172.28.0.4"
generate_cert "kv" "kv.serviceradar" "DNS:kv,DNS:kv.serviceradar,DNS:localhost,IP:127.0.0.1,IP:172.28.0.5"
generate_cert "web" "web.serviceradar" "DNS:web,DNS:web.serviceradar,DNS:localhost,IP:127.0.0.1"
generate_cert "poller" "poller.serviceradar" "DNS:poller,DNS:poller.serviceradar,DNS:localhost,IP:127.0.0.1"
generate_cert "agent" "agent.serviceradar" "DNS:agent,DNS:agent.serviceradar,DNS:localhost,IP:127.0.0.1"
generate_cert "db-event-writer" "db-event-writer.serviceradar" "DNS:db-event-writer,DNS:db-event-writer.serviceradar,DNS:localhost,IP:127.0.0.1"
generate_cert "mapper" "mapper.serviceradar" "DNS:mapper,DNS:mapper.serviceradar,DNS:localhost,IP:127.0.0.1"
generate_cert "snmp-checker" "snmp-checker.serviceradar" "DNS:snmp-checker,DNS:snmp-checker.serviceradar,DNS:localhost,IP:127.0.0.1"
generate_cert "rperf-client" "rperf-client.serviceradar" "DNS:rperf-client,DNS:rperf-client.serviceradar,DNS:localhost,IP:127.0.0.1"
generate_cert "sync" "sync.serviceradar" "DNS:sync,DNS:sync.serviceradar,DNS:localhost,IP:127.0.0.1"
generate_cert "otel" "otel.serviceradar" "DNS:otel,DNS:otel.serviceradar,DNS:localhost,IP:127.0.0.1"
generate_cert "flowgger" "flowgger.serviceradar" "DNS:flowgger,DNS:flowgger.serviceradar,DNS:localhost,IP:127.0.0.1"
generate_cert "trapd" "trapd.serviceradar" "DNS:trapd,DNS:trapd.serviceradar,DNS:localhost,IP:127.0.0.1"
generate_cert "zen" "zen.serviceradar" "DNS:zen,DNS:zen.serviceradar,DNS:localhost,IP:127.0.0.1"

# Copy core certificate for Proton to use
cp "$CERT_DIR/core.pem" "$CERT_DIR/proton-core.pem"
cp "$CERT_DIR/core-key.pem" "$CERT_DIR/proton-core-key.pem"

# Set ownership on copied certificates
chown serviceradar:serviceradar "$CERT_DIR/proton-core.pem" "$CERT_DIR/proton-core-key.pem"
chmod 644 "$CERT_DIR/proton-core.pem"
chmod 640 "$CERT_DIR/proton-core-key.pem"

# Generate JWT secret for authentication
JWT_SECRET_FILE="$CERT_DIR/jwt-secret"
if [ ! -f "$JWT_SECRET_FILE" ]; then
    echo "Generating JWT secret..."
    openssl rand -hex 32 > "$JWT_SECRET_FILE"
    chown serviceradar:serviceradar "$JWT_SECRET_FILE"
    chmod 640 "$JWT_SECRET_FILE"
    echo "JWT secret generated."
else
    echo "JWT secret already exists."
fi

# Generate API key
API_KEY_FILE="$CERT_DIR/api-key" 
if [ ! -f "$API_KEY_FILE" ]; then
    echo "Generating API key..."
    openssl rand -hex 32 > "$API_KEY_FILE"
    chown serviceradar:serviceradar "$API_KEY_FILE"
    chmod 640 "$API_KEY_FILE"
    echo "API key generated."
else
    echo "API key already exists."
fi

echo "All certificates and secrets generated successfully in $CERT_DIR"
echo ""
echo "Files generated:"
ls -la "$CERT_DIR"/*.pem "$CERT_DIR"/jwt-secret "$CERT_DIR"/api-key 2>/dev/null | awk '{print $9}' | sort