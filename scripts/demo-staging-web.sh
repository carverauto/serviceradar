#!/usr/bin/env bash
set -euo pipefail

NS="${1:-demo-staging}"

echo "[demo-staging-web] Pushing web image (latest)..."
bazel run --config=remote --stamp //docker/images:web_ng_image_amd64_push

echo "[demo-staging-web] Restarting web-ng deployment in namespace ${NS}..."
kubectl -n "${NS}" rollout restart deployment/serviceradar-web-ng
kubectl -n "${NS}" rollout status deployment/serviceradar-web-ng --timeout=300s

echo "[demo-staging-web] Current web-ng image:"
kubectl -n "${NS}" get deploy serviceradar-web-ng -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
