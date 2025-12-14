#!/bin/sh
set -euo pipefail

echo "Fixing certificate permissions..."

CERT_DIR="/etc/serviceradar/certs"

# Default to the poller image user/group (serviceradar:serviceradar = 1001:1001).
APP_UID="${SERVICERADAR_UID:-1001}"
APP_GID="${SERVICERADAR_GID:-1001}"

# Owner/group: ServiceRadar runtime user so non-root containers (notably poller) can read.
chown -R "${APP_UID}:${APP_GID}" "${CERT_DIR}"
# Allow other service users to traverse the cert dir (but not list contents).
find "${CERT_DIR}" -type d -exec chmod 711 {} \;

# Public certs are non-sensitive; private keys stay owner/group readable only
find "${CERT_DIR}" -type f -name '*.pem' ! -name '*-key.pem' -exec chmod 644 {} \;
find "${CERT_DIR}" -type f -name '*-key.pem' -exec chmod 640 {} \;

# CNPG (PostgreSQL) key needs postgres user ownership (uid 26 in serviceradar-cnpg image)
if [ -f "${CERT_DIR}/cnpg-key.pem" ]; then
  chown 26:26 "${CERT_DIR}/cnpg-key.pem"
  chmod 600 "${CERT_DIR}/cnpg-key.pem"
  echo "  CNPG key: uid 26, mode 600"
fi

echo "✅ Certificate permissions fixed (uid ${APP_UID}, gid ${APP_GID}, keys 640)"
