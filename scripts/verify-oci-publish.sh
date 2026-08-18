#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1090,SC1091
source "${SERVICERADAR_COSIGN_COMMON:-${SCRIPT_DIR}/cosign_common.sh}"
trap cosign_cleanup_temp_files EXIT

# Release retries copy this script to RUNNER_TEMP. Honor the checkout root so
# image_inventory.bzl is not resolved as $RUNNER_TEMP/../docker/images/...
REPO_ROOT="${SERVICERADAR_REPO_ROOT:-$(cd "${SCRIPT_DIR}/.." && pwd)}"
INVENTORY="${SERVICERADAR_IMAGE_INVENTORY:-${REPO_ROOT}/docker/images/image_inventory.bzl}"
REGISTRY_HOST="${OCI_REGISTRY:-registry.carverauto.dev}"
OCI_PROJECT="${OCI_PROJECT:-serviceradar}"
OCI_REPOSITORY_BASE="${REGISTRY_HOST}/${OCI_PROJECT}"

if ! command -v python3 >/dev/null 2>&1; then
  echo "error: python3 is required" >&2
  exit 1
fi

if [[ ! -r "${INVENTORY}" ]]; then
  echo "error: image inventory is not readable: ${INVENTORY}" >&2
  exit 1
fi

image_specs_output="$(
  python3 - "${INVENTORY}" "${OCI_REPOSITORY_BASE}" <<'PY'
import ast
import re
import sys
from pathlib import Path

inventory_path = Path(sys.argv[1])
repository_base = sys.argv[2]
text = inventory_path.read_text()
match = re.search(r"PUBLISHABLE_IMAGES\s*=\s*(\[[\s\S]*?\])\n\n", text)
if not match:
    raise SystemExit(f"unable to parse image inventory: {inventory_path}")

entries = ast.literal_eval(match.group(1))
for entry in entries:
    image_name = entry["repository"].rsplit("/", 1)[-1]
    kind = "index" if entry.get("push_image") else "single"
    print(f"{repository_base}/{image_name}|{kind}")
PY
)" || {
  echo "error: failed to parse publishable image repositories from ${INVENTORY}" >&2
  exit 1
}

if [[ -z "${image_specs_output}" ]]; then
  echo "error: no publishable image repositories found in ${INVENTORY}" >&2
  exit 1
fi

mapfile -t IMAGE_SPECS <<<"${image_specs_output}"

if [[ "${1:-}" == "--list-image-specs" ]]; then
  printf '%s\n' "${IMAGE_SPECS[@]}"
  exit 0
fi

if ! command -v oras >/dev/null 2>&1; then
  echo "error: oras is required" >&2
  exit 1
fi
# shellcheck source=scripts/oci_registry.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/oci_registry.sh"

if ! command -v jq >/dev/null 2>&1; then
  echo "error: jq is required" >&2
  exit 1
fi

if ! command -v curl >/dev/null 2>&1; then
  echo "error: curl is required" >&2
  exit 1
fi

if ! command -v cosign >/dev/null 2>&1; then
  echo "error: cosign is required" >&2
  exit 1
fi

if [[ "$#" -eq 0 ]]; then
  TAGS=("latest")
else
  TAGS=("$@")
fi

fail() {
  echo "error: $*" >&2
  exit 1
}

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
  printf '|\n'
}

assert_eq() {
  local actual="$1"
  local expected="$2"
  local context="$3"
  if [[ "$actual" != "$expected" ]]; then
    fail "$context: expected '$expected', got '$actual'"
  fi
}

assert_contains_env() {
  local config_json="$1"
  local expected="$2"
  local context="$3"
  if ! jq -e --arg expected "$expected" '.config.Env // [] | index($expected)' <<<"$config_json" >/dev/null; then
    fail "$context: missing env '$expected'"
  fi
}

resolve_digest() {
  local ref="$1"
  oci_registry_digest "${ref}"
}

