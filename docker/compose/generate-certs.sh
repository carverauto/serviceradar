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
COMPONENT_DAYS_VALID=365   # 1 year for edge component certs
COUNTRY="US"
STATE="CA"
LOCALITY="San Francisco"
ORGANIZATION="ServiceRadar"
ORG_UNIT="Docker"

DEFAULT_PARTITION_ID="${DEFAULT_PARTITION_ID:-default}"

read_trimmed_file() {
    local path="$1"
    if [ -f "$path" ]; then
        tr -d '\r\n' < "$path"
    fi
}

# Create certificate directory
mkdir -p "$CERT_DIR"
mkdir -p "$CERT_DIR/components"

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

# Function to generate an edge component certificate
# Usage: generate_component_cert <component_type> <component_id> <partition_id> [extra_san]
# CN format: <component_id>.<partition_id>.serviceradar
generate_component_cert() {
    local component_type=$1
    local component_id=$2
    local partition_id=$3
    local extra_san="${4:-}"

    local component_dir="$CERT_DIR/components"
    local cert_name="${component_id}-${partition_id}"

    mkdir -p "$component_dir"

    if [ -f "$component_dir/$cert_name.pem" ]; then
        echo "Component certificate $cert_name already exists."
        return
    fi

    echo "Generating component certificate: $component_id.$partition_id.serviceradar"

    local cn="${component_id}.${partition_id}.serviceradar"
    local spiffe_id="spiffe://serviceradar.local/${component_type}/${partition_id}/${component_id}"

    # Build SAN list
    local san="DNS:$cn,DNS:${component_id}.serviceradar,DNS:localhost,IP:127.0.0.1,URI:$spiffe_id"
    if [ -n "$extra_san" ]; then
        san="${san},${extra_san}"
    fi

    # Generate private key
    openssl genrsa -out "$component_dir/$cert_name-key.pem" 2048

    # Create config
    cat > "$component_dir/$cert_name.conf" <<EOF
[req]
distinguished_name = req_distinguished_name
req_extensions = v3_req
prompt = no

[req_distinguished_name]
C = $COUNTRY
ST = $STATE
L = $LOCALITY
O = $ORGANIZATION
OU = Edge
CN = $cn

[v3_req]
basicConstraints = CA:FALSE
keyUsage = keyEncipherment, dataEncipherment, digitalSignature
extendedKeyUsage = serverAuth, clientAuth
subjectAltName = $san
EOF

    # Generate CSR
    openssl req -new -sha256 -key "$component_dir/$cert_name-key.pem" \
        -out "$component_dir/$cert_name.csr" -config "$component_dir/$cert_name.conf"

    # Sign with root CA
    openssl x509 -req -in "$component_dir/$cert_name.csr" -CA "$CERT_DIR/root.pem" \
        -CAkey "$CERT_DIR/root-key.pem" -CAcreateserial -out "$component_dir/$cert_name.pem" \
        -days $COMPONENT_DAYS_VALID -sha256 -extensions v3_req -extfile "$component_dir/$cert_name.conf"

    # Create full chain (component cert + root CA)
    cat "$component_dir/$cert_name.pem" "$CERT_DIR/root.pem" > "$component_dir/$cert_name-chain.pem"

    # Clean up
    rm "$component_dir/$cert_name.csr" "$component_dir/$cert_name.conf"

    # Set permissions
    chmod 644 "$component_dir/$cert_name.pem" "$component_dir/$cert_name-chain.pem"
    chmod 600 "$component_dir/$cert_name-key.pem"

    echo "Component certificate generated: $component_dir/$cert_name.pem"
}

