#!/usr/bin/env bash
# Publish a native add-on bundle as an OCI artifact (issue 3425,
# add-native-addon-build-signing §2). Mirrors build/wasm_plugins/publish_plugin.sh
# but a native add-on additionally ships, per architecture, the pushed-artifact
# tarball plus its raw ed25519 signature (agent release key) that the agent
# verifies on fetch. Layers pushed:
#
#   <bundle>.zip                         bundle_media_type        (manifest + per-arch binaries)
#   <name>.<os>.<arch>.tar.gz            _ARTIFACT_MEDIA_TYPE     (per-arch pushed-artifact)
#   <name>.<os>.<arch>.tar.gz.sig        _ARTIFACT_SIGNATURE_MEDIA_TYPE (hex ed25519 over the tarball, agent release key)
#
# oras stamps each layer's org.opencontainers.image.title with the file name, so
# the index/verify/importer recover the (os, arch) from the tarball file name.
set -euo pipefail

_ARTIFACT_MEDIA_TYPE="application/vnd.serviceradar.native-addon.artifact.v1+gzip"
_ARTIFACT_SIGNATURE_MEDIA_TYPE="application/vnd.serviceradar.native-addon.artifact-signature.v1+hex"

bundle=""
metadata=""
oras_bin=""
artifact_signature_tool=""
extra_tag=""

usage() {
  cat <<'EOF'
Usage: publish_addon.sh --bundle <bundle.zip> --metadata <bundle.metadata.json>
         --oras <oras-bin> --artifact-signature-tool <tool> [--tag <tag>]
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --bundle) bundle="$2"; shift 2 ;;
    --metadata) metadata="$2"; shift 2 ;;
    --oras) oras_bin="$2"; shift 2 ;;
    --artifact-signature-tool) artifact_signature_tool="$2"; shift 2 ;;
    --tag) extra_tag="$2"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) echo "error: unknown argument: $1" >&2; usage >&2; exit 1 ;;
  esac
done

[[ -n "${bundle}" ]] || { echo "error: --bundle is required" >&2; exit 1; }
[[ -n "${metadata}" ]] || { echo "error: --metadata is required" >&2; exit 1; }
[[ -n "${oras_bin}" ]] || { echo "error: --oras is required" >&2; exit 1; }
[[ -n "${artifact_signature_tool}" ]] || { echo "error: --artifact-signature-tool is required" >&2; exit 1; }

export PATH="/opt/homebrew/bin:/usr/local/bin:${HOME:-}/.local/bin:${HOME:-}/bin:/usr/bin:/bin:${PATH:-}"

