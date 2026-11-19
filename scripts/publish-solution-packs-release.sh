#!/usr/bin/env bash
# Package, sign, verify, index, and optionally upload ServiceRadar Solution Packs
# (.srpack, .srpack.sig, and serviceradar-pack-index.json) to a GitHub Release.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${SERVICERADAR_REPO_ROOT:-$(cd "${SCRIPT_DIR}/.." && pwd)}"

DRY_RUN="false"
SKIP_CLI_BUILD="false"
OUT_DIR=""
PACKS_DIR="${REPO_ROOT}/elixir/serviceradar_core/priv/solution_packs"
RELEASE_TAG="${RELEASE_TAG:-${EXTRA_TAG:-}}"
GITHUB_REPO="${GITHUB_REPOSITORY:-carverauto/serviceradar}"
RELEASE_ID_ARG="${RELEASE_ID:-}"

usage() {
  cat <<'EOF'
Usage: publish-solution-packs-release.sh [options]

Options:
  --release-tag, --tag <tag>  Release tag for download URLs and GitHub Release upload.
  --repo <owner/repo>         GitHub repository (default: GITHUB_REPOSITORY or carverauto/serviceradar).
  --out-dir <dir>             Output directory for .srpack, .srpack.sig, and serviceradar-pack-index.json.
  --packs-dir <dir>           Source directory containing pack subdirectories.
  --release-id <id>           Pre-resolved GitHub Release numeric ID.
  --dry-run                   Run validate -> build -> sign -> verify -> index without GitHub upload.
  --skip-cli-build            Skip building js/cli if js/cli/dist/cli.js already exists.
  -h, --help                  Show this help text.

Signing environment (one mode required):
  1. Direct Ed25519 key:
     PACK_UPLOAD_SIGNING_PRIVATE_KEY[_FILE] or PLUGIN_UPLOAD_SIGNING_PRIVATE_KEY[_FILE]
     PACK_UPLOAD_SIGNING_KEY_ID or PLUGIN_UPLOAD_SIGNING_KEY_ID
     Optional: PACK_UPLOAD_SIGNING_SIGNER / PLUGIN_UPLOAD_SIGNING_SIGNER
               PACK_UPLOAD_SIGNING_PUBLIC_KEY[_FILE] / PLUGIN_UPLOAD_SIGNING_PUBLIC_KEY[_FILE]
  2. OpenBao Transit:
     PLUGIN_UPLOAD_SIGNING_TRANSIT_KEY (with VAULT_ADDR and VAULT_TOKEN)
     PLUGIN_UPLOAD_SIGNING_KEY_ID
     Optional: PLUGIN_UPLOAD_SIGNING_SIGNER, VAULT_CACERT, VAULT_SKIP_VERIFY
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --release-tag|--tag)
      RELEASE_TAG="${2:-}"
      shift 2
      ;;
    --repo)
      GITHUB_REPO="${2:-}"
      shift 2
      ;;
    --out-dir)
      OUT_DIR="${2:-}"
      shift 2
      ;;
    --packs-dir)
      PACKS_DIR="${2:-}"
      shift 2
      ;;
    --release-id)
      RELEASE_ID_ARG="${2:-}"
      shift 2
      ;;
    --dry-run)
      DRY_RUN="true"
      shift
      ;;
    --skip-cli-build)
      SKIP_CLI_BUILD="true"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ -z "${RELEASE_TAG}" ]]; then
  if [[ "${DRY_RUN}" == "true" ]]; then
    RELEASE_TAG="v0.0.0-dry-run"
  elif [[ -n "${GITHUB_REF_NAME:-}" ]]; then
    RELEASE_TAG="${GITHUB_REF_NAME}"
  else
    echo "Missing --release-tag (or RELEASE_TAG)." >&2
    exit 1
  fi
fi

if [[ -z "${OUT_DIR}" ]]; then
  OUT_DIR="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/serviceradar-solution-packs-${RELEASE_TAG}"
fi

if [[ ! -d "${PACKS_DIR}" ]]; then
  echo "Solution packs directory does not exist: ${PACKS_DIR}" >&2
  exit 1
fi

CLI_DIR="${REPO_ROOT}/js/cli"
CLI_ENTRY="${CLI_DIR}/dist/cli.js"

