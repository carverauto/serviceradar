#!/usr/bin/env bash
# Monorepo convenience entrypoint (mirrors ~/src/developer/scripts/dev-with-k8s-db.sh).
#
# Usage from repo root (or the UI worktree):
#   ./scripts/dev-web-ng-k8s.sh
#   ./scripts/dev-web-ng-k8s.sh mix phx.server
#   NAMESPACE=demo ./scripts/dev-web-ng-k8s.sh

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec "${ROOT}/elixir/web-ng/scripts/dev-with-k8s-db.sh" "$@"
