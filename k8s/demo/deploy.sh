#!/bin/bash

# ServiceRadar K8s Deployment Script
# This script deploys the core ServiceRadar services to Kubernetes

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

ENVIRONMENT="${1:-prod}"
case "$ENVIRONMENT" in
  prod)
    NAMESPACE="demo"
    HOSTNAME="demo.serviceradar.cloud"
    ;;
  staging)
    NAMESPACE="demo-staging"
    HOSTNAME="demo-staging.serviceradar.cloud"
    ;;
  *)
    echo "Usage: $0 [prod|staging]"
    exit 1
    ;;
esac

echo "🚀 Deploying ServiceRadar to Kubernetes"
echo "Namespace: $NAMESPACE"
echo "Environment: $ENVIRONMENT"

# Create namespace if it doesn't exist
kubectl create namespace $NAMESPACE --dry-run=client -o yaml | kubectl apply -f -

# Generate secrets if not already present
if ! kubectl get secret serviceradar-secrets -n $NAMESPACE >/dev/null 2>&1; then
    echo "⚠️  Secrets not found. Creating from template..."
    
    # Generate random secrets
    JWT_SECRET_RAW=$(openssl rand -hex 32)
    JWT_SECRET=$(echo -n "$JWT_SECRET_RAW" | base64 | tr -d '\n')
    API_KEY=$(openssl rand -hex 32 | base64 | tr -d '\n')
    ADMIN_PASSWORD_RAW=$(openssl rand -base64 16 | tr -d '=' | head -c 16)
    ADMIN_PASSWORD=$(echo -n "$ADMIN_PASSWORD_RAW" | base64 | tr -d '\n')
    
    # Generate bcrypt hash of admin password (cost 12)
    echo "🔐 Generating bcrypt hash for admin password..."
    if command -v htpasswd >/dev/null 2>&1; then
        ADMIN_BCRYPT_HASH=$(htpasswd -nbB admin "$ADMIN_PASSWORD_RAW" | cut -d: -f2)
    elif command -v python3 >/dev/null 2>&1; then
        ADMIN_BCRYPT_HASH=$(python3 -c "import bcrypt; print(bcrypt.hashpw('$ADMIN_PASSWORD_RAW'.encode('utf-8'), bcrypt.gensalt()).decode('utf-8'))")
    else
        echo "❌ Error: Neither htpasswd nor python3 found for bcrypt hashing"
        echo "Please install apache2-utils or python3-bcrypt"
        exit 1
    fi
    
    cat <<EOF | kubectl apply -n $NAMESPACE -f -
apiVersion: v1
kind: Secret
metadata:
  name: serviceradar-secrets
type: Opaque
  data:
    jwt-secret: $JWT_SECRET
    api-key: $API_KEY
    admin-password: $ADMIN_PASSWORD
    admin-bcrypt-hash: $(echo -n "$ADMIN_BCRYPT_HASH" | base64 -w 0)
EOF

    echo "✅ Secrets created successfully"
else
    echo "✅ Secrets already exist, extracting values..."
    # Extract existing values for configmap generation
    ADMIN_PASSWORD_RAW=$(kubectl get secret serviceradar-secrets -n $NAMESPACE -o jsonpath='{.data.admin-password}' | base64 -d)
    JWT_SECRET_RAW=$(kubectl get secret serviceradar-secrets -n $NAMESPACE -o jsonpath='{.data.jwt-secret}' | base64 -d)
    
    # Generate bcrypt hash for existing admin password
    echo "🔐 Generating bcrypt hash for existing admin password..."
    if command -v htpasswd >/dev/null 2>&1; then
        ADMIN_BCRYPT_HASH=$(htpasswd -nbB admin "$ADMIN_PASSWORD_RAW" | cut -d: -f2)
    elif command -v python3 >/dev/null 2>&1; then
        ADMIN_BCRYPT_HASH=$(python3 -c "import bcrypt; print(bcrypt.hashpw('$ADMIN_PASSWORD_RAW'.encode('utf-8'), bcrypt.gensalt()).decode('utf-8'))")
    else
        echo "❌ Error: Neither htpasswd nor python3 found for bcrypt hashing"
        exit 1
    fi