ensure_cli_built() {
  if [[ "${SKIP_CLI_BUILD}" == "true" && -f "${CLI_ENTRY}" ]]; then
    return 0
  fi

  if [[ ! -f "${CLI_DIR}/package.json" ]]; then
    echo "Missing js/cli package at ${CLI_DIR}" >&2
    exit 1
  fi

  if [[ ! -d "${CLI_DIR}/node_modules" ]]; then
    if command -v sfw >/dev/null 2>&1; then
      (cd "${CLI_DIR}" && sfw npm ci)
    else
      (cd "${CLI_DIR}" && npm ci)
    fi
  fi

  (cd "${CLI_DIR}" && npm run build)

  if [[ ! -f "${CLI_ENTRY}" ]]; then
    echo "Expected built CLI entrypoint at ${CLI_ENTRY}" >&2
    exit 1
  fi
}

SIGNING_MODE=""
SIGNING_KEY_ID="${PACK_UPLOAD_SIGNING_KEY_ID:-${PLUGIN_UPLOAD_SIGNING_KEY_ID:-}}"
SIGNING_SIGNER="${PACK_UPLOAD_SIGNING_SIGNER:-${PLUGIN_UPLOAD_SIGNING_SIGNER:-${SIGNING_KEY_ID}}}"
TRANSIT_KEY="${PLUGIN_UPLOAD_SIGNING_TRANSIT_KEY:-}"
VAULT_BASE_URL=""
VAULT_AUTH_TOKEN=""
VAULT_CURL_TLS_ARGS=()
PUBLIC_KEY_B64=""

resolve_signing_mode() {
  if [[ -z "${SIGNING_KEY_ID}" ]]; then
    echo "Missing signing key id: set PACK_UPLOAD_SIGNING_KEY_ID or PLUGIN_UPLOAD_SIGNING_KEY_ID." >&2
    exit 1
  fi

  if [[ -n "${PACK_UPLOAD_SIGNING_PRIVATE_KEY:-}" || \
        -n "${PACK_UPLOAD_SIGNING_PRIVATE_KEY_FILE:-}" || \
        -n "${PLUGIN_UPLOAD_SIGNING_PRIVATE_KEY:-}" || \
        -n "${PLUGIN_UPLOAD_SIGNING_PRIVATE_KEY_FILE:-}" ]]; then
    SIGNING_MODE="private_key"
    return 0
  fi

  VAULT_BASE_URL="${VAULT_ADDR:-${BAO_ADDR:-${OPENBAO_ADDR:-}}}"
  VAULT_BASE_URL="${VAULT_BASE_URL%/}"
  VAULT_AUTH_TOKEN="${VAULT_TOKEN:-${BAO_TOKEN:-}}"

  if [[ -n "${TRANSIT_KEY}" || ( -n "${VAULT_BASE_URL}" && -n "${VAULT_AUTH_TOKEN}" ) ]]; then
    if [[ -z "${VAULT_BASE_URL}" || -z "${VAULT_AUTH_TOKEN}" ]]; then
      echo "OpenBao Transit signing requires VAULT_ADDR and VAULT_TOKEN." >&2
      exit 1
    fi
    if [[ -z "${TRANSIT_KEY}" ]]; then
      TRANSIT_KEY="plugin-upload-signing"
    fi
    local cacert="${VAULT_CACERT:-${BAO_CACERT:-${OPENBAO_CACERT:-}}}"
    if [[ -n "${cacert}" ]]; then
      VAULT_CURL_TLS_ARGS=(--cacert "${cacert}")
    elif [[ "${VAULT_SKIP_VERIFY:-${BAO_SKIP_VERIFY:-}}" =~ ^(1|true|yes|TRUE|YES)$ ]]; then
      VAULT_CURL_TLS_ARGS=(--insecure)
    fi
    SIGNING_MODE="transit"
    return 0
  fi

  echo "Missing solution pack signing key: set PLUGIN_UPLOAD_SIGNING_PRIVATE_KEY[_FILE], PACK_UPLOAD_SIGNING_PRIVATE_KEY[_FILE], or OpenBao Transit credentials." >&2
  exit 1
}

