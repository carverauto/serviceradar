#!/bin/sh
set -eu

DATA_DIR="${CNPG_DATA_DIR:-/var/lib/postgresql/data}"
VERSION_FILE="${DATA_DIR}/PG_VERSION"
EXPECTED_MAJOR="${CNPG_EXPECTED_PG_MAJOR:-18}"
CNPG_ENTRYPOINT="${CNPG_ENTRYPOINT:-/usr/local/bin/docker-entrypoint.sh}"
WAIT_TIMEOUT="${CNPG_STARTUP_WAIT_TIMEOUT_SECONDS:-300}"

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
  exec "$CNPG_ENTRYPOINT" "$@"
fi

actual_version="$(tr -d '\r\n' < "$VERSION_FILE")"
actual_major="${actual_version%%.*}"

if [ "$actual_major" != "$EXPECTED_MAJOR" ]; then
  echo "CNPG data volume version mismatch: found PostgreSQL ${actual_version}, expected PostgreSQL ${EXPECTED_MAJOR}." >&2
  echo "Docker Compose does not perform Postgres major upgrades automatically." >&2
  echo "Migrate the existing CNPG data volume to PostgreSQL ${EXPECTED_MAJOR} before starting this stack." >&2
  exit 42
fi

exec "$CNPG_ENTRYPOINT" "$@"
