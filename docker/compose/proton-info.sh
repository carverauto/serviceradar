#!/usr/bin/env bash
set -euo pipefail

HOST=${PROTON_HOST:-serviceradar-proton}
PORT=${PROTON_PORT:-9440}
DATABASE=${PROTON_DATABASE:-default}
SECURE=${PROTON_SECURE:-1}
CONFIG=${PROTON_CONFIG:-/etc/serviceradar/proton-client/config.xml}
PASSWORD_FILE=${PROTON_PASSWORD_FILE:-}
PASSWORD=${PROTON_PASSWORD:-}
CLIENT_BIN=${PROTON_BIN:-/usr/local/bin/proton}
REAL_BIN=${PROTON_REAL:-/usr/local/bin/proton.bin}

printf 'Proton connection defaults\n'
printf '  host: %s\n' "$HOST"
printf '  port: %s\n' "$PORT"
printf '  database: %s\n' "$DATABASE"
printf '  secure: %s\n' "$SECURE"
printf '  config: %s\n' "$CONFIG"
if [[ -n "$PASSWORD_FILE" && -r "$PASSWORD_FILE" ]]; then
    printf '  password source: file (%s)\n' "$PASSWORD_FILE"
elif [[ -n "$PASSWORD" ]]; then
    printf '  password source: env (PROTON_PASSWORD)\n'
else
    printf '  password source: <not set>\n'
fi
if [[ -r /etc/serviceradar/credentials/proton-password ]]; then
    printf '  mounted secret: /etc/serviceradar/credentials/proton-password\n'
fi
printf '\nBinaries\n'
printf '  proton wrapper: %s\n' "$CLIENT_BIN"
printf '  proton binary:  %s\n' "$REAL_BIN"
printf '\nRun a quick probe:\n  proton_sql "SELECT 1"\n  proton-client --query "SHOW DATABASES"\n'
