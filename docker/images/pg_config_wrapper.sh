#!/usr/bin/env bash
set -euo pipefail

ROOT="${CNPG_ROOT:?CNPG_ROOT must be set}"
REAL="${CNPG_REAL_PG_CONFIG:?CNPG_REAL_PG_CONFIG must be set}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

"$REAL" "$@" | python3 "$SCRIPT_DIR/pg_config_rewrite.py"
