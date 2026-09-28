#!/usr/bin/env bash
# Bazel test wrapper for the demo dashboard kit. Runs the kit's
# `node --test` suites (presenter logic, fixture round-trip, component
# renders with stand-in SDK hooks) from the source tree.
#
# Marked `local = True` + `no-sandbox` in BUILD.bazel because it shells out to
# the host's npm to install `react`/`react-dom` for the component tests:
# aspect_rules_js `npm_link_all_packages` may only run inside the
# `elixir/web-ng/assets` pnpm workspace, so the fenced `//demo` tree cannot
# consume the workspace lock, and the kit tests need the real React a
# dashboard runs on. Same corner as `//js/cli:ci` (see
# `js/cli/scripts/bazel_test.sh`).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -n "${BUILD_WORKSPACE_DIRECTORY:-}" && -f "${BUILD_WORKSPACE_DIRECTORY}/demo/dashboard-kit/package.json" ]]; then
  KIT_DIR="${BUILD_WORKSPACE_DIRECTORY}/demo/dashboard-kit"
elif [[ -n "${TEST_SRCDIR:-}" && -n "${TEST_WORKSPACE:-}" ]]; then
  RUNFILES_PKG="${TEST_SRCDIR}/${TEST_WORKSPACE}/demo/dashboard-kit/package.json"
  if [[ -e "$RUNFILES_PKG" ]]; then
    KIT_DIR="$(cd "$(dirname "$RUNFILES_PKG")" && pwd -P)"
  fi
fi

if [[ -z "${KIT_DIR:-}" ]]; then
  KIT_DIR="$SCRIPT_DIR"
  while [[ "$KIT_DIR" != "/" && ! -f "$KIT_DIR/package.json" ]]; do
    KIT_DIR="$(dirname "$KIT_DIR")"
  done
fi

if [[ ! -f "$KIT_DIR/package.json" ]]; then
  echo "bazel_test.sh: could not locate demo/dashboard-kit/package.json from $SCRIPT_DIR" >&2
  exit 1
fi

cd "$KIT_DIR"

# `bazel test` runs with a minimal PATH that hides version-manager installs.
if ! command -v npm >/dev/null 2>&1; then
  for dir in "$HOME"/.nvm/versions/node/*/bin /usr/local/bin /opt/homebrew/bin; do
    if [[ -x "$dir/npm" ]]; then
      export PATH="$dir:$PATH"
      break
    fi
  done
fi

if ! command -v npm >/dev/null 2>&1; then
  echo "bazel_test.sh: npm not found on PATH; install Node.js >= 20 to run this target." >&2
  exit 1
fi

if [[ ! -d node_modules/react || ! -d node_modules/react-dom ]]; then
  npm install --no-audit --no-fund
fi

node --test presenter.test.mjs fixtures.test.mjs hook.test.mjs kit.test.mjs
