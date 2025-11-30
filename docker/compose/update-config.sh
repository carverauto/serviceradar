#!/bin/sh
# Update configuration files with generated secrets

set -e

random_hex() {
    # $1: number of bytes to read from urandom
    dd if=/dev/urandom bs=1 count="$1" 2>/dev/null \
        | hexdump -v -e '/1 "%02x"'
}

random_base64() {
    # $1: number of raw bytes before base64 encoding
    dd if=/dev/urandom bs=1 count="$1" 2>/dev/null \
        | base64 | tr -d '\n'
}

CERT_DIR="/etc/serviceradar/certs"
CONFIG_DIR="/etc/serviceradar/config"
CORE_CONFIG="$CONFIG_DIR/core.json"
API_ENV="$CONFIG_DIR/api.env"
CHECKERS_DIR="$CONFIG_DIR/checkers"
SYSMON_VM_ADDRESS="${SYSMON_VM_ADDRESS:-192.168.1.219:50110}"
SYSMON_VM_SECURITY_MODE="${SYSMON_VM_SECURITY_MODE:-none}"
CNPG_HOST="${CNPG_HOST:-cnpg}"
CNPG_PORT="${CNPG_PORT:-5432}"
CNPG_DATABASE="${CNPG_DATABASE:-serviceradar}"
CNPG_USERNAME="${CNPG_USERNAME:-serviceradar}"
CNPG_PASSWORD="${CNPG_PASSWORD:-serviceradar}"
CNPG_SSL_MODE="${CNPG_SSL_MODE:-verify-full}"

# Create config directory
mkdir -p "$CONFIG_DIR"
mkdir -p "$CHECKERS_DIR"

echo "Updating ServiceRadar configurations with generated secrets..."

# Seed core.json from template only on first run so we preserve generated keys between restarts
if [ ! -f "$CORE_CONFIG" ]; then
    echo "Seeding core.json from template for the first time..."
    cp /config/core.docker.json "$CORE_CONFIG"
    echo "✅ Created core.json from template"
else
    echo "core.json already exists; preserving existing auth keys and settings"
fi

# Generate JWT secret and API key if they don't exist
if [ ! -f "$CERT_DIR/jwt-secret" ]; then
    echo "Generating JWT secret..."
    random_hex 32 > "$CERT_DIR/jwt-secret"
    echo "✅ Generated JWT secret"
fi

if [ ! -f "$CERT_DIR/api-key" ]; then
    echo "Generating API key..."
    random_hex 32 > "$CERT_DIR/api-key"
    echo "✅ Generated API key"
fi

# Generate admin password bcrypt hash if it doesn't exist
if [ ! -f "$CERT_DIR/admin-password-hash" ]; then
    echo "Generating admin password bcrypt hash..."
    # Generate a random password
    ADMIN_PASSWORD=$(random_base64 12)
    echo "$ADMIN_PASSWORD" > "$CERT_DIR/admin-password"
    
    # Generate bcrypt hash using serviceradar-cli
    ADMIN_PASSWORD_HASH=$(echo "$ADMIN_PASSWORD" | serviceradar-cli)
    echo "$ADMIN_PASSWORD_HASH" > "$CERT_DIR/admin-password-hash"
    echo "✅ Generated admin password: $ADMIN_PASSWORD"
    echo "✅ Generated bcrypt hash for admin password using serviceradar-cli"
    
    # Also write the password to the standard location for user reference
    echo "$ADMIN_PASSWORD" > "$CERT_DIR/password.txt"
    echo "✅ Admin password saved to: $CERT_DIR/password.txt"
fi

# Update core.json with JWT secret and admin password hash if the files exist
if [ -f "$CERT_DIR/jwt-secret" ] && [ -f "$CORE_CONFIG" ]; then
    JWT_SECRET=$(cat "$CERT_DIR/jwt-secret")
    echo "Updating core.json with generated JWT secret..."
    
    # Use jq to update the JWT secret in core.json
    jq --arg jwt_secret "$JWT_SECRET" '.auth.jwt_secret = $jwt_secret' "$CORE_CONFIG" > "$CORE_CONFIG.tmp"
    mv "$CORE_CONFIG.tmp" "$CORE_CONFIG"
    echo "✅ Updated core.json with generated JWT secret"
