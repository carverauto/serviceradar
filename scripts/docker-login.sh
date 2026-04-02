#!/usr/bin/env bash

set -euo pipefail

REGISTRY_HOST="${REGISTRY_HOST:-registry.carverauto.dev}"
USERNAME="${HARBOR_ROBOT_USERNAME:-}"
SECRET="${HARBOR_ROBOT_SECRET:-}"

usage() {
  cat <<'EOF'
Usage: ./scripts/docker-login.sh [--host HOST] [--username USERNAME] [--token TOKEN]

Logs Docker into the ServiceRadar Harbor registry.

Environment:
  HARBOR_ROBOT_USERNAME   Harbor robot or user name
  HARBOR_ROBOT_SECRET     Harbor robot secret or password
  REGISTRY_HOST           Registry host (default: registry.carverauto.dev)
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host)
      REGISTRY_HOST="$2"
      shift 2
      ;;
    --username)
      USERNAME="$2"
      shift 2
      ;;
    --token|--password)
      SECRET="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ -z "$USERNAME" ]]; then
  echo "HARBOR_ROBOT_USERNAME is required" >&2
  exit 1
fi

if [[ -z "$SECRET" ]]; then
  echo "HARBOR_ROBOT_SECRET is required" >&2
  exit 1
fi

echo "$SECRET" | docker login "$REGISTRY_HOST" -u "$USERNAME" --password-stdin
