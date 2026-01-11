#!/bin/bash

# Run psql against CNPG with mTLS + password using .env defaults.
# Usage: ./scripts/psql-cnpg.sh [psql args...]

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT_DIR/.env}"

if [ -f "$ENV_FILE" ]; then
  set -a
  # shellcheck disable=SC1090
  . "$ENV_FILE"
  set +a
fi

if ! command -v psql >/dev/null 2>&1; then
  echo "Error: psql is required" >&2
  exit 1
fi

CNPG_HOST="${CNPG_HOST:-localhost}"
CNPG_PORT="${CNPG_PORT:-5455}"
CNPG_DATABASE="${CNPG_DATABASE:-serviceradar}"
CNPG_USERNAME="${CNPG_USERNAME:-serviceradar}"
CNPG_PASSWORD="${CNPG_PASSWORD:-}"
CNPG_SSL_MODE="${CNPG_SSL_MODE:-verify-full}"

if [ -z "$CNPG_PASSWORD" ]; then
  echo "Error: CNPG_PASSWORD is required (set in .env or env)" >&2
  exit 1
fi

CNPG_CERT_DIR="${CNPG_CERT_DIR:-}"
CNPG_CA_FILE="${CNPG_CA_FILE:-${CNPG_CERT_DIR}/root.pem}"
CNPG_CERT_FILE="${CNPG_CERT_FILE:-${CNPG_CERT_DIR}/workstation.pem}"
CNPG_KEY_FILE="${CNPG_KEY_FILE:-${CNPG_CERT_DIR}/workstation-key.pem}"

if [ ! -f "$CNPG_CA_FILE" ]; then
  echo "Error: CNPG_CA_FILE not found at $CNPG_CA_FILE" >&2
  exit 1
fi

if [ ! -f "$CNPG_CERT_FILE" ]; then
  echo "Error: CNPG_CERT_FILE not found at $CNPG_CERT_FILE" >&2
  exit 1
fi

if [ ! -f "$CNPG_KEY_FILE" ]; then
  echo "Error: CNPG_KEY_FILE not found at $CNPG_KEY_FILE" >&2
  exit 1
fi

PGPASSWORD="$CNPG_PASSWORD" \
PGSSLMODE="$CNPG_SSL_MODE" \
PGSSLROOTCERT="$CNPG_CA_FILE" \
PGSSLCERT="$CNPG_CERT_FILE" \
PGSSLKEY="$CNPG_KEY_FILE" \
exec psql -h "$CNPG_HOST" -p "$CNPG_PORT" -U "$CNPG_USERNAME" -d "$CNPG_DATABASE" "$@"