fi

# Update core.json with admin password hash if it exists
if [ -f "$CERT_DIR/admin-password-hash" ] && [ -f "$CORE_CONFIG" ]; then
    ADMIN_HASH=$(cat "$CERT_DIR/admin-password-hash")
    echo "Updating core.json with generated admin password hash..."
    
    # Use jq to update the admin password hash in core.json
    jq --arg admin_hash "$ADMIN_HASH" '.auth.local_users.admin = $admin_hash' "$CORE_CONFIG" > "$CORE_CONFIG.tmp"
    mv "$CORE_CONFIG.tmp" "$CORE_CONFIG"
    echo "✅ Updated core.json with generated admin password hash"
fi

# Create/update api.env with generated secrets
if [ -f "$CERT_DIR/api-key" ] && [ -f "$CERT_DIR/jwt-secret" ]; then
    API_KEY=$(cat "$CERT_DIR/api-key")
    JWT_SECRET=$(cat "$CERT_DIR/jwt-secret")
    
    echo "Creating api.env with generated secrets..."
    
    # Create api.env
    cat > "$API_ENV" <<EOF
# ServiceRadar API Configuration - Auto-generated
API_KEY=$API_KEY
JWT_SECRET=$JWT_SECRET
AUTH_ENABLED=true
NEXT_INTERNAL_API_URL=http://core:8090
NEXT_INTERNAL_SRQL_URL=http://kong:8000
NEXT_PUBLIC_API_URL=http://localhost
EOF
    
    echo "✅ Created api.env with generated secrets"
fi

# Create a Docker environment file for the core service to use
# This allows docker-compose to inject the generated secrets directly
if [ -f "$CERT_DIR/api-key" ] && [ -f "$CERT_DIR/jwt-secret" ]; then
    API_KEY=$(cat "$CERT_DIR/api-key")
    JWT_SECRET=$(cat "$CERT_DIR/jwt-secret")
    
    echo "Creating .env file for Docker Compose..."
    cat > "$CONFIG_DIR/.env" <<EOF
API_KEY=$API_KEY
JWT_SECRET=$JWT_SECRET
AUTH_ENABLED=true
EOF
    
    echo "✅ Created .env file for Docker Compose"
fi

# Ensure edge onboarding config exists (used by web/CLI issuance)
EDGE_KEY_FILE="$CERT_DIR/edge-onboarding.key"
if [ ! -s "$EDGE_KEY_FILE" ]; then
    EDGE_ONBOARDING_KEY="$(random_base64 32)"
    printf "%s" "$EDGE_ONBOARDING_KEY" > "$EDGE_KEY_FILE"
    echo "✅ Generated edge onboarding encryption key"
fi
EDGE_ONBOARDING_KEY=$(cat "$EDGE_KEY_FILE")

EDGE_DEFAULT_META="{}"
if [ "$SYSMON_VM_SECURITY_MODE" = "mtls" ]; then
    EDGE_DEFAULT_META=$(cat <<EOF
{"security_mode":"mtls","poller_endpoint":"$SYSMON_VM_ADDRESS","core_address":"core:50052","kv_address":"datasvc:50057"}
EOF
)
fi

# Ensure core security configuration matches the desired mode (default: SPIFFE)
CORE_SECURITY_MODE="${CORE_SECURITY_MODE:-spiffe}"
SPIRE_TRUST_DOMAIN_DEFAULT="${SPIRE_TRUST_DOMAIN:-carverauto.dev}"
CORE_TRUST_DOMAIN="${CORE_TRUST_DOMAIN:-$SPIRE_TRUST_DOMAIN_DEFAULT}"
DEFAULT_AGENT_SOCKET="${SPIRE_AGENT_SOCKET:-/run/spire/sockets/agent.sock}"
if printf '%s' "$DEFAULT_AGENT_SOCKET" | grep -q '^unix://'; then
    DEFAULT_CORE_WORKLOAD_SOCKET="$DEFAULT_AGENT_SOCKET"