check_image_shape() {
  local tag="$1"
  local ref="$2"
  local kind="$3"
  local raw
  raw="$(oci_registry_manifest "${ref}:${tag}")"
  local media_type
  media_type="$(jq -r '.mediaType' <<<"$raw")"

  if [[ "$kind" == "index" ]]; then
    assert_eq "$media_type" "application/vnd.oci.image.index.v1+json" "${ref}:${tag} mediaType"
    jq -e '
      [.manifests[].platform | "\(.os)/\(.architecture)\(if .variant then "/" + .variant else "" end)"] as $platforms
      | ($platforms | index("linux/amd64")) != null
      and ($platforms | index("linux/arm64/v8")) != null
    ' <<<"$raw" >/dev/null || fail "${ref}:${tag} is missing amd64/arm64-v8 manifests"
  else
    assert_eq "$media_type" "application/vnd.oci.image.manifest.v1+json" "${ref}:${tag} mediaType"
  fi
}

check_config() {
  local tag="$1"
  local ref="$2"
  local config
  config="$(oci_registry_config "${ref}:${tag}" linux amd64)"

  case "${ref##*/}" in
    serviceradar-web-ng)
      assert_eq "$(jq -c '.config.Entrypoint' <<<"$config")" '["/app/bin/serviceradar_web_ng"]' "${ref}:${tag} entrypoint"
      assert_eq "$(jq -c '.config.Cmd' <<<"$config")" '["start"]' "${ref}:${tag} cmd"
      assert_eq "$(jq -r '.config.WorkingDir' <<<"$config")" "/app" "${ref}:${tag} workdir"
      assert_contains_env "$config" "PHX_SERVER=true" "${ref}:${tag}"
      assert_contains_env "$config" "MIX_ENV=prod" "${ref}:${tag}"
      ;;
    serviceradar-core-elx)
      assert_eq "$(jq -c '.config.Entrypoint' <<<"$config")" '["/app/bin/serviceradar_core_elx"]' "${ref}:${tag} entrypoint"
      assert_eq "$(jq -c '.config.Cmd' <<<"$config")" '["start"]' "${ref}:${tag} cmd"
      assert_eq "$(jq -r '.config.WorkingDir' <<<"$config")" "/app" "${ref}:${tag} workdir"
      assert_contains_env "$config" "MIX_ENV=prod" "${ref}:${tag}"
      ;;
    serviceradar-agent-gateway)
      assert_eq "$(jq -c '.config.Entrypoint' <<<"$config")" '["/app/bin/serviceradar_agent_gateway"]' "${ref}:${tag} entrypoint"
      assert_eq "$(jq -c '.config.Cmd' <<<"$config")" '["start"]' "${ref}:${tag} cmd"
      assert_eq "$(jq -r '.config.WorkingDir' <<<"$config")" "/app" "${ref}:${tag} workdir"
      assert_contains_env "$config" "MIX_ENV=prod" "${ref}:${tag}"
      ;;
    serviceradar-agent)
      assert_eq "$(jq -c '.config.Entrypoint // []' <<<"$config")" '[]' "${ref}:${tag} entrypoint"
      assert_eq "$(jq -c '.config.Cmd' <<<"$config")" '["/usr/local/lib/serviceradar/agent/serviceradar-agent-seed","-config","/etc/serviceradar/agent.json"]' "${ref}:${tag} cmd"
      assert_eq "$(jq -r '.config.WorkingDir' <<<"$config")" "/var/lib/serviceradar" "${ref}:${tag} workdir"
      ;;
    serviceradar-log-collector)
      assert_eq "$(jq -c '.config.Entrypoint' <<<"$config")" '["/usr/local/bin/entrypoint.sh"]' "${ref}:${tag} entrypoint"
      assert_eq "$(jq -c '.config.Cmd' <<<"$config")" '["serviceradar-log-collector"]' "${ref}:${tag} cmd"
      assert_eq "$(jq -r '.config.WorkingDir' <<<"$config")" "/var/lib/serviceradar" "${ref}:${tag} workdir"
      ;;
    serviceradar-flow-collector)
      assert_eq "$(jq -c '.config.Entrypoint' <<<"$config")" '["/usr/local/bin/serviceradar-flow-collector"]' "${ref}:${tag} entrypoint"
      assert_eq "$(jq -c '.config.Cmd' <<<"$config")" '["--config","/etc/serviceradar/flow-collector.json"]' "${ref}:${tag} cmd"
      assert_eq "$(jq -r '.config.WorkingDir' <<<"$config")" "/var/lib/serviceradar" "${ref}:${tag} workdir"
      ;;
    arancini)
      assert_eq "$(jq -c '.config.Entrypoint' <<<"$config")" '["/usr/local/bin/serviceradar-bmp-collector"]' "${ref}:${tag} entrypoint"
      assert_eq "$(jq -c '.config.Cmd // []' <<<"$config")" '[]' "${ref}:${tag} cmd"
      assert_eq "$(jq -r '.config.WorkingDir' <<<"$config")" "/var/lib/serviceradar" "${ref}:${tag} workdir"
      ;;
    serviceradar-rperf-client)
      assert_eq "$(jq -c '.config.Entrypoint' <<<"$config")" '["/usr/local/bin/entrypoint.sh"]' "${ref}:${tag} entrypoint"
      assert_eq "$(jq -c '.config.Cmd' <<<"$config")" '["/usr/local/bin/serviceradar-rperf-checker","--config","/etc/serviceradar/checkers/rperf.json"]' "${ref}:${tag} cmd"
      assert_eq "$(jq -r '.config.WorkingDir' <<<"$config")" "/var/lib/serviceradar" "${ref}:${tag} workdir"
      ;;
    serviceradar-faker)
      assert_eq "$(jq -c '.config.Entrypoint // []' <<<"$config")" '[]' "${ref}:${tag} entrypoint"
      assert_eq "$(jq -c '.config.Cmd' <<<"$config")" '["/usr/local/bin/serviceradar-faker","-config","/etc/serviceradar/faker.json"]' "${ref}:${tag} cmd"
      assert_eq "$(jq -r '.config.WorkingDir' <<<"$config")" "/var/lib/serviceradar" "${ref}:${tag} workdir"
      ;;
    serviceradar-tools)
      assert_eq "$(jq -c '.config.Entrypoint' <<<"$config")" '["/usr/local/bin/entrypoint.sh"]' "${ref}:${tag} entrypoint"
      assert_eq "$(jq -c '.config.Cmd' <<<"$config")" '["/bin/sh"]' "${ref}:${tag} cmd"
      assert_eq "$(jq -r '.config.WorkingDir' <<<"$config")" "/" "${ref}:${tag} workdir"
      assert_contains_env "$config" "PATH=/usr/libexec/postgresql18:/usr/local/bin:/usr/bin:/bin" "${ref}:${tag}"
      ;;
  esac
}

