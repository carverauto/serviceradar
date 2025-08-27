#!/bin/bash

# ServiceRadar Deployment Validation Script
# This script validates that all components are properly deployed and functional

set -e

NAMESPACE="serviceradar-staging"
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo "🔍 ServiceRadar Deployment Validation"
echo "======================================"
echo ""

# Check namespace exists
echo -n "📁 Checking namespace '$NAMESPACE'... "
if kubectl get namespace $NAMESPACE >/dev/null 2>&1; then
    echo -e "${GREEN}✓${NC}"
else
    echo -e "${RED}✗${NC}"
    echo "❌ Namespace $NAMESPACE not found"
    exit 1
fi

# Check secrets exist
echo -n "🔐 Checking secrets... "
if kubectl get secret serviceradar-secrets -n $NAMESPACE >/dev/null 2>&1; then
    echo -e "${GREEN}✓${NC}"
else
    echo -e "${RED}✗${NC}"
    echo "❌ ServiceRadar secrets not found"
    exit 1
fi

# Check configmap exists
echo -n "📝 Checking configmap... "
if kubectl get configmap serviceradar-config -n $NAMESPACE >/dev/null 2>&1; then
    echo -e "${GREEN}✓${NC}"
else
    echo -e "${RED}✗${NC}"
    echo "❌ ServiceRadar configmap not found"
    exit 1
fi

# Check deployments
echo ""
echo "🚀 Checking deployment status:"
DEPLOYMENTS=("serviceradar-core" "serviceradar-proton" "serviceradar-web" "serviceradar-nats" "serviceradar-kv" "serviceradar-agent" "serviceradar-poller" "serviceradar-snmp-checker")
ALL_READY=true

for deployment in "${DEPLOYMENTS[@]}"; do
    echo -n "   $deployment... "
    if kubectl get deployment $deployment -n $NAMESPACE >/dev/null 2>&1; then
        READY=$(kubectl get deployment $deployment -n $NAMESPACE -o jsonpath='{.status.readyReplicas}')
        DESIRED=$(kubectl get deployment $deployment -n $NAMESPACE -o jsonpath='{.spec.replicas}')
        if [ "$READY" = "$DESIRED" ]; then
            echo -e "${GREEN}✓ ($READY/$DESIRED)${NC}"
        else
            echo -e "${YELLOW}⚠ ($READY/$DESIRED)${NC}"
            ALL_READY=false
        fi
    else
        echo -e "${RED}✗ (not found)${NC}"
        ALL_READY=false
    fi
done

if [ "$ALL_READY" = false ]; then
    echo ""
    echo -e "${YELLOW}⚠️  Some deployments are not fully ready. Check with:${NC}"
    echo "   kubectl get deployments -n $NAMESPACE"
    echo "   kubectl describe deployment <deployment-name> -n $NAMESPACE"
fi

# Check services
echo ""
echo "🌐 Checking services:"
SERVICES=("serviceradar-core" "serviceradar-proton" "serviceradar-web" "serviceradar-nats" "serviceradar-kv")
for service in "${SERVICES[@]}"; do
    echo -n "   $service... "
    if kubectl get service $service -n $NAMESPACE >/dev/null 2>&1; then
        echo -e "${GREEN}✓${NC}"
    else
        echo -e "${RED}✗${NC}"
    fi
done

# Check ingress
echo ""
echo -n "🌍 Checking ingress... "
if kubectl get ingress -n $NAMESPACE >/dev/null 2>&1; then
    INGRESS_NAME=$(kubectl get ingress -n $NAMESPACE -o jsonpath='{.items[0].metadata.name}')
    INGRESS_HOST=$(kubectl get ingress $INGRESS_NAME -n $NAMESPACE -o jsonpath='{.spec.rules[0].host}')
    echo -e "${GREEN}✓${NC}"
    echo "   Host: $INGRESS_HOST"
else
    echo -e "${YELLOW}⚠${NC}"
    echo "   No ingress found"
fi

# Test API connectivity
echo ""
echo "🔌 Testing API connectivity:"

# Try port-forward test
echo -n "   Port-forward test... "
kubectl port-forward -n $NAMESPACE svc/serviceradar-web 3001:3000 >/dev/null 2>&1 &
PORT_FORWARD_PID=$!
sleep 3

if curl -s http://localhost:3001/api/auth/status >/dev/null 2>&1; then
    echo -e "${GREEN}✓${NC}"
    API_RESPONSE=$(curl -s http://localhost:3001/api/auth/status)
    echo "   Response: $API_RESPONSE"
else
    echo -e "${RED}✗${NC}"
    echo "   Failed to connect to API via port-forward"
fi

# Clean up port-forward
kill $PORT_FORWARD_PID >/dev/null 2>&1 || true

# Check certificates
echo ""
echo "🔒 Checking certificates:"
if kubectl get job serviceradar-cert-generator -n $NAMESPACE >/dev/null 2>&1; then
    JOB_STATUS=$(kubectl get job serviceradar-cert-generator -n $NAMESPACE -o jsonpath='{.status.succeeded}')
    if [ "$JOB_STATUS" = "1" ]; then
        echo -e "   Certificate generation job... ${GREEN}✓${NC}"
    else
        echo -e "   Certificate generation job... ${YELLOW}⚠${NC}"
        echo "   Check logs: kubectl logs job/serviceradar-cert-generator -n $NAMESPACE"
    fi
fi

# Check TLS certificates from cert-manager
if kubectl get certificate -n $NAMESPACE >/dev/null 2>&1; then
    echo "   TLS certificates:"
    kubectl get certificate -n $NAMESPACE -o custom-columns=NAME:.metadata.name,READY:.status.conditions[?@.type==\"Ready\"].status,SECRET:.spec.secretName --no-headers | while read name ready secret; do
        if [ "$ready" = "True" ]; then
            echo -e "     $name... ${GREEN}✓${NC}"
        else
            echo -e "     $name... ${YELLOW}⚠${NC}"
        fi
    done
fi

# Get admin credentials
echo ""
echo "🔑 Admin credentials:"
ADMIN_PASSWORD=$(kubectl get secret serviceradar-secrets -n $NAMESPACE -o jsonpath='{.data.admin-password}' | base64 -d)
echo "   Username: admin"
echo "   Password: $ADMIN_PASSWORD"

# Summary
echo ""
echo "📊 Validation Summary:"
if [ "$ALL_READY" = true ]; then
    echo -e "   Deployment Status: ${GREEN}✅ All services ready${NC}"
else
    echo -e "   Deployment Status: ${YELLOW}⚠️  Some services not ready${NC}"
fi

echo ""
echo "🎯 Access Information:"
if [ -n "$INGRESS_HOST" ]; then
    echo "   Web UI: https://$INGRESS_HOST"
    echo "   API: https://$INGRESS_HOST/api"
fi
echo "   Port-forward: kubectl port-forward -n $NAMESPACE svc/serviceradar-web 3000:3000"
echo "   Local access: http://localhost:3000"

echo ""
echo "🔧 Troubleshooting commands:"
echo "   kubectl get all -n $NAMESPACE"
echo "   kubectl logs -n $NAMESPACE deployment/serviceradar-core"
echo "   kubectl logs -n $NAMESPACE deployment/serviceradar-web"
echo "   kubectl describe ingress -n $NAMESPACE"

echo ""
echo -e "${GREEN}✅ Validation complete!${NC}"