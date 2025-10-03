#!/bin/bash
set -euo pipefail

# BuildBuddy Executor Deployment Script
# This script deploys the BuildBuddy executor with the API key from Kubernetes secret

NAMESPACE="buildbuddy"
RELEASE_NAME="buildbuddy"
SECRET_NAME="buildbuddy-api-key"

# Check if secret exists
if ! kubectl get secret "$SECRET_NAME" -n "$NAMESPACE" &>/dev/null; then
    echo "Error: Secret '$SECRET_NAME' not found in namespace '$NAMESPACE'"
    echo "Create it with: kubectl create secret generic $SECRET_NAME -n $NAMESPACE --from-literal=api-key='YOUR_API_KEY'"
    exit 1
fi

# Get API key from secret
API_KEY=$(kubectl get secret "$SECRET_NAME" -n "$NAMESPACE" -o jsonpath='{.data.api-key}' | base64 -d)

if [ -z "$API_KEY" ]; then
    echo "Error: API key is empty in secret"
    exit 1
fi

echo "Deploying BuildBuddy executor..."
helm upgrade "$RELEASE_NAME" buildbuddy/buildbuddy-executor \
    -n "$NAMESPACE" \
    -f "$(dirname "$0")/values.yaml" \
    --set config.executor.api_key="$API_KEY"

echo "Deployment complete!"
echo "Check status with: kubectl get pods -n $NAMESPACE -l app.kubernetes.io/name=buildbuddy-executor"
