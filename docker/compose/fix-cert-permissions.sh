#!/bin/sh
set -euo pipefail

echo "Fixing certificate permissions..."

CERT_DIR="/etc/serviceradar/certs"

# Default to the ServiceRadar runtime user/group (serviceradar:serviceradar = 10001:10001).
APP_UID="${SERVICERADAR_UID:-10001}"
APP_GID="${SERVICERADAR_GID:-10001}"

# Owner/group: ServiceRadar runtime user so non-root containers can read their cert material.
chown -R "${APP_UID}:${APP_GID}" "${CERT_DIR}"
# Allow other service users to traverse the cert dir (but not list contents).
find "${CERT_DIR}" -type d -exec chmod 711 {} \;

# Public certs are non-sensitive; private keys stay owner/group readable only
find "${CERT_DIR}" -type f -name '*.pem' ! -name '*-key.pem' -exec chmod 644 {} \;
find "${CERT_DIR}" -type f -name '*-key.pem' -exec chmod 640 {} \;

# Keep authentication/bootstrap secrets root-only even though certs are shared with runtime users.
for secret_file in \
  jwt-secret \
  api-key \
  admin-password \
  admin-password-hash \
  password.txt \
  edge-onboarding.key
do
  if [ -f "${CERT_DIR}/${secret_file}" ]; then
    chown 0:0 "${CERT_DIR}/${secret_file}"
    chmod 600 "${CERT_DIR}/${secret_file}"
  fi
done

# CNPG (PostgreSQL) key needs postgres user ownership (uid 26 in serviceradar-cnpg image)
if [ -f "${CERT_DIR}/cnpg-key.pem" ]; then
  chown 26:26 "${CERT_DIR}/cnpg-key.pem"
  chmod 600 "${CERT_DIR}/cnpg-key.pem"
  echo "  CNPG key: uid 26, mode 600"
fi

echo "✅ Certificate permissions fixed (uid ${APP_UID}, gid ${APP_GID}, keys 640)"
