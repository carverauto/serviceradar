#!/usr/bin/env bash
# Thin wrapper — canonical script lives in scripts/dev-with-k8s-db.sh
#
# Usage:
#   ./dev-k8s.sh
#   ./dev-k8s.sh demo
#   ./dev-k8s.sh demo my-kube-context
#   ./dev-k8s.sh -- mix test
#   NAMESPACE=demo ./dev-k8s.sh mix phx.server

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="${SCRIPT_DIR}/scripts/dev-with-k8s-db.sh"

# Back-compat: ./dev-k8s.sh [namespace] [context] [cmd...]
args=()
if [[ $# -ge 1 && "$1" != -* && "$1" != mix ]]; then
  args+=(--namespace "$1")
  shift
  if [[ $# -ge 1 && "$1" != -* && "$1" != mix ]]; then
    args+=(--context "$1")
    shift
  fi
fi

exec "$TARGET" "${args[@]}" "$@"
