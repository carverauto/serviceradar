#!/bin/sh
# Update configuration files with generated secrets

set -e

CERT_DIR="/etc/serviceradar/certs"
CONFIG_DIR="/etc/serviceradar/config"
CORE_CONFIG="$CONFIG_DIR/core.json"
API_ENV="$CONFIG_DIR/api.env"

# Create config directory
mkdir -p "$CONFIG_DIR"

echo "Updating ServiceRadar configurations with generated secrets..."

# Copy template config to generated config directory
cp /config/core.docker.json "$CORE_CONFIG"

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

# Generate admin password bcrypt hash if it doesn't exist
if [ ! -f "$CERT_DIR/admin-password-hash" ]; then
    echo "Generating admin password bcrypt hash..."
    # Generate a random password
    ADMIN_PASSWORD=$(openssl rand -base64 12)
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