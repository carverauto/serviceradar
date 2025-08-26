#!/bin/bash

# ServiceRadar K8s Deployment Script
# This script deploys the core ServiceRadar services to Kubernetes

set -e

NAMESPACE="serviceradar-staging"
ENVIRONMENT="staging"

echo "🚀 Deploying ServiceRadar to Kubernetes"
echo "Namespace: $NAMESPACE"
echo "Environment: $ENVIRONMENT"

# Create namespace if it doesn't exist
kubectl create namespace $NAMESPACE --dry-run=client -o yaml | kubectl apply -f -

# Generate secrets if not already present
if ! kubectl get secret serviceradar-secrets -n $NAMESPACE >/dev/null 2>&1; then
    echo "⚠️  Secrets not found. Creating from template..."
    echo "Please update the secrets with actual values!"
    
    # Generate random secrets
    JWT_SECRET=$(openssl rand -hex 32 | base64)
    API_KEY=$(openssl rand -hex 32 | base64)
    PROTON_PASSWORD=$(openssl rand -hex 16 | base64)
    ADMIN_PASSWORD=$(echo -n "serviceradar2025" | base64)
    
    cat <<EOF | kubectl apply -n $NAMESPACE -f -
apiVersion: v1
kind: Secret
metadata:
  name: serviceradar-secrets
type: Opaque
data:
  jwt-secret: $JWT_SECRET
  api-key: $API_KEY
  proton-password: $PROTON_PASSWORD
  admin-password: $ADMIN_PASSWORD
EOF
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

# Apply kustomization
echo "📦 Applying base configuration..."
kubectl apply -k base/ -n $NAMESPACE

# Apply environment-specific configuration
echo "📦 Applying $ENVIRONMENT configuration..."
kubectl apply -k $ENVIRONMENT/ -n $NAMESPACE

# Wait for deployments
echo "⏳ Waiting for deployments to be ready..."

# Wait for Proton first (database)
kubectl wait --for=condition=available --timeout=300s deployment/serviceradar-proton -n $NAMESPACE

# Wait for NATS
kubectl wait --for=condition=available --timeout=180s deployment/serviceradar-nats -n $NAMESPACE

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
    echo "🌐 Access ServiceRadar at: http://$INGRESS_URL"
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

echo ""
echo "🔐 Default credentials:"
echo "   Username: admin"
echo "   Password: serviceradar2025"
echo ""
echo "⚠️  Remember to change these credentials in production!"
