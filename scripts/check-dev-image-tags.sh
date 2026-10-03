#!/usr/bin/env bash
set -euo pipefail

fail=0

if ! rg -n 'appTag: &appTag "latest"' helm/serviceradar/values.yaml >/dev/null; then
  echo "Expected helm/serviceradar/values.yaml to default appTag to latest." >&2
  fail=1
fi

if ! rg -n 'imageTag: "latest"' helm/serviceradar/values-demo-staging.yaml >/dev/null; then
  echo "Expected helm/serviceradar/values-demo-staging.yaml to set global.imageTag to latest." >&2
  fail=1
fi

compose_files=(docker-compose.yml docker-compose.spiffe.yml)
for file in "${compose_files[@]}"; do
  matched=$(rg -n 'image:\s+ghcr.io/carverauto/serviceradar-' "$file" || true)
  matched=$(printf '%s\n' "$matched" | rg -v 'serviceradar-cnpg' || true)
  matched=$(printf '%s\n' "$matched" | rg -F -v '${APP_TAG:-latest}' || true)
  if [[ -n "$matched" ]]; then
    echo "Found ServiceRadar images without APP_TAG default in $file:" >&2
    echo "$matched" >&2
    fail=1
  fi
done

if ! rg -n 'static_tags = \["latest"\] \+ target.get\("static_tags", \[\]\)' docker/images/push_targets.bzl >/dev/null; then
  echo "Expected docker/images/push_targets.bzl to include latest in static tags." >&2
  fail=1
fi

if [[ "$fail" -ne 0 ]]; then
  exit 1
fi

echo "Dev image tag defaults look good."
