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

echo "✅ Certificate permissions fixed (uid 1000, gid 999, keys 640)"
