#!/bin/sh
set -euo pipefail

echo "Fixing certificate permissions..."

CERT_DIR="/etc/serviceradar/certs"

# Owner: app user (uid 1000), group: db user (gid 999) so both can read; no world access
chown -R 1000:999 "${CERT_DIR}"
find "${CERT_DIR}" -type d -exec chmod 750 {} \;

# Public certs are non-sensitive; private keys stay owner/group readable only
find "${CERT_DIR}" -type f -name '*.pem' ! -name '*-key.pem' -exec chmod 644 {} \;
find "${CERT_DIR}" -type f -name '*-key.pem' -exec chmod 640 {} \;

# CNPG (PostgreSQL) key needs postgres user ownership (uid 26 in serviceradar-cnpg image)
if [ -f "${CERT_DIR}/cnpg-key.pem" ]; then
  chown 26:999 "${CERT_DIR}/cnpg-key.pem"
  chmod 600 "${CERT_DIR}/cnpg-key.pem"
  echo "  CNPG key: uid 26, mode 600"
fi

echo "✅ Certificate permissions fixed (uid 1000, gid 999, keys 640)"