resolve_public_key_b64() {
  if [[ -n "${PACK_UPLOAD_SIGNING_PUBLIC_KEY:-}" ]]; then
    PUBLIC_KEY_B64="$(printf '%s' "${PACK_UPLOAD_SIGNING_PUBLIC_KEY}" | tr -d '\r\n')"
    return 0
  fi
  if [[ -n "${PLUGIN_UPLOAD_SIGNING_PUBLIC_KEY:-}" ]]; then
    PUBLIC_KEY_B64="$(printf '%s' "${PLUGIN_UPLOAD_SIGNING_PUBLIC_KEY}" | tr -d '\r\n')"
    return 0
  fi
  if [[ -n "${PACK_UPLOAD_SIGNING_PUBLIC_KEY_FILE:-}" ]]; then
    PUBLIC_KEY_B64="$(tr -d '\r\n' < "${PACK_UPLOAD_SIGNING_PUBLIC_KEY_FILE}")"
    return 0
  fi
  if [[ -n "${PLUGIN_UPLOAD_SIGNING_PUBLIC_KEY_FILE:-}" ]]; then
    PUBLIC_KEY_B64="$(tr -d '\r\n' < "${PLUGIN_UPLOAD_SIGNING_PUBLIC_KEY_FILE}")"
    return 0
  fi

  if [[ "${SIGNING_MODE}" == "private_key" ]]; then
    PUBLIC_KEY_B64="$(
      node --input-type=module - "${CLI_DIR}/dist/pack/sign.js" <<'NODE'
import {readFileSync} from "node:fs"
import {pathToFileURL} from "node:url"

const signMod = await import(pathToFileURL(process.argv[2]).href)
const raw =
  process.env.PACK_UPLOAD_SIGNING_PRIVATE_KEY?.trim() ||
  process.env.PLUGIN_UPLOAD_SIGNING_PRIVATE_KEY?.trim() ||
  (process.env.PACK_UPLOAD_SIGNING_PRIVATE_KEY_FILE?.trim()
    ? readFileSync(process.env.PACK_UPLOAD_SIGNING_PRIVATE_KEY_FILE.trim(), "utf8").trim()
    : "") ||
  (process.env.PLUGIN_UPLOAD_SIGNING_PRIVATE_KEY_FILE?.trim()
    ? readFileSync(process.env.PLUGIN_UPLOAD_SIGNING_PRIVATE_KEY_FILE.trim(), "utf8").trim()
    : "")

if (!raw) {
  throw new Error("unable to resolve private key to derive public key")
}
const {publicKeyBytes} = signMod.parseEd25519PrivateKey(raw)
process.stdout.write(publicKeyBytes.toString("base64"))
NODE
    )"
  else
    local key_resp
    key_resp="$(curl -fsSL "${VAULT_CURL_TLS_ARGS[@]}" \
      -H "X-Vault-Token: ${VAULT_AUTH_TOKEN}" \
      "${VAULT_BASE_URL}/v1/transit/keys/${TRANSIT_KEY}")"
    PUBLIC_KEY_B64="$(
      KEY_RESP="${key_resp}" node --input-type=module - "${CLI_DIR}/dist/pack/sign.js" <<'NODE'
import {pathToFileURL} from "node:url"

const signMod = await import(pathToFileURL(process.argv[2]).href)
const parsed = JSON.parse(process.env.KEY_RESP || "{}")
if (Array.isArray(parsed.errors) && parsed.errors.length > 0) {
  throw new Error(`OpenBao transit public key lookup failed: ${parsed.errors.join("; ")}`)
}
const version = String(parsed?.data?.latest_version || 1)
const pubRaw = parsed?.data?.keys?.[version]?.public_key
if (typeof pubRaw !== "string" || !pubRaw.trim()) {
  throw new Error(`OpenBao transit key missing public_key for version ${version}`)
}
let keyBytes = signMod.decodeSigningBytes(pubRaw)
if (keyBytes.length > 32) {
  keyBytes = keyBytes.subarray(keyBytes.length - 32)
}
if (keyBytes.length !== 32) {
  throw new Error(`expected 32-byte Ed25519 public key from OpenBao, got ${keyBytes.length}`)
}
process.stdout.write(keyBytes.toString("base64"))
NODE
    )"
  fi

  if [[ -z "${PUBLIC_KEY_B64}" ]]; then
    echo "Failed to resolve Ed25519 public key for signature verification." >&2
    exit 1
  fi
}

