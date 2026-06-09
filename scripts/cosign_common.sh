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

cosign_resolve_executable() {
  local candidate="${1:-}"
  local path_candidate
  local resolved

  export PATH="/opt/homebrew/bin:/usr/local/bin:${HOME:-}/.local/bin:${HOME:-}/bin:/usr/bin:/bin:${PATH:-}"

  if [[ -z "${candidate}" ]]; then
    return 1
  fi

  if [[ "${candidate}" = */* ]]; then
    if [[ -x "${candidate}" ]]; then
      printf '%s\n' "${candidate}"
      return 0
    fi
    return 1
  fi

  resolved="$(command -v "${candidate}" 2>/dev/null || true)"
  if [[ -n "${resolved}" && -x "${resolved}" ]]; then
    printf '%s\n' "${resolved}"
    return 0
  fi

  for path_candidate in \
    "${PWD}/${candidate}" \
    "/opt/homebrew/bin/${candidate}" \
    "/usr/local/bin/${candidate}" \
    "${HOME:-}/.local/bin/${candidate}" \
    "${HOME:-}/bin/${candidate}" \
    "/usr/bin/${candidate}" \
    "/bin/${candidate}"; do
    if [[ -x "${path_candidate}" ]]; then
      printf '%s\n' "${path_candidate}"
      return 0
    fi
  done

  return 1
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

cosign_resolve_public_key_file() {
  cosign_resolve_file \
    "${COSIGN_PUBLIC_KEY_FILE:-}" \
    "${COSIGN_PUBLIC_KEY:-}" \
    "${COSIGN_COMMON_REPO_ROOT}/docs/cosign.pub"
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

  token="$(
    RESPONSE="${response}" python3 - <<'PY'
import json
import os

text = os.environ["RESPONSE"].strip()
if not text:
    print("")
    raise SystemExit(0)

try:
    payload = json.loads(text)
except json.JSONDecodeError:
    print(text)
    raise SystemExit(0)

if isinstance(payload, dict):
    value = payload.get("value") or payload.get("token") or ""
    print(value if isinstance(value, str) else "")
else:
    print("")
PY
  )"

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

cosign_resolve_key_ref() {
  if [[ -n "${COSIGN_KEY_REF:-}" ]]; then
    printf '%s\n' "${COSIGN_KEY_REF}"
    return 0
  fi

  if [[ -n "${COSIGN_KMS_KEY:-}" ]]; then
    printf '%s\n' "${COSIGN_KMS_KEY}"
    return 0
  fi

  printf '\n'
}

cosign_init_sign_args() {
  declare -g -a COSIGN_SIGN_ARGS=()

  local trusted_root_file identity_token_file key_ref
  trusted_root_file="$(cosign_resolve_trusted_root_file)"
  if [[ -n "${trusted_root_file}" ]]; then
    COSIGN_SIGN_ARGS+=(--trusted-root "${trusted_root_file}")
  fi

  cosign_export_trust_overrides

  key_ref="$(cosign_resolve_key_ref)"
  if [[ -n "${key_ref}" ]]; then
    COSIGN_SIGN_ARGS+=(--key "${key_ref}")
    return 0
  fi

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
  COSIGN_KEY_REF=hashivault://key-name
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

  local trusted_root_file public_key_file pubkey key_ref key_pub_file
  trusted_root_file="$(cosign_resolve_trusted_root_file)"
  if [[ -n "${trusted_root_file}" ]]; then
    COSIGN_VERIFY_ARGS+=(--trusted-root "${trusted_root_file}")
  fi

  cosign_export_trust_overrides

  key_ref="$(cosign_resolve_key_ref)"
  if [[ -n "${key_ref}" ]]; then
    pubkey="$(mktemp)"
    cosign public-key --key "${key_ref}" >"${pubkey}"
    cosign_register_temp_file "${pubkey}"
    COSIGN_VERIFY_ARGS+=(--key "${pubkey}")
    return 0
  fi

  if [[ -n "${COSIGN_KEY_FILE:-}" && -f "${COSIGN_KEY_FILE}" ]]; then
    key_pub_file="${COSIGN_KEY_FILE%.key}.pub"
    if [[ "${key_pub_file}" != "${COSIGN_KEY_FILE}" && -f "${key_pub_file}" ]]; then
      COSIGN_VERIFY_ARGS+=(--key "${key_pub_file}")
      return 0
    fi

    pubkey="$(mktemp)"
    cosign public-key --key "${COSIGN_KEY_FILE}" >"${pubkey}"
    cosign_register_temp_file "${pubkey}"
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

  public_key_file="$(cosign_resolve_public_key_file)"
  if [[ -n "${public_key_file}" ]]; then
    COSIGN_VERIFY_ARGS+=(--key "${public_key_file}")
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

cosign_log_has_tlog_conflict() {
  local log_file="$1"

  grep -q 'createLogEntryConflict' "${log_file}" \
    && grep -qi 'equivalent entry already exists' "${log_file}"
}

cosign_log_has_transient_tlog_error() {
  local log_file="$1"
  local retryable_pattern

  retryable_pattern='(giving up after|timeout|timed out|temporary|temporarily|connection reset|connection refused|TLS handshake timeout|EOF|429|502|503|504)'

  grep -Eqi "rekor.*${retryable_pattern}" "${log_file}" \
    || grep -Eqi "api/v1/log/entries.*${retryable_pattern}" "${log_file}"
}

cosign_supports_signing_config() {
  cosign sign --help 2>/dev/null | grep -q -- '--signing-config' \
    && cosign signing-config create --help >/dev/null 2>&1
}

cosign_no_tlog_signing_config() {
  local signing_config_file

  signing_config_file="$(mktemp)"
  if ! cosign signing-config create --out "${signing_config_file}" >/dev/null; then
    rm -f "${signing_config_file}"
    return 1
  fi

  cosign_register_temp_file "${signing_config_file}"
  printf '%s\n' "${signing_config_file}"
}

cosign_init_tlog_args() {
  local tlog_upload="$1"
  local signing_config_file
  declare -g -a COSIGN_TLOG_ARGS=()

  if [[ "${tlog_upload}" == "false" ]] && cosign_supports_signing_config; then
    signing_config_file="$(cosign_no_tlog_signing_config)"
    COSIGN_TLOG_ARGS+=(--signing-config "${signing_config_file}")
    return 0
  fi

  COSIGN_TLOG_ARGS+=(--tlog-upload="${tlog_upload}")
}

cosign_verify_existing_signature() {
  local ref="$1"

  if ! cosign_init_verify_args; then
    echo "warning: cannot verify existing cosign signature for ${ref}; no verification identity configured" >&2
    return 1
  fi

  cosign verify \
    --experimental-oci11 \
    "${COSIGN_VERIFY_ARGS[@]}" \
    "${ref}" >/dev/null
}

cosign_sign_ref() {
  local ref="$1"
  local tlog_upload="$2"

  cosign_init_tlog_args "${tlog_upload}"

  cosign sign \
    --yes \
    "${COSIGN_TLOG_ARGS[@]}" \
    --registry-referrers-mode="${COSIGN_REFERRERS_MODE:-oci-1-1}" \
    "${COSIGN_SIGN_ARGS[@]}" \
    "${ref}"
}

cosign_sign_blob_to_files() {
  local payload_file="$1"
  local bundle_file="$2"
  local signature_file="$3"
  local stdout_file="$4"
  local requested_tlog_upload="${5:-true}"
  local stderr_file
  local status=1
  local attempt=1
  local max_attempts="${COSIGN_SIGN_MAX_ATTEMPTS:-4}"
  local retry_delay="${COSIGN_SIGN_RETRY_DELAY_SECONDS:-10}"

  stderr_file="$(mktemp)"
  cosign_register_temp_file "${stderr_file}"

  while ((attempt <= max_attempts)); do
    : >"${stderr_file}"
    : >"${signature_file}"
    : >"${bundle_file}"
    : >"${stdout_file}"

    cosign_init_tlog_args "${requested_tlog_upload}"
    if cosign sign-blob \
      --yes \
      "${COSIGN_TLOG_ARGS[@]}" \
      "${COSIGN_SIGN_ARGS[@]}" \
      --bundle "${bundle_file}" \
      --output-signature "${signature_file}" \
      "${payload_file}" >"${stdout_file}" 2> >(tee "${stderr_file}" >&2); then
      return 0
    else
      status=$?
    fi

    if [[ "${requested_tlog_upload}" != "false" ]] && cosign_log_has_tlog_conflict "${stderr_file}"; then
      echo "warning: transparency log already contains an equivalent blob entry; retrying without transparency log upload" >&2
      : >"${stderr_file}"
      : >"${signature_file}"
      : >"${bundle_file}"
      : >"${stdout_file}"
      cosign_init_tlog_args false
      if cosign sign-blob \
        --yes \
        "${COSIGN_TLOG_ARGS[@]}" \
        "${COSIGN_SIGN_ARGS[@]}" \
        --bundle "${bundle_file}" \
        --output-signature "${signature_file}" \
        "${payload_file}" >"${stdout_file}" 2> >(tee "${stderr_file}" >&2); then
        return 0
      else
        status=$?
      fi
    fi

    if ((attempt < max_attempts)) && cosign_log_has_transient_tlog_error "${stderr_file}"; then
      echo "warning: transient transparency-log blob signing failure; retrying attempt $((attempt + 1))/${max_attempts} after ${retry_delay}s" >&2
      sleep "${retry_delay}"
      attempt=$((attempt + 1))
      continue
    fi

    break
  done

  return "${status}"
}

cosign_sign_ref_idempotent() {
  local ref="$1"
  local stderr_file
  local status=1
  local attempt=1
  local max_attempts="${COSIGN_SIGN_MAX_ATTEMPTS:-4}"
  local retry_delay="${COSIGN_SIGN_RETRY_DELAY_SECONDS:-10}"

  stderr_file="$(mktemp)"
  cosign_register_temp_file "${stderr_file}"

  while ((attempt <= max_attempts)); do
    : >"${stderr_file}"

    if cosign_sign_ref "${ref}" "${COSIGN_TLOG_UPLOAD:-true}" 2> >(tee "${stderr_file}" >&2); then
      return 0
    else
      status=$?
    fi

    if cosign_log_has_tlog_conflict "${stderr_file}"; then
      echo "warning: transparency log already contains an equivalent entry for ${ref}; verifying existing signature" >&2
      if cosign_verify_existing_signature "${ref}"; then
        return 0
      fi

      echo "warning: existing registry signature was not valid for ${ref}; retrying without transparency log upload" >&2
      if cosign_sign_ref "${ref}" false && cosign_verify_existing_signature "${ref}"; then
        return 0
      fi
    fi

    if ((attempt < max_attempts)) && cosign_log_has_transient_tlog_error "${stderr_file}"; then
      echo "warning: transient transparency-log signing failure for ${ref}; retrying attempt $((attempt + 1))/${max_attempts} after ${retry_delay}s" >&2
      sleep "${retry_delay}"
      attempt=$((attempt + 1))
      continue
    fi

    break
  done

  return "${status}"
}
