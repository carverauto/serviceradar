#!/bin/sh
set -eu

DATA_DIR="${CNPG_DATA_DIR:-/var/lib/postgresql/data}"
VERSION_FILE="${DATA_DIR}/PG_VERSION"
EXPECTED_MAJOR="${CNPG_EXPECTED_PG_MAJOR:-18}"
CNPG_ENTRYPOINT="${CNPG_ENTRYPOINT:-/usr/local/bin/docker-entrypoint.sh}"
WAIT_TIMEOUT="${CNPG_STARTUP_WAIT_TIMEOUT_SECONDS:-900}"
export PGDATA="$DATA_DIR"

run_as_postgres() {
  if [ "$(id -u)" = "0" ]; then
    exec runuser -u postgres -- "$@"
  fi

  exec "$@"
}

call_as_postgres() {
  if [ "$(id -u)" = "0" ]; then
    runuser -u postgres -- "$@"
    return
  fi

  "$@"
}

init_compose_database() {
  postgres_user="${POSTGRES_USER:-postgres}"
  postgres_db="${POSTGRES_DB:-$postgres_user}"
  password_file="${POSTGRES_PASSWORD_FILE:-}"

  if [ -z "$password_file" ] || [ ! -s "$password_file" ]; then
    echo "POSTGRES_PASSWORD_FILE must point at a non-empty password file for first-time initialization." >&2
    exit 1
  fi

  mkdir -p "$DATA_DIR"
  if [ "$(id -u)" = "0" ]; then
    chown -R postgres:postgres "$DATA_DIR"
  fi

  call_as_postgres initdb -D "$DATA_DIR" --username="$postgres_user" --pwfile="$password_file"

  call_as_postgres pg_ctl -D "$DATA_DIR" -w \
    -o "-c listen_addresses='' -c shared_preload_libraries=timescaledb,age" \
    start

  if [ "$postgres_db" != "postgres" ]; then
    call_as_postgres createdb -U "$postgres_user" "$postgres_db"
  fi

  call_as_postgres pg_ctl -D "$DATA_DIR" -m fast -w stop
}

start_postgres() {
  if [ -x "$CNPG_ENTRYPOINT" ]; then
    exec "$CNPG_ENTRYPOINT" "$@"
  fi

  if [ "$#" -gt 0 ] && [ "$1" = "postgres" ]; then
    run_as_postgres "$@" -c "listen_addresses=*"
  fi

  run_as_postgres postgres -c "listen_addresses=*" "$@"
}

wait_for_file() {
  target="$1"
  deadline=$(( $(date +%s) + WAIT_TIMEOUT ))

  while [ ! -s "$target" ]; do
    if [ "$(date +%s)" -ge "$deadline" ]; then
      echo "Timed out waiting for required CNPG file: $target" >&2
      exit 1
    fi

    sleep 1
  done
}

wait_for_prerequisites() {
  wait_for_file /etc/serviceradar/cnpg/superuser-password
  wait_for_file /etc/serviceradar/cnpg/superuser-username
  wait_for_file /etc/serviceradar/certs/root.pem
  wait_for_file /etc/serviceradar/certs/cnpg.pem
  wait_for_file /etc/serviceradar/certs/cnpg-key.pem
}

wait_for_prerequisites

if [ ! -f "$VERSION_FILE" ]; then
  if [ ! -x "$CNPG_ENTRYPOINT" ]; then
    init_compose_database
  fi

  start_postgres "$@"
fi

actual_version="$(tr -d '\r\n' < "$VERSION_FILE")"
actual_major="${actual_version%%.*}"

if [ "$actual_major" != "$EXPECTED_MAJOR" ]; then
  echo "CNPG data volume version mismatch: found PostgreSQL ${actual_version}, expected PostgreSQL ${EXPECTED_MAJOR}." >&2
  echo "Docker Compose does not perform Postgres major upgrades automatically." >&2
  echo "Migrate the existing CNPG data volume to PostgreSQL ${EXPECTED_MAJOR} before starting this stack." >&2
  exit 42
fi

start_postgres "$@"
