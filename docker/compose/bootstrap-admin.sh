#!/bin/sh
set -eu

ADMIN_DIR="/etc/serviceradar/admin"
ADMIN_PASSWORD_FILE="${ADMIN_DIR}/admin-password"
RELEASE_COOKIE_FILE="${ADMIN_DIR}/release-cookie"
SECRET_KEY_BASE_FILE="${ADMIN_DIR}/secret-key-base"
PLUGIN_STORAGE_SIGNING_SECRET_FILE="${ADMIN_DIR}/plugin-storage-signing-secret"
ADMIN_EMAIL="${SERVICERADAR_ADMIN_EMAIL:-root@localhost}"

mkdir -p "${ADMIN_DIR}"
chmod 0700 "${ADMIN_DIR}"

ensure_secret_file() {
  path="$1"
  generator="$2"
  label="$3"

  if [ -s "${path}" ]; then
    echo "${label} already present at ${path}; preserving"
    return
  fi

  value="$(sh -c "${generator}")"
  printf '%s' "${value}" > "${path}"
  chmod 0600 "${path}"
  echo "Generated ${label} at ${path}"
}

ensure_secret_file "${ADMIN_PASSWORD_FILE}" \
  "head -c 24 /dev/urandom | base64 | tr -d '=+/' | head -c 20" \
  "admin password"

ensure_secret_file "${RELEASE_COOKIE_FILE}" \
  "head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n'" \
  "release cookie"

ensure_secret_file "${SECRET_KEY_BASE_FILE}" \
  "head -c 48 /dev/urandom | base64 | tr -d '\n'" \
  "Phoenix secret key base"

ensure_secret_file "${PLUGIN_STORAGE_SIGNING_SECRET_FILE}" \
  "head -c 48 /dev/urandom | base64 | tr -d '\n'" \
  "plugin storage signing secret"

ADMIN_PASSWORD="$(cat "${ADMIN_PASSWORD_FILE}")"

cat <<EOF_MSG
ServiceRadar admin bootstrap complete

Login:
  Email: ${ADMIN_EMAIL}
  Password: ${ADMIN_PASSWORD}

Credentials saved to ${ADMIN_PASSWORD_FILE}
Additional runtime secrets saved under ${ADMIN_DIR}
EOF_MSG