check_signature_accessory() {
  local tag="$1"
  local ref="$2"
  local digest
  digest="$(resolve_digest "${ref}:${tag}")"
  [[ -n "${digest}" && "${digest}" != "null" ]] || fail "${ref}:${tag} digest lookup failed"

  local repo_path="${ref#"${REGISTRY_HOST}"/}"
  local auth user pass token
  auth="$(resolve_registry_auth)"
  IFS='|' read -r user pass <<<"${auth}"

  local token_url="https://${REGISTRY_HOST}/service/token?service=harbor-registry&scope=repository:${repo_path}:pull"
  if [[ -n "${user}" && -n "${pass}" ]]; then
    token="$(curl -fsSL -u "${user}:${pass}" "${token_url}" | jq -r '.token')"
  else
    token="$(curl -fsSL "${token_url}" | jq -r '.token')"
  fi
  [[ -n "${token}" && "${token}" != "null" ]] || fail "${ref}:${tag} registry token lookup failed"

  local referrers
  referrers="$(
    curl -fsSL \
      -H "Authorization: Bearer ${token}" \
      "https://${REGISTRY_HOST}/v2/${repo_path}/referrers/${digest}"
  )"

  if jq -e '
    (.manifests // []) as $m
    | ($m | length) > 0
    and any(
      $m[];
      ((.artifactType // "") | startswith("application/vnd.dev.sigstore"))
      or ((.annotations["dev.sigstore.bundle.predicateType"] // "") == "https://sigstore.dev/cosign/sign/v1")
    )
  ' <<<"${referrers}" >/dev/null; then
    return 0
  fi

  local referrer_digests=()
  mapfile -t referrer_digests < <(jq -r '.manifests[]?.digest // empty' <<<"${referrers}")
  [[ ${#referrer_digests[@]} -gt 0 ]] || fail "${ref}:${tag} is missing a Harbor-visible Cosign signature accessory"

  local referrer_manifest
  local referrer_digest
  for referrer_digest in "${referrer_digests[@]}"; do
    referrer_manifest="$(
      curl -fsSL \
        -H "Authorization: Bearer ${token}" \
        -H 'Accept: application/vnd.oci.image.manifest.v1+json, application/vnd.oci.artifact.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json' \
        "https://${REGISTRY_HOST}/v2/${repo_path}/manifests/${referrer_digest}"
    )"

    if jq -e '
      any(
        .layers[]?;
        (.mediaType == "application/vnd.dev.cosign.simplesigning.v1+json")
        and ((.annotations["dev.cosignproject.cosign/signature"] // "") != "")
      )
    ' <<<"${referrer_manifest}" >/dev/null; then
      return 0
    fi
  done

  fail "${ref}:${tag} is missing a Harbor-visible Cosign signature accessory"
}

check_legacy_signature_tag() {
  local tag="$1"
  local ref="$2"
  local digest
  digest="$(resolve_digest "${ref}:${tag}")"
  [[ -n "${digest}" && "${digest}" != "null" ]] || fail "${ref}:${tag} digest lookup failed"

  local signature_ref
  signature_ref="$(cosign triangulate "${ref}@${digest}")"
  [[ -n "${signature_ref}" ]] || fail "${ref}:${tag} legacy signature reference lookup failed"

  local signature_repo="${signature_ref%:*}"
  local signature_tag="${signature_ref##*:}"
  local signature_repo_path="${signature_repo#"${REGISTRY_HOST}"/}"
  local auth user pass token
  auth="$(resolve_registry_auth)"
  IFS='|' read -r user pass <<<"${auth}"

  local token_url="https://${REGISTRY_HOST}/service/token?service=harbor-registry&scope=repository:${signature_repo_path}:pull"
  if [[ -n "${user}" && -n "${pass}" ]]; then
    token="$(curl -fsSL -u "${user}:${pass}" "${token_url}" | jq -r '.token')"
  else
    token="$(curl -fsSL "${token_url}" | jq -r '.token')"
  fi
  [[ -n "${token}" && "${token}" != "null" ]] || fail "${ref}:${tag} legacy signature token lookup failed"

  curl -fsSI \
    -H "Authorization: Bearer ${token}" \
    -H 'Accept: application/vnd.oci.image.manifest.v1+json' \
    "https://${REGISTRY_HOST}/v2/${signature_repo_path}/manifests/${signature_tag}" >/dev/null \
    || fail "${ref}:${tag} is missing the legacy cosign signature tag ${signature_tag}"
}

check_cosign_verify() {
  local tag="$1"
  local ref="$2"
  local digest
  digest="$(resolve_digest "${ref}:${tag}")"
  [[ -n "${digest}" && "${digest}" != "null" ]] || fail "${ref}:${tag} digest lookup failed"

  if ! cosign_init_verify_args; then
    return 0
  fi

  cosign verify \
    --experimental-oci11 \
    "${COSIGN_VERIFY_ARGS[@]}" \
    "${ref}@${digest}" >/dev/null || fail "${ref}:${tag} failed cosign verification"
}

for tag in "${TAGS[@]}"; do
  for spec in "${IMAGE_SPECS[@]}"; do
    IFS="|" read -r ref kind <<<"$spec"
    echo "checking ${ref}:${tag}"
    check_image_shape "$tag" "$ref" "$kind"
    check_config "$tag" "$ref"
    check_signature_accessory "$tag" "$ref"
    check_legacy_signature_tag "$tag" "$ref"
    check_cosign_verify "$tag" "$ref"
  done
done

echo "verified OCI publish metadata, Harbor Cosign accessories, legacy signature tags, and signature verification for tags: ${TAGS[*]}"
