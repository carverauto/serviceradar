#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
NAMESPACE="${NAMESPACE:-demo}"
PHX_PORT="${PHX_PORT:-4000}"
CNPG_DATABASE="${CNPG_DATABASE:-serviceradar}"
CNPG_USERNAME="${CNPG_USERNAME:-serviceradar}"
CNPG_SSL_MODE="${CNPG_SSL_MODE:-require}"
CNPG_POOL_SIZE="${CNPG_POOL_SIZE:-2}"
CNPG_QUEUE_TARGET_MS="${CNPG_QUEUE_TARGET_MS:-60000}"
CNPG_QUEUE_INTERVAL_MS="${CNPG_QUEUE_INTERVAL_MS:-60000}"
CHECK_ONLY=false

case "${1:-}" in
  --check)
    CHECK_ONLY=true
    ;;
  "")
    ;;
  *)
    echo "usage: $0 [--check]" >&2
    exit 2
    ;;
esac

need() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "missing required command: $1" >&2
    exit 1
  }
}

tcp_open() {
  local host="$1"
  local port="$2"

  nc -z -w 3 "$host" "$port" >/dev/null 2>&1
}

jsonpath() {
  kubectl "$@" 2>/dev/null || true
}

first_ipv4() {
  tr ' ' '\n' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -n 1
}

need kubectl
need nc
need base64
if [[ "$CHECK_ONLY" != "true" ]]; then
  need mix
fi

password="$(kubectl get secret serviceradar-db-credentials -n "$NAMESPACE" -o jsonpath='{.data.password}' | base64 -d)"
if [[ -z "$password" ]]; then
  echo "failed to read $NAMESPACE/serviceradar-db-credentials password" >&2
  exit 1
fi

declare -a candidates=()

if [[ -n "${CNPG_HOST_OVERRIDE:-}" ]]; then
  candidates+=("${CNPG_HOST_OVERRIDE}:${CNPG_PORT_OVERRIDE:-5432}:override")
fi

lb_ip="$(jsonpath get svc cnpg-rw-internal-lb -n "$NAMESPACE" -o jsonpath='{.status.loadBalancer.ingress[0].ip}')"
if [[ -n "$lb_ip" ]]; then
  candidates+=("${lb_ip}:5432:cnpg-rw-internal-lb-vip")
fi

primary_node="$(jsonpath get pod -n "$NAMESPACE" -l 'cnpg.io/cluster=cnpg,cnpg.io/instanceRole=primary' -o jsonpath='{.items[0].spec.nodeName}')"
if [[ -n "$primary_node" ]]; then
  primary_node_ip="$(jsonpath get node "$primary_node" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}' | first_ipv4)"

  if [[ -n "$primary_node_ip" ]]; then
    for svc in cnpg-rw-internal-lb cnpg-local-dev; do
      node_port="$(jsonpath get svc "$svc" -n "$NAMESPACE" -o jsonpath='{.spec.ports[0].nodePort}')"
      if [[ -n "$node_port" ]]; then
        candidates+=("${primary_node_ip}:${node_port}:${svc}-nodeport-on-${primary_node}")
      fi
    done
  fi
fi

if [[ ${#candidates[@]} -eq 0 ]]; then
  echo "no CNPG connection candidates found in namespace $NAMESPACE" >&2
  exit 1
fi

selected=""
for candidate in "${candidates[@]}"; do
  IFS=: read -r host port label <<<"$candidate"
  echo "checking $label at $host:$port"

  if tcp_open "$host" "$port"; then
    selected="$candidate"
    break
  fi
done

if [[ -z "$selected" ]]; then
  echo "no reachable CNPG route found; tried:" >&2
  printf '  %s\n' "${candidates[@]}" >&2
  exit 1
fi

IFS=: read -r cnpg_host cnpg_port cnpg_label <<<"$selected"
echo "using CNPG route: $cnpg_label at $cnpg_host:$cnpg_port"

if [[ "$CHECK_ONLY" == "true" ]]; then
  exit 0
fi

cd "$ROOT/elixir/web-ng"

exec env \
  DATASVC_ENABLED="${DATASVC_ENABLED:-false}" \
  SERVICE_HEARTBEAT_ENABLED="${SERVICE_HEARTBEAT_ENABLED:-false}" \
  SERVICERADAR_WEB_NG_OBAN_ENABLED="${SERVICERADAR_WEB_NG_OBAN_ENABLED:-false}" \
  SERVICERADAR_GOD_VIEW_RUNTIME_GRAPH_AUTO_REFRESH="${SERVICERADAR_GOD_VIEW_RUNTIME_GRAPH_AUTO_REFRESH:-false}" \
  PHX_HOST="${PHX_HOST:-localhost}" \
  PHX_PORT="$PHX_PORT" \
  SERVICERADAR_DEV_ROUTES="${SERVICERADAR_DEV_ROUTES:-true}" \
  CNPG_HOST="$cnpg_host" \
  CNPG_PORT="$cnpg_port" \
  CNPG_DATABASE="$CNPG_DATABASE" \
  CNPG_USERNAME="$CNPG_USERNAME" \
  CNPG_PASSWORD="$password" \
  CNPG_SSL_MODE="$CNPG_SSL_MODE" \
  CNPG_POOL_SIZE="$CNPG_POOL_SIZE" \
  CNPG_QUEUE_TARGET_MS="$CNPG_QUEUE_TARGET_MS" \
  CNPG_QUEUE_INTERVAL_MS="$CNPG_QUEUE_INTERVAL_MS" \
  mix phx.server
