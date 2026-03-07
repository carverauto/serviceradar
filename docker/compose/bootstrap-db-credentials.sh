#!/bin/sh
set -eu

CRED_DIR="${CNPG_CRED_DIR:-/etc/serviceradar/cnpg}"
DATA_DIR="${CNPG_DATA_DIR:-/var/lib/postgresql/data}"
SUPERUSER_FILE="${CNPG_SUPERUSER_PASSWORD_FILE:-$CRED_DIR/superuser-password}"
SUPERUSER_USER_FILE="${CNPG_SUPERUSER_USER_FILE:-$CRED_DIR/superuser-username}"
APP_FILE="${CNPG_APP_PASSWORD_FILE:-$CRED_DIR/serviceradar-password}"
SPIRE_FILE="${CNPG_SPIRE_PASSWORD_FILE:-$CRED_DIR/spire-password}"
LEGACY_RECOVERY_MODE="${CNPG_LEGACY_RECOVERY:-auto}"
LEGACY_SUPERUSER="${CNPG_LEGACY_SUPERUSER:-serviceradar}"
LEGACY_SUPERUSER_PASSWORD="${CNPG_LEGACY_SUPERUSER_PASSWORD:-serviceradar}"
LEGACY_APP_PASSWORD="${CNPG_LEGACY_APP_PASSWORD:-serviceradar}"

umask 077
mkdir -p "$CRED_DIR"

generate_password() {
  od -An -N 32 -tx1 /dev/urandom | tr -d ' \n'
}

read_value() {
  target="$1"
  if [ -f "$target" ]; then
    tr -d '\r\n' < "$target"
  fi
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
    current="$(read_value "$target")"
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

has_any_persisted_credentials=false
for target in "$SUPERUSER_FILE" "$SUPERUSER_USER_FILE" "$APP_FILE"; do
  if [ -s "$target" ]; then
    has_any_persisted_credentials=true
    break
  fi
done

has_any_explicit_overrides=false
for value in "${CNPG_SUPERUSER:-}" "${CNPG_SUPERUSER_PASSWORD:-}" "${CNPG_PASSWORD:-}"; do
  if [ -n "$value" ]; then
    has_any_explicit_overrides=true
    break
  fi
done

use_legacy_defaults=false
if [ "$has_existing_db" = true ] && [ "$has_any_persisted_credentials" = false ] && [ "$has_any_explicit_overrides" = false ]; then
  case "$LEGACY_RECOVERY_MODE" in
    auto|"")
      use_legacy_defaults=true
      ;;
    true|TRUE|1|yes|YES|on|ON)
      use_legacy_defaults=true
      ;;
  esac
fi

if [ "$use_legacy_defaults" = true ]; then
  echo "Existing CNPG data detected without persisted credentials; assuming legacy Docker Compose defaults."
  echo "To override recovery values, set CNPG_SUPERUSER, CNPG_SUPERUSER_PASSWORD, and CNPG_PASSWORD."
fi

if [ -n "${CNPG_SUPERUSER:-}" ]; then
  superuser_name="$CNPG_SUPERUSER"
else
  superuser_name="$(read_value "$SUPERUSER_USER_FILE")"
  if [ -z "$superuser_name" ]; then
    if [ "$use_legacy_defaults" = true ]; then
      superuser_name="$LEGACY_SUPERUSER"
    else
      superuser_name="postgres"
    fi
  fi
fi
write_if_changed "$SUPERUSER_USER_FILE" "$superuser_name"

if [ -n "${CNPG_SUPERUSER_PASSWORD:-}" ]; then
  write_if_changed "$SUPERUSER_FILE" "$CNPG_SUPERUSER_PASSWORD"
  superuser_password="$CNPG_SUPERUSER_PASSWORD"
else
  superuser_password="$(read_value "$SUPERUSER_FILE")"
  if [ -z "$superuser_password" ]; then
    if [ "$use_legacy_defaults" = true ]; then
      superuser_password="$LEGACY_SUPERUSER_PASSWORD"
      write_if_changed "$SUPERUSER_FILE" "$superuser_password"
    elif [ "$has_existing_db" = true ]; then
      echo "Existing CNPG data detected but no superuser password provided." >&2
      echo "Set CNPG_SUPERUSER_PASSWORD or create $SUPERUSER_FILE before starting." >&2
      exit 1
    else
      superuser_password="$(generate_password)"
      write_if_missing "$SUPERUSER_FILE" "$superuser_password"
    fi
  fi
fi

if [ -n "${CNPG_PASSWORD:-}" ]; then
  write_if_changed "$APP_FILE" "$CNPG_PASSWORD"
  app_password="$CNPG_PASSWORD"
else
  app_password="$(read_value "$APP_FILE")"
  if [ -z "$app_password" ]; then
    if [ "$use_legacy_defaults" = true ]; then
      app_password="$LEGACY_APP_PASSWORD"
      write_if_changed "$APP_FILE" "$app_password"
    elif [ "$has_existing_db" = true ]; then
      echo "Existing CNPG data detected but no app password provided." >&2
      echo "Set CNPG_PASSWORD or create $APP_FILE before starting." >&2
      exit 1
    else
      app_password="$(generate_password)"
      write_if_missing "$APP_FILE" "$app_password"
    fi
  fi
fi

if [ -n "${CNPG_SPIRE_PASSWORD:-}" ]; then
  write_if_changed "$SPIRE_FILE" "$CNPG_SPIRE_PASSWORD"
fi
