#!/usr/bin/env bash

# Shared Cosign helpers for key-based and keyless signing/verification.

COSIGN_COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COSIGN_COMMON_REPO_ROOT="${SERVICERADAR_REPO_ROOT:-$(cd "${COSIGN_COMMON_DIR}/.." && pwd)}"
# ServiceRadar's self-hosted Rekor v1 log, which every release signature is written to, and
# the directory holding its key (rekor.pub), every accepted Rekor key (rekor-keys/<logID>.pub)
# and the public-good key that only reused pre-cutover receipts may name
# (pre-cutover-rekor-keys/<logID>.pub). release.yml points SERVICERADAR_SIGSTORE_DIR at a copy
# taken before it checks out an older release, as it does for the current scripts.
COSIGN_PINNED_REKOR_URL="https://rekor.serviceradar.cloud"
COSIGN_SIGSTORE_DIR="${SERVICERADAR_SIGSTORE_DIR:-${COSIGN_COMMON_REPO_ROOT}/docs/sigstore}"
COSIGN_RECEIPT_TOOL="${COSIGN_COMMON_DIR}/cosign_receipt.py"
COSIGN_VERIFY_TIMEOUT="60s"

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

  # No implicit default: the pinned docs/sigstore/rekor.pub is passed only to the
  # receipt verification below. Exported globally, it would also replace the TUF trusted
  # root that a protobuf-bundle verify-blob (the release checksum) requires.
  rekor_key_file="$(cosign_resolve_file \
    "${SIGSTORE_REKOR_PUBLIC_KEY_FILE:-}" \
    "${SIGSTORE_REKOR_PUBLIC_KEY_PEM:-}" \
    "")"
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
    if cosign public-key --key "${key_ref}" >"${pubkey}" 2>/dev/null && [[ -s "${pubkey}" ]]; then
      cosign_register_temp_file "${pubkey}"
      COSIGN_VERIFY_ARGS+=(--key "${pubkey}")
      return 0
    fi
    rm -f "${pubkey}"
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


cosign_log_has_transient_tlog_error() {
  local log_file="$1"
  local retryable_pattern

  retryable_pattern='(giving up after|timeout|timed out|temporary|temporarily|connection reset|connection refused|TLS handshake timeout|EOF|429|502|503|504)'

  grep -Eqi "rekor.*${retryable_pattern}" "${log_file}" \
    || grep -Eqi "api/v1/log/entries.*${retryable_pattern}" "${log_file}"
}

