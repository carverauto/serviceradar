#!/usr/bin/env bash

set -euo pipefail

expected_key="${SERVICERADAR_AGENT_RELEASE_PUBLIC_KEY:-}"
if [[ -z "${expected_key}" ]]; then
  echo "SERVICERADAR_AGENT_RELEASE_PUBLIC_KEY is required to verify agent release-key stamping" >&2
  exit 1
fi

bazel_args=("$@")
target="//go/cmd/agent:agent"
key_file="${SERVICERADAR_AGENT_RELEASE_PUBLIC_KEY_FILE:-.bazel-agent-release-public-key}"

printf '%s\n' "${expected_key}" > "${key_file}"

bazel build "${bazel_args[@]}" --stamp --remote_download_outputs=all "${target}"

output="$(
  bazel cquery "${bazel_args[@]}" --stamp --output=files "${target}" 2>/dev/null \
    | awk 'NF { last = $0 } END { print last }'
)"

if [[ -z "${output}" ]]; then
  echo "Unable to resolve built agent binary output path" >&2
  exit 1
fi

execroot="$(bazel info "${bazel_args[@]}" execution_root 2>/dev/null | tail -n1)"
binary_path="${execroot}/${output}"

if [[ ! -f "${binary_path}" ]]; then
  echo "Built agent binary not found at ${binary_path}" >&2
  exit 1
fi

strings_output="$(mktemp)"
trap 'rm -f "${strings_output}"' EXIT
strings "${binary_path}" > "${strings_output}"

if ! grep -Fq "${expected_key}" "${strings_output}"; then
  echo "Built agent binary is missing the managed release public key stamp" >&2
  exit 1
fi

echo "Verified managed agent release public key stamp in ${output}"
