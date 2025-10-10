#!/usr/bin/env bash
set -euo pipefail

if [[ $# -eq 0 ]]; then
    echo "Usage: proton-sql <SQL...>" >&2
    echo "  proton-sql SELECT 1" >&2
    echo "  proton-sql \"SELECT count() FROM table(unified_devices)\"" >&2
    exit 1
fi

query="$*"
exec proton-client --query "$query"
