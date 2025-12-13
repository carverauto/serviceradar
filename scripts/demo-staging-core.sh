#!/usr/bin/env bash
set -euo pipefail

NS="${1:-demo-staging}"

echo "[demo-staging-core] Pushing core image (latest)..."
bazel run --config=remote --stamp //docker/images:core_image_amd64_push

echo "[demo-staging-core] Restarting core deployment in namespace ${NS}..."
kubectl -n "${NS}" rollout restart deployment/serviceradar-core
kubectl -n "${NS}" rollout status deployment/serviceradar-core --timeout=300s

echo "[demo-staging-core] Current core image:"
kubectl -n "${NS}" get deploy serviceradar-core -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'

