#!/bin/bash
# Script to resize Proton PVC from the previous default (512Gi) to 1Ti.
# Idempotent – safe to run multiple times.

set -euo pipefail

NAMESPACE="demo"
DEPLOYMENT="serviceradar-proton"
PVC_NAME="serviceradar-proton-data"
TARGET_SIZE="1Ti"

echo "=== Proton PVC Resize Script ==="
echo "Namespace: $NAMESPACE"
echo "Deployment: $DEPLOYMENT"
echo "Target PVC size: $TARGET_SIZE"
echo ""

if ! command -v kubectl >/dev/null 2>&1; then
  echo "kubectl is required on PATH"
  exit 1
fi

# Step 0: Inspect existing PVC size (if present)
if kubectl get pvc -n "$NAMESPACE" "$PVC_NAME" >/dev/null 2>&1; then
  CURRENT_SIZE=$(kubectl get pvc -n "$NAMESPACE" "$PVC_NAME" -o jsonpath='{.spec.resources.requests.storage}')
  echo "Current PVC size: $CURRENT_SIZE"
  if [ "$CURRENT_SIZE" = "$TARGET_SIZE" ]; then
    echo "PVC already at target size. Nothing to do."
    exit 0
  fi
else
  echo "PVC does not exist; applying manifests will create it at $TARGET_SIZE."
fi

# Step 1: Scale down Proton so the volume can be recreated safely
echo ""
echo "Scaling down $DEPLOYMENT to 0 replicas..."
kubectl scale deployment "$DEPLOYMENT" -n "$NAMESPACE" --replicas=0
echo "Waiting for pods to terminate..."
kubectl wait --for=delete pod -n "$NAMESPACE" -l app=serviceradar-proton --timeout=180s 2>/dev/null || true

# Step 2: Delete the PVC so the provisioner can recreate it with new size
if kubectl get pvc -n "$NAMESPACE" "$PVC_NAME" >/dev/null 2>&1; then
  echo ""
  echo "Deleting PVC $PVC_NAME..."
  kubectl delete pvc "$PVC_NAME" -n "$NAMESPACE" --timeout=120s
  echo "Waiting briefly for local-path provisioner to clean up..."
  sleep 5
fi

# Step 3: Reapply manifests so the PVC is recreated with updated capacity
echo ""
echo "Applying demo manifests to recreate PVC..."
kubectl apply -k /home/mfreeman/serviceradar/k8s/demo/prod/

echo "Waiting for PVC to bind..."
kubectl wait --for=jsonpath='{.status.phase}'=Bound pvc "$PVC_NAME" -n "$NAMESPACE" --timeout=180s

NEW_SIZE=$(kubectl get pvc -n "$NAMESPACE" "$PVC_NAME" -o jsonpath='{.spec.resources.requests.storage}')
echo "PVC recreated with size: $NEW_SIZE"

# Step 4: Bring Proton back online
echo ""
echo "Scaling $DEPLOYMENT back to 1 replica..."
kubectl scale deployment "$DEPLOYMENT" -n "$NAMESPACE" --replicas=1
echo "Waiting for deployment to become ready..."
kubectl rollout status deployment/"$DEPLOYMENT" -n "$NAMESPACE" --timeout=300s

echo ""
echo "=== Proton PVC resize complete ==="
