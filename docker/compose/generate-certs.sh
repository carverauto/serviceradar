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

# Create serviceradar user and group if they don't exist (skip in Alpine containers)
if command -v groupadd >/dev/null 2>&1; then
    groupadd -f serviceradar || true
    useradd -r -g serviceradar -s /bin/false -d /nonexistent serviceradar 2>/dev/null || true
    # Set proper ownership on cert directory
    chown serviceradar:serviceradar "$CERT_DIR"
else
    # In Alpine container, use root ownership
    echo "Running in minimal container, using root ownership for certificates"
fi
chmod 755 "$CERT_DIR"

# Generate Root CA
if [ ! -f "$CERT_DIR/root.pem" ]; then
    echo "Generating Root CA..."
    openssl genrsa -out "$CERT_DIR/root-key.pem" 4096
    openssl req -new -x509 -sha256 -key "$CERT_DIR/root-key.pem" -out "$CERT_DIR/root.pem" \
        -days $DAYS_VALID -subj "/C=$COUNTRY/ST=$STATE/L=$LOCALITY/O=$ORGANIZATION/OU=$ORG_UNIT/CN=ServiceRadar Root CA"
    
    # Set permissions and ownership for root CA
    if command -v groupadd >/dev/null 2>&1; then
        chown serviceradar:serviceradar "$CERT_DIR/root.pem" "$CERT_DIR/root-key.pem"
    fi
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
    local required_dns=""
    
    if [ -f "$CERT_DIR/$component.pem" ]; then
        if [ "$component" = "cnpg" ] && [ -n "${CNPG_CERT_EXTRA_IPS:-}" ]; then
            for ip in $(echo "$CNPG_CERT_EXTRA_IPS" | tr ',' ' '); do
                if ! openssl x509 -in "$CERT_DIR/$component.pem" -noout -text | grep -q "IP Address:${ip}"; then
                    echo "CNPG certificate is missing SAN IP ${ip}; regenerating cnpg certificate..."
                    rm -f "$CERT_DIR/$component.pem" "$CERT_DIR/$component-key.pem"
                    break
                fi
            done
        fi
        if [ "$component" = "core" ]; then
            required_dns="core-elx"
        elif [ "$component" = "poller" ]; then
            required_dns="poller-elx-t2"
        elif [ "$component" = "agent" ]; then
            required_dns="agent-elx-t2"
        fi

        if [ -n "$required_dns" ]; then
            if ! openssl x509 -in "$CERT_DIR/$component.pem" -noout -text | grep -q "DNS:${required_dns}"; then
                echo "Certificate for $component missing SAN DNS:${required_dns}; regenerating..."
                rm -f "$CERT_DIR/$component.pem" "$CERT_DIR/$component-key.pem"
            fi
        fi

        if [ -f "$CERT_DIR/$component.pem" ]; then
            echo "Certificate for $component already exists, ensuring permissions."
            chmod 600 "$CERT_DIR/$component-key.pem" 2>/dev/null || true
            if [ "$component" = "cnpg" ]; then
                chown 26:999 "$CERT_DIR/$component-key.pem" "$CERT_DIR/$component.pem" 2>/dev/null || true
            fi
            return
        fi
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
    
    # Set permissions and ownership based on component
    if command -v chown >/dev/null 2>&1 && id -u serviceradar >/dev/null 2>&1; then
        chown serviceradar:serviceradar "$CERT_DIR/$component.pem" "$CERT_DIR/$component-key.pem" || true
    fi
    chmod 644 "$CERT_DIR/$component.pem"
    chmod 600 "$CERT_DIR/$component-key.pem"
    if [ "$component" = "cnpg" ]; then
        chown 26:999 "$CERT_DIR/$component.pem" "$CERT_DIR/$component-key.pem" 2>/dev/null || true
    fi
    
    echo "Certificate for $component generated."
}

# Generate certificates for each component
# Using <service>.serviceradar naming convention consistently
# Include comprehensive cross-service SAN entries for all inter-service communication

# Core services that many others connect to - include common client service names
generate_cert "core" "core.serviceradar" "DNS:core,DNS:core-elx,DNS:core.serviceradar,DNS:serviceradar-core,DNS:poller.serviceradar,DNS:agent.serviceradar,DNS:web.serviceradar,DNS:localhost,IP:127.0.0.1"

# NATS - messaging backbone, many services connect to it
generate_cert "nats" "nats.serviceradar" "DNS:nats,DNS:nats.serviceradar,DNS:serviceradar-nats,DNS:datasvc.serviceradar,DNS:sync.serviceradar,DNS:zen.serviceradar,DNS:trapd.serviceradar,DNS:flowgger.serviceradar,DNS:otel.serviceradar,DNS:db-event-writer.serviceradar,DNS:localhost,IP:127.0.0.1"

