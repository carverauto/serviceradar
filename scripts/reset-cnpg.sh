#!/bin/bash

# Reset the CloudNativePG (CNPG) cluster backing the demo environments.
# Usage: scripts/reset-cnpg.sh [prod|staging]

set -euo pipefail

ENVIRONMENT="${1:-prod}"
case "$ENVIRONMENT" in
  prod)
    NAMESPACE="demo"
    OVERLAY="k8s/demo/prod"
    ;;
  staging)
    NAMESPACE="demo-staging"
    OVERLAY="k8s/demo/staging"
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

echo "📦 Reapplying overlay ${OVERLAY} to recreate CNPG + SPIRE manifests..."
kubectl apply -k "${OVERLAY}"

echo "⏳ Waiting for CNPG pods to become Ready..."
kubectl wait --for=condition=Ready --timeout=600s pod -l "${SELECTOR}" -n "${NAMESPACE}"

echo "🔁 Ash migrations are applied by core-elx on startup (SERVICERADAR_CORE_RUN_MIGRATIONS=true)."

echo "♻️  Restarting core services so they reconnect to the fresh database..."
for deployment in serviceradar-core serviceradar-datasvc \
  serviceradar-db-event-writer serviceradar-web-ng serviceradar-agent; do
  kubectl rollout restart "deployment/${deployment}" -n "${NAMESPACE}" || true
done

echo "✅ CNPG reset completed. Monitor rollouts with:"
echo "   kubectl get pods -n ${NAMESPACE}"