cosign_retry_delay_seconds() {
  local base_delay="$1"
  local attempt="$2"
  local multiplier=$((1 << (attempt - 1)))

  printf '%s\n' "$((base_delay * multiplier))"
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

cosign_sign_blob_to_files() {
  cosign_init_tlog_args "${5:-true}"
  cosign_sign_blob_retrying "$1" "$2" "$3" "$4"
}

# Release signatures for images, native add-ons and Wasm plugins. cosign's legacy upload
# path writes to the pinned self-hosted Rekor v1 log, never to a log a TUF-delivered signing
# config names, and the legacy `--bundle` file carries the receipt (`rekorBundle`): a Rekor v2
# entry has no SignedEntryTimestamp and cannot be carried in the classic annotation. When that
# log is unreachable, cosign fails after its retries and so does the release.
cosign_sign_blob_with_receipt() {
  declare -g -a COSIGN_TLOG_ARGS=(
    --use-signing-config=false
    --new-bundle-format=false
    --rekor-url "${COSIGN_PINNED_REKOR_URL}"
    --tlog-upload=true
  )
  cosign_sign_blob_retrying "$1" "$2" "$3" "$4"
}

# Signs with COSIGN_TLOG_ARGS and retries only transient transparency-log errors.
cosign_sign_blob_retrying() {
  local payload_file="$1"
  local bundle_file="$2"
  local signature_file="$3"
  local stdout_file="$4"
  local stderr_file
  local status=1
  local attempt=1
  local max_attempts="${COSIGN_SIGN_MAX_ATTEMPTS:-4}"
  local retry_delay="${COSIGN_SIGN_RETRY_DELAY_SECONDS:-5}"
  local backoff_delay

  stderr_file="$(mktemp)"
  cosign_register_temp_file "${stderr_file}"

  while ((attempt <= max_attempts)); do
    : >"${stderr_file}"
    : >"${signature_file}"
    : >"${bundle_file}"
    : >"${stdout_file}"

    if cosign sign-blob \
      --yes \
      "${COSIGN_TLOG_ARGS[@]}" \
      "${COSIGN_SIGN_ARGS[@]}" \
      --bundle "${bundle_file}" \
      --output-signature "${signature_file}" \
      "${payload_file}" >"${stdout_file}" 2>"${stderr_file}"; then
      cat "${stderr_file}" >&2
      return 0
    else
      status=$?
      cat "${stderr_file}" >&2
    fi

    if ((attempt < max_attempts)) && cosign_log_has_transient_tlog_error "${stderr_file}"; then
      backoff_delay="$(cosign_retry_delay_seconds "${retry_delay}" "${attempt}")"
      echo "warning: transient transparency-log blob signing failure; retrying attempt $((attempt + 1))/${max_attempts} after ${backoff_delay}s" >&2
      sleep "${backoff_delay}"
      attempt=$((attempt + 1))
      continue
    fi

    break
  done

  return "${status}"
}

# Return an explicit reused/absent result. Authentication or verification errors
# must never become the caller's permission to generate a replacement signature.
cosign_reconcile_legacy_signature() (
  local ref="$1" key_ref public_key="" owned_key="" result
  local helper
  helper="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/reconcile-legacy-signature.py"
  trap '[[ -z "${owned_key}" ]] || rm -f "${owned_key}"' EXIT
  key_ref="$(cosign_resolve_key_ref)"
  if [[ -z "${key_ref}" && -n "${COSIGN_KEY_FILE:-}" ]]; then
    key_ref="${COSIGN_KEY_FILE}"
  elif [[ -z "${key_ref}" && -n "${COSIGN_PRIVATE_KEY:-}" ]]; then
    key_ref="env://COSIGN_PRIVATE_KEY"
  fi
  if [[ -n "${key_ref}" ]]; then
    owned_key="$(mktemp)"
    public_key="${owned_key}"
    if ! cosign public-key --key "${key_ref}" >"${public_key}" || [[ ! -s "${public_key}" ]]; then
      echo "error: cannot export the configured signing key for exact legacy signature verification" >&2
      return 1
    fi
  else
    if cosign_keyless_requested && [[ -z "${COSIGN_PUBLIC_KEY_FILE:-}${COSIGN_PUBLIC_KEY:-}" ]]; then
      echo "error: legacy signature reconciliation requires an explicit trusted key; keyless legacy reconciliation is unsupported" >&2
      return 1
    fi
    public_key="${COSIGN_PUBLIC_KEY_FILE:-}"
    if [[ -z "${public_key}" && -n "${COSIGN_PUBLIC_KEY:-}" ]]; then
      owned_key="$(mktemp)"
      printf '%s\n' "${COSIGN_PUBLIC_KEY}" >"${owned_key}"
      public_key="${owned_key}"
    elif [[ -z "${public_key}" ]]; then
      public_key="${COSIGN_COMMON_REPO_ROOT}/docs/cosign.pub"
    fi
    if [[ -z "${public_key}" || ! -s "${public_key}" ]]; then
      echo "error: legacy signature reconciliation requires a trusted public key file" >&2
      return 1
    fi
  fi
  result="$(python3 "${helper}" "${ref}" "${public_key}")" || return $?
  case "${result}" in
    reused|absent) printf '%s\n' "${result}" ;;
    *) echo "error: invalid legacy reconciliation result" >&2; return 1 ;;
  esac
)


cosign_receipt() {
  python3 "${COSIGN_RECEIPT_TOOL}" "$@"
}

# --- Classic `.sig` publication, shared by the image, native add-on and Wasm signers ---
# Callers set REGISTRY_HOST and run on the publisher host with registry credentials.

resolve_registry_auth() {
  if [[ -n "${OCI_USERNAME:-}" && -n "${OCI_TOKEN:-}" ]]; then
    printf '%s|%s\n' "${OCI_USERNAME}" "${OCI_TOKEN}"
    return 0
  fi
  if [[ -n "${HARBOR_ROBOT_USERNAME:-}" && -n "${HARBOR_ROBOT_SECRET:-}" ]]; then
    printf '%s|%s\n' "${HARBOR_ROBOT_USERNAME}" "${HARBOR_ROBOT_SECRET}"
    return 0
  fi
  if [[ -n "${HARBOR_USERNAME:-}" && -n "${HARBOR_PASSWORD:-}" ]]; then
    printf '%s|%s\n' "${HARBOR_USERNAME}" "${HARBOR_PASSWORD}"
    return 0
  fi

  local docker_config
  docker_config="${DOCKER_CONFIG:-${HOME}/.docker}/config.json"
  if [[ -f "${docker_config}" ]]; then
    python3 - <<'PY' "${docker_config}" "${REGISTRY_HOST}"
import base64
import json
import sys
from pathlib import Path

config_path = Path(sys.argv[1])
registry_host = sys.argv[2]
config = json.loads(config_path.read_text())
auths = config.get("auths") or {}
entry = auths.get(registry_host) or auths.get(f"https://{registry_host}") or {}
auth = entry.get("auth") or ""
if auth:
    decoded = base64.b64decode(auth).decode("utf-8")
    user, _, password = decoded.partition(":")
    print(f"{user}|{password}")
else:
    print("|")
PY
    return 0
  fi

  printf '|\n'
}

