#!/bin/sh
set -eu

WAIT_TIMEOUT="${NATS_STARTUP_WAIT_TIMEOUT_SECONDS:-900}"

wait_for_file() {
  target="$1"
  deadline=$(( $(date +%s) + WAIT_TIMEOUT ))

  while [ ! -s "$target" ]; do
    if [ "$(date +%s)" -ge "$deadline" ]; then
      echo "Timed out waiting for required NATS file: $target" >&2
      exit 1
    fi

    sleep 1
  done
}

mkdir -p /data/jwt

wait_for_file /etc/serviceradar/creds/operator.jwt
wait_for_file /etc/serviceradar/certs/root.pem
wait_for_file /etc/serviceradar/certs/nats.pem
wait_for_file /etc/serviceradar/certs/nats-key.pem

exec nats-server "$@"
