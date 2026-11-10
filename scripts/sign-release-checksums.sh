#!/usr/bin/env bash
#
# Sign the release SHA256SUMS file with the Cosign release key and write the
# Sigstore bundle next to it. //build/release:publish_packages runs this after
# it has written SHA256SUMS and before it creates or changes the draft release:
#
#   sign-release-checksums.sh <SHA256SUMS path> <bundle output path>
#
# The file is signed in place and never rewritten. OpenBao login happens here,
# not in the workflow step, because the publisher is started by `bazel run` and
# the token would expire while the packages build. See docs/sigstore/README.md.

set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "usage: $0 <SHA256SUMS path> <bundle output path>" >&2
  exit 2
fi

payload_file="$1"
bundle_file="$2"

if [[ ! -s "${payload_file}" ]]; then
  echo "error: checksum file is missing or empty: ${payload_file}" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
public_key_file="${SCRIPT_DIR}/../docs/cosign.pub"
if [[ ! -s "${public_key_file}" ]]; then
  echo "error: release public key not found: ${public_key_file}" >&2
  exit 1
fi

# `bazel run` does not carry the directories a workflow added to GITHUB_PATH.
if [[ -n "${SERVICERADAR_COSIGN_BIN_DIR:-}" ]]; then
  export PATH="${SERVICERADAR_COSIGN_BIN_DIR}:${PATH}"
fi

# shellcheck source=scripts/cosign_common.sh
source "${SERVICERADAR_COSIGN_COMMON:-${SCRIPT_DIR}/cosign_common.sh}"
trap cosign_cleanup_temp_files EXIT
cosign_require_tool cosign

# shellcheck source=scripts/ci/prepare-openbao-cosign-env.sh
source "${SCRIPT_DIR}/ci/prepare-openbao-cosign-env.sh"

if [[ -z "$(cosign_resolve_key_ref)" ]]; then
  echo "error: release checksums are signed with the release key only; COSIGN_KEY_REF is not set" >&2
  exit 1
fi

cosign_init_sign_args

signature_file="$(mktemp)"
stdout_file="$(mktemp)"
cosign_register_temp_file "${signature_file}"
cosign_register_temp_file "${stdout_file}"

# Same transparency-log default as the image and add-on signers.
cosign_sign_blob_to_files \
  "${payload_file}" \
  "${bundle_file}" \
  "${signature_file}" \
  "${stdout_file}" \
  "${COSIGN_TLOG_UPLOAD:-true}"

if [[ ! -s "${bundle_file}" ]]; then
  echo "error: cosign wrote an empty bundle for ${payload_file}" >&2
  exit 1
fi

# Verify the way a user will: the committed public key and the bundle. A key
# other than the published one, or a bundle that does not verify, stops here.
verify_args=()
trusted_root_file="$(cosign_resolve_trusted_root_file)"
if [[ -n "${trusted_root_file}" ]]; then
  verify_args+=(--trusted-root "${trusted_root_file}")
fi
cosign verify-blob \
  "${verify_args[@]}" \
  --key "${public_key_file}" \
  --bundle "${bundle_file}" \
  "${payload_file}"

unset VAULT_TOKEN VAULT_ADDR COSIGN_KEY_REF
echo "Signed and verified $(basename "${payload_file}") with the release key."