# Function to generate certificate for a component (platform services, signed by root CA)
generate_cert() {
    local component=$1
    local cn=$2
    local san=$3
    local required_dns=""
    local existing_cn=""
    
    if [ -f "$CERT_DIR/$component.pem" ]; then
        existing_cn="$(openssl x509 -in "$CERT_DIR/$component.pem" -noout -subject -nameopt RFC2253 | sed -n 's/^subject=.*CN=\([^,]*\).*$/\1/p')"
        if [ -n "$existing_cn" ] && [ "$existing_cn" != "$cn" ]; then
            echo "Certificate for $component has CN ${existing_cn}, expected ${cn}; regenerating..."
            rm -f "$CERT_DIR/$component.pem" "$CERT_DIR/$component-key.pem"
        fi

        if [ -f "$CERT_DIR/$component.pem" ] && [ "$component" = "cnpg" ] && [ -n "${CNPG_CERT_EXTRA_IPS:-}" ]; then
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
        elif [ "$component" = "agent" ]; then
            required_dns="agent-elx-t2"
        fi

        if [ -f "$CERT_DIR/$component.pem" ] && [ -n "$required_dns" ]; then
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
generate_cert "core" "core.serviceradar" "DNS:core,DNS:core-elx,DNS:core.serviceradar,DNS:serviceradar-core,DNS:agent-gateway.serviceradar,DNS:agent.serviceradar,DNS:web.serviceradar,DNS:localhost,IP:127.0.0.1"

# NATS - messaging backbone, many services connect to it
generate_cert "nats" "nats.serviceradar" "DNS:nats,DNS:nats.serviceradar,DNS:serviceradar-nats,DNS:datasvc.serviceradar,DNS:zen.serviceradar,DNS:trapd.serviceradar,DNS:log-collector.serviceradar,DNS:db-event-writer.serviceradar,DNS:localhost,IP:127.0.0.1"

# Services that agent connects to
generate_cert "datasvc" "datasvc.serviceradar" "DNS:datasvc,DNS:datasvc.serviceradar,DNS:serviceradar-datasvc,DNS:agent.serviceradar,DNS:zen.serviceradar,DNS:core.serviceradar,DNS:localhost,IP:127.0.0.1"
generate_cert "zen" "zen.serviceradar" "DNS:zen,DNS:zen.serviceradar,DNS:serviceradar-zen,DNS:agent.serviceradar,DNS:agent-gateway.serviceradar,DNS:localhost,IP:127.0.0.1"
generate_cert "trapd" "trapd.serviceradar" "DNS:trapd,DNS:trapd.serviceradar,DNS:serviceradar-trapd,DNS:agent.serviceradar,DNS:agent-gateway.serviceradar,DNS:localhost,IP:127.0.0.1"
# Services that are clients to others
generate_cert "gateway" "agent-gateway.serviceradar" "DNS:gateway,DNS:agent-gateway,DNS:agent-gateway-t2,DNS:agent-gateway.serviceradar,DNS:serviceradar-agent-gateway,DNS:localhost,IP:127.0.0.1"
generate_cert "agent" "agent.serviceradar" "DNS:agent,DNS:agent-elx,DNS:agent-elx-t2,DNS:agent.serviceradar,DNS:serviceradar-agent,DNS:agent-gateway.serviceradar,DNS:localhost,IP:127.0.0.1"
generate_cert "web" "web.serviceradar" "DNS:web,DNS:web.serviceradar,DNS:serviceradar-web-ng,DNS:web-ng,DNS:serviceradar-web,DNS:localhost,IP:127.0.0.1"
generate_cert "db-event-writer" "db-event-writer.serviceradar" "DNS:db-event-writer,DNS:db-event-writer.serviceradar,DNS:serviceradar-db-event-writer,DNS:localhost,IP:127.0.0.1"
CNPG_SAN="DNS:cnpg,DNS:cnpg-rw,DNS:cnpg.serviceradar,DNS:cnpg-rw.serviceradar,DNS:serviceradar-cnpg,DNS:localhost,IP:127.0.0.1"
if [ -n "${CNPG_CERT_EXTRA_IPS:-}" ]; then
    for ip in $(echo "$CNPG_CERT_EXTRA_IPS" | tr ',' ' '); do
        CNPG_SAN="${CNPG_SAN},IP:${ip}"
    done
fi
generate_cert "cnpg" "cnpg.serviceradar" "${CNPG_SAN}"

# Client cert for DB auth (CN must match DB username)
generate_cert "db-client" "serviceradar" "DNS:serviceradar,DNS:localhost,IP:127.0.0.1"

# Client cert for DB superuser tasks (CN must match DB username)
DB_SUPERUSER="${CNPG_SUPERUSER:-}"
if [ -z "$DB_SUPERUSER" ] && [ -n "${CNPG_SUPERUSER_FILE:-}" ]; then
    DB_SUPERUSER="$(read_trimmed_file "$CNPG_SUPERUSER_FILE")"
fi
DB_SUPERUSER="${DB_SUPERUSER:-postgres}"
generate_cert "db-superuser" "$DB_SUPERUSER" "DNS:${DB_SUPERUSER},DNS:localhost,IP:127.0.0.1"

# Client cert intended for developers connecting from outside the Docker network
generate_cert "workstation" "workstation.serviceradar" "DNS:workstation,DNS:workstation.serviceradar,DNS:localhost,IP:127.0.0.1"

# Other services
generate_cert "rperf-client" "rperf-client.serviceradar" "DNS:rperf-client,DNS:rperf-client.serviceradar,DNS:serviceradar-rperf-client,DNS:agent.serviceradar,DNS:localhost,IP:127.0.0.1"
generate_cert "log-collector" "log-collector.serviceradar" "DNS:log-collector,DNS:log-collector.serviceradar,DNS:serviceradar-log-collector,DNS:localhost,IP:127.0.0.1"
generate_cert "flow-collector" "flow-collector.serviceradar" "DNS:flow-collector,DNS:flow-collector.serviceradar,DNS:serviceradar-flow-collector,DNS:localhost,IP:127.0.0.1"
generate_cert "bmp-collector" "bmp-collector.serviceradar" "DNS:bmp-collector,DNS:bmp-collector.serviceradar,DNS:serviceradar-bmp-collector,DNS:localhost,IP:127.0.0.1"

# Alias flow client cert names for collector defaults.
if [ -f "$CERT_DIR/flow-collector.pem" ] && [ -f "$CERT_DIR/flow-collector-key.pem" ]; then
    if [ ! -f "$CERT_DIR/flow-client.crt" ]; then
        cp "$CERT_DIR/flow-collector.pem" "$CERT_DIR/flow-client.crt"
        chmod 644 "$CERT_DIR/flow-client.crt"
    fi
    if [ ! -f "$CERT_DIR/flow-client.key" ]; then
        cp "$CERT_DIR/flow-collector-key.pem" "$CERT_DIR/flow-client.key"
        chmod 600 "$CERT_DIR/flow-client.key"
    fi
fi
if [ -f "$CERT_DIR/flow-collector.pem" ] && [ ! -f "$CERT_DIR/netflow-collector.pem" ]; then
    cp "$CERT_DIR/flow-collector.pem" "$CERT_DIR/netflow-collector.pem"
    chmod 644 "$CERT_DIR/netflow-collector.pem"
fi
if [ -f "$CERT_DIR/flow-collector-key.pem" ] && [ ! -f "$CERT_DIR/netflow-collector-key.pem" ]; then
    cp "$CERT_DIR/flow-collector-key.pem" "$CERT_DIR/netflow-collector-key.pem"
    chmod 600 "$CERT_DIR/netflow-collector-key.pem"
fi
if [ -f "$CERT_DIR/log-collector.pem" ] && [ ! -f "$CERT_DIR/flowgger.pem" ]; then
    cp "$CERT_DIR/log-collector.pem" "$CERT_DIR/flowgger.pem"
    chmod 644 "$CERT_DIR/flowgger.pem"
fi
if [ -f "$CERT_DIR/log-collector-key.pem" ] && [ ! -f "$CERT_DIR/flowgger-key.pem" ]; then
    cp "$CERT_DIR/log-collector-key.pem" "$CERT_DIR/flowgger-key.pem"
    chmod 600 "$CERT_DIR/flowgger-key.pem"
fi
if [ -f "$CERT_DIR/log-collector.pem" ] && [ ! -f "$CERT_DIR/otel.pem" ]; then
    cp "$CERT_DIR/log-collector.pem" "$CERT_DIR/otel.pem"
    chmod 644 "$CERT_DIR/otel.pem"
fi
if [ -f "$CERT_DIR/log-collector-key.pem" ] && [ ! -f "$CERT_DIR/otel-key.pem" ]; then
    cp "$CERT_DIR/log-collector-key.pem" "$CERT_DIR/otel-key.pem"
    chmod 600 "$CERT_DIR/otel-key.pem"
fi
if [ -f "$CERT_DIR/root.pem" ] && [ ! -f "$CERT_DIR/ca.crt" ]; then
    cp "$CERT_DIR/root.pem" "$CERT_DIR/ca.crt"
    chmod 644 "$CERT_DIR/ca.crt"
fi

# Edge / checker
generate_cert "sysmon-osx" "sysmon-osx.serviceradar" "DNS:sysmon-osx,DNS:sysmon-osx.serviceradar,DNS:serviceradar-sysmon-osx,DNS:sysmon-osx-checker,DNS:localhost,IP:127.0.0.1"
generate_cert "agent" "agent.serviceradar" "DNS:agent,DNS:agent-elx,DNS:agent-elx-t2,DNS:agent.serviceradar,DNS:serviceradar-agent,DNS:localhost,IP:127.0.0.1"

# Generate example edge component certificates for development
echo ""
echo "=== Generating edge component certificates ==="

# Default agent
generate_component_cert "agent" "agent-001" "$DEFAULT_PARTITION_ID" "DNS:agent,DNS:agent-elx,DNS:agent-elx-t2"

# Docker Compose dev agent (matches docker/compose/agent.mtls.json)
generate_component_cert "agent" "docker-agent" "$DEFAULT_PARTITION_ID" "DNS:agent,DNS:agent-elx,DNS:agent-elx-t2"

echo ""
echo "All certificates generated successfully in $CERT_DIR"
echo ""
echo "Platform certificates:"
ls -la "$CERT_DIR"/*.pem 2>/dev/null | awk '{print $9}' | sort

echo ""
echo "Component certificates:"
find "$CERT_DIR/components" -name "*.pem" -not -name "*-key.pem" -not -name "*-chain.pem" 2>/dev/null | sort
