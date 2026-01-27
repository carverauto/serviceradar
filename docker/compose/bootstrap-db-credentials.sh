#!/bin/sh
set -eu

CRED_DIR="${CNPG_CRED_DIR:-/etc/serviceradar/cnpg}"
SUPERUSER_FILE="${CNPG_SUPERUSER_PASSWORD_FILE:-$CRED_DIR/superuser-password}"
APP_FILE="${CNPG_APP_PASSWORD_FILE:-$CRED_DIR/serviceradar-password}"
SPIRE_FILE="${CNPG_SPIRE_PASSWORD_FILE:-$CRED_DIR/spire-password}"

umask 077
mkdir -p "$CRED_DIR"

generate_password() {
  openssl rand -hex 32
}

write_if_missing() {
  target="$1"
  value="$2"
  if [ -s "$target" ]; then
    echo "Password already present at $target; skipping"
    return
  fi
  printf "%s" "$value" > "$target"
  chmod 0600 "$target"
  echo "Wrote password to $target"
}

superuser_password="${CNPG_SUPERUSER_PASSWORD:-}"
if [ -z "$superuser_password" ] && [ -f "$SUPERUSER_FILE" ]; then
  superuser_password="$(cat "$SUPERUSER_FILE")"
fi
if [ -z "$superuser_password" ]; then
  superuser_password="$(generate_password)"
fi
write_if_missing "$SUPERUSER_FILE" "$superuser_password"

app_password="${CNPG_PASSWORD:-}"
if [ -z "$app_password" ] && [ -f "$APP_FILE" ]; then
  app_password="$(cat "$APP_FILE")"
fi
if [ -z "$app_password" ]; then
  app_password="$(generate_password)"
fi
write_if_missing "$APP_FILE" "$app_password"

spire_password="${CNPG_SPIRE_PASSWORD:-}"
if [ -z "$spire_password" ] && [ -f "$SPIRE_FILE" ]; then
  spire_password="$(cat "$SPIRE_FILE")"
fi
if [ -z "$spire_password" ]; then
  spire_password="$(generate_password)"
fi
write_if_missing "$SPIRE_FILE" "$spire_password"
