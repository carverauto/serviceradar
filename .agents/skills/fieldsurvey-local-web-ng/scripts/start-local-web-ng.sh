#!/usr/bin/env bash
set -euo pipefail

namespace="${NAMESPACE:-demo}"
cnpg_service="${CNPG_NODEPORT_SERVICE:-cnpg-local-dev}"
nats_service="${NATS_SERVICE:-serviceradar-nats}"
nats_port="${LOCAL_NATS_PORT:-4222}"
phx_port="${PHX_PORT:-4000}"

repo_root="$(git rev-parse --show-toplevel)"
work_dir="${repo_root}/tmp/fieldsurvey-local"
cert_dir="${work_dir}/certs"
creds_dir="${work_dir}/creds"

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    printf 'Missing required command: %s\n' "$1" >&2
    exit 1
  fi
}

require_cmd kubectl
require_cmd psql
require_cmd base64
require_cmd lsof

mkdir -p "$cert_dir" "$creds_dir"

db_user="$(
  kubectl get secret serviceradar-db-credentials -n "$namespace" \
    -o jsonpath='{.data.username}' | base64 -d
)"
db_password="$(
  kubectl get secret serviceradar-db-credentials -n "$namespace" \
    -o jsonpath='{.data.password}' | base64 -d
)"
db_port="$(
  kubectl get svc "$cnpg_service" -n "$namespace" \
    -o jsonpath='{.spec.ports[0].nodePort}'
)"

kubectl get secret -n "$namespace" serviceradar-runtime-certs \
  -o jsonpath='{.data.root\.pem}' | base64 -d > "${cert_dir}/root.pem"
kubectl get secret -n "$namespace" serviceradar-runtime-certs \
  -o jsonpath='{.data.core\.pem}' | base64 -d > "${cert_dir}/core.pem"
kubectl get secret -n "$namespace" serviceradar-runtime-certs \
  -o jsonpath='{.data.core-key\.pem}' | base64 -d > "${cert_dir}/core-key.pem"
kubectl get secret -n "$namespace" serviceradar-nats-creds \
  -o jsonpath='{.data.platform\.creds}' | base64 -d > "${creds_dir}/platform.creds"
chmod 600 "${cert_dir}"/* "${creds_dir}"/*

db_host=""
while IFS= read -r node_ip; do
  if PGPASSWORD="$db_password" psql \
    "sslmode=require host=${node_ip} port=${db_port} user=${db_user} dbname=serviceradar connect_timeout=3" \
    -Atc 'select 1' >/dev/null 2>&1; then
    db_host="$node_ip"
    break
  fi
done < <(kubectl get nodes -o jsonpath='{range .items[*]}{.status.addresses[?(@.type=="InternalIP")].address}{"\n"}{end}')

if [[ -z "$db_host" ]]; then
  printf 'Could not reach %s NodePort %s from any Kubernetes node IP.\n' "$cnpg_service" "$db_port" >&2
  exit 1
fi

started_nats=0
if ! lsof -nP -iTCP:"$nats_port" -sTCP:LISTEN >/dev/null 2>&1; then
  kubectl port-forward -n "$namespace" "svc/${nats_service}" "${nats_port}:4222" \
    > "${work_dir}/nats-port-forward.log" 2>&1 &
  echo "$!" > "${work_dir}/nats-port-forward.pid"
  started_nats=1
  sleep 1
fi

cleanup() {
  if [[ "$started_nats" == "1" ]] && [[ -f "${work_dir}/nats-port-forward.pid" ]]; then
    kill "$(cat "${work_dir}/nats-port-forward.pid")" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

printf 'Starting web-ng at http://localhost:%s using CNPG %s:%s and NATS localhost:%s\n' \
  "$phx_port" "$db_host" "$db_port" "$nats_port"

cd "${repo_root}/elixir/web-ng"

CNPG_HOST="$db_host" \
CNPG_PORT="$db_port" \
CNPG_DATABASE=serviceradar \
CNPG_USERNAME="$db_user" \
CNPG_PASSWORD="$db_password" \
CNPG_SSL_MODE=require \
CNPG_SEARCH_PATH='platform, public, ag_catalog' \
CNPG_POOL_SIZE="${CNPG_POOL_SIZE:-10}" \
DATABASE_PREPARE=unnamed \
SERVICERADAR_DEV_ROUTES=true \
SERVICERADAR_LOCAL_MAILER=true \
SERVICERADAR_WEB_NG_OBAN_ENABLED=false \
SERVICERADAR_LOCAL_LOG_LEVEL="${SERVICERADAR_LOCAL_LOG_LEVEL:-info}" \
NATS_ENABLED=true \
NATS_URL="tls://127.0.0.1:${nats_port}" \
NATS_TLS=true \
NATS_SERVER_NAME=serviceradar-nats \
SPIFFE_CERT_DIR="$cert_dir" \
NATS_CREDS_FILE="${creds_dir}/platform.creds" \
PHX_HOST=localhost \
PHX_PORT="$phx_port" \
mix phx.server
