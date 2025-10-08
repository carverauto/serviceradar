#!/bin/bash
# Script to resize NATS PVC from 1Gi to 30Gi
# This is an idempotent script - safe to run multiple times

set -e

NAMESPACE="demo"
DEPLOYMENT="serviceradar-nats"
PVC_NAME="serviceradar-nats-data"

echo "=== NATS PVC Resize Script ==="
echo "This script will resize the NATS PVC from 1Gi to 30Gi"
echo "Namespace: $NAMESPACE"
echo ""

# Check if PVC exists and get current size
if kubectl get pvc -n "$NAMESPACE" "$PVC_NAME" &>/dev/null; then
    CURRENT_SIZE=$(kubectl get pvc -n "$NAMESPACE" "$PVC_NAME" -o jsonpath='{.spec.resources.requests.storage}')
    echo "Current PVC size: $CURRENT_SIZE"

    if [ "$CURRENT_SIZE" = "30Gi" ]; then
        echo "PVC is already 30Gi. Nothing to do."
        exit 0
    fi
else
    echo "PVC does not exist. It will be created with 30Gi when applying manifests."
fi

# Step 1: Scale down NATS deployment
echo ""
echo "Step 1: Scaling down $DEPLOYMENT deployment to 0 replicas..."
kubectl scale deployment -n "$NAMESPACE" "$DEPLOYMENT" --replicas=0

echo "Waiting for pods to terminate..."
kubectl wait --for=delete pod -n "$NAMESPACE" -l app=serviceradar-nats --timeout=120s 2>/dev/null || true

# Step 2: Delete the PVC (PV will be auto-deleted by local-path provisioner)
echo ""
echo "Step 2: Deleting PVC $PVC_NAME..."
kubectl delete pvc -n "$NAMESPACE" "$PVC_NAME" --timeout=60s

echo "Waiting for PVC to be fully deleted..."
sleep 5

# Step 3: Apply the updated manifest to recreate PVC with new size
echo ""
echo "Step 3: Applying updated manifests to recreate PVC with 30Gi..."
kubectl apply -k /home/mfreeman/serviceradar/k8s/demo/prod/

# Wait for PVC to be created and bound
echo "Waiting for PVC to be bound..."
kubectl wait --for=jsonpath='{.status.phase}'=Bound pvc -n "$NAMESPACE" "$PVC_NAME" --timeout=120s

# Verify new size
NEW_SIZE=$(kubectl get pvc -n "$NAMESPACE" "$PVC_NAME" -o jsonpath='{.spec.resources.requests.storage}')
echo "New PVC size: $NEW_SIZE"

# Step 4: Scale back up NATS deployment
echo ""
echo "Step 4: Scaling $DEPLOYMENT deployment back to 1 replica..."
kubectl scale deployment -n "$NAMESPACE" "$DEPLOYMENT" --replicas=1

echo "Waiting for pod to be ready..."
kubectl wait --for=condition=ready pod -n "$NAMESPACE" -l app=serviceradar-nats --timeout=180s

echo ""
echo "=== PVC Resize Complete ==="
echo "NATS PVC has been resized to 30Gi and deployment is running."