sign_srpack_bundle() {
  local bundle_path="$1"
  local sig_path="$2"

  if [[ "${SIGNING_MODE}" == "private_key" ]]; then
    node "${CLI_ENTRY}" pack sign "${bundle_path}" \
      --out "${sig_path}" \
      --key-id "${SIGNING_KEY_ID}" \
      --signer "${SIGNING_SIGNER}"
    return 0
  fi

  local payload_info content_hash payload_b64 transit_body transit_resp sig_b64
  payload_info="$(
    node --input-type=module - "${CLI_DIR}/dist/pack" "${bundle_path}" <<'NODE'
import {readFileSync} from "node:fs"
import {join} from "node:path"
import {pathToFileURL} from "node:url"

const packDir = process.argv[2]
const bundlePath = process.argv[3]
const archiveMod = await import(pathToFileURL(join(packDir, "archive.js")).href)
const validateMod = await import(pathToFileURL(join(packDir, "validate.js")).href)
const canonicalMod = await import(pathToFileURL(join(packDir, "canonical.js")).href)
const signMod = await import(pathToFileURL(join(packDir, "sign.js")).href)

const archiveBytes = readFileSync(bundlePath)
const archiveFiles = archiveMod.readSrpackArchive(archiveBytes)
const validation = validateMod.validatePackFiles(archiveFiles, {verifyHashes: true})
if (!validation.ok) {
  throw new validateMod.PackValidationError(validation.issues)
}
const contentHash = canonicalMod.sha256Hex(archiveBytes)
const payload = signMod.buildVerificationPayload(validation.result.manifest, contentHash)
process.stdout.write(JSON.stringify({
  content_hash: contentHash,
  payload_b64: payload.toString("base64"),
}))
NODE
  )"

  content_hash="$(jq -er '.content_hash' <<<"${payload_info}")"
  payload_b64="$(jq -er '.payload_b64' <<<"${payload_info}")"
  transit_body="$(jq -cn --arg input "${payload_b64}" '{input: $input}')"

  transit_resp="$(curl -fsSL "${VAULT_CURL_TLS_ARGS[@]}" \
    -X POST \
    -H "X-Vault-Token: ${VAULT_AUTH_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "${transit_body}" \
    "${VAULT_BASE_URL}/v1/transit/sign/${TRANSIT_KEY}")"

  sig_b64="$(jq -er '.data.signature // empty' <<<"${transit_resp}")"
  if [[ -z "${sig_b64}" ]]; then
    echo "OpenBao transit sign returned no signature for ${bundle_path}" >&2
    exit 1
  fi
  sig_b64="${sig_b64##*:}"

  jq -n \
    --arg algorithm "ed25519" \
    --arg key_id "${SIGNING_KEY_ID}" \
    --arg signer "${SIGNING_SIGNER}" \
    --arg content_hash "${content_hash}" \
    --arg signature "${sig_b64}" \
    '{
      algorithm: $algorithm,
      key_id: $key_id,
      signer: $signer,
      content_hash: $content_hash,
      signature: $signature
    }' > "${sig_path}"

  echo "Signed ${bundle_path} via OpenBao Transit -> ${sig_path}"
}

ensure_cli_built
resolve_signing_mode
resolve_public_key_b64

