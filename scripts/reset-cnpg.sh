#!/bin/bash

# Reset the CloudNativePG (CNPG) cluster backing the Helm-managed demo environments.
# Usage: scripts/reset-cnpg.sh [prod|staging]

set -euo pipefail

ENVIRONMENT="${1:-prod}"
case "$ENVIRONMENT" in
  prod)
    NAMESPACE="demo"
    VALUES_FILE="helm/serviceradar/values-demo.yaml"
    ;;
  staging)
    NAMESPACE="demo-staging"
    VALUES_FILE="helm/serviceradar/values-demo-staging.yaml"
    ;;
  *)
    echo "Usage: $0 [prod|staging]" >&2
    exit 1
    ;;
esac

CLUSTER_NAME="cnpg"
SELECTOR="cnpg.io/cluster=${CLUSTER_NAME}"

echo "⚠️  Resetting CNPG cluster '${CLUSTER_NAME}' in namespace '${NAMESPACE}'"

echo "🗑  Deleting CNPG cluster resource (this drains existing pods)..."
kubectl delete cluster "${CLUSTER_NAME}" -n "${NAMESPACE}" --ignore-not-found --wait=true

echo "🧹 Deleting old PVCs labelled ${SELECTOR}..."
kubectl delete pvc -n "${NAMESPACE}" -l "${SELECTOR}" --ignore-not-found --wait=false

echo "📦 Reapplying Helm release in namespace ${NAMESPACE} to recreate CNPG resources..."
helm upgrade --install serviceradar ./helm/serviceradar \
  -n "${NAMESPACE}" \
  -f "${VALUES_FILE}" \
  --wait \
  --timeout 10m

echo "⏳ Waiting for CNPG pods to become Ready..."
kubectl wait --for=condition=Ready --timeout=600s pod -l "${SELECTOR}" -n "${NAMESPACE}"

echo "🔁 Ash migrations are applied by core-elx on startup (SERVICERADAR_CORE_RUN_MIGRATIONS=true)."

echo "♻️  Restarting core services so they reconnect to the fresh database..."
for deployment in serviceradar-core serviceradar-datasvc \
  serviceradar-web-ng serviceradar-agent; do
  kubectl rollout restart "deployment/${deployment}" -n "${NAMESPACE}" || true
done

echo "✅ CNPG reset completed. Monitor rollouts with:"
echo "   kubectl get pods -n ${NAMESPACE}"
