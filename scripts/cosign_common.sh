#!/usr/bin/env bash

# Shared Cosign helpers for key-based and keyless signing/verification.

COSIGN_COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COSIGN_COMMON_REPO_ROOT="$(cd "${COSIGN_COMMON_DIR}/.." && pwd)"

declare -ag COSIGN_TEMP_FILES=()

cosign_register_temp_file() {
  COSIGN_TEMP_FILES+=("$1")
}

cosign_cleanup_temp_files() {
  if [[ ${#COSIGN_TEMP_FILES[@]} -eq 0 ]]; then
    return
  fi
  rm -f "${COSIGN_TEMP_FILES[@]}"
  COSIGN_TEMP_FILES=()
}

cosign_require_tool() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "error: $1 is required" >&2
    exit 1
  fi
}

cosign_urlencode() {
  python3 - <<'PY' "$1"
import sys
import urllib.parse

print(urllib.parse.quote(sys.argv[1], safe=""))
PY
}

cosign_write_temp_file() {
  local content="$1"
  local temp_file
  temp_file="$(mktemp)"
  printf '%s\n' "${content}" >"${temp_file}"
  cosign_register_temp_file "${temp_file}"
  printf '%s\n' "${temp_file}"
}

cosign_resolve_file() {
  local explicit_path="${1:-}"
  local inline_content="${2:-}"
  local fallback_path="${3:-}"

  if [[ -n "${explicit_path}" ]]; then
    if [[ ! -f "${explicit_path}" ]]; then
      echo "error: file does not exist: ${explicit_path}" >&2
      exit 1
    fi
    printf '%s\n' "${explicit_path}"
    return 0
  fi

  if [[ -n "${inline_content}" ]]; then
    cosign_write_temp_file "${inline_content}"
    return 0
  fi

  if [[ -n "${fallback_path}" && -f "${fallback_path}" ]]; then
    printf '%s\n' "${fallback_path}"
    return 0
  fi

  printf '\n'
}

cosign_resolve_trusted_root_file() {
  cosign_resolve_file \
    "${SIGSTORE_TRUSTED_ROOT_FILE:-}" \
    "${SIGSTORE_TRUSTED_ROOT:-}" \
    "${COSIGN_COMMON_REPO_ROOT}/docs/sigstore/trusted-root.json"
}

cosign_export_trust_overrides() {
  local fulcio_root_file
  local ctlog_key_file
  local rekor_key_file

  fulcio_root_file="$(cosign_resolve_file \
    "${SIGSTORE_ROOT_FILE:-}" \
    "${SIGSTORE_ROOT_PEM:-}" \
    "${COSIGN_COMMON_REPO_ROOT}/docs/sigstore/fulcio-root.pem")"
  if [[ -n "${fulcio_root_file}" ]]; then
    export SIGSTORE_ROOT_FILE="${fulcio_root_file}"
  fi

  ctlog_key_file="$(cosign_resolve_file \
    "${SIGSTORE_CT_LOG_PUBLIC_KEY_FILE:-}" \
    "${SIGSTORE_CT_LOG_PUBLIC_KEY:-}" \
    "${COSIGN_COMMON_REPO_ROOT}/docs/sigstore/ctfe.pub")"
  if [[ -n "${ctlog_key_file}" ]]; then
    export SIGSTORE_CT_LOG_PUBLIC_KEY_FILE="${ctlog_key_file}"
  fi

  rekor_key_file="$(cosign_resolve_file \
    "${SIGSTORE_REKOR_PUBLIC_KEY_FILE:-}" \
    "${SIGSTORE_REKOR_PUBLIC_KEY_PEM:-}" \
    "${COSIGN_COMMON_REPO_ROOT}/docs/sigstore/rekor.pub")"
  if [[ -n "${rekor_key_file}" ]]; then
    export SIGSTORE_REKOR_PUBLIC_KEY="${rekor_key_file}"
  fi
}

cosign_keyless_requested() {
  [[ "${COSIGN_KEYLESS:-false}" == "true" ]] \
    || [[ -n "${SIGSTORE_FULCIO_URL:-}" ]] \
    || [[ -n "${SIGSTORE_REKOR_URL:-}" ]] \
    || [[ -n "${SIGSTORE_OIDC_ISSUER:-}" ]] \
    || [[ -n "${SIGSTORE_ID_TOKEN:-}" ]] \
    || [[ -n "${SIGSTORE_ID_TOKEN_FILE:-}" ]] \
    || [[ -n "${SIGSTORE_TRUSTED_ROOT_FILE:-}" ]] \
    || [[ -n "${SIGSTORE_TRUSTED_ROOT:-}" ]] \
    || [[ -n "${COSIGN_CERTIFICATE_IDENTITY:-}" ]] \
    || [[ -n "${COSIGN_CERTIFICATE_IDENTITY_REGEXP:-}" ]] \
    || [[ -n "${COSIGN_CERTIFICATE_OIDC_ISSUER:-}" ]] \
    || [[ -n "${COSIGN_CERTIFICATE_OIDC_ISSUER_REGEXP:-}" ]] \
    || [[ -n "${ACTIONS_ID_TOKEN_REQUEST_URL:-}" ]] \
    || [[ -f "${COSIGN_COMMON_REPO_ROOT}/docs/sigstore/trusted-root.json" ]]
}

cosign_fetch_actions_id_token() {
  cosign_require_tool curl
  cosign_require_tool jq
  cosign_require_tool python3

  [[ -n "${ACTIONS_ID_TOKEN_REQUEST_URL:-}" ]] || return 1
  [[ -n "${ACTIONS_ID_TOKEN_REQUEST_TOKEN:-}" ]] || return 1

  local audience request_url response token separator
  audience="${SIGSTORE_OIDC_AUDIENCE:-${SIGSTORE_OIDC_CLIENT_ID:-sigstore}}"
  request_url="${ACTIONS_ID_TOKEN_REQUEST_URL}"

  if [[ -n "${audience}" ]]; then
    separator='?'
    if [[ "${request_url}" == *\?* ]]; then
      separator='&'
    fi
    request_url="${request_url}${separator}audience=$(cosign_urlencode "${audience}")"
  fi

  response="$(
    curl -fsSL \
      -H "Authorization: bearer ${ACTIONS_ID_TOKEN_REQUEST_TOKEN}" \
      "${request_url}"
  )"

  if jq -e . >/dev/null 2>&1 <<<"${response}"; then
    token="$(jq -r '.value // .token // empty' <<<"${response}")"
  else
    token="${response}"
  fi

  if [[ -z "${token}" || "${token}" == "null" ]]; then
    echo "error: failed to obtain an OIDC identity token from the runner" >&2
    exit 1
  fi

  printf '%s\n' "${token}"
}

cosign_resolve_identity_token_file() {
  if [[ -n "${SIGSTORE_ID_TOKEN_FILE:-}" ]]; then
    if [[ ! -f "${SIGSTORE_ID_TOKEN_FILE}" ]]; then
      echo "error: SIGSTORE_ID_TOKEN_FILE does not exist: ${SIGSTORE_ID_TOKEN_FILE}" >&2
      exit 1
    fi
    printf '%s\n' "${SIGSTORE_ID_TOKEN_FILE}"
    return 0
  fi

  if [[ -n "${SIGSTORE_ID_TOKEN:-}" ]]; then
    cosign_write_temp_file "${SIGSTORE_ID_TOKEN}"
    return 0
  fi

  if [[ -n "${ACTIONS_ID_TOKEN_REQUEST_URL:-}" ]]; then
    cosign_write_temp_file "$(cosign_fetch_actions_id_token)"
    return 0
  fi

  printf '\n'
}

cosign_init_sign_args() {
  declare -g -a COSIGN_SIGN_ARGS=()

  local trusted_root_file identity_token_file
  trusted_root_file="$(cosign_resolve_trusted_root_file)"
  if [[ -n "${trusted_root_file}" ]]; then
    COSIGN_SIGN_ARGS+=(--trusted-root "${trusted_root_file}")
  fi

  cosign_export_trust_overrides

  if [[ -n "${COSIGN_KEY_FILE:-}" ]]; then
    if [[ ! -f "${COSIGN_KEY_FILE}" ]]; then
      echo "error: COSIGN_KEY_FILE does not exist: ${COSIGN_KEY_FILE}" >&2
      exit 1
    fi
    if [[ -z "${COSIGN_PASSWORD:-}" && -t 0 ]]; then
      read -r -s -p "Cosign password: " COSIGN_PASSWORD
      printf '\n' >&2
      export COSIGN_PASSWORD
    fi
    COSIGN_SIGN_ARGS+=(--key "${COSIGN_KEY_FILE}")
    return 0
  fi

  if [[ -n "${COSIGN_PRIVATE_KEY:-}" ]]; then
    COSIGN_SIGN_ARGS+=(--key env://COSIGN_PRIVATE_KEY)
    return 0
  fi

  if ! cosign_keyless_requested; then
    cat >&2 <<'EOF'
error: no cosign signing identity configured.
Set one of:
  COSIGN_KEY_FILE=/path/to/cosign.key
  COSIGN_PRIVATE_KEY environment variable with signing material
  COSIGN_KEYLESS=true
  SIGSTORE_FULCIO_URL / SIGSTORE_REKOR_URL / SIGSTORE_OIDC_ISSUER
EOF
    exit 1
  fi

  identity_token_file="$(cosign_resolve_identity_token_file)"
  if [[ -n "${identity_token_file}" ]]; then
    COSIGN_SIGN_ARGS+=(--identity-token "${identity_token_file}")
  fi
  if [[ -n "${SIGSTORE_FULCIO_URL:-}" ]]; then
    COSIGN_SIGN_ARGS+=(--fulcio-url "${SIGSTORE_FULCIO_URL}")
  fi
  if [[ -n "${SIGSTORE_REKOR_URL:-}" ]]; then
    COSIGN_SIGN_ARGS+=(--rekor-url "${SIGSTORE_REKOR_URL}")
  fi
  if [[ -n "${SIGSTORE_OIDC_ISSUER:-}" ]]; then
    COSIGN_SIGN_ARGS+=(--oidc-issuer "${SIGSTORE_OIDC_ISSUER}")
  fi
  if [[ -n "${SIGSTORE_OIDC_CLIENT_ID:-}" ]]; then
    COSIGN_SIGN_ARGS+=(--oidc-client-id "${SIGSTORE_OIDC_CLIENT_ID}")
  fi
}

cosign_init_verify_args() {
  declare -g -a COSIGN_VERIFY_ARGS=()

  local trusted_root_file pubkey
  trusted_root_file="$(cosign_resolve_trusted_root_file)"
  if [[ -n "${trusted_root_file}" ]]; then
    COSIGN_VERIFY_ARGS+=(--trusted-root "${trusted_root_file}")
  fi

  cosign_export_trust_overrides

  if [[ -n "${COSIGN_PUBLIC_KEY_FILE:-}" ]]; then
    if [[ ! -f "${COSIGN_PUBLIC_KEY_FILE}" ]]; then
      echo "error: COSIGN_PUBLIC_KEY_FILE does not exist: ${COSIGN_PUBLIC_KEY_FILE}" >&2
      exit 1
    fi
    COSIGN_VERIFY_ARGS+=(--key "${COSIGN_PUBLIC_KEY_FILE}")
    return 0
  fi

  if [[ -n "${COSIGN_KEY_FILE:-}" && -f "${COSIGN_KEY_FILE}" ]]; then
    pubkey="$(mktemp)"
    cosign public-key --key "${COSIGN_KEY_FILE}" >"${pubkey}"
    cosign_register_temp_file "${pubkey}"
    COSIGN_VERIFY_ARGS+=(--key "${pubkey}")
    return 0
  fi

  if [[ -n "${COSIGN_PUBLIC_KEY:-}" ]]; then
    pubkey="$(cosign_write_temp_file "${COSIGN_PUBLIC_KEY}")"
    COSIGN_VERIFY_ARGS+=(--key "${pubkey}")
    return 0
  fi

  if [[ -n "${COSIGN_PRIVATE_KEY:-}" ]]; then
    pubkey="$(mktemp)"
    cosign public-key --key env://COSIGN_PRIVATE_KEY >"${pubkey}"
    cosign_register_temp_file "${pubkey}"
    COSIGN_VERIFY_ARGS+=(--key "${pubkey}")
    return 0
  fi

  if ! cosign_keyless_requested; then
    return 1
  fi

  if [[ -n "${SIGSTORE_REKOR_URL:-}" ]]; then
    COSIGN_VERIFY_ARGS+=(--rekor-url "${SIGSTORE_REKOR_URL}")
  fi

  if [[ -n "${COSIGN_CERTIFICATE_IDENTITY:-}" ]]; then
    COSIGN_VERIFY_ARGS+=(--certificate-identity "${COSIGN_CERTIFICATE_IDENTITY}")
  elif [[ -n "${COSIGN_CERTIFICATE_IDENTITY_REGEXP:-}" ]]; then
    COSIGN_VERIFY_ARGS+=(--certificate-identity-regexp "${COSIGN_CERTIFICATE_IDENTITY_REGEXP}")
  else
    echo "error: keyless verification requires COSIGN_CERTIFICATE_IDENTITY or COSIGN_CERTIFICATE_IDENTITY_REGEXP" >&2
    exit 1
  fi

  if [[ -n "${COSIGN_CERTIFICATE_OIDC_ISSUER:-}" ]]; then
    COSIGN_VERIFY_ARGS+=(--certificate-oidc-issuer "${COSIGN_CERTIFICATE_OIDC_ISSUER}")
  elif [[ -n "${COSIGN_CERTIFICATE_OIDC_ISSUER_REGEXP:-}" ]]; then
    COSIGN_VERIFY_ARGS+=(--certificate-oidc-issuer-regexp "${COSIGN_CERTIFICATE_OIDC_ISSUER_REGEXP}")
  elif [[ -n "${SIGSTORE_OIDC_ISSUER:-}" ]]; then
    COSIGN_VERIFY_ARGS+=(--certificate-oidc-issuer "${SIGSTORE_OIDC_ISSUER}")
  else
    echo "error: keyless verification requires COSIGN_CERTIFICATE_OIDC_ISSUER, COSIGN_CERTIFICATE_OIDC_ISSUER_REGEXP, or SIGSTORE_OIDC_ISSUER" >&2
    exit 1
  fi

  return 0
}
