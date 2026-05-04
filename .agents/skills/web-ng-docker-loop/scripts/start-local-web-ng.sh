#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: start-local-web-ng.sh [--repair-app-password] [--refresh-certs] [--no-validate] [--no-sync-plugin-storage] [--port PORT]

Start elixir/web-ng locally against the Docker Compose CNPG database.

Options:
  --repair-app-password  Reset the local Docker CNPG serviceradar role to the Docker app secret before starting.
  --refresh-certs        Re-copy CNPG client certs from the running Docker web-ng container.
  --no-validate          Skip psql validation before starting Phoenix.
  --no-sync-plugin-storage
                         Skip copying Docker filesystem plugin/dashboard package blobs into tmp/.
  --validate-only        Validate cert/password access and exit without starting Phoenix.
  --port PORT            Phoenix port, default 4000.
USAGE
}

repair_app_password=false
refresh_certs=false
validate_db=true
validate_only=false
sync_plugin_storage=true
phx_port="${PHX_PORT:-4000}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repair-app-password)
      repair_app_password=true
      shift
      ;;
    --refresh-certs)
      refresh_certs=true
      shift
      ;;
    --no-validate)
      validate_db=false
      shift
      ;;
    --no-sync-plugin-storage)
      sync_plugin_storage=false
      shift
      ;;
    --validate-only)
      validate_only=true
      shift
      ;;
    --port)
      phx_port="${2:?missing port}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

repo_root="$(git rev-parse --show-toplevel)"
web_container="${WEB_NG_CONTAINER:-serviceradar-web-ng-mtls}"
cnpg_container="${CNPG_CONTAINER:-serviceradar-cnpg-mtls}"
cert_dir="${SERVICERADAR_LOCAL_CNPG_CERT_DIR:-$repo_root/tmp/web-ng-docker-loop/certs}"
plugin_storage_path="${PLUGIN_STORAGE_PATH:-$repo_root/tmp/web-ng-docker-loop/plugin-packages}"
cnpg_host="${CNPG_HOST:-localhost}"
cnpg_port="${CNPG_PORT:-5455}"
cnpg_database="${CNPG_DATABASE:-serviceradar}"
cnpg_username="${CNPG_USERNAME:-serviceradar}"

require_container() {
  local name="$1"
  if ! docker inspect "$name" >/dev/null 2>&1; then
    echo "container not found: $name" >&2
    exit 1
  fi
}

copy_cert() {
  local src="$1"
  local dst="$2"
  if [[ "$refresh_certs" == true || ! -s "$dst" ]]; then
    docker cp "$web_container:$src" "$dst"
  fi
}

require_container "$web_container"
require_container "$cnpg_container"

mkdir -p "$cert_dir"
copy_cert /etc/serviceradar/certs/root.pem "$cert_dir/root.pem"
copy_cert /etc/serviceradar/certs/db-client.pem "$cert_dir/db-client.pem"
copy_cert /etc/serviceradar/certs/db-client-key.pem "$cert_dir/db-client-key.pem"
chmod 600 "$cert_dir/db-client-key.pem"

app_password="$(docker exec "$web_container" sh -c 'cat /etc/serviceradar/cnpg/serviceradar-password')"

validate_app_connection() {
  PGPASSWORD="$app_password" \
    PGSSLMODE=verify-full \
    PGSSLROOTCERT="$cert_dir/root.pem" \
    PGSSLCERT="$cert_dir/db-client.pem" \
    PGSSLKEY="$cert_dir/db-client-key.pem" \
    psql -h "$cnpg_host" -p "$cnpg_port" -U "$cnpg_username" -d "$cnpg_database" \
      -v ON_ERROR_STOP=1 -c 'select current_user' >/dev/null
}

repair_password() {
  local super_cert="$cert_dir/db-superuser.pem"
  local super_key="$cert_dir/db-superuser-key.pem"
  copy_cert /etc/serviceradar/certs/db-superuser.pem "$super_cert"
  copy_cert /etc/serviceradar/certs/db-superuser-key.pem "$super_key"
  chmod 600 "$super_key"

  local super_user
  local super_password
  super_user="$(docker exec "$cnpg_container" sh -c 'cat /etc/serviceradar/cnpg/superuser-username 2>/dev/null || printf postgres')"
  super_password="$(docker exec "$cnpg_container" sh -c 'cat /etc/serviceradar/cnpg/superuser-password')"

  PGPASSWORD="$super_password" \
    PGSSLMODE=verify-full \
    PGSSLROOTCERT="$cert_dir/root.pem" \
    PGSSLCERT="$super_cert" \
    PGSSLKEY="$super_key" \
    psql -h "$cnpg_host" -p "$cnpg_port" -U "$super_user" -d "$cnpg_database" \
      -v ON_ERROR_STOP=1 \
      --set=app_password="$app_password" \
      -c "alter role serviceradar with password :'app_password';" >/dev/null
}

if [[ "$repair_app_password" == true ]]; then
  echo "Repairing local Docker CNPG app password from Docker secret..."
  repair_password
fi

if [[ "$validate_db" == true ]]; then
  echo "Validating CNPG mTLS connection on $cnpg_host:$cnpg_port..."
  if ! validate_app_connection; then
    echo "CNPG validation failed. If this is a local Docker stack, rerun with --repair-app-password." >&2
    exit 1
  fi
fi

if [[ "$validate_only" == true ]]; then
  echo "CNPG validation succeeded."
  exit 0
fi

if [[ "$sync_plugin_storage" == true ]]; then
  echo "Syncing Docker plugin/dashboard package blobs into $plugin_storage_path..."
  rm -rf "$plugin_storage_path"
  mkdir -p "$(dirname "$plugin_storage_path")"
  docker cp "$web_container:/var/lib/serviceradar/plugin-packages" "$plugin_storage_path"
fi

cd "$repo_root/elixir/web-ng"

export DATASVC_ENABLED="${DATASVC_ENABLED:-false}"
export SERVICE_HEARTBEAT_ENABLED="${SERVICE_HEARTBEAT_ENABLED:-false}"
export SERVICERADAR_WEB_NG_OBAN_ENABLED="${SERVICERADAR_WEB_NG_OBAN_ENABLED:-false}"
export SERVICERADAR_GOD_VIEW_RUNTIME_GRAPH_AUTO_REFRESH="${SERVICERADAR_GOD_VIEW_RUNTIME_GRAPH_AUTO_REFRESH:-false}"
export PHX_HOST="${PHX_HOST:-localhost}"
export PHX_PORT="$phx_port"
export SERVICERADAR_DEV_ROUTES="${SERVICERADAR_DEV_ROUTES:-true}"
export CNPG_HOST="$cnpg_host"
export CNPG_PORT="$cnpg_port"
export CNPG_DATABASE="$cnpg_database"
export CNPG_USERNAME="$cnpg_username"
export CNPG_PASSWORD="$app_password"
export CNPG_SSL_MODE="${CNPG_SSL_MODE:-verify-full}"
export CNPG_TLS_SERVER_NAME="${CNPG_TLS_SERVER_NAME:-cnpg}"
export CNPG_CA_FILE="$cert_dir/root.pem"
export CNPG_CERT_FILE="$cert_dir/db-client.pem"
export CNPG_KEY_FILE="$cert_dir/db-client-key.pem"
export CNPG_POOL_SIZE="${CNPG_POOL_SIZE:-12}"
export PLUGIN_STORAGE_BACKEND="${PLUGIN_STORAGE_BACKEND:-filesystem}"
export PLUGIN_STORAGE_PATH="$plugin_storage_path"

echo "Starting web-ng at http://localhost:$phx_port"
exec mix phx.server
