#!/usr/bin/env bash
# Wrapper around the Proton CLI that injects ServiceRadar defaults and TLS settings.
set -euo pipefail

HOST=${PROTON_HOST:-serviceradar-proton}
PORT=${PROTON_PORT:-9440}
USER=${PROTON_USER:-default}
DATABASE=${PROTON_DATABASE:-default}
SECURE=${PROTON_SECURE:-1}
CONFIG_PATH=${PROTON_CONFIG:-/etc/serviceradar/proton-client/config.xml}
PASSWORD=${PROTON_PASSWORD:-}
PASSWORD_FILE=${PROTON_PASSWORD_FILE:-}
PASSWORD_CREDENTIALS_PATH=${PROTON_PASSWORD_CREDENTIALS_PATH:-/etc/serviceradar/credentials/proton-password}
PROTON_BIN=${PROTON_BIN:-/usr/local/bin/proton}
GLIBC_LIB=${GLIBC_LIB:-/usr/glibc-compat/lib}
GLIBC_LIB64=${GLIBC_LIB64:-/usr/glibc-compat/lib64}

if [ -d "$GLIBC_LIB" ]; then
    export LD_LIBRARY_PATH="${GLIBC_LIB}${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"
fi
if [ -d "$GLIBC_LIB64" ]; then
    export LD_LIBRARY_PATH="${GLIBC_LIB64}${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"
fi

read_password_from() {
    local candidate="$1"
    if [[ -z "$candidate" ]]; then
        return 1
    fi
    if [[ -r "$candidate" ]]; then
        PASSWORD=$(<"$candidate")
        PASSWORD=${PASSWORD//$'\r'/}
        PASSWORD=${PASSWORD//$'\n'/}
        return 0
    fi
    return 1
}

if [[ -z "$PASSWORD" ]]; then
    if ! read_password_from "$PASSWORD_FILE"; then
        if ! read_password_from "$PASSWORD_CREDENTIALS_PATH"; then
            if ! read_password_from "/etc/proton-server/generated_password.txt"; then
                read_password_from "/etc/serviceradar/certs/password.txt" || true
            fi
        fi
    fi
fi

args=("client" "--host" "$HOST" "--port" "$PORT")

if [[ "${SECURE}" != "0" ]]; then
    args+=("--secure")
fi

if [[ -n "$DATABASE" ]]; then
    args+=("--database" "$DATABASE")
fi

if [[ -n "$USER" ]]; then
    args+=("--user" "$USER")
fi

if [[ -n "$PASSWORD" ]]; then
    args+=("--password" "$PASSWORD")
fi

if [[ -n "$CONFIG_PATH" && -r "$CONFIG_PATH" ]]; then
    args+=("--config-file" "$CONFIG_PATH")
fi

if [[ ! -x "$PROTON_BIN" ]]; then
    echo "proton-client wrapper: missing proton binary at $PROTON_BIN" >&2
    exit 127
fi

exec "$PROTON_BIN" "${args[@]}" "$@"
