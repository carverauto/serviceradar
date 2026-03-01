#!/bin/bash

# ServiceRadar Admin Password Sync/Regeneration Script
# By default, this script syncs the DB hash to the existing secret password.
# Use --rotate or --password to force rotation.

set -euo pipefail

NAMESPACE="serviceradar-staging"
ROTATE=false
ADMIN_PASSWORD_RAW=""
ADMIN_EMAIL="${ADMIN_EMAIL:-root@localhost}"
DB_USER="${DB_USER:-serviceradar}"
DB_NAME="${DB_NAME:-serviceradar}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        -n|--namespace)
            NAMESPACE="$2"
            shift 2
            ;;
        --rotate)
            ROTATE=true
            shift
            ;;
        --password)
            ADMIN_PASSWORD_RAW="$2"
            ROTATE=true
            shift 2
            ;;
        *)
            NAMESPACE="$1"
            shift
            ;;
    esac
done

echo "🔐 Syncing admin password for namespace: $NAMESPACE"

# Check if secret exists
if ! kubectl get secret serviceradar-secrets -n $NAMESPACE >/dev/null 2>&1; then
    echo "❌ Secret 'serviceradar-secrets' not found in namespace '$NAMESPACE'"
    echo "Run the deploy script first to create the initial secret"
    exit 1
fi

EXISTING_PASSWORD_RAW=$(kubectl get secret serviceradar-secrets -n $NAMESPACE -o jsonpath='{.data.admin-password}' | base64 -d || true)

if [ -z "$ADMIN_PASSWORD_RAW" ]; then
    if [ "$ROTATE" = true ] || [ -z "$EXISTING_PASSWORD_RAW" ]; then
        ADMIN_PASSWORD_RAW=$(openssl rand -base64 16 | tr -d '=' | head -c 16)
        ROTATE=true
    else
        ADMIN_PASSWORD_RAW="$EXISTING_PASSWORD_RAW"
    fi
fi

ADMIN_PASSWORD_B64=$(echo -n "$ADMIN_PASSWORD_RAW" | base64)

bcrypt_hash() {
    if command -v htpasswd >/dev/null 2>&1; then
        htpasswd -nbB admin "$1" | cut -d: -f2
    elif command -v python3 >/dev/null 2>&1; then
        python3 -c "import bcrypt; print(bcrypt.hashpw('$1'.encode('utf-8'), bcrypt.gensalt()).decode('utf-8'))"
    else
        echo "❌ Error: Neither htpasswd nor python3 found for bcrypt hashing"
        echo "Please install apache2-utils or python3-bcrypt"
        exit 1
    fi
}

bcrypt_verify() {
    if command -v python3 >/dev/null 2>&1; then
        python3 - "$1" "$2" <<'PY'
import bcrypt, sys
password = sys.argv[1].encode("utf-8")
hashed = sys.argv[2].encode("utf-8")
sys.exit(0 if bcrypt.checkpw(password, hashed) else 1)
PY
    elif command -v htpasswd >/dev/null 2>&1; then
        tmpfile=$(mktemp)
        printf 'admin:%s\n' "$2" > "$tmpfile"
        htpasswd -vb "$tmpfile" admin "$1" >/dev/null 2>&1
        rc=$?
        rm -f "$tmpfile"
        return $rc
    else
        return 1
    fi
}

echo "🔐 Ensuring bcrypt hash matches desired password..."
EXISTING_ADMIN_HASH=$(kubectl get secret serviceradar-secrets -n $NAMESPACE -o jsonpath='{.data.admin-bcrypt-hash}' | base64 -d || true)
if [ -n "$EXISTING_ADMIN_HASH" ] && bcrypt_verify "$ADMIN_PASSWORD_RAW" "$EXISTING_ADMIN_HASH"; then
    ADMIN_BCRYPT_HASH="$EXISTING_ADMIN_HASH"
    UPDATE_SECRET_HASH=false
else
    ADMIN_BCRYPT_HASH=$(bcrypt_hash "$ADMIN_PASSWORD_RAW")
    UPDATE_SECRET_HASH=true
fi

echo "📝 Updating secret with new password..."

# Update the secret
if [ "$EXISTING_PASSWORD_RAW" != "$ADMIN_PASSWORD_RAW" ]; then
    kubectl patch secret serviceradar-secrets -n $NAMESPACE -p="{\"data\":{\"admin-password\":\"$ADMIN_PASSWORD_B64\"}}"
fi

if [ "$UPDATE_SECRET_HASH" = true ]; then
    kubectl patch secret serviceradar-secrets -n $NAMESPACE -p="{\"data\":{\"admin-bcrypt-hash\":\"$(echo -n "$ADMIN_BCRYPT_HASH" | base64 -w 0)\"}}"
fi

echo "🗄 Syncing database admin hash (if user exists)..."

DB_PASS=$(kubectl get secret serviceradar-db-credentials -n $NAMESPACE -o jsonpath='{.data.password}' | base64 -d || true)
if [ -n "$DB_PASS" ]; then
    DB_HASH=$(kubectl exec -n $NAMESPACE cnpg-1 -- bash -lc "PGPASSWORD=$DB_PASS psql -h 127.0.0.1 -U $DB_USER -d $DB_NAME -At -c \"SELECT hashed_password FROM platform.ng_users WHERE email='${ADMIN_EMAIL}';\"")
    if [ -n "$DB_HASH" ]; then
        if bcrypt_verify "$ADMIN_PASSWORD_RAW" "$DB_HASH"; then
            echo "✅ DB hash already matches desired password"
        else
            HASH_ESCAPED=$(printf '%s' "$ADMIN_BCRYPT_HASH" | sed 's/[$]/\\$/g')
            kubectl exec -n $NAMESPACE cnpg-1 -- bash -lc "PGPASSWORD=$DB_PASS psql -h 127.0.0.1 -U $DB_USER -d $DB_NAME -c \"UPDATE platform.ng_users SET hashed_password='${HASH_ESCAPED}', updated_at=now() WHERE email='${ADMIN_EMAIL}';\""
            echo "✅ Updated DB hash for ${ADMIN_EMAIL}"
        fi
    else
        echo "⚠️  No admin user found for ${ADMIN_EMAIL}; restart web-ng to bootstrap if needed."
    fi
else
    echo "⚠️  serviceradar-db-credentials not found; skipping DB sync."
fi

echo "📝 Updating core.json configmap with new bcrypt hash (if present)..."

# Get current configmap and update the bcrypt hash
if kubectl get configmap serviceradar-config -n $NAMESPACE >/dev/null 2>&1; then
    CURRENT_HASH=$(kubectl get configmap serviceradar-config -n $NAMESPACE -o json | \
      jq -r '.data."core.json" | fromjson | .auth.local_users.admin // ""')

    if [ -n "$CURRENT_HASH" ] && bcrypt_verify "$ADMIN_PASSWORD_RAW" "$CURRENT_HASH"; then
        echo "✅ core.json already matches desired password"
    else
        kubectl get configmap serviceradar-config -n $NAMESPACE -o json | \
          jq --arg hash "$ADMIN_BCRYPT_HASH" '.data."core.json" |= (fromjson | .auth.local_users.admin = $hash | tojson)' | \
          kubectl apply -f -

        echo "🔄 Restarting core deployment to pick up new configuration..."
        kubectl rollout restart deployment/serviceradar-core -n $NAMESPACE
    fi
fi

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
