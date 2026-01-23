#!/bin/sh
set -eu

ADMIN_DIR="/etc/serviceradar/admin"
ADMIN_PASSWORD_FILE="${ADMIN_DIR}/admin-password"
ADMIN_EMAIL="${SERVICERADAR_ADMIN_EMAIL:-root@localhost}"

mkdir -p "${ADMIN_DIR}"

if [ -f "${ADMIN_PASSWORD_FILE}" ]; then
  echo "Admin password already present at ${ADMIN_PASSWORD_FILE}; skipping"
  exit 0
fi

# Generate a random password (20 chars) without URL-unsafe chars.
ADMIN_PASSWORD=$(head -c 24 /dev/urandom | base64 | tr -d '=+/' | head -c 20)

printf '%s' "${ADMIN_PASSWORD}" > "${ADMIN_PASSWORD_FILE}"
chmod 0600 "${ADMIN_PASSWORD_FILE}"

cat <<EOF_MSG
ServiceRadar admin bootstrap complete

Login:
  Email: ${ADMIN_EMAIL}
  Password: ${ADMIN_PASSWORD}

Credentials saved to ${ADMIN_PASSWORD_FILE}
EOF_MSG