fi

# Check if ghcr.io credentials exist
if ! kubectl get secret ghcr-io-cred -n $NAMESPACE >/dev/null 2>&1; then
    echo "⚠️  GitHub Container Registry credentials not found!"
    echo "Please create the secret manually:"
    echo "kubectl create secret docker-registry ghcr-io-cred \\"
    echo "  --docker-server=ghcr.io \\"
    echo "  --docker-username=YOUR_GITHUB_USERNAME \\"
    echo "  --docker-password=YOUR_GITHUB_TOKEN \\"
    echo "  --namespace=$NAMESPACE"
    exit 1
fi

# Apply the selected overlay (includes the shared base)
echo "📦 Applying $ENVIRONMENT configuration..."
kubectl apply -k $ENVIRONMENT/ -n $NAMESPACE

echo ""
echo "🗄 Waiting for CNPG cluster pods..."
CNPG_SELECTOR="cnpg.io/cluster=cnpg"
CNPG_READY=false
for attempt in {1..60}; do
    POD_COUNT=$(kubectl get pods -n $NAMESPACE -l "$CNPG_SELECTOR" -o name 2>/dev/null | wc -l)
    if [ "${POD_COUNT:-0}" -gt 0 ]; then
        if kubectl wait --for=condition=Ready pod -l "$CNPG_SELECTOR" -n $NAMESPACE --timeout=120s >/dev/null 2>&1; then
            CNPG_READY=true
            break
        fi
    fi
    echo "   CNPG pods not ready yet ($attempt/60)..."
    sleep 5
done
if [ "$CNPG_READY" = true ]; then
    echo "   CNPG pods are ready."
else
    echo "   ⚠️  CNPG pods did not become ready within the expected window; check cnpg-* pods manually."
fi

# Wait for deployments
echo "⏳ Waiting for deployments to be ready..."

# Wait for NATS
kubectl wait --for=condition=available --timeout=180s deployment/serviceradar-nats -n $NAMESPACE

# Wait for KV
kubectl wait --for=condition=available --timeout=180s deployment/serviceradar-datasvc -n $NAMESPACE

# Wait for Core
kubectl wait --for=condition=available --timeout=180s deployment/serviceradar-core -n $NAMESPACE

# Wait for Web
kubectl wait --for=condition=available --timeout=180s deployment/serviceradar-web -n $NAMESPACE

# Get service endpoints
echo ""
echo "✅ Deployment complete!"
echo ""
echo "📊 Service Status:"
kubectl get deployments -n $NAMESPACE
echo ""
kubectl get services -n $NAMESPACE
echo ""

# Get ingress URL if available
INGRESS_URL=$(kubectl get ingress -n $NAMESPACE -o jsonpath='{.items[0].spec.rules[0].host}' 2>/dev/null || echo "Not configured")
if [ "$INGRESS_URL" != "Not configured" ]; then
    echo "🌐 Access ServiceRadar at: https://$INGRESS_URL"
else
    # Try to get LoadBalancer IP from web service
    LB_IP=$(kubectl get svc serviceradar-web -n $NAMESPACE -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
    if [ -n "$LB_IP" ]; then
        echo "🌐 Access ServiceRadar at: http://$LB_IP:3000"
    else
        echo "🌐 Use port-forward to access ServiceRadar:"
        echo "   kubectl port-forward -n $NAMESPACE svc/serviceradar-web 3000:3000"
        echo "   Then access at: http://localhost:3000"
    fi
fi

if [ "$INGRESS_URL" = "Not configured" ]; then
    echo "   (Expected ingress host: https://$HOSTNAME )"
fi

echo ""
echo "🔐 Admin credentials:"
echo "   Username: admin"
if ! kubectl get secret serviceradar-secrets -n $NAMESPACE >/dev/null 2>&1; then
    echo "   Password: $ADMIN_PASSWORD_RAW"
else
    echo "   Password: (stored in secret 'serviceradar-secrets', key 'admin-password')"
    echo "   To retrieve: kubectl get secret serviceradar-secrets -n $NAMESPACE -o jsonpath='{.data.admin-password}' | base64 -d"
fi
echo ""
echo "⚠️  Store these credentials securely!"
