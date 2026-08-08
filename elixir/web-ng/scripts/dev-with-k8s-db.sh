#!/usr/bin/env bash
# Run web-ng locally against the cluster CNPG database (same idea as
# ~/src/developer/scripts/dev-with-k8s-db.sh).
#
# Opens a port-forward to cnpg-rw, loads app credentials from the cluster
# secret, extracts the CA for TLS verify-full, then starts mix phx.server
# (or any command you pass).
#
# Usage (from elixir/web-ng, or via the thin wrappers below):
#   ./scripts/dev-with-k8s-db.sh
#   ./scripts/dev-with-k8s-db.sh mix phx.server
#   ./scripts/dev-with-k8s-db.sh mix test test/phoenix/live/dashboard_live_test.exs
#   NAMESPACE=demo LOCAL_PG_PORT=15432 ./scripts/dev-with-k8s-db.sh
#   ./scripts/dev-with-k8s-db.sh --context my-ctx
#   ./dev-k8s.sh              # thin wrapper → this script
#
# Defaults target the live **demo** namespace. Writes hit the real demo DB —
# prefer read-only browsing of the UI redesign unless you know what you're doing.
#
# Prerequisites:
#   - kubectl access to the target namespace
#   - Elixir/mix + (for UI) assets deps under assets/
#   - From a worktree/checkout that includes elixir/web-ng + path deps

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WEB_NG_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${WEB_NG_DIR}"

# --- defaults (override with env) ---
NAMESPACE="${NAMESPACE:-demo}"
SVC="${SVC:-cnpg-rw}"
CA_SECRET="${CA_SECRET:-cnpg-ca}"
CRED_SECRET="${CRED_SECRET:-serviceradar-db-credentials}"
LOCAL_PG_PORT="${LOCAL_PG_PORT:-${CNPG_LOCAL_PORT:-15432}}"
REMOTE_PG_PORT="${REMOTE_PG_PORT:-5432}"
PHX_PORT="${PHX_PORT:-4000}"
CNPG_DATABASE="${CNPG_DATABASE:-serviceradar}"
CNPG_SEARCH_PATH="${CNPG_SEARCH_PATH:-platform, public, ag_catalog}"
# Must match a SAN on the CNPG server cert (cnpg-rw is listed for demo).
CNPG_TLS_SERVER_NAME="${CNPG_TLS_SERVER_NAME:-cnpg-rw}"
CERT_DIR="${CNPG_CERT_DIR:-${WEB_NG_DIR}/.local-dev-certs}"
PF_LOG="${PF_LOG:-/tmp/serviceradar-web-ng-cnpg-forward.log}"

KUBE_CONTEXT="${KUBE_CONTEXT:-}"
EXTRA_ARGS=()

usage() {
  sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage ;;
    --context)
      KUBE_CONTEXT="${2:?--context requires a value}"
      shift 2
      ;;
    --namespace|-n)
      NAMESPACE="${2:?--namespace requires a value}"
      shift 2
      ;;
    --)
      shift
      EXTRA_ARGS+=("$@")
      break
      ;;
    *)
      EXTRA_ARGS+=("$1")
      shift
      ;;
  esac
done

