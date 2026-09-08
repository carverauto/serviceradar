#!/usr/bin/env bash
set -euo pipefail

SWIFTLINT_CONFIG="${1:-.swiftlint.yml}"

if [[ -n "${BUILD_WORKSPACE_DIRECTORY:-}" ]]; then
  cd "${BUILD_WORKSPACE_DIRECTORY}"
fi

if [[ "$(uname -m)" == "arm64" ]]; then
  export PATH="/opt/homebrew/bin:$PATH"
fi

if ! command -v swiftlint >/dev/null 2>&1; then
  echo "swiftlint not found, install it from https://github.com/realm/SwiftLint" >&2
  exit 1
fi

swiftlint lint --config "${SWIFTLINT_CONFIG}"