fetch_registry_token() {
  local repo_path="$1"
  local scope_actions="${2:-pull,push}"
  local auth user pass
  auth="$(resolve_registry_auth)"
  IFS='|' read -r user pass <<<"${auth}"

  local token_url="https://${REGISTRY_HOST}/service/token?service=harbor-registry&scope=repository:${repo_path}:${scope_actions}"
  if [[ -n "${user}" && -n "${pass}" ]]; then
    curl -fsSL -u "${user}:${pass}" "${token_url}" | jq -r '.token'
  else
    curl -fsSL "${token_url}" | jq -r '.token'
  fi
}

upload_blob() {
  local repo_path="$1"
  local file_path="$2"
  local token digest status upload_url patch_headers

  token="$(fetch_registry_token "${repo_path}" "pull,push")"
  [[ -n "${token}" && "${token}" != "null" ]] || {
    echo "error: registry token lookup failed for ${repo_path}" >&2
    return 1
  }

  digest="sha256:$(shasum -a 256 "${file_path}" | awk '{print $1}')"
  status="$(
    curl -sS -o /dev/null \
      -H "Authorization: Bearer ${token}" \
      -I "https://${REGISTRY_HOST}/v2/${repo_path}/blobs/${digest}" \
      -w '%{http_code}' || true
  )"
  if [[ "${status}" == "200" ]]; then
    printf '%s\n' "${digest}"
    return 0
  fi

  upload_url="$(
    curl -fsSI -X POST \
      -H "Authorization: Bearer ${token}" \
      "https://${REGISTRY_HOST}/v2/${repo_path}/blobs/uploads/" \
      | awk 'tolower($1)=="location:" {print $2}' \
      | tr -d '\r'
  )"
  [[ -n "${upload_url}" ]] || {
    echo "error: failed to start blob upload for ${repo_path}" >&2
    return 1
  }
  case "${upload_url}" in
    http*) ;;
    /*) upload_url="https://${REGISTRY_HOST}${upload_url}" ;;
    *) upload_url="https://${REGISTRY_HOST}/${upload_url}" ;;
  esac

  patch_headers="$(mktemp)"
  if ! curl -fsS -D "${patch_headers}" -X PATCH \
    -H "Authorization: Bearer ${token}" \
    -H 'Content-Type: application/octet-stream' \
    --data-binary @"${file_path}" \
    "${upload_url}" >/dev/null; then
    rm -f "${patch_headers}"
    return 1
  fi
  upload_url="$(awk 'tolower($1)=="location:" {print $2}' "${patch_headers}" | tr -d '\r')"
  rm -f "${patch_headers}"
  [[ -n "${upload_url}" ]] || {
    echo "error: registry did not return upload location for ${repo_path}" >&2
    return 1
  }
  case "${upload_url}" in
    http*) ;;
    /*) upload_url="https://${REGISTRY_HOST}${upload_url}" ;;
    *) upload_url="https://${REGISTRY_HOST}/${upload_url}" ;;
  esac
  if [[ "${upload_url}" == *\?* ]]; then
    upload_url="${upload_url}&digest=${digest}"
  else
    upload_url="${upload_url}?digest=${digest}"
  fi

  curl -fsS -X PUT \
    -H "Authorization: Bearer ${token}" \
    "${upload_url}" >/dev/null || return 1
  printf '%s\n' "${digest}"
}

put_manifest_tag() {
  local repo_path="$1"
  local tag="$2"
  local manifest_file="$3"
  local token

  token="$(fetch_registry_token "${repo_path}" "pull,push")"
  [[ -n "${token}" && "${token}" != "null" ]] || {
    echo "error: registry token lookup failed for ${repo_path}" >&2
    return 1
  }

  curl -fsS -X PUT \
    -H "Authorization: Bearer ${token}" \
    -H 'Content-Type: application/vnd.oci.image.manifest.v1+json' \
    --data-binary @"${manifest_file}" \
    "https://${REGISTRY_HOST}/v2/${repo_path}/manifests/${tag}" >/dev/null || return 1
}

extract_detached_signature() {
  local signature_file="$1"
  local stdout_file="$2"
  local bundle_file="$3"
  local candidate=""

  if [[ -s "${signature_file}" ]]; then
    candidate="$(tr -d '\r\n' <"${signature_file}")"
  fi

  if [[ -z "${candidate}" && -s "${stdout_file}" ]]; then
    candidate="$(tr -d '\r\n' <"${stdout_file}")"
  fi

  if [[ ! "${candidate}" =~ ^[A-Za-z0-9+/]+={0,2}$ ]] && [[ -s "${bundle_file}" ]]; then
    candidate="$(
      jq -r '
        .messageSignature.signature
        // .base64Signature
        // .Base64Signature
        // .dsseEnvelope.signatures[0].sig
        // empty
      ' "${bundle_file}"
    )"
  fi

  if [[ ! "${candidate}" =~ ^[A-Za-z0-9+/]+={0,2}$ ]]; then
    return 1
  fi

  printf '%s\n' "${candidate}"
}

# Sign one digest with exactly one classic `.sig` signature that carries its Rekor
# receipt in the `dev.sigstore.cosign/bundle` annotation. A verified existing signature
# is reused and never replaced: classic tags are content-addressed by digest and Harbor
# immutability rejects an overwrite. Every signature, created or reused, is recorded in
# the signing ledger, and a new one is recorded before it is uploaded to the log.
attach_legacy_signature() {
  local ref="$1"
  local repo="${ref%@*}"
  local repo_path="${repo#"${REGISTRY_HOST}"/}"
  local signature_ref signature_tag legacy_state temp_file
  local payload_file signature_file bundle_file stdout_file extracted_signature_file
  local receipt_file config_file manifest_file payload_digest

  signature_ref="$(cosign triangulate "${ref}")" || return 1
  signature_tag="${signature_ref##*:}"

  legacy_state="$(cosign_reconcile_legacy_signature "${ref}")" || return 1
  if [[ "${legacy_state}" == "reused" ]]; then
    cosign_receipt ledger-reused "${ref}" || return 1
    echo "verified existing legacy signature for ${ref}; not signing again"
    return 0
  fi

  payload_file="$(mktemp)"
  signature_file="$(mktemp)"
  bundle_file="$(mktemp)"
  stdout_file="$(mktemp)"
  extracted_signature_file="$(mktemp)"
  receipt_file="$(mktemp)"
  config_file="$(mktemp)"
  manifest_file="$(mktemp)"
  for temp_file in "${payload_file}" "${signature_file}" "${bundle_file}" "${stdout_file}" \
    "${extracted_signature_file}" "${receipt_file}" "${config_file}" "${manifest_file}"; do
    cosign_register_temp_file "${temp_file}"
  done

  cosign generate "${ref}" >"${payload_file}" || return 1
  cosign_receipt ledger-sign "${ref}" "${payload_file}" || return 1
  cosign_sign_blob_with_receipt "${payload_file}" "${bundle_file}" "${signature_file}" "${stdout_file}" || return 1
  # No `.sig` tag is written for a signature without its receipt from the pinned log.
  cosign_receipt receipt "${bundle_file}" "${COSIGN_SIGSTORE_DIR}/rekor.pub" >"${receipt_file}" || return 1
  cosign_receipt ledger-logged "${ref}" "${payload_file}" "${bundle_file}" || return 1

  if ! extract_detached_signature "${signature_file}" "${stdout_file}" "${bundle_file}" >"${extracted_signature_file}"; then
    echo "error: detached cosign signature was empty for ${ref}" >&2
    return 1
  fi

  payload_digest="sha256:$(shasum -a 256 "${payload_file}" | awk '{print $1}')"
  cat >"${config_file}" <<EOF
{"architecture":"","created":"0001-01-01T00:00:00Z","history":[{"created":"0001-01-01T00:00:00Z"}],"os":"","rootfs":{"type":"layers","diff_ids":["${payload_digest}"]},"config":{}}
EOF

  upload_blob "${repo_path}" "${config_file}" >/dev/null || return 1
  upload_blob "${repo_path}" "${payload_file}" >/dev/null || return 1
  cosign_receipt manifest "${config_file}" "${payload_file}" "${extracted_signature_file}" "${receipt_file}" \
    >"${manifest_file}" || return 1
  put_manifest_tag "${repo_path}" "${signature_tag}" "${manifest_file}" || return 1
}

# --- Release verification of classic `.sig` signatures ---

# The release public key passed to `cosign verify`. Call after cosign_init_verify_args.
cosign_release_verify_key() {
  local index
  for ((index = 0; index < ${#COSIGN_VERIFY_ARGS[@]} - 1; index++)); do
    if [[ "${COSIGN_VERIFY_ARGS[index]}" == "--key" ]]; then
      printf '%s\n' "${COSIGN_VERIFY_ARGS[index + 1]}"
      return 0
    fi
  done
  echo "error: release signature verification requires the release public key" >&2
  return 1
}

# Verify the classic `.sig` of one digest (kind: image, wasm-plugin or native-addon) the way
# this run's signing ledger says it was produced, never by whether a receipt happens to be
# present. A reused signature counts as pre-cutover only within bounds: a public-good
# receipt must have been integrated before the pinned cutover (cutover.json), and a reused
# Wasm plugin or native add-on signature without a receipt must be on the frozen
# pre-cutover allowlist; a reused image relies on Kyverno admission. A digest created in the run
# must carry a receipt from an accepted (self-hosted) log that verifies offline under the
# pinned key for its log ID. A reused signature is held to its receipt when it carries one,
# from an accepted log or, for a pre-cutover manual signing, from the public-good log; it is
# verified with the release key alone when it carries none, which only a pre-cutover
# signature can. A digest the ledger does not record fails. No Rekor is contacted.
# Call after cosign_init_verify_args.
cosign_verify_legacy_signature() {
  local ref="$1"
  local kind="${2:-}"
  local digest="${ref##*@}"
  local class signature_ref log_id release_key key_file output

  case "${kind}" in
    image|wasm-plugin|native-addon) ;;
    *) echo "error: cosign_verify_legacy_signature needs the artifact kind (image, wasm-plugin or native-addon)" >&2; return 1 ;;
  esac

  class="$(cosign_receipt ledger-classify "${digest}")" || return 1
  if [[ "${class}" == "unrecorded" ]]; then
    echo "error: ${ref} was neither signed nor reused by this run (no signing-ledger record)" >&2
    return 1
  fi
  release_key="$(cosign_release_verify_key)" || return 1
  signature_ref="$(cosign triangulate "${ref}")" || return 1
  if ! log_id="$("${ORAS_BIN:-oras}" manifest fetch "${signature_ref}" | cosign_receipt receipt-log-id)"; then
    echo "error: cannot read the transparency-log receipt of ${signature_ref}" >&2
    return 1
  fi

  if [[ -z "${log_id}" ]]; then
    if [[ "${class}" == "created" ]]; then
      echo "error: ${ref} was signed in this run but its signature carries no transparency-log receipt" >&2
      return 1
    fi
    if [[ "${kind}" != "image" ]] && ! cosign_receipt allowlisted "${digest}" \
      "${COSIGN_SIGSTORE_DIR}/pre-cutover-first-party-digests.json"; then
      echo "error: ${ref} reuses a signature without a receipt and is not on the frozen pre-cutover allowlist" >&2
      return 1
    fi
    env -u SIGSTORE_REKOR_PUBLIC_KEY \
      cosign verify --new-bundle-format=false --insecure-ignore-tlog=true \
      --key "${release_key}" --timeout "${COSIGN_VERIFY_TIMEOUT}" "${ref}"
    return
  fi

  key_file="${COSIGN_SIGSTORE_DIR}/rekor-keys/${log_id}.pub"
  if [[ -f "${key_file}" ]]; then
    SIGSTORE_REKOR_PUBLIC_KEY="${key_file}" \
      cosign verify --new-bundle-format=false --offline=true \
      --key "${release_key}" --timeout "${COSIGN_VERIFY_TIMEOUT}" "${ref}"
    return
  fi
  key_file="${COSIGN_SIGSTORE_DIR}/pre-cutover-rekor-keys/${log_id}.pub"
  if [[ "${class}" != "reused" || ! -f "${key_file}" ]]; then
    echo "error: ${ref} carries a receipt from log ${log_id}, which is not an accepted Rekor log for a ${class} signature" >&2
    return 1
  fi
  # A pre-cutover log's receipt counts only for an entry integrated before the cutover; the
  # integrated time is read from what cosign verified, which the SET covers.
  output="$(SIGSTORE_REKOR_PUBLIC_KEY="${key_file}" \
    cosign verify --new-bundle-format=false --offline=true \
    --key "${release_key}" --timeout "${COSIGN_VERIFY_TIMEOUT}" "${ref}")" || return 1
  if ! cosign_receipt verified-before-cutover "${log_id}" "${COSIGN_SIGSTORE_DIR}/cutover.json" <<<"${output}"; then
    echo "error: ${ref} reuses a receipt from the pre-cutover log ${log_id} integrated at or after the cutover" >&2
    return 1
  fi
  printf '%s\n' "${output}"
}
