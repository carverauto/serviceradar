#!/bin/sh
set -eu

MARKER_PATH="${SERVICERADAR_MIGRATIONS_MARKER_PATH:-/var/lib/serviceradar/migrations/complete}"
WAIT_TIMEOUT="${SERVICERADAR_MIGRATIONS_WAIT_TIMEOUT_SECONDS:-300}"

if [ -n "$MARKER_PATH" ]; then
  deadline=$(( $(date +%s) + WAIT_TIMEOUT ))

  while [ ! -f "$MARKER_PATH" ]; do
    if [ "$(date +%s)" -ge "$deadline" ]; then
      echo "Timed out waiting for migrations marker: $MARKER_PATH" >&2
      exit 1
    fi

    sleep 1
  done
fi

exec "$@"
