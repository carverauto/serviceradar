#!/usr/bin/env bash
# Bazel test wrapper for @carverauto/create-dashboard. Same shape as the CLI
# wrapper at js/cli/scripts/bazel_test.sh — see that file for path-resolution
# rationale.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -n "${BUILD_WORKSPACE_DIRECTORY:-}" && -f "${BUILD_WORKSPACE_DIRECTORY}/js/create-dashboard/package.json" ]]; then
  PKG_DIR="${BUILD_WORKSPACE_DIRECTORY}/js/create-dashboard"
elif [[ -n "${TEST_SRCDIR:-}" && -n "${TEST_WORKSPACE:-}" ]]; then
  RUNFILES_PKG="${TEST_SRCDIR}/${TEST_WORKSPACE}/js/create-dashboard/package.json"
  if [[ -e "$RUNFILES_PKG" ]]; then
    PKG_DIR="$(dirname "$(readlink -f "$RUNFILES_PKG")")"
  fi
fi

if [[ -z "${PKG_DIR:-}" ]]; then
  PKG_DIR="$SCRIPT_DIR"
  while [[ "$PKG_DIR" != "/" && ! -f "$PKG_DIR/package.json" ]]; do
    PKG_DIR="$(dirname "$PKG_DIR")"
  done
fi

if [[ ! -f "$PKG_DIR/package.json" ]]; then
  echo "bazel_test.sh: could not locate js/create-dashboard/package.json from $SCRIPT_DIR" >&2
  exit 1
fi

cd "$PKG_DIR"

if ! command -v npm >/dev/null 2>&1; then
  echo "bazel_test.sh: npm not found on PATH; install Node.js >= 20 to run this target." >&2
  exit 1
fi

if [[ "${SR_CREATE_DASHBOARD_BAZEL_SKIP_INSTALL:-0}" != "1" ]]; then
  npm ci --no-audit --no-fund
fi

npm test
npm pack --dry-run "$PKG_DIR"