else
    DEFAULT_CORE_WORKLOAD_SOCKET="unix://$DEFAULT_AGENT_SOCKET"
fi
CORE_WORKLOAD_SOCKET="${CORE_WORKLOAD_SOCKET:-$DEFAULT_CORE_WORKLOAD_SOCKET}"
CORE_SERVER_NAME="${CORE_SERVER_NAME:-core.serviceradar}"

if [ -f "$CORE_CONFIG" ]; then
case "$CORE_SECURITY_MODE" in
    spiffe)
        jq --arg mode "spiffe" \
           --arg td "$CORE_TRUST_DOMAIN" \
           --arg socket "$CORE_WORKLOAD_SOCKET" \
               --arg server "$CORE_SERVER_NAME" \
               '.security.mode = $mode
                | .security.trust_domain = $td
                | .security.workload_socket = $socket
            | .security.server_name = $server
            | .security.role = "core"' \
            "$CORE_CONFIG" > "$CORE_CONFIG.tmp"
        mv "$CORE_CONFIG.tmp" "$CORE_CONFIG"
        echo "✅ Applied SPIFFE security settings to core.json"
        ;;
    mtls)
        jq --arg mode "mtls" \
           --arg cd "$CERT_DIR" \
           --arg server "$CORE_SERVER_NAME" \
           '
           .security.mode = $mode
           | .security.cert_dir = $cd
           | .security.server_name = $server
           | .security.role = "core"
           | del(.security.trust_domain)
           | del(.security.workload_socket)
           ' "$CORE_CONFIG" > "$CORE_CONFIG.tmp"
        mv "$CORE_CONFIG.tmp" "$CORE_CONFIG"
        echo "✅ Applied mTLS security settings to core.json"
        ;;
    *)
        echo "ℹ️  CORE_SECURITY_MODE set to $CORE_SECURITY_MODE; leaving existing security block in place"
        ;;
esac

