#!/bin/sh
# Ensure the shared Proton credentials file is readable by the application containers.
set -eu

PASSWORD_FILE="/etc/serviceradar/credentials/proton-password"
PASSWORD_DIR="/etc/serviceradar/credentials"
MAX_WAIT_SECONDS="${MAX_WAIT_SECONDS:-60}"
SLEEP_SECONDS="${SLEEP_SECONDS:-2}"

echo "[credentials-fixer] Waiting for ${PASSWORD_FILE}..."

elapsed=0
while [ $elapsed -lt "$MAX_WAIT_SECONDS" ]; do
    if [ -s "$PASSWORD_FILE" ]; then
        break
    fi
    sleep "$SLEEP_SECONDS"
    elapsed=$((elapsed + SLEEP_SECONDS))
done

if [ ! -s "$PASSWORD_FILE" ]; then
    echo "[credentials-fixer] ERROR: ${PASSWORD_FILE} not found or empty after waiting ${MAX_WAIT_SECONDS}s" >&2
    exit 1
fi

if [ -d "$PASSWORD_DIR" ]; then
    echo "[credentials-fixer] Setting directory ownership and permissions..."
    chown 1000:1000 "$PASSWORD_DIR"
    chmod 0755 "$PASSWORD_DIR"
fi

echo "[credentials-fixer] Setting ownership to 1000:1000..."
chown 1000:1000 "$PASSWORD_FILE"

echo "[credentials-fixer] Setting permissions to 0644..."
chmod 0644 "$PASSWORD_FILE"

echo "[credentials-fixer] Credentials file ready."
