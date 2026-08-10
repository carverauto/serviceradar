#!/usr/bin/env bash

set -euo pipefail

expected_key="${SERVICERADAR_AGENT_RELEASE_PUBLIC_KEY:-}"
if [[ -z "${expected_key}" ]]; then
  echo "SERVICERADAR_AGENT_RELEASE_PUBLIC_KEY is required to verify agent release-key stamping" >&2
  exit 1
fi

bazel_args=("$@")
target="//go/cmd/agent:agent"

# THIS IS NOW AN ASSERTION, NOT A STAMP CHECK, and that is a stronger guarantee.
#
# The key used to be injected by the linker from workspace status, so this script had to write
# ${SERVICERADAR_AGENT_RELEASE_PUBLIC_KEY} into .bazel-agent-release-public-key and build with
# --stamp -- it was verifying its own injection. The key now comes from the committed
# go/pkg/agent/release_signing_key.txt, so the grep below compares that COMMITTED value against
# the one derived from the release signing secret. A mismatch means the repo and the signer have
# diverged, which is the thing actually worth catching.
#
# No --stamp: nothing in the agent graph consumes stamp data any more, and passing it would fork
# the configuration away from every other bazel call in the release job for no effect.
bazel build \
  "${bazel_args[@]}" \
  --remote_download_outputs=all \
  "${target}"

output="$(
  bazel cquery \
    "${bazel_args[@]}" \
    --output=files \
    "${target}" 2>/dev/null \
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
  echo "Built agent binary does not contain the expected release public key." >&2
  echo "go/pkg/agent/release_signing_key.txt disagrees with the key derived from the" >&2
  echo "release signing secret. Update the committed file, or fix the signer." >&2
  exit 1
fi

echo "Verified committed release public key matches the signing secret, embedded in ${output}"