if [[ ${#EXTRA_ARGS[@]} -eq 0 ]]; then
  EXTRA_ARGS=(mix phx.server)
fi

KUBECTL=(kubectl)
if [[ -n "${KUBE_CONTEXT}" ]]; then
  KUBECTL+=(--context "${KUBE_CONTEXT}")
fi

if ! command -v kubectl >/dev/null 2>&1; then
  echo "kubectl is required" >&2
  exit 1
fi

if ! command -v mix >/dev/null 2>&1; then
  echo "mix is required (install Elixir)" >&2
  exit 1
fi

if ! "${KUBECTL[@]}" get ns "${NAMESPACE}" >/dev/null 2>&1; then
  echo "Cannot access namespace '${NAMESPACE}' (context: $("${KUBECTL[@]}" config current-context 2>/dev/null || echo unknown))" >&2
  exit 1
fi

if ! "${KUBECTL[@]}" -n "${NAMESPACE}" get svc "${SVC}" >/dev/null 2>&1; then
  echo "Service ${NAMESPACE}/svc/${SVC} not found." >&2
  exit 1
fi

mkdir -p "${CERT_DIR}"

echo "==> Extracting CNPG CA (${NAMESPACE}/${CA_SECRET})"
if ! "${KUBECTL[@]}" -n "${NAMESPACE}" get secret "${CA_SECRET}" \
  -o jsonpath='{.data.ca\.crt}' | base64 -d >"${CERT_DIR}/root.pem"; then
  echo "Failed to read secret ${NAMESPACE}/${CA_SECRET}" >&2
  exit 1
fi
if [[ ! -s "${CERT_DIR}/root.pem" ]]; then
  echo "CA cert empty from ${NAMESPACE}/${CA_SECRET}" >&2
  exit 1
fi

echo "==> Loading DB credentials (${NAMESPACE}/${CRED_SECRET})"
CNPG_USERNAME="${CNPG_USERNAME:-$("${KUBECTL[@]}" -n "${NAMESPACE}" get secret "${CRED_SECRET}" -o jsonpath='{.data.username}' | base64 -d)}"
CNPG_PASSWORD="${CNPG_PASSWORD:-$("${KUBECTL[@]}" -n "${NAMESPACE}" get secret "${CRED_SECRET}" -o jsonpath='{.data.password}' | base64 -d)}"
if [[ -z "${CNPG_USERNAME}" || -z "${CNPG_PASSWORD}" ]]; then
  echo "Could not load username/password from ${NAMESPACE}/${CRED_SECRET}" >&2
  exit 1
fi

# App secrets — required to decrypt AshCloak fields (auth_settings OIDC/SAML secrets,
# credentials, etc.) that were encrypted by the in-cluster web-ng/core with CLOAK_KEY.
# Without this, local Phoenix uses the dev fallback key and every auth_settings read
# 500s with AshCloak FunctionClauseError on decrypt.
APP_SECRET="${APP_SECRET:-serviceradar-secrets}"
echo "==> Loading app secrets (${NAMESPACE}/${APP_SECRET})"
if "${KUBECTL[@]}" -n "${NAMESPACE}" get secret "${APP_SECRET}" >/dev/null 2>&1; then
  if [[ -z "${CLOAK_KEY:-}" ]]; then
    CLOAK_KEY="$("${KUBECTL[@]}" -n "${NAMESPACE}" get secret "${APP_SECRET}" \
      -o jsonpath='{.data.cloak-key}' | base64 -d)"
  fi
  if [[ -z "${SECRET_KEY_BASE:-}" ]]; then
    SECRET_KEY_BASE="$("${KUBECTL[@]}" -n "${NAMESPACE}" get secret "${APP_SECRET}" \
      -o jsonpath='{.data.web-ng-secret-key-base}' | base64 -d)"
  fi
  # Cluster maps edge crypto to web-ng-secret-key-base on the web-ng Deployment.
  if [[ -z "${SERVICERADAR_EDGE_CRYPTO_SECRET:-}" && -n "${SECRET_KEY_BASE:-}" ]]; then
    SERVICERADAR_EDGE_CRYPTO_SECRET="${SECRET_KEY_BASE}"
  fi
  if [[ -z "${CLOAK_KEY}" ]]; then
    echo "WARNING: ${APP_SECRET} has empty cloak-key; AuthSettings decrypt will fail." >&2
  else
    echo "  CLOAK_KEY loaded (len=${#CLOAK_KEY})"
  fi
else
  echo "WARNING: secret ${NAMESPACE}/${APP_SECRET} not found; using local dev cloak fallback" >&2
  echo "         (encrypted auth_settings rows will not decrypt)." >&2
fi

cleanup() {
  if [[ -n "${PF_PID:-}" ]] && kill -0 "${PF_PID}" 2>/dev/null; then
    kill "${PF_PID}" 2>/dev/null || true
    wait "${PF_PID}" 2>/dev/null || true
    echo "==> Port-forward stopped"
  fi
}
trap cleanup EXIT INT TERM

echo "==> Port-forwarding ${NAMESPACE}/svc/${SVC} ${LOCAL_PG_PORT}->${REMOTE_PG_PORT}"
echo "    log: ${PF_LOG}"
: >"${PF_LOG}"
"${KUBECTL[@]}" -n "${NAMESPACE}" port-forward "svc/${SVC}" \
  "${LOCAL_PG_PORT}:${REMOTE_PG_PORT}" >"${PF_LOG}" 2>&1 &
PF_PID=$!

ready=0
for _ in $(seq 1 40); do
  if ! kill -0 "${PF_PID}" 2>/dev/null; then
    echo "port-forward exited early; see ${PF_LOG}" >&2
    cat "${PF_LOG}" >&2 || true
    exit 1
  fi
  if command -v nc >/dev/null 2>&1; then
    if nc -z 127.0.0.1 "${LOCAL_PG_PORT}" 2>/dev/null; then
      ready=1
      break
    fi
  elif (echo >/dev/tcp/127.0.0.1/"${LOCAL_PG_PORT}") >/dev/null 2>&1; then
    ready=1
    break
  fi
  sleep 0.25
done

if [[ "${ready}" -ne 1 ]]; then
  echo "Timed out waiting for port-forward on 127.0.0.1:${LOCAL_PG_PORT}" >&2
  cat "${PF_LOG}" >&2 || true
  exit 1
fi

# Repo + TLS env consumed by config/dev.exs
export CNPG_HOST="127.0.0.1"
export CNPG_PORT="${LOCAL_PG_PORT}"
export CNPG_DATABASE
export CNPG_USERNAME
export CNPG_PASSWORD
export CNPG_SSL_MODE="${CNPG_SSL_MODE:-verify-full}"
export CNPG_CERT_DIR="${CERT_DIR}"
export CNPG_TLS_SERVER_NAME
export CNPG_SEARCH_PATH
# Password auth only — do not send workstation client certs.
export CNPG_CERT_FILE=""
export CNPG_KEY_FILE=""

# AshCloak / Phoenix secrets (must match cluster encryption for shared CNPG)
if [[ -n "${CLOAK_KEY:-}" ]]; then
  export CLOAK_KEY
fi
if [[ -n "${SECRET_KEY_BASE:-}" ]]; then
  export SECRET_KEY_BASE
  export DEV_SECRET_KEY_BASE="${DEV_SECRET_KEY_BASE:-${SECRET_KEY_BASE}}"
fi
if [[ -n "${SERVICERADAR_EDGE_CRYPTO_SECRET:-}" ]]; then
  export SERVICERADAR_EDGE_CRYPTO_SECRET
fi

# Phoenix local UX
export PHX_PORT
export BASE_URL="${BASE_URL:-http://127.0.0.1:${PHX_PORT}}"
export SERVICERADAR_GOD_VIEW_ENABLED="${SERVICERADAR_GOD_VIEW_ENABLED:-true}"
# Avoid noisy local OTEL export unless you intentionally wire a collector.
unset OTEL_EXPORTER_OTLP_ENDPOINT || true

# ---------------------------------------------------------------------------
# Migrations: web-ng must NEVER apply DDL against a shared/live CNPG.
# Schema ownership is core-elx / the core-migrations Job
# (SERVICERADAR_CORE_RUN_MIGRATIONS=true only there).
#
# Force-disable even if your shell exported the flag for a one-off migrate.
# The HTTP gate (RequireMigrations) only *checks* pending status; with a
# branch ahead of demo it 503s with a misleading "migrations still running"
# message — for local UI against demo we disable the gate by default.
# Override: SERVICERADAR_MIGRATIONS_GATE=true ./scripts/dev-with-k8s-db.sh
# ---------------------------------------------------------------------------
export SERVICERADAR_CORE_RUN_MIGRATIONS="${SERVICERADAR_CORE_RUN_MIGRATIONS:-false}"
if [[ "${SERVICERADAR_CORE_RUN_MIGRATIONS}" != "false" && "${SERVICERADAR_CORE_RUN_MIGRATIONS}" != "0" ]]; then
  echo "Refusing to start: SERVICERADAR_CORE_RUN_MIGRATIONS=${SERVICERADAR_CORE_RUN_MIGRATIONS}" >&2
  echo "Local web-ng against a shared namespace must not run DDL." >&2
  echo "Unset the var or pass SERVICERADAR_CORE_RUN_MIGRATIONS=false." >&2
  exit 1
fi
export SERVICERADAR_CORE_RUN_MIGRATIONS=false
export SERVICERADAR_MIGRATIONS_GATE="${SERVICERADAR_MIGRATIONS_GATE:-false}"

# datasvc gRPC client (ServiceRadar.DataService.Client) defaults to enabled and
# will forever log "Failed to connect to datasvc (:timeout)" when nothing is
# listening on datasvc:50057. Local UI work against CNPG does not need KV/object
# store. Port-forward datasvc yourself and set DATASVC_ENABLED=true if you do.
export DATASVC_ENABLED="${DATASVC_ENABLED:-false}"

echo ""
echo "Database  ${CNPG_HOST}:${CNPG_PORT}/${CNPG_DATABASE}  user=${CNPG_USERNAME}"
echo "TLS       mode=${CNPG_SSL_MODE}  sni=${CNPG_TLS_SERVER_NAME}  ca=${CERT_DIR}/root.pem"
echo "search_path=${CNPG_SEARCH_PATH}"
echo "Phoenix   ${BASE_URL}  (PHX_PORT=${PHX_PORT})"
echo "Migrations RUN=${SERVICERADAR_CORE_RUN_MIGRATIONS}  GATE=${SERVICERADAR_MIGRATIONS_GATE}"
echo "datasvc   ENABLED=${DATASVC_ENABLED}"
if [[ -n "${CLOAK_KEY:-}" ]]; then
  echo "cloak     loaded from cluster (len=${#CLOAK_KEY})"
else
  echo "cloak     MISSING (dev fallback — decrypt will fail)"
fi
echo ""
echo "WARNING: namespace=${NAMESPACE} is the live cluster DB."
echo "         web-ng will NOT run migrations (core-elx / migrate job only)."
echo "         Prefer UI browsing; never mix ecto.migrate against this DB."
echo "         CLOAK_KEY must match the cluster or AuthSettings 500s on decrypt."
echo ""

if [[ ! -d deps ]] || [[ ! -d _build ]]; then
  echo "==> mix deps.get (deps/_build missing)"
  mix deps.get
fi

if [[ ! -d assets/node_modules ]]; then
  echo "==> assets deps missing — install once for CSS/JS watchers:"
  echo "    (cd assets && bun install)   # or npm install"
fi

echo "==> exec: ${EXTRA_ARGS[*]}"
exec "${EXTRA_ARGS[@]}"
