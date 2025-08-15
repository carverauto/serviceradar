#!/bin/sh
# Update configuration files with generated secrets

set -e

CERT_DIR="/etc/serviceradar/certs"
CORE_CONFIG="/etc/serviceradar/core.json"
API_ENV="/etc/serviceradar/api.env"

echo "Updating ServiceRadar configurations with generated secrets..."

# Update core.json with JWT secret if the secret file exists
if [ -f "$CERT_DIR/jwt-secret" ] && [ -f "$CORE_CONFIG" ]; then
    JWT_SECRET=$(cat "$CERT_DIR/jwt-secret")
    echo "Updating core.json with generated JWT secret..."
    
    # Use jq to update the JWT secret in core.json
    if command -v jq >/dev/null 2>&1; then
        jq --arg jwt_secret "$JWT_SECRET" '.auth.jwt_secret = $jwt_secret' "$CORE_CONFIG" > "$CORE_CONFIG.tmp"
        mv "$CORE_CONFIG.tmp" "$CORE_CONFIG"
        echo "✅ Updated core.json with generated JWT secret"
    else
        echo "❌ jq not available, cannot update core.json"
    fi
fi

# Update/create api.env with generated secrets
if [ -f "$CERT_DIR/api-key" ] && [ -f "$CERT_DIR/jwt-secret" ]; then
    API_KEY=$(cat "$CERT_DIR/api-key")
    JWT_SECRET=$(cat "$CERT_DIR/jwt-secret")
    
    echo "Updating api.env with generated secrets..."
    
    # Create or update api.env
    cat > "$API_ENV" <<EOF
# ServiceRadar API Configuration - Auto-generated
API_KEY=$API_KEY
JWT_SECRET=$JWT_SECRET
AUTH_ENABLED=true
NEXT_INTERNAL_API_URL=http://core:8090
NEXT_PUBLIC_API_URL=http://localhost/api
EOF
    
    # Set proper ownership and permissions
    chown serviceradar:serviceradar "$API_ENV"
    chmod 640 "$API_ENV"
    
    echo "✅ Updated api.env with generated secrets"
fi

echo "🎉 Configuration update complete!"