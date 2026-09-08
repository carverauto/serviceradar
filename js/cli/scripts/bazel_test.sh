#!/usr/bin/env bash
# Bazel test wrapper for @carverauto/serviceradar-cli. Runs the same `npm run ci` pipeline
# (typecheck → unit tests → pack dry-run) that contributors run locally.
#
# Marked `local = True` + `no-sandbox` in BUILD.bazel because it shells out to
# the host's npm to install + execute. Bazel's nodejs toolchain is not used
# here yet; once the monorepo grows a shared npm-via-bazel pattern, this
# wrapper should adopt it.

set -euo pipefail

# Resolve the source `js/cli` directory. Three invocation modes are supported:
#   1. `bazel run //js/cli:ci`  — BUILD_WORKSPACE_DIRECTORY is set.
#   2. `bazel test //js/cli:ci` — TEST_SRCDIR + TEST_WORKSPACE are set; resolve
#      through the runfiles symlink to reach the real source dir so that
#      `npm pack` and friends operate on the workspace tree, not the read-only
#      runfiles tree.
#   3. Direct invocation outside Bazel — walk up from the script's location.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -n "${BUILD_WORKSPACE_DIRECTORY:-}" && -f "${BUILD_WORKSPACE_DIRECTORY}/js/cli/package.json" ]]; then
  CLI_DIR="${BUILD_WORKSPACE_DIRECTORY}/js/cli"
elif [[ -n "${TEST_SRCDIR:-}" && -n "${TEST_WORKSPACE:-}" ]]; then
  RUNFILES_PKG="${TEST_SRCDIR}/${TEST_WORKSPACE}/js/cli/package.json"
  if [[ -e "$RUNFILES_PKG" ]]; then
    CLI_DIR="$(dirname "$(readlink -f "$RUNFILES_PKG")")"
  fi
fi

if [[ -z "${CLI_DIR:-}" ]]; then
  CLI_DIR="$SCRIPT_DIR"
  while [[ "$CLI_DIR" != "/" && ! -f "$CLI_DIR/package.json" ]]; do
    CLI_DIR="$(dirname "$CLI_DIR")"
  done
fi

if [[ ! -f "$CLI_DIR/package.json" ]]; then
  echo "bazel_test.sh: could not locate js/cli/package.json from $SCRIPT_DIR" >&2
  exit 1
fi

cd "$CLI_DIR"

if ! command -v npm >/dev/null 2>&1; then
  echo "bazel_test.sh: npm not found on PATH; install Node.js >= 20 to run this target." >&2
  exit 1
fi

# Use a clean install when running under Bazel so the lockfile stays authoritative.
# Skip if node_modules already has the deps cached locally and CI=false is set.
if [[ "${SR_CLI_BAZEL_SKIP_INSTALL:-0}" != "1" ]]; then
  npm ci --no-audit --no-fund
fi

npm run typecheck
npm test
npm pack --dry-run "$CLI_DIR"
