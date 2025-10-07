#!/bin/bash

# ServiceRadar Admin Password Regeneration Script
# This script generates a new random admin password and updates the secret

set -e

NAMESPACE="${1:-serviceradar-staging}"

echo "🔐 Regenerating admin password for namespace: $NAMESPACE"

# Check if secret exists
if ! kubectl get secret serviceradar-secrets -n $NAMESPACE >/dev/null 2>&1; then
    echo "❌ Secret 'serviceradar-secrets' not found in namespace '$NAMESPACE'"
    echo "Run the deploy script first to create the initial secret"
    exit 1
fi

# Generate new random password
ADMIN_PASSWORD_RAW=$(openssl rand -base64 16 | tr -d '=' | head -c 16)
ADMIN_PASSWORD_B64=$(echo -n "$ADMIN_PASSWORD_RAW" | base64)

# Generate bcrypt hash of admin password (cost 12)
echo "🔐 Generating bcrypt hash for new admin password..."
if command -v htpasswd >/dev/null 2>&1; then
    ADMIN_BCRYPT_HASH=$(htpasswd -nbB admin "$ADMIN_PASSWORD_RAW" | cut -d: -f2)
elif command -v python3 >/dev/null 2>&1; then
    ADMIN_BCRYPT_HASH=$(python3 -c "import bcrypt; print(bcrypt.hashpw('$ADMIN_PASSWORD_RAW'.encode('utf-8'), bcrypt.gensalt()).decode('utf-8'))")
else
    echo "❌ Error: Neither htpasswd nor python3 found for bcrypt hashing"
    echo "Please install apache2-utils or python3-bcrypt"
    exit 1
fi

echo "📝 Updating secret with new password..."

# Update the secret
kubectl patch secret serviceradar-secrets -n $NAMESPACE -p="{\"data\":{\"admin-password\":\"$ADMIN_PASSWORD_B64\"}}"

echo "📝 Updating core.json configmap with new bcrypt hash..."

# Get current configmap and update the bcrypt hash
kubectl get configmap serviceradar-config -n $NAMESPACE -o json | \
  jq --arg hash "$ADMIN_BCRYPT_HASH" '.data."core.json" |= (fromjson | .auth.local_users.admin = $hash | tojson)' | \
  kubectl apply -f -

echo "🔄 Restarting core deployment to pick up new configuration..."
kubectl rollout restart deployment/serviceradar-core -n $NAMESPACE

echo "✅ Admin password updated successfully!"
echo ""
echo "🔐 New admin credentials:"
echo "   Username: admin"
echo "   Password: $ADMIN_PASSWORD_RAW"
echo ""
echo "⚠️  Store this password securely! This is the only time it will be displayed."
echo ""
echo "To retrieve the password later:"
echo "kubectl get secret serviceradar-secrets -n $NAMESPACE -o jsonpath='{.data.admin-password}' | base64 -d"