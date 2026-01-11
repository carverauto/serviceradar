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
TENANT_CA_DAYS_VALID=3650  # 10 years for tenant CAs
COMPONENT_DAYS_VALID=365   # 1 year for edge component certs
COUNTRY="US"
STATE="CA"
LOCALITY="San Francisco"
ORGANIZATION="ServiceRadar"
ORG_UNIT="Docker"

# Default tenant for development (creates a "default" tenant CA)
DEFAULT_TENANT_SLUG="${DEFAULT_TENANT_SLUG:-default}"
DEFAULT_PARTITION_ID="${DEFAULT_PARTITION_ID:-default}"

# Create certificate directory
mkdir -p "$CERT_DIR"
mkdir -p "$CERT_DIR/tenants"

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

# Function to generate a tenant intermediate CA
# Usage: generate_tenant_ca <tenant_slug>
generate_tenant_ca() {
    local tenant_slug=$1
    local tenant_ca_dir="$CERT_DIR/tenants/$tenant_slug"

    mkdir -p "$tenant_ca_dir"

    if [ -f "$tenant_ca_dir/ca.pem" ]; then
        echo "Tenant CA for $tenant_slug already exists."
        return
    fi

    echo "Generating tenant intermediate CA for $tenant_slug..."

    local cn="tenant-${tenant_slug}.ca.serviceradar"

    # Generate CA private key
    openssl genrsa -out "$tenant_ca_dir/ca-key.pem" 4096

    # Create CA config
    cat > "$tenant_ca_dir/ca.conf" <<EOF
[req]
distinguished_name = req_distinguished_name
req_extensions = v3_ca
prompt = no

[req_distinguished_name]
C = $COUNTRY
ST = $STATE
L = $LOCALITY
O = $ORGANIZATION
OU = Tenant-$tenant_slug
CN = $cn

[v3_ca]
basicConstraints = critical, CA:TRUE, pathlen:0
keyUsage = critical, keyCertSign, cRLSign
subjectKeyIdentifier = hash
EOF

    # Generate CSR
    openssl req -new -sha256 -key "$tenant_ca_dir/ca-key.pem" \
        -out "$tenant_ca_dir/ca.csr" -config "$tenant_ca_dir/ca.conf"

    # Sign with root CA (intermediate CA)
    openssl x509 -req -in "$tenant_ca_dir/ca.csr" -CA "$CERT_DIR/root.pem" \
        -CAkey "$CERT_DIR/root-key.pem" -CAcreateserial -out "$tenant_ca_dir/ca.pem" \
        -days $TENANT_CA_DAYS_VALID -sha256 -extensions v3_ca -extfile "$tenant_ca_dir/ca.conf"

    # Create CA chain (tenant CA + root CA)
    cat "$tenant_ca_dir/ca.pem" "$CERT_DIR/root.pem" > "$tenant_ca_dir/ca-chain.pem"

    # Clean up
    rm "$tenant_ca_dir/ca.csr" "$tenant_ca_dir/ca.conf"

    # Set permissions
    chmod 644 "$tenant_ca_dir/ca.pem" "$tenant_ca_dir/ca-chain.pem"
    chmod 600 "$tenant_ca_dir/ca-key.pem"

    echo "Tenant CA for $tenant_slug generated: $tenant_ca_dir/ca.pem"
}

# Function to generate a tenant-scoped component certificate
# Usage: generate_tenant_component_cert <tenant_slug> <component_id> <partition_id> [extra_san]
# CN format: <component_id>.<partition_id>.<tenant_slug>.serviceradar
generate_tenant_component_cert() {
    local tenant_slug=$1
    local component_id=$2
    local partition_id=$3
    local extra_san="${4:-}"

    local tenant_ca_dir="$CERT_DIR/tenants/$tenant_slug"
    local component_dir="$tenant_ca_dir/components"
    local cert_name="${component_id}-${partition_id}"

    # Ensure tenant CA exists
    if [ ! -f "$tenant_ca_dir/ca.pem" ]; then
        echo "Error: Tenant CA for $tenant_slug does not exist. Generate it first."
        return 1
    fi

    mkdir -p "$component_dir"

    if [ -f "$component_dir/$cert_name.pem" ]; then
        echo "Component certificate $cert_name for $tenant_slug already exists."
        return
    fi

    echo "Generating component certificate: $component_id.$partition_id.$tenant_slug.serviceradar"

    local cn="${component_id}.${partition_id}.${tenant_slug}.serviceradar"
    local spiffe_id="spiffe://serviceradar.local/${component_id}/${tenant_slug}/${partition_id}"

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
OU = Tenant-$tenant_slug
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

    # Sign with tenant CA
    openssl x509 -req -in "$component_dir/$cert_name.csr" -CA "$tenant_ca_dir/ca.pem" \
        -CAkey "$tenant_ca_dir/ca-key.pem" -CAcreateserial -out "$component_dir/$cert_name.pem" \
        -days $COMPONENT_DAYS_VALID -sha256 -extensions v3_req -extfile "$component_dir/$cert_name.conf"

    # Create full chain (component cert + tenant CA + root CA)
    cat "$component_dir/$cert_name.pem" "$tenant_ca_dir/ca-chain.pem" > "$component_dir/$cert_name-chain.pem"

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
generate_cert "core" "core.serviceradar" "DNS:core,DNS:core-elx,DNS:core.serviceradar,DNS:serviceradar-core,DNS:agent-gateway.serviceradar,DNS:agent.serviceradar,DNS:web.serviceradar,DNS:localhost,IP:127.0.0.1"

# NATS - messaging backbone, many services connect to it
generate_cert "nats" "nats.serviceradar" "DNS:nats,DNS:nats.serviceradar,DNS:serviceradar-nats,DNS:datasvc.serviceradar,DNS:zen.serviceradar,DNS:trapd.serviceradar,DNS:flowgger.serviceradar,DNS:otel.serviceradar,DNS:db-event-writer.serviceradar,DNS:localhost,IP:127.0.0.1"

# Services that agent connects to
generate_cert "datasvc" "datasvc.serviceradar" "DNS:datasvc,DNS:datasvc.serviceradar,DNS:serviceradar-datasvc,DNS:agent.serviceradar,DNS:zen.serviceradar,DNS:core.serviceradar,DNS:localhost,IP:127.0.0.1"
generate_cert "zen" "zen.serviceradar" "DNS:zen,DNS:zen.serviceradar,DNS:serviceradar-zen,DNS:agent.serviceradar,DNS:agent-gateway.serviceradar,DNS:localhost,IP:127.0.0.1"
generate_cert "trapd" "trapd.serviceradar" "DNS:trapd,DNS:trapd.serviceradar,DNS:serviceradar-trapd,DNS:agent.serviceradar,DNS:agent-gateway.serviceradar,DNS:localhost,IP:127.0.0.1"
generate_cert "mapper" "mapper.serviceradar" "DNS:mapper,DNS:mapper.serviceradar,DNS:serviceradar-mapper,DNS:agent.serviceradar,DNS:agent-gateway.serviceradar,DNS:localhost,IP:127.0.0.1"

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

# Generate default tenant CA for local development
echo ""
echo "=== Generating tenant CAs ==="
generate_tenant_ca "$DEFAULT_TENANT_SLUG"

# Generate example tenant-scoped edge component certificates for development
# These follow the CN format: <component>.<partition>.<tenant>.serviceradar
echo ""
echo "=== Generating tenant-scoped component certificates ==="

# Default tenant agent
generate_tenant_component_cert "$DEFAULT_TENANT_SLUG" "agent-001" "$DEFAULT_PARTITION_ID" "DNS:agent,DNS:agent-elx,DNS:agent-elx-t2"

# Docker Compose dev agent (matches docker/compose/agent.mtls.json)
generate_tenant_component_cert "$DEFAULT_TENANT_SLUG" "docker-agent" "$DEFAULT_PARTITION_ID" "DNS:agent,DNS:agent-elx,DNS:agent-elx-t2"

# Support multi-tenant testing with a second tenant
if [ "${ENABLE_MULTI_TENANT:-false}" = "true" ]; then
    echo ""
    echo "=== Multi-tenant mode enabled, generating additional tenant ==="
    generate_tenant_ca "acme-corp"
    generate_tenant_component_cert "acme-corp" "agent-001" "partition-1" "DNS:agent"
fi

echo ""
echo "All certificates and secrets generated successfully in $CERT_DIR"
echo ""
echo "Platform certificates:"
ls -la "$CERT_DIR"/*.pem "$CERT_DIR"/jwt-secret "$CERT_DIR"/api-key 2>/dev/null | awk '{print $9}' | sort

echo ""
echo "Tenant CAs:"
find "$CERT_DIR/tenants" -name "ca.pem" 2>/dev/null | sort

echo ""
echo "Tenant component certificates:"
find "$CERT_DIR/tenants" -path "*/components/*.pem" -not -name "*-key.pem" -not -name "*-chain.pem" 2>/dev/null | sort