resolve_executable() {
  local candidate="$1"
  [[ -n "${candidate}" ]] || return 1
  if [[ "${candidate}" = */* ]]; then
    [[ -x "${candidate}" ]] && { printf '%s\n' "${candidate}"; return 0; }
    return 1
  fi
  local resolved
  resolved="$(command -v "${candidate}" 2>/dev/null || true)"
  [[ -n "${resolved}" && -x "${resolved}" ]] && { printf '%s\n' "${resolved}"; return 0; }
  return 1
}

local_oras="$(resolve_executable oras || true)"
[[ -n "${local_oras}" ]] && oras_bin="${local_oras}" || oras_bin="$(resolve_executable "${oras_bin}" || true)"
[[ -n "${oras_bin}" && -x "${oras_bin}" ]] || { echo "error: unable to resolve a runnable oras binary" >&2; exit 1; }
[[ -x "${artifact_signature_tool}" ]] || { echo "error: artifact signature tool is not executable: ${artifact_signature_tool}" >&2; exit 1; }

# SERVICERADAR_AGENT_RELEASE_PRIVATE_KEY is required to sign per-arch artifacts.
if [[ -z "${SERVICERADAR_AGENT_RELEASE_PRIVATE_KEY:-}" ]]; then
  echo "error: SERVICERADAR_AGENT_RELEASE_PRIVATE_KEY must be set to sign per-arch artifacts" >&2
  exit 1
fi

read_metadata() {
  python3 - "$1" <<'PY'
import json, sys
with open(sys.argv[1], "r", encoding="utf-8") as fh:
    data = json.load(fh)
print(data["addon_id"])
print(data["repository_name"])
print(data["artifact_type"])
print(data["bundle_media_type"])
# Each per-arch artifact that ships a tarball, one per line: "os arch tarball_file".
for a in data.get("artifacts", []):
    if a.get("tarball_file"):
        print(f"ARTIFACT\t{a['os']}\t{a['arch']}\t{a['tarball_file']}")
PY
}

mapfile -t meta < <(read_metadata "${metadata}")
addon_id="${meta[0]}"
repository_name="${meta[1]}"
artifact_type="${meta[2]}"
bundle_media_type="${meta[3]}"

registry="${OCI_REGISTRY:-registry.carverauto.dev}"
project="${OCI_PROJECT:-serviceradar}"
repo="${registry}/${project}/${repository_name}"
commit_sha="$(git -C "${BUILD_WORKSPACE_DIRECTORY:-$(pwd)}" rev-parse HEAD)"
tags=("sha-${commit_sha}")
[[ -n "${extra_tag}" ]] && tags+=("${extra_tag}")

bundle_dir="$(cd "$(dirname "${bundle}")" && pwd)"
staging="$(mktemp -d "${TMPDIR:-/tmp}/native-addon-publish.XXXXXX")"
trap 'rm -rf "${staging}"' EXIT

# Stage every layer in one directory and push by basename: oras push rejects
# absolute file paths, and the verify/index steps recover (os, arch) from each
# layer's org.opencontainers.image.title, which oras sets to the path as given —
# so a clean basename is required. The bundle zip's integrity/provenance is covered
# by the Cosign signature over the OCI artifact (sign-native-addon-publish.sh); no
# separate bundle-level ed25519 is carried. Each per-arch tarball gets the
# agent-release ed25519 signature the agent itself verifies on fetch.
bundle_name="$(basename "${bundle}")"
cp "${bundle}" "${staging}/${bundle_name}"
layer_specs=("${bundle_name}:${bundle_media_type}")
for line in "${meta[@]}"; do
  [[ "${line}" == ARTIFACT$'\t'* ]] || continue
  IFS=$'\t' read -r _ _os _arch tarball_file <<<"${line}"
  tarball_path="${bundle_dir}/${tarball_file}"
  [[ -f "${tarball_path}" ]] || { echo "error: tarball not found: ${tarball_path}" >&2; exit 1; }
  cp "${tarball_path}" "${staging}/${tarball_file}"
  "${artifact_signature_tool}" sign --artifact "${staging}/${tarball_file}" --out "${staging}/${tarball_file}.sig"
  layer_specs+=("${tarball_file}:${_ARTIFACT_MEDIA_TYPE}" "${tarball_file}.sig:${_ARTIFACT_SIGNATURE_MEDIA_TYPE}")
done

for tag in "${tags[@]}"; do
  echo "publishing ${repo}:${tag}"
  if ! push_out="$(
    cd "${staging}" && "${oras_bin}" push \
      --artifact-type "${artifact_type}" \
      "${repo}:${tag}" \
      "${layer_specs[@]}" \
      --annotation "io.serviceradar.addon.id=${addon_id}" 2>&1
  )"; then
    if [[ -n "${extra_tag}" && "${tag}" == "${extra_tag}" ]] && \
       grep -Eiq 'immutable|already exists|precondition' <<<"${push_out}"; then
      echo "${push_out}"
      echo "Harbor tag ${repo}:${tag} is already immutable; leaving the existing artifact."
      continue
    fi
    echo "${push_out}" >&2
    exit 1
  fi
  echo "${push_out}"
done