# Ensure CNPG configuration is present for core (Compose uses local Timescale/Postgres)
if [ -f "$CORE_CONFIG" ]; then
    jq --arg host "$CNPG_HOST" \
       --argjson port "${CNPG_PORT:-5432}" \
       --arg db "$CNPG_DATABASE" \
       --arg user "$CNPG_USERNAME" \
       --arg pwd "$CNPG_PASSWORD" \
       --arg ssl "$CNPG_SSL_MODE" \
       --arg cd "$CERT_DIR" \
       '
       .cnpg = (.cnpg // {})
       | .cnpg.host = $host
       | .cnpg.port = ($port | tonumber)
       | .cnpg.database = $db
       | .cnpg.username = $user
       | .cnpg.password = $pwd
       | .cnpg.ssl_mode = $ssl
       | .cnpg.tls = (if $ssl != "disable" then {
           ca_file: ($cd + "/root.pem"),
           cert_file: ($cd + "/core.pem"),
           key_file: ($cd + "/core-key.pem")
         } else .cnpg.tls end)
       | .database = {
           addresses: [($host + ":" + ($port|tostring))],
           name: $db,
           username: $user,
           password: $pwd,
           max_conns: 10,
           idle_conns: 5,
           tls: {
             ca_file: ($cd + "/root.pem"),
             cert_file: ($cd + "/core.pem"),
             key_file: ($cd + "/core-key.pem"),
             server_name: ($host + ".serviceradar")
           },
           settings: {
             max_execution_time: 60,
             output_format_json_quote_64bit_int: 0,
             allow_experimental_live_view: 1,
             idle_connection_timeout: 600,
             join_use_nulls: 1,
             input_format_defaults_for_omitted_fields: 1
           }
         }
       ' "$CORE_CONFIG" > "$CORE_CONFIG.tmp"
    mv "$CORE_CONFIG.tmp" "$CORE_CONFIG"
    echo "✅ Ensured CNPG config for core.json (host $CNPG_HOST:$CNPG_PORT, ssl_mode $CNPG_SSL_MODE)"
fi

    # Ensure NATS security is set for mTLS compose (core publishes/consumes)
    jq --arg cd "$CERT_DIR" \
       '
       .nats = (.nats // {})
       | .nats.url = (.nats.url // "nats://nats:4222")
       | .nats.domain = (.nats.domain // "")
       | .nats.security = (.nats.security // {
           mode: "mtls",
           cert_dir: $cd,
           role: "core",
           server_name: "nats.serviceradar",
           tls: {
             cert_file: ($cd + "/core.pem"),
             key_file: ($cd + "/core-key.pem"),
             ca_file: ($cd + "/root.pem"),
             client_ca_file: ($cd + "/root.pem")
           }
         })
       ' "$CORE_CONFIG" > "$CORE_CONFIG.tmp"
    mv "$CORE_CONFIG.tmp" "$CORE_CONFIG"
    echo "✅ Applied NATS mTLS settings in core.json"

    # Seed edge_onboarding defaults when missing (enables web/CLI issuance)
    jq --arg key "$EDGE_ONBOARDING_KEY" \
       --arg meta "$EDGE_DEFAULT_META" \
       '
       .edge_onboarding = (.edge_onboarding // {})
       | .edge_onboarding.enabled = true
       | .edge_onboarding.encryption_key = $key
       | .edge_onboarding.default_selectors = (.edge_onboarding.default_selectors // ["unix:uid:0","unix:gid:0","unix:user:root","unix:group:root"])
       | .edge_onboarding.default_metadata = (.edge_onboarding.default_metadata // {})
       | .edge_onboarding.default_metadata.checker = (if $meta != "{}" then ($meta|fromjson) else (.edge_onboarding.default_metadata.checker // {}) end)
       | .edge_onboarding.join_token_ttl = (.edge_onboarding.join_token_ttl // "15m")
       | .edge_onboarding.download_token_ttl = (.edge_onboarding.download_token_ttl // "10m")
       ' "$CORE_CONFIG" > "$CORE_CONFIG.tmp"
    mv "$CORE_CONFIG.tmp" "$CORE_CONFIG"
    echo "✅ Ensured edge_onboarding config with mTLS defaults"
fi

# Display important setup information to the user
if [ -f "$CERT_DIR/admin-password" ]; then
    ADMIN_PASSWORD=$(cat "$CERT_DIR/admin-password")
    echo ""
    echo "🔐 IMPORTANT: ServiceRadar Admin Credentials"
    echo "============================================="
    echo "Username: admin"
    echo "Password: $ADMIN_PASSWORD"
    echo ""
    echo "📁 Password Location: /etc/serviceradar/certs/password.txt"
    echo ""
    echo "⚠️  SECURITY NOTICE:"
    echo "   • Please save this password in a secure location"
    echo "   • Delete the password.txt file after saving: rm /etc/serviceradar/certs/password.txt"
    echo "   • You can change this password using the ServiceRadar CLI"
    echo ""
    echo "🔧 To change your admin password:"
    echo "   1. Generate a new bcrypt hash: echo 'your-new-password' | serviceradar-cli"
    echo "   2. Update core.json: serviceradar-cli update-config -file=/path/to/core.json -admin-hash=<new-hash>"
    echo "   3. Restart the core service: docker-compose restart core"
    echo ""
fi

# Note: We do NOT copy generated secrets back to host to avoid
# persisting sensitive data to the source tree. The generated
# configurations are only used within the running containers.

echo "🎉 Configuration update complete!"

# Generate sysmon-vm checker configuration with runtime overrides
SYSMON_VM_CERT_FILE="${SYSMON_VM_CERT_FILE:-sysmon-vm.pem}"
SYSMON_VM_KEY_FILE="${SYSMON_VM_KEY_FILE:-sysmon-vm-key.pem}"
SYSMON_VM_CA_FILE="${SYSMON_VM_CA_FILE:-root.pem}"

if [ "$SYSMON_VM_SECURITY_MODE" = "mtls" ]; then
    cat > "$CHECKERS_DIR/sysmon-vm.json" <<EOF
{
  "name": "sysmon-vm",
  "type": "grpc",
  "address": "$SYSMON_VM_ADDRESS",
  "security": {
    "mode": "mtls",
    "role": "checker",
    "cert_dir": "/etc/serviceradar/certs",
    "server_name": "sysmon-vm.serviceradar",
    "tls": {
      "cert_file": "$SYSMON_VM_CERT_FILE",
      "key_file": "$SYSMON_VM_KEY_FILE",
      "ca_file": "$SYSMON_VM_CA_FILE",
      "client_ca_file": "$SYSMON_VM_CA_FILE"
    }
  }
}
EOF
    echo "✅ Generated sysmon-vm checker config (mTLS) with address $SYSMON_VM_ADDRESS"
else
    cat > "$CHECKERS_DIR/sysmon-vm.json" <<EOF
{
  "name": "sysmon-vm",
  "type": "grpc",
  "address": "$SYSMON_VM_ADDRESS",
  "security": {
    "mode": "none",
    "role": "agent"
  }
}
EOF
    echo "✅ Generated sysmon-vm checker config (no security) with address $SYSMON_VM_ADDRESS"
fi

POLLERS_SECURITY_MODE="${POLLERS_SECURITY_MODE:-mtls}"
POLLERS_TRUST_DOMAIN="${POLLERS_TRUST_DOMAIN:-carverauto.dev}"
POLLERS_AGENT_SPIFFE_ID="${POLLERS_AGENT_SPIFFE_ID:-spiffe://$POLLERS_TRUST_DOMAIN/services/agent}"
POLLERS_CORE_SPIFFE_ID="${POLLERS_CORE_SPIFFE_ID:-spiffe://$POLLERS_TRUST_DOMAIN/services/core}"
POLLERS_WORKLOAD_SOCKET="${POLLERS_WORKLOAD_SOCKET:-unix:/run/spire/sockets/agent.sock}"
POLLERS_SPIRE_CONFIG_DIR="${POLLERS_SPIRE_CONFIG_DIR:-$CONFIG_DIR/poller-spire}"
POLLERS_SPIRE_UPSTREAM_ADDRESS="${POLLERS_SPIRE_UPSTREAM_ADDRESS:-spire-server}"
POLLERS_SPIRE_UPSTREAM_PORT="${POLLERS_SPIRE_UPSTREAM_PORT:-8081}"
POLLERS_SPIRE_UPSTREAM_SOCKET_PATH="${POLLERS_SPIRE_UPSTREAM_SOCKET_PATH:-/run/spire/nested/upstream/agent.sock}"
POLLERS_SPIRE_DOWNSTREAM_PORT="${POLLERS_SPIRE_DOWNSTREAM_PORT:-8083}"
POLLERS_SPIRE_DOWNSTREAM_SOCKET_PATH="${POLLERS_SPIRE_DOWNSTREAM_SOCKET_PATH:-/run/spire/nested/server/api.sock}"
POLLERS_SPIRE_WORKLOAD_SOCKET_PATH="${POLLERS_SPIRE_WORKLOAD_SOCKET_PATH:-/run/spire/nested/workload/agent.sock}"
POLLERS_SPIRE_INSECURE_BOOTSTRAP="${POLLERS_SPIRE_INSECURE_BOOTSTRAP:-true}"
POLLERS_SPIRE_SERVER_BIND_ADDRESS="${POLLERS_SPIRE_SERVER_BIND_ADDRESS:-0.0.0.0}"
POLLERS_SPIRE_CA_COMMON_NAME="${POLLERS_SPIRE_CA_COMMON_NAME:-$POLLERS_TRUST_DOMAIN}"
POLLERS_SPIRE_PARENT_ID="${POLLERS_SPIRE_PARENT_ID:-spiffe://$POLLERS_TRUST_DOMAIN/ns/edge/poller-nested-spire}"
POLLERS_SPIRE_DOWNSTREAM_SPIFFE_ID="${POLLERS_SPIRE_DOWNSTREAM_SPIFFE_ID:-spiffe://$POLLERS_TRUST_DOMAIN/services/poller}"
POLLERS_SPIRE_SQLITE_PATH="${POLLERS_SPIRE_SQLITE_PATH:-/run/spire/nested/server/datastore.sqlite3}"
POLLERS_SPIRE_SERVER_KEYS_PATH="${POLLERS_SPIRE_SERVER_KEYS_PATH:-/run/spire/nested/server/keys.json}"
POLLERS_SPIRE_SERVER_SOCKET="${POLLERS_SPIRE_SERVER_SOCKET:-/run/spire/nested/server/api.sock}"

# Prepare poller configuration with sysmon-vm override
POLLERS_TEMPLATE="/templates/poller.docker.json"
if [ "$POLLERS_SECURITY_MODE" = "spiffe" ] && [ -f /templates/poller.spiffe.json ]; then
    POLLERS_TEMPLATE="/templates/poller.spiffe.json"
elif [ "$POLLERS_SECURITY_MODE" != "spiffe" ] && [ -f /templates/poller.docker.json.orig ]; then
    POLLERS_TEMPLATE="/templates/poller.docker.json.orig"
fi

if [ "$POLLERS_SECURITY_MODE" = "spiffe" ]; then
    cp "$POLLERS_TEMPLATE" "$CONFIG_DIR/poller.json"
    jq --arg addr "$SYSMON_VM_ADDRESS" \
       --arg td "$POLLERS_TRUST_DOMAIN" \
       --arg agentId "$POLLERS_AGENT_SPIFFE_ID" \
       --arg coreId "$POLLERS_CORE_SPIFFE_ID" \
       --arg socket "$POLLERS_WORKLOAD_SOCKET" '
        (.agents[]?.security.trust_domain) = $td
        | (.agents[]?.security.server_spiffe_id) = $agentId
        | (.agents[]?.security.workload_socket) = $socket
        | (.security.trust_domain) = $td
        | (.security.server_spiffe_id) = $coreId
        | (.security.workload_socket) = $socket
        | (.agents[]?.checks[]? | select(.service_name == "sysmon-vm")).details = $addr
    ' "$CONFIG_DIR/poller.json" > "$CONFIG_DIR/poller.json.tmp"
    mv "$CONFIG_DIR/poller.json.tmp" "$CONFIG_DIR/poller.json"
    echo "✅ Generated poller.json (SPIFFE mode) with sysmon-vm address $SYSMON_VM_ADDRESS"
    mkdir -p "$POLLERS_SPIRE_CONFIG_DIR"
    cat > "$POLLERS_SPIRE_CONFIG_DIR/upstream-agent.conf" <<EOF
agent {
  data_dir = "/run/spire/nested/upstream-agent"
  log_level = "INFO"
  trust_domain = "$POLLERS_TRUST_DOMAIN"
  server_address = "$POLLERS_SPIRE_UPSTREAM_ADDRESS"
  server_port = "$POLLERS_SPIRE_UPSTREAM_PORT"
  socket_path = "$POLLERS_SPIRE_UPSTREAM_SOCKET_PATH"
  insecure_bootstrap = $POLLERS_SPIRE_INSECURE_BOOTSTRAP
  retry_bootstrap = true
}

plugins {
  NodeAttestor "join_token" {
    plugin_data {}
  }

  KeyManager "memory" {
    plugin_data {}
  }

  WorkloadAttestor "unix" {
    plugin_data {}
  }
}

health_checks {
  listener_enabled = true
  bind_address = "0.0.0.0"
  bind_port = "18080"
  live_path = "/live"
  ready_path = "/ready"
}
EOF

    cat > "$POLLERS_SPIRE_CONFIG_DIR/server.conf" <<EOF
server {
  bind_address = "$POLLERS_SPIRE_SERVER_BIND_ADDRESS"
  bind_port = "$POLLERS_SPIRE_DOWNSTREAM_PORT"
  socket_path = "$POLLERS_SPIRE_SERVER_SOCKET"
  trust_domain = "$POLLERS_TRUST_DOMAIN"
  data_dir = "/run/spire/nested/server"
  log_level = "INFO"
  ca_key_type = "rsa-2048"
  admin_ids = ["$POLLERS_CORE_SPIFFE_ID"]

  ca_subject = {
    country = ["US"],
    organization = ["Carver Automation Corporation"],
    common_name = "$POLLERS_SPIRE_CA_COMMON_NAME",
  }
}

plugins {
  DataStore "sql" {
    plugin_data {
      database_type = "sqlite3"
      connection_string = "$POLLERS_SPIRE_SQLITE_PATH"
    }
  }

  KeyManager "disk" {
    plugin_data {
      keys_path = "$POLLERS_SPIRE_SERVER_KEYS_PATH"
    }
  }

  NodeAttestor "join_token" {
    plugin_data {}
  }

  UpstreamAuthority "spire" {
    plugin_data {
      server_address = "$POLLERS_SPIRE_UPSTREAM_ADDRESS"
      server_port = "$POLLERS_SPIRE_UPSTREAM_PORT"
      workload_api_socket = "$POLLERS_SPIRE_UPSTREAM_SOCKET_PATH"
    }
  }
}

health_checks {
  listener_enabled = true
  bind_address = "0.0.0.0"
  bind_port = "18082"
  live_path = "/live"
  ready_path = "/ready"
}
EOF

    cat > "$POLLERS_SPIRE_CONFIG_DIR/downstream-agent.conf" <<EOF
agent {
  data_dir = "/run/spire/nested/downstream-agent"
  log_level = "INFO"
  trust_domain = "$POLLERS_TRUST_DOMAIN"
  server_address = "127.0.0.1"
  server_port = "$POLLERS_SPIRE_DOWNSTREAM_PORT"
  socket_path = "$POLLERS_SPIRE_WORKLOAD_SOCKET_PATH"
  insecure_bootstrap = true
  retry_bootstrap = true
}

plugins {
  NodeAttestor "join_token" {
    plugin_data {}
  }

  KeyManager "memory" {
    plugin_data {}
  }

  WorkloadAttestor "unix" {
    plugin_data {}
  }
}

health_checks {
  listener_enabled = true
  bind_address = "0.0.0.0"
  bind_port = "18081"
  live_path = "/live"
  ready_path = "/ready"
}
EOF
    cat > "$POLLERS_SPIRE_CONFIG_DIR/env" <<EOF
POLLERS_TRUST_DOMAIN="$POLLERS_TRUST_DOMAIN"
NESTED_SPIRE_PARENT_ID="$POLLERS_SPIRE_PARENT_ID"
NESTED_SPIRE_DOWNSTREAM_SPIFFE_ID="$POLLERS_SPIRE_DOWNSTREAM_SPIFFE_ID"
NESTED_SPIRE_SERVER_SOCKET="$POLLERS_SPIRE_SERVER_SOCKET"
EOF
    echo "✅ Generated nested SPIRE configuration under $POLLERS_SPIRE_CONFIG_DIR"
elif [ -f "$POLLERS_TEMPLATE" ]; then
    cp "$POLLERS_TEMPLATE" "$CONFIG_DIR/poller.json"
    jq --arg addr "$SYSMON_VM_ADDRESS" '
        (.agents[]?.checks[]? | select(.service_name == "sysmon-vm")).details = $addr
    ' "$CONFIG_DIR/poller.json" > "$CONFIG_DIR/poller.json.tmp"
    mv "$CONFIG_DIR/poller.json.tmp" "$CONFIG_DIR/poller.json"
    echo "✅ Generated poller.json with sysmon-vm address $SYSMON_VM_ADDRESS (security mode: ${POLLERS_SECURITY_MODE:-mtls})"
fi
