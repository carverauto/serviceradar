#!/usr/bin/env bash

set -euo pipefail

namespace="${SRQL_FIXTURE_NAMESPACE:-srql-fixtures}"
service="${SRQL_FIXTURE_SERVICE:-svc/srql-fixture-rw}"
local_host="${SRQL_FIXTURE_LOCAL_HOST:-127.0.0.1}"
local_port="${SRQL_FIXTURE_LOCAL_PORT:-5455}"
cache_root="${XDG_CACHE_HOME:-$HOME/.cache}/serviceradar"
ca_file="${cache_root}/srql-fixture-ca.crt"
port_forward_log="${cache_root}/srql-fixture-port-forward.log"
port_forward_pid_file="${cache_root}/srql-fixture-port-forward.pid"

mkdir -p "${cache_root}"

shell_quote() {
  printf "%q" "$1"
}

build_postgres_url() {
  local username="$1"
  local password="$2"
  local hostname="$3"
  local port="$4"
  local dbname="$5"

  python3 - "$username" "$password" "$hostname" "$port" "$dbname" <<'PY'
import sys
from urllib.parse import quote

user, password, host, port, dbname = sys.argv[1:]
print(
    f"postgres://{quote(user, safe='')}:{quote(password, safe='')}@"
    f"{host}:{port}/{quote(dbname, safe='')}?sslmode=require"
)
PY
}

port_is_listening() {
  python3 - "$local_host" "$local_port" <<'PY'
import socket
import sys

host = sys.argv[1]
port = int(sys.argv[2])

with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
    sock.settimeout(0.2)
    result = sock.connect_ex((host, port))
    raise SystemExit(0 if result == 0 else 1)
PY
}

clear_stale_listeners() {
  if ! command -v lsof >/dev/null 2>&1; then
    return 0
  fi

  local listeners
  listeners="$(lsof -tiTCP:"${local_port}" -sTCP:LISTEN 2>/dev/null || true)"

  if [[ -n "${listeners}" ]]; then
    kill ${listeners} 2>/dev/null || true
    sleep 0.5
  fi
}

start_port_forward() {
  local target="${service}"

  if [[ -f "${port_forward_pid_file}" ]]; then
    local existing_pid
    existing_pid="$(cat "${port_forward_pid_file}")"
    if kill -0 "${existing_pid}" 2>/dev/null; then
      for _ in {1..20}; do
        if port_is_listening; then
          return 0
        fi
        sleep 0.25
      done

      kill "${existing_pid}" 2>/dev/null || true
      rm -f "${port_forward_pid_file}"
    fi
  fi

  clear_stale_listeners

  nohup env \
    SRQL_FIXTURE_NAMESPACE="${namespace}" \
    SRQL_FIXTURE_TARGET="${target}" \
    SRQL_FIXTURE_LOCAL_PORT="${local_port}" \
    SRQL_FIXTURE_PORT_FORWARD_LOG="${port_forward_log}" \
    bash -lc '
      while true; do
        if python3 - "${SRQL_FIXTURE_LOCAL_PORT}" <<'"'"'PY'"'"'
import socket
import sys

port = int(sys.argv[1])
for host in ("127.0.0.1", "::1"):
    family = socket.AF_INET6 if ":" in host else socket.AF_INET
    with socket.socket(family, socket.SOCK_STREAM) as sock:
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        if sock.connect_ex((host, port)) == 0:
            raise SystemExit(0)
raise SystemExit(1)
PY
        then
          sleep 1
          continue
        fi

        kubectl port-forward --address 127.0.0.1 -n "${SRQL_FIXTURE_NAMESPACE}" "${SRQL_FIXTURE_TARGET}" "${SRQL_FIXTURE_LOCAL_PORT}:5432" \
          >>"${SRQL_FIXTURE_PORT_FORWARD_LOG}" 2>&1 || true
        sleep 1
      done
    ' >/dev/null 2>&1 &
  local pf_pid=$!
  echo "${pf_pid}" >"${port_forward_pid_file}"

  for _ in {1..40}; do
    if port_is_listening; then
      return 0
    fi

    if ! kill -0 "${pf_pid}" 2>/dev/null; then
      echo "failed to start port-forward to ${namespace}/${service}; see ${port_forward_log}" >&2
      exit 1
    fi

    sleep 0.25
  done

  echo "timed out waiting for port-forward on ${local_host}:${local_port}; see ${port_forward_log}" >&2
  exit 1
}

