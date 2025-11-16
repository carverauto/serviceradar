#!/bin/bash

# Resize the CNPG storage for the demo cluster.
# Usage: ./resize-cnpg-pvc.sh [namespace] [size]

set -euo pipefail

NAMESPACE="${1:-demo}"
NEW_SIZE="${2:-20Gi}"
CLUSTER_NAME="cnpg"

echo "🔧 Resizing CNPG storage in namespace ${NAMESPACE} to ${NEW_SIZE}"

kubectl patch cluster "${CLUSTER_NAME}" -n "${NAMESPACE}" \
  --type merge \
  -p "{\"spec\":{\"storage\":{\"size\":\"${NEW_SIZE}\"}}}"

echo "⏳ Waiting for CNPG pods to report Ready after the resize..."
kubectl wait --for=condition=Ready pod -l "cnpg.io/cluster=${CLUSTER_NAME}" -n "${NAMESPACE}" --timeout=600s

echo "✅ CNPG storage resize request applied. Verify actual PVC sizes with:"
echo "   kubectl get pvc -n ${NAMESPACE} -l cnpg.io/cluster=${CLUSTER_NAME}"
