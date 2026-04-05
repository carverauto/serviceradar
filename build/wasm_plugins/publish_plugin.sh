#!/usr/bin/env bash
set -euo pipefail

bundle=""
metadata=""
oras_bin=""
upload_signature_tool=""
extra_tag=""

usage() {
  cat <<'EOF'
Usage: publish_plugin.sh --bundle <bundle.zip> --metadata <bundle.metadata.json> --oras <oras-bin> --upload-signature-tool <tool> [--tag <tag>]
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --bundle)
      bundle="$2"
      shift 2
      ;;
    --metadata)
      metadata="$2"
      shift 2
      ;;
    --oras)
      oras_bin="$2"
      shift 2
      ;;
    --upload-signature-tool)
      upload_signature_tool="$2"
      shift 2
      ;;
    --tag)
      extra_tag="$2"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

[[ -n "${bundle}" ]] || { echo "error: --bundle is required" >&2; exit 1; }
[[ -n "${metadata}" ]] || { echo "error: --metadata is required" >&2; exit 1; }
[[ -n "${oras_bin}" ]] || { echo "error: --oras is required" >&2; exit 1; }
[[ -n "${upload_signature_tool}" ]] || { echo "error: --upload-signature-tool is required" >&2; exit 1; }

resolve_from_host() {
  command -v "$1" 2>/dev/null || true
}

local_oras="$(resolve_from_host oras)"
if [[ -z "${local_oras}" ]]; then
  for candidate in /opt/homebrew/bin/oras /usr/local/bin/oras "${HOME:-}/bin/oras"; do
    if [[ -x "${candidate}" ]]; then
      local_oras="${candidate}"
      break
    fi
  done
fi

if [[ -n "${local_oras}" && -x "${local_oras}" ]]; then
  oras_bin="${local_oras}"
elif [[ "${oras_bin}" != /* ]]; then
  candidate="${PWD}/${oras_bin}"
  if [[ -x "${candidate}" ]]; then
    oras_bin="${candidate}"
  fi
fi

if [[ -z "${oras_bin}" || ! -x "${oras_bin}" ]]; then
  echo "error: unable to resolve a runnable oras binary" >&2
  exit 1
fi

if [[ ! -x "${upload_signature_tool}" ]]; then
  echo "error: upload signature tool is not executable: ${upload_signature_tool}" >&2
  exit 1
fi

read_metadata() {
  python3 - "$1" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as fh:
    data = json.load(fh)
print(data["plugin_id"])
print(data["repository_name"])
print(data["artifact_type"])
print(data["bundle_media_type"])
print(data["upload_signature_media_type"])
PY
}

mapfile -t meta < <(read_metadata "${metadata}")
plugin_id="${meta[0]}"
repository_name="${meta[1]}"
artifact_type="${meta[2]}"
bundle_media_type="${meta[3]}"
upload_signature_media_type="${meta[4]}"

registry="${OCI_REGISTRY:-registry.carverauto.dev}"
project="${OCI_PROJECT:-serviceradar}"
repo="${registry}/${project}/${repository_name}"
commit_sha="$(git -C "${BUILD_WORKSPACE_DIRECTORY:-$(pwd)}" rev-parse HEAD)"
tags=("sha-${commit_sha}")
tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT
upload_signature_path="${tmp_dir}/upload-signature.json"

"${upload_signature_tool}" sign --metadata "${metadata}" --out "${upload_signature_path}"

if [[ -n "${extra_tag}" ]]; then
  tags+=("${extra_tag}")
fi

for tag in "${tags[@]}"; do
  echo "publishing ${repo}:${tag}"
  "${oras_bin}" push \
    --artifact-type "${artifact_type}" \
    "${repo}:${tag}" \
    "${bundle}:${bundle_media_type}" \
    "${upload_signature_path}:${upload_signature_media_type}" \
    --annotation "org.opencontainers.image.title=$(basename "${bundle}")" \
    --annotation "io.serviceradar.plugin.id=${plugin_id}"
done