mkdir -p "${OUT_DIR}"
rm -f "${OUT_DIR}"/*.srpack "${OUT_DIR}"/*.srpack.sig "${OUT_DIR}/serviceradar-pack-index.json"

pack_dirs=()
while IFS= read -r dir_path; do
  if [[ -f "${dir_path}/manifest.json" ]]; then
    pack_dirs+=("${dir_path}")
  fi
done < <(find "${PACKS_DIR}" -mindepth 1 -maxdepth 1 -type d | LC_ALL=C sort)

if (( ${#pack_dirs[@]} == 0 )); then
  echo "No solution pack directories with manifest.json found under ${PACKS_DIR}" >&2
  exit 1
fi

uploaded_files=()

for pack_dir in "${pack_dirs[@]}"; do
  manifest_path="${pack_dir}/manifest.json"
  slug="$(jq -er '.slug' "${manifest_path}")"
  version="$(jq -er '.version' "${manifest_path}")"

  if [[ ! "${slug}" =~ ^[a-z0-9][a-z0-9._-]*$ ]]; then
    echo "Invalid pack slug '${slug}' in ${manifest_path}" >&2
    exit 1
  fi
  if [[ ! "${version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+([+-][0-9A-Za-z.-]+)?$ ]]; then
    echo "Invalid pack version '${version}' in ${manifest_path}" >&2
    exit 1
  fi

  bundle_file="${slug}-${version}.srpack"
  bundle_path="${OUT_DIR}/${bundle_file}"
  sig_path="${bundle_path}.sig"

  echo "Validating pack ${slug}@${version} (${pack_dir})..."
  node "${CLI_ENTRY}" pack validate "${pack_dir}"

  echo "Building ${bundle_file}..."
  node "${CLI_ENTRY}" pack build "${pack_dir}" -o "${bundle_path}"

  echo "Signing ${bundle_file}..."
  sign_srpack_bundle "${bundle_path}" "${sig_path}"

  echo "Verifying ${bundle_file}..."
  node "${CLI_ENTRY}" pack verify "${bundle_path}" \
    --signature "${sig_path}" \
    --public-key "${PUBLIC_KEY_B64}" \
    --key-id "${SIGNING_KEY_ID}"

  uploaded_files+=("${bundle_path}" "${sig_path}")
done

INDEX_PATH="${OUT_DIR}/serviceradar-pack-index.json"
echo "Generating catalog index ${INDEX_PATH} for ${GITHUB_REPO}@${RELEASE_TAG}..."
node "${CLI_ENTRY}" pack index "${OUT_DIR}" \
  --out "${INDEX_PATH}" \
  --repo "${GITHUB_REPO}" \
  --release-tag "${RELEASE_TAG}" \
  --require-signatures \
  --public-key "${PUBLIC_KEY_B64}"

jq -e --argjson expected "${#pack_dirs[@]}" \
  '.format_version == 1 and (.packs | length) == $expected and all(.packs[]; .signed == true)' \
  "${INDEX_PATH}" >/dev/null

uploaded_files+=("${INDEX_PATH}")

echo "Prepared ${#pack_dirs[@]} signed solution pack(s) in ${OUT_DIR}:"
for asset in "${uploaded_files[@]}"; do
  echo "  - $(basename "${asset}")"
done

if [[ "${DRY_RUN}" == "true" ]]; then
  echo "Dry-run enabled; skipping GitHub Release upload."
  exit 0
fi

token="${GITHUB_TOKEN:-${GH_TOKEN:-}}"
if [[ -z "${token}" ]]; then
  echo "Missing GitHub token (GITHUB_TOKEN/GH_TOKEN)." >&2
  exit 1
fi

api_base="https://api.github.com/repos/${GITHUB_REPO}"
gh_headers=(
  -H "Accept: application/vnd.github+json"
  -H "Authorization: Bearer ${token}"
  -H "X-GitHub-Api-Version: 2022-11-28"
)

# /releases/tags/{tag} hides drafts. Always list first.
fetch_release() {
  local release_json releases_json
  releases_json="$(curl -sS "${gh_headers[@]}" \
    "${api_base}/releases?per_page=100" || true)"
  release_json="$(jq -c --arg tag "${RELEASE_TAG}" \
    'if type == "array" then first(.[] | select(.tag_name == $tag)) // empty else empty end' \
    <<<"${releases_json}" 2>/dev/null || true)"
  if [[ -n "${release_json}" ]]; then
    printf '%s\n' "${release_json}"
    return 0
  fi
  curl -sS "${gh_headers[@]}" \
    "${api_base}/releases/tags/${RELEASE_TAG}" || true
}

release_id="${RELEASE_ID_ARG}"
if [[ -z "${release_id}" ]]; then
  release_json="$(fetch_release)"
  release_id="$(echo "${release_json}" | jq -r 'select(type == "object") | .id // empty')"
fi

if [[ -z "${release_id}" ]]; then
  target_commitish=""
  if [[ "${RELEASE_TAG}" =~ ^sha-([0-9a-f]{40})$ ]]; then
    target_commitish="${BASH_REMATCH[1]}"
  elif git -C "${REPO_ROOT}" rev-parse -q --verify "refs/tags/${RELEASE_TAG}" >/dev/null 2>&1; then
    target_commitish=""
  elif [[ -n "${GITHUB_SHA:-}" ]]; then
    peeled="$(git -C "${REPO_ROOT}" rev-parse -q --verify "${GITHUB_SHA}^{commit}" 2>/dev/null || true)"
    if [[ "${peeled}" =~ ^[0-9a-f]{40}$ ]]; then
      target_commitish="${peeled}"
    fi
  fi

  if [[ -n "${target_commitish}" ]]; then
    create_body="$(
      jq -n \
        --arg tag_name "${RELEASE_TAG}" \
        --arg target_commitish "${target_commitish}" \
        --arg name "Solution packs catalog ${RELEASE_TAG}" \
        --arg body "Generated signed solution pack catalog for ${RELEASE_TAG}." \
        '{
          tag_name: $tag_name,
          target_commitish: $target_commitish,
          name: $name,
          body: $body,
          draft: true,
          prerelease: true
        }'
    )"
  else
    create_body="$(
      jq -n \
        --arg tag_name "${RELEASE_TAG}" \
        --arg name "Solution packs catalog ${RELEASE_TAG}" \
        --arg body "Generated signed solution pack catalog for ${RELEASE_TAG}." \
        '{
          tag_name: $tag_name,
          name: $name,
          body: $body,
          draft: true,
          prerelease: true
        }'
    )"
  fi

  create_json="$(curl -sS -w '\n%{http_code}' -X POST \
    "${gh_headers[@]}" \
    -H "Content-Type: application/json" \
    -d "${create_body}" \
    "${api_base}/releases" || true)"
  create_code="$(echo "${create_json}" | tail -n1)"
  create_json="$(echo "${create_json}" | sed '$d')"
  echo "Create release HTTP ${create_code}"
  release_id="$(echo "${create_json}" | jq -r 'select(type == "object") | .id // empty')"
  if [[ -z "${release_id}" ]]; then
    echo "${create_json}" | jq -c . >&2 || echo "${create_json}" >&2
    release_json="$(fetch_release)"
    release_id="$(echo "${release_json}" | jq -r 'select(type == "object") | .id // empty')"
  fi
fi

if [[ ! "${release_id}" =~ ^[0-9]+$ ]]; then
  echo "Unable to resolve or create numeric release id for ${RELEASE_TAG}" >&2
  exit 1
fi

release_json="$(curl -sSf "${gh_headers[@]}" "${api_base}/releases/${release_id}")"
resolved_release_id="$(echo "${release_json}" | jq -r '.id // empty')"
if [[ "${resolved_release_id}" != "${release_id}" ]]; then
  echo "GitHub returned an unexpected release while resolving ${RELEASE_TAG}" >&2
  exit 1
fi

is_draft="$(echo "${release_json}" | jq -r '.draft // false')"
upload_resp_file="$(mktemp)"
trap 'rm -f "${upload_resp_file}"' EXIT

for asset_path in "${uploaded_files[@]}"; do
  asset_name="$(basename "${asset_path}")"
  existing_asset_id="$(echo "${release_json}" | jq -r --arg name "${asset_name}" \
    '.assets[]? | select(.name == $name) | .id' | head -n1)"

  if [[ -n "${existing_asset_id}" ]]; then
    if [[ "${is_draft}" != "true" ]]; then
      echo "Release ${RELEASE_TAG} is published and immutable; cannot replace ${asset_name} (asset ${existing_asset_id})." >&2
      exit 1
    fi
    curl -sSf -X DELETE "${gh_headers[@]}" \
      "${api_base}/releases/assets/${existing_asset_id}" >/dev/null
  fi

  upload_url="https://uploads.github.com/repos/${GITHUB_REPO}/releases/${release_id}/assets?name=${asset_name}"
  upload_status="$(curl -sS -o "${upload_resp_file}" -w '%{http_code}' -X POST \
    "${gh_headers[@]}" \
    -H "Content-Type: application/octet-stream" \
    --data-binary "@${asset_path}" \
    "${upload_url}")"
  if [[ "${upload_status}" != "201" ]]; then
    echo "Upload of ${asset_name} failed with HTTP ${upload_status}" >&2
    jq -c . "${upload_resp_file}" 2>/dev/null || cat "${upload_resp_file}" >&2
    exit 1
  fi
  echo "Uploaded ${asset_name} to ${RELEASE_TAG} (release ${release_id})"
done

refreshed_release_json="$(curl -sSf "${gh_headers[@]}" "${api_base}/releases/${release_id}")"
for asset_path in "${uploaded_files[@]}"; do
  asset_name="$(basename "${asset_path}")"
  uploaded_count="$(echo "${refreshed_release_json}" | jq -r --arg name "${asset_name}" \
    '[.assets[]? | select(.name == $name and ((.size // 0) > 0))] | length')"
  if [[ "${uploaded_count}" != "1" ]]; then
    echo "Expected uploaded asset ${asset_name} to be present on ${RELEASE_TAG} after upload" >&2
    exit 1
  fi
done

echo "Verified ${#uploaded_files[@]} solution pack release asset(s) on ${RELEASE_TAG}."
