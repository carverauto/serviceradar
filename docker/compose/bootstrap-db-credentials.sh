#!/bin/sh
set -eu

CRED_DIR="${CNPG_CRED_DIR:-/etc/serviceradar/cnpg}"
DATA_DIR="${CNPG_DATA_DIR:-/var/lib/postgresql/data}"
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
    chmod "${CNPG_CRED_MODE:-0644}" "$target"
    return
  fi
  printf "%s" "$value" > "$target"
  chmod "${CNPG_CRED_MODE:-0644}" "$target"
  echo "Wrote password to $target"
}

write_if_changed() {
  target="$1"
  value="$2"
  if [ -f "$target" ]; then
    current="$(cat "$target")"
    if [ "$current" = "$value" ]; then
      echo "Password already matches at $target; skipping"
      chmod "${CNPG_CRED_MODE:-0644}" "$target"
      return
    fi
  fi
  printf "%s" "$value" > "$target"
  chmod "${CNPG_CRED_MODE:-0644}" "$target"
  echo "Synced password to $target"
}

has_existing_db=false
if [ -f "$DATA_DIR/PG_VERSION" ]; then
  has_existing_db=true
fi

if [ -n "${CNPG_SUPERUSER_PASSWORD:-}" ]; then
  write_if_changed "$SUPERUSER_FILE" "$CNPG_SUPERUSER_PASSWORD"
  superuser_password="$CNPG_SUPERUSER_PASSWORD"
else
  superuser_password=""
  if [ -f "$SUPERUSER_FILE" ]; then
    superuser_password="$(cat "$SUPERUSER_FILE")"
  fi
  if [ -z "$superuser_password" ]; then
    if [ "$has_existing_db" = true ]; then
      echo "Existing CNPG data detected but no superuser password provided." >&2
      echo "Set CNPG_SUPERUSER_PASSWORD or create $SUPERUSER_FILE before starting." >&2
      exit 1
    fi
    superuser_password="$(generate_password)"
    write_if_missing "$SUPERUSER_FILE" "$superuser_password"
  fi
fi

if [ -n "${CNPG_PASSWORD:-}" ]; then
  write_if_changed "$APP_FILE" "$CNPG_PASSWORD"
  app_password="$CNPG_PASSWORD"
else
  app_password=""
  if [ -f "$APP_FILE" ]; then
    app_password="$(cat "$APP_FILE")"
  fi
  if [ -z "$app_password" ]; then
    if [ "$has_existing_db" = true ]; then
      echo "Existing CNPG data detected but no app password provided." >&2
      echo "Set CNPG_PASSWORD or create $APP_FILE before starting." >&2
      exit 1
    fi
    app_password="$(generate_password)"
    write_if_missing "$APP_FILE" "$app_password"
  fi
fi

if [ -n "${CNPG_SPIRE_PASSWORD:-}" ]; then
  write_if_changed "$SPIRE_FILE" "$CNPG_SPIRE_PASSWORD"
  spire_password="$CNPG_SPIRE_PASSWORD"
else
  spire_password=""
  if [ -f "$SPIRE_FILE" ]; then
    spire_password="$(cat "$SPIRE_FILE")"
  fi
  if [ -z "$spire_password" ]; then
    if [ "$has_existing_db" = true ]; then
      echo "Existing CNPG data detected but no spire password provided." >&2
      echo "Set CNPG_SPIRE_PASSWORD or create $SPIRE_FILE before starting." >&2
      exit 1
    fi
    spire_password="$(generate_password)"
    write_if_missing "$SPIRE_FILE" "$spire_password"
  fi
fi
