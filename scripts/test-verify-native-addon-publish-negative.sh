#!/usr/bin/env bash
#
# Copyright 2026 Carver Automation Corporation.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# Negative tests for scripts/verify-native-addon-publish.sh. The release job uses
# this as a cheap fail-closed check before publishing real artifacts: an unsigned
# OCI artifact must fail Cosign verification, and a tampered per-arch tarball must
# fail the agent-release ed25519 verification path.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/native-addon-verify-negative.XXXXXX")"
trap 'rm -rf "${TMP_DIR}"' EXIT

fake_bin="${TMP_DIR}/bin"
bazel_bin="${TMP_DIR}/bazel-bin"
metadata_dir="${bazel_bin}/build/native_addons"
mkdir -p "${fake_bin}" "${metadata_dir}"

cat >"${metadata_dir}/fixture.metadata.json" <<'JSON'
{
  "repository_name": "serviceradar-addon-fixture",
  "artifact_type": "application/vnd.serviceradar.native-addon.bundle.v1+zip",
  "bundle_media_type": "application/zip"
}
JSON

cat >"${fake_bin}/bazel" <<EOF
#!/usr/bin/env bash
set -euo pipefail
case "\${1:-}" in
  info)
    if [[ "\${2:-}" == "bazel-bin" ]]; then
      printf '%s\n' "${bazel_bin}"
      exit 0
    fi
    ;;
  build)
    exit 0
    ;;
  cquery)
    printf '%s\n' "${fake_bin}/addon_artifact_signature_tool"
    exit 0
    ;;
esac
echo "unexpected fake bazel invocation: \$*" >&2
exit 2
EOF

cat >"${fake_bin}/oras" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
artifact_digest="sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
signature_digest="sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
manifest_digest="sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"

if [[ "$1" == "manifest" && "$2" == "fetch" && "$3" == "--descriptor" ]]; then
  printf '{"digest":"%s"}\n' "${manifest_digest}"
  exit 0
fi

if [[ "$1" == "manifest" && "$2" == "fetch" ]]; then
  cat <<JSON
{
  "content": {
    "artifactType": "application/vnd.serviceradar.native-addon.bundle.v1+zip",
    "layers": [
      {
        "mediaType": "application/zip",
        "digest": "sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd",
        "annotations": {"org.opencontainers.image.title": "fixture.zip"}
      },
      {
        "mediaType": "application/vnd.serviceradar.native-addon.artifact.v1+gzip",
        "digest": "${artifact_digest}",
        "annotations": {"org.opencontainers.image.title": "fixture.linux.amd64.tar.gz"}
      },
      {
        "mediaType": "application/vnd.serviceradar.native-addon.artifact-signature.v1+hex",
        "digest": "${signature_digest}",
        "annotations": {"org.opencontainers.image.title": "fixture.linux.amd64.tar.gz.sig"}
      }
    ]
  }
}
JSON
  exit 0
fi

if [[ "$1" == "blob" && "$2" == "fetch" && "$3" == "--output" ]]; then
  output="$4"
  ref="$5"
  case "${ref}" in
    *"${artifact_digest}")
      if [[ "${VERIFY_NATIVE_ADDON_FIXTURE_MODE:-}" == "tampered" ]]; then
        printf 'tampered artifact' >"${output}"
      else
        printf 'fixture artifact' >"${output}"
      fi
      ;;
    *"${signature_digest}")
      printf 'fixture signature' >"${output}"
      ;;
    *)
      echo "unexpected blob ref: ${ref}" >&2
      exit 2
      ;;
  esac
  exit 0
fi

echo "unexpected fake oras invocation: $*" >&2
exit 2
EOF

cat >"${fake_bin}/cosign" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  verify)
    if [[ "${VERIFY_NATIVE_ADDON_FIXTURE_MODE:-}" == "unsigned" ]]; then
      echo "fixture unsigned artifact" >&2
      exit 1
    fi
    exit 0
    ;;
  *)
    echo "unexpected fake cosign invocation: $*" >&2
    exit 2
    ;;
esac
EOF

cat >"${fake_bin}/addon_artifact_signature_tool" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" != "verify" ]]; then
  echo "unexpected signature-tool invocation: $*" >&2
  exit 2
fi
if [[ "${VERIFY_NATIVE_ADDON_FIXTURE_MODE:-}" == "tampered" ]]; then
  echo "fixture invalid artifact signature" >&2
  exit 1
fi
exit 0
EOF

chmod +x "${fake_bin}/bazel" "${fake_bin}/oras" "${fake_bin}/cosign" "${fake_bin}/addon_artifact_signature_tool"

run_expected_failure() {
  local mode="$1"
  local log_file="${TMP_DIR}/${mode}.log"

  echo "CHECK verify-before-release rejects ${mode} fixture"
  if PATH="${fake_bin}:${PATH}" \
    BAZEL_BIN="${fake_bin}/bazel" \
    BAZEL_BIN_DIR="${bazel_bin}" \
    METADATA_DIR="${metadata_dir}" \
    OCI_REGISTRY="registry.example.test" \
    OCI_PROJECT="serviceradar" \
    VERIFY_NATIVE_ADDON_FIXTURE_MODE="${mode}" \
    "${REPO_ROOT}/scripts/verify-native-addon-publish.sh" "fixture-tag" >"${log_file}" 2>&1; then
    echo "  VIOLATION verifier accepted ${mode} fixture" >&2
    sed 's/^/    /' "${log_file}" >&2
    return 1
  fi

  echo "  OK rejected ${mode} fixture"
}

run_expected_failure unsigned
run_expected_failure tampered

echo "verify-before-release negative tests passed"