# Services that agent connects to
generate_cert "datasvc" "datasvc.serviceradar" "DNS:datasvc,DNS:datasvc.serviceradar,DNS:serviceradar-datasvc,DNS:agent.serviceradar,DNS:sync.serviceradar,DNS:zen.serviceradar,DNS:core.serviceradar,DNS:localhost,IP:127.0.0.1"
generate_cert "sync" "sync.serviceradar" "DNS:sync,DNS:sync.serviceradar,DNS:serviceradar-sync,DNS:agent.serviceradar,DNS:poller.serviceradar,DNS:localhost,IP:127.0.0.1"
generate_cert "zen" "zen.serviceradar" "DNS:zen,DNS:zen.serviceradar,DNS:serviceradar-zen,DNS:agent.serviceradar,DNS:poller.serviceradar,DNS:localhost,IP:127.0.0.1"
generate_cert "trapd" "trapd.serviceradar" "DNS:trapd,DNS:trapd.serviceradar,DNS:serviceradar-trapd,DNS:agent.serviceradar,DNS:poller.serviceradar,DNS:localhost,IP:127.0.0.1"
generate_cert "mapper" "mapper.serviceradar" "DNS:mapper,DNS:mapper.serviceradar,DNS:serviceradar-mapper,DNS:agent.serviceradar,DNS:poller.serviceradar,DNS:localhost,IP:127.0.0.1"

# Services that are clients to others
generate_cert "poller" "poller.serviceradar" "DNS:poller,DNS:poller-elx,DNS:poller-elx-t2,DNS:poller.serviceradar,DNS:serviceradar-poller,DNS:localhost,IP:127.0.0.1"
generate_cert "agent" "agent.serviceradar" "DNS:agent,DNS:agent-elx,DNS:agent-elx-t2,DNS:agent.serviceradar,DNS:serviceradar-agent,DNS:poller.serviceradar,DNS:localhost,IP:127.0.0.1"
generate_cert "web" "web.serviceradar" "DNS:web,DNS:web.serviceradar,DNS:serviceradar-web-ng,DNS:web-ng,DNS:serviceradar-web,DNS:localhost,IP:127.0.0.1"
generate_cert "db-event-writer" "db-event-writer.serviceradar" "DNS:db-event-writer,DNS:db-event-writer.serviceradar,DNS:serviceradar-db-event-writer,DNS:localhost,IP:127.0.0.1"

CNPG_SAN="DNS:cnpg,DNS:cnpg-rw,DNS:cnpg.serviceradar,DNS:cnpg-rw.serviceradar,DNS:serviceradar-cnpg,DNS:localhost,IP:127.0.0.1"
if [ -n "${CNPG_CERT_EXTRA_IPS:-}" ]; then
    for ip in $(echo "$CNPG_CERT_EXTRA_IPS" | tr ',' ' '); do
        CNPG_SAN="${CNPG_SAN},IP:${ip}"
    done
fi
generate_cert "cnpg" "cnpg.serviceradar" "${CNPG_SAN}"

# Client cert intended for developers connecting from outside the Docker network
generate_cert "workstation" "workstation.serviceradar" "DNS:workstation,DNS:workstation.serviceradar,DNS:localhost,IP:127.0.0.1"

# Other services
generate_cert "snmp-checker" "snmp-checker.serviceradar" "DNS:snmp-checker,DNS:snmp-checker.serviceradar,DNS:serviceradar-snmp-checker,DNS:agent.serviceradar,DNS:localhost,IP:127.0.0.1"
generate_cert "rperf-client" "rperf-client.serviceradar" "DNS:rperf-client,DNS:rperf-client.serviceradar,DNS:serviceradar-rperf-client,DNS:agent.serviceradar,DNS:localhost,IP:127.0.0.1"
generate_cert "otel" "otel.serviceradar" "DNS:otel,DNS:otel.serviceradar,DNS:serviceradar-otel,DNS:localhost,IP:127.0.0.1"
generate_cert "flowgger" "flowgger.serviceradar" "DNS:flowgger,DNS:flowgger.serviceradar,DNS:serviceradar-flowgger,DNS:localhost,IP:127.0.0.1"

# Edge / checker
generate_cert "sysmon-osx" "sysmon-osx.serviceradar" "DNS:sysmon-osx,DNS:sysmon-osx.serviceradar,DNS:serviceradar-sysmon-osx,DNS:sysmon-osx-checker,DNS:localhost,IP:127.0.0.1"
generate_cert "agent" "agent.serviceradar" "DNS:agent,DNS:agent-elx,DNS:agent-elx-t2,DNS:agent.serviceradar,DNS:serviceradar-agent,DNS:localhost,IP:127.0.0.1"

# Generate JWT secret for authentication
JWT_SECRET_FILE="$CERT_DIR/jwt-secret"
if [ ! -f "$JWT_SECRET_FILE" ]; then
    echo "Generating JWT secret..."
    openssl rand -hex 32 > "$JWT_SECRET_FILE"
    if command -v groupadd >/dev/null 2>&1; then
        chown serviceradar:serviceradar "$JWT_SECRET_FILE"
    fi
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
    if command -v groupadd >/dev/null 2>&1; then
        chown serviceradar:serviceradar "$API_KEY_FILE"
    fi
    chmod 640 "$API_KEY_FILE"
    echo "API key generated."
else
    echo "API key already exists."
fi

echo "All certificates and secrets generated successfully in $CERT_DIR"
echo ""
echo "Files generated:"
ls -la "$CERT_DIR"/*.pem "$CERT_DIR"/jwt-secret "$CERT_DIR"/api-key 2>/dev/null | awk '{print $9}' | sort