fetch_secret_field() {
  local secret_name="$1"
  local field="$2"

  kubectl get secret "${secret_name}" -n "${namespace}" -o "jsonpath={.data.${field}}" | base64 -d
}

write_ca_file() {
  kubectl get secret srql-fixture-ca -n "${namespace}" -o jsonpath='{.data.ca\.crt}' | base64 -d >"${ca_file}"
}

emit_env() {
  local db_user db_pass admin_user admin_pass db_url admin_url db_name admin_db_name

  write_ca_file

  if [[ "${SRQL_FIXTURE_SKIP_PORT_FORWARD:-0}" != "1" ]]; then
    start_port_forward
  fi

  db_user="$(fetch_secret_field srql-test-db-credentials username)"
  db_pass="$(fetch_secret_field srql-test-db-credentials password)"
  admin_user="$(fetch_secret_field srql-test-admin-credentials username)"
  admin_pass="$(fetch_secret_field srql-test-admin-credentials password)"
  db_name="${SRQL_FIXTURE_DATABASE_NAME:-serviceradar_web_ng_test}"
  admin_db_name="${SRQL_FIXTURE_ADMIN_DATABASE_NAME:-postgres}"

  db_url="$(build_postgres_url "${db_user}" "${db_pass}" "${local_host}" "${local_port}" "${db_name}")"
  admin_url="$(build_postgres_url "${admin_user}" "${admin_pass}" "${local_host}" "${local_port}" "${admin_db_name}")"

  cat <<EOF
unset CNPG_CERT_DIR
unset CNPG_CERT_FILE
unset CNPG_KEY_FILE
export CNPG_HOST=$(shell_quote "${local_host}")
export CNPG_PORT=$(shell_quote "${local_port}")
export CNPG_DATABASE=$(shell_quote "${db_name}")
export CNPG_USERNAME=$(shell_quote "${admin_user}")
export CNPG_PASSWORD=$(shell_quote "${admin_pass}")
export CNPG_ADMIN_DATABASE=$(shell_quote "${admin_db_name}")
export CNPG_APP_USER=$(shell_quote "${db_user}")
export CNPG_APP_PASSWORD=$(shell_quote "${db_pass}")
export CNPG_SSL_MODE=require
unset CNPG_TLS_SERVER_NAME
export SERVICERADAR_TEST_DATABASE_URL=$(shell_quote "${db_url}")
export SERVICERADAR_TEST_ADMIN_URL=$(shell_quote "${admin_url}")
export PGSSLROOTCERT=$(shell_quote "${ca_file}")
export CNPG_CA_FILE=$(shell_quote "${ca_file}")
export SERVICERADAR_TEST_DATABASE_CA_CERT_FILE=$(shell_quote "${ca_file}")
export SRQL_TEST_DATABASE_CA_CERT_FILE=$(shell_quote "${ca_file}")
export SERVICERADAR_USE_SRQL_FIXTURE_RESET=1
export SERVICERADAR_TEST_DATABASE_POOL_SIZE=${SERVICERADAR_TEST_DATABASE_POOL_SIZE:-10}
export SERVICERADAR_TEST_DATABASE_QUEUE_TARGET_MS=${SERVICERADAR_TEST_DATABASE_QUEUE_TARGET_MS:-20000}
export SERVICERADAR_TEST_DATABASE_QUEUE_INTERVAL_MS=${SERVICERADAR_TEST_DATABASE_QUEUE_INTERVAL_MS:-2000}
EOF
}

if [[ "${1:-}" == "--print-env" ]]; then
  shift
  emit_env
  exit 0
fi

eval "$(emit_env)"

if [[ "$#" -eq 0 ]]; then
  exec "${SHELL:-/bin/zsh}" -l
fi

exec "$@"
