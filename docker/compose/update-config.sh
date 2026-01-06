#!/bin/sh
# Update configuration files with generated secrets

set -e

is_truthy() {
    case "${1:-}" in
        1|true|TRUE|yes|YES|y|Y|on|ON) return 0 ;;
        *) return 1 ;;
    esac
}

warn() {
    printf '%s\n' "⚠️  $*" >&2
}

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
FORCE_REGENERATE_CONFIG="${FORCE_REGENERATE_CONFIG:-false}"
EDGE_DEFAULT_CHECKER_ENDPOINT="${EDGE_DEFAULT_CHECKER_ENDPOINT:-}"
EDGE_DEFAULT_CHECKER_SECURITY_MODE="${EDGE_DEFAULT_CHECKER_SECURITY_MODE:-}"
CNPG_HOST="${CNPG_HOST:-cnpg}"
CNPG_PORT="${CNPG_PORT:-5432}"
CNPG_DATABASE="${CNPG_DATABASE:-serviceradar}"
CNPG_USERNAME="${CNPG_USERNAME:-serviceradar}"
CNPG_PASSWORD="${CNPG_PASSWORD:-serviceradar}"
CNPG_SSL_MODE="${CNPG_SSL_MODE:-verify-full}"

# Backwards-compatible fallbacks (deprecated names used by older compose files).
if [ -z "$EDGE_DEFAULT_CHECKER_ENDPOINT" ] && [ -n "${SYSMON_VM_ADDRESS:-}" ]; then
    EDGE_DEFAULT_CHECKER_ENDPOINT="$SYSMON_VM_ADDRESS"
fi
if [ -z "$EDGE_DEFAULT_CHECKER_SECURITY_MODE" ] && [ -n "${SYSMON_VM_SECURITY_MODE:-}" ]; then
    EDGE_DEFAULT_CHECKER_SECURITY_MODE="$SYSMON_VM_SECURITY_MODE"
fi

# Create config directory
mkdir -p "$CONFIG_DIR"
mkdir -p "$CHECKERS_DIR"

echo "Updating ServiceRadar configurations with generated secrets..."

# Seed core.json from template only on first run so we preserve generated keys between restarts
if [ ! -f "$CORE_CONFIG" ] || is_truthy "$FORCE_REGENERATE_CONFIG"; then
    if [ -f "$CORE_CONFIG" ]; then
        warn "FORCE_REGENERATE_CONFIG enabled; overwriting existing core.json from template"
    else
        echo "Seeding core.json from template for the first time..."
    fi
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
NEXT_PUBLIC_API_URL=http://localhost
EOF
    
    echo "✅ Created api.env with generated secrets"
fi

# Remove legacy SRQL block; web-ng now serves SRQL queries directly
if [ -f "$CORE_CONFIG" ]; then
    jq 'del(.srql)' "$CORE_CONFIG" > "$CORE_CONFIG.tmp"
    mv "$CORE_CONFIG.tmp" "$CORE_CONFIG"
    echo "✅ Removed legacy SRQL config from core.json"
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
if [ -n "$EDGE_DEFAULT_CHECKER_ENDPOINT" ] && [ "$EDGE_DEFAULT_CHECKER_SECURITY_MODE" = "mtls" ]; then
    EDGE_DEFAULT_META=$(cat <<EOF
{"security_mode":"mtls","checker_endpoint":"$EDGE_DEFAULT_CHECKER_ENDPOINT","gateway_endpoint":"$EDGE_DEFAULT_CHECKER_ENDPOINT","core_address":"core:50052","kv_address":"datasvc:50057"}
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
