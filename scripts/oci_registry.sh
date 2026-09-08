#!/usr/bin/env bash
# Registry inspect helpers that do not need skopeo or dockerd.
# Requires oras + jq. Used by release publish/verify on ARC signing runners.

oci_registry_digest() {
  local ref="$1"
  local desc digest
  if ! command -v oras >/dev/null 2>&1; then
    echo "error: oras is required to inspect ${ref}" >&2
    return 2
  fi
  if ! desc="$(oras manifest fetch --descriptor "${ref}" 2>&1)"; then
    printf '%s\n' "${desc}" >&2
    return 1
  fi
  digest="$(jq -r '.digest // empty' <<<"${desc}")"
  if [[ ! "${digest}" =~ ^sha256:[0-9a-f]{64}$ ]]; then
    echo "error: invalid descriptor digest for ${ref}: ${desc}" >&2
    return 2
  fi
  printf '%s\n' "${digest}"
}

oci_registry_manifest() {
  local ref="$1"
  shift
  if ! command -v oras >/dev/null 2>&1; then
    echo "error: oras is required to fetch ${ref}" >&2
    return 2
  fi
  # oras 1.3 still prints manifests to stdout; --output - keeps that contract
  # if a later oras tightens the same required-flag rule as blob fetch.
  oras manifest fetch --output - "$@" "${ref}"
}

oci_registry_platform_manifest() {
  local ref="$1"
  local os="${2:-linux}"
  local arch="${3:-amd64}"
  local raw media_type digest
  raw="$(oci_registry_manifest "${ref}")" || return $?
  media_type="$(jq -r '.mediaType // empty' <<<"${raw}")"
  case "${media_type}" in
    application/vnd.oci.image.index.v1+json|application/vnd.docker.distribution.manifest.list.v2+json)
      digest="$(
        jq -r --arg os "${os}" --arg arch "${arch}" '
          .manifests[]
          | select(.platform.os == $os and .platform.architecture == $arch)
          | .digest
        ' <<<"${raw}" | head -n1
      )"
      if [[ ! "${digest}" =~ ^sha256:[0-9a-f]{64}$ ]]; then
        echo "error: ${ref} has no ${os}/${arch} manifest" >&2
        return 1
      fi
      oci_registry_manifest "${ref%@*}@${digest}"
      ;;
    *)
      printf '%s\n' "${raw}"
      ;;
  esac
}

oci_registry_config() {
  local ref="$1"
  local os="${2:-linux}"
  local arch="${3:-amd64}"
  local manifest config_digest
  manifest="$(oci_registry_platform_manifest "${ref}" "${os}" "${arch}")" || return $?
  config_digest="$(jq -r '.config.digest // empty' <<<"${manifest}")"
  if [[ ! "${config_digest}" =~ ^sha256:[0-9a-f]{64}$ ]]; then
    echo "error: ${ref} is missing a config digest" >&2
    return 1
  fi
  # oras 1.3 blob fetch refuses to write to stdout unless --output is set.
  oras blob fetch --output - "${ref%@*}@${config_digest}"
}
