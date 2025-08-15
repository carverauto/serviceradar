#!/bin/sh
# Update configuration files with generated secrets

set -e

CERT_DIR="/etc/serviceradar/certs"
CORE_CONFIG="/etc/serviceradar/core.json"
API_ENV="/etc/serviceradar/api.env"

echo "Updating ServiceRadar configurations with generated secrets..."

# Copy template config
cp /config/core.docker.json /etc/serviceradar/core.json

# Generate JWT secret and API key if they don't exist
if [ ! -f "$CERT_DIR/jwt-secret" ]; then
    echo "Generating JWT secret..."
    openssl rand -hex 32 > "$CERT_DIR/jwt-secret"
    echo "✅ Generated JWT secret"
fi

if [ ! -f "$CERT_DIR/api-key" ]; then
    echo "Generating API key..."
    openssl rand -hex 32 > "$CERT_DIR/api-key"
    echo "✅ Generated API key"
fi

# Update core.json with JWT secret if the secret file exists
if [ -f "$CERT_DIR/jwt-secret" ] && [ -f "$CORE_CONFIG" ]; then
    JWT_SECRET=$(cat "$CERT_DIR/jwt-secret")
    echo "Updating core.json with generated JWT secret..."
    
    # Use jq to update the JWT secret in core.json
    jq --arg jwt_secret "$JWT_SECRET" '.auth.jwt_secret = $jwt_secret' "$CORE_CONFIG" > "$CORE_CONFIG.tmp"
    mv "$CORE_CONFIG.tmp" "$CORE_CONFIG"
    echo "✅ Updated core.json with generated JWT secret"
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
NEXT_PUBLIC_API_URL=http://localhost/api
EOF
    
    echo "✅ Created api.env with generated secrets"
fi

# Note: We do NOT copy generated secrets back to host to avoid
# persisting sensitive data to the source tree. The generated
# configurations are only used within the running containers.

echo "🎉 Configuration update complete!"