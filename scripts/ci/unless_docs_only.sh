#!/usr/bin/env bash
set -euo pipefail

MARKER="${DOCS_ONLY_MARKER:-/tmp/serviceradar-docs-only-marker}"

if [ -e "$MARKER" ]; then
  echo "docs-only change: BazelCI step skipped ($*)"
  exit 0
fi

exec "$@"
