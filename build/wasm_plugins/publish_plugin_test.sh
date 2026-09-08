#!/usr/bin/env bash
set -euo pipefail

if [[ -n "${TEST_SRCDIR:-}" && -n "${TEST_WORKSPACE:-}" ]]; then
  script="${TEST_SRCDIR}/${TEST_WORKSPACE}/build/wasm_plugins/publish_plugin.sh"
else
  script="$(git rev-parse --show-toplevel)/build/wasm_plugins/publish_plugin.sh"
fi

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT
bundle="${tmp_dir}/test.zip"
metadata="${tmp_dir}/test.metadata.json"
oras_log="${tmp_dir}/oras.log"

printf 'bundle\n' >"${bundle}"
cat >"${metadata}" <<'JSON'
{
  "plugin_id": "test",
  "repository_name": "wasm-plugin-test",
  "artifact_type": "application/test",
  "bundle_media_type": "application/zip",
  "upload_signature_media_type": "application/test-signature"
}
JSON

cat >"${tmp_dir}/upload_signature_tool" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
out=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --out) out="$2"; shift 2 ;;
    *) shift ;;
  esac
done
printf '{}\n' >"${out}"
SH
chmod +x "${tmp_dir}/upload_signature_tool"

cat >"${tmp_dir}/oras" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${ORAS_LOG}"
SH
chmod +x "${tmp_dir}/oras"

(
  cd "${tmp_dir}"
  PATH="${tmp_dir}:${PATH}" \
    ORAS_LOG="${oras_log}" \
    OCI_REGISTRY=registry.test \
    OCI_PROJECT=project \
    "${script}" \
      --bundle "${bundle}" \
      --metadata "${metadata}" \
      --oras "${tmp_dir}/oras" \
      --upload-signature-tool "${tmp_dir}/upload_signature_tool" \
      --commit-sha aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
      --tag v0.1.0
)

grep -F "registry.test/project/wasm-plugin-test:sha-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" "${oras_log}" >/dev/null
grep -F "registry.test/project/wasm-plugin-test:v0.1.0" "${oras_log}" >/dev/null

cat >"${tmp_dir}/oras" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${ORAS_LOG}"
if [[ " $* " == *" registry.test/project/wasm-plugin-test:v0.1.0 "* ]]; then
  echo "Error response from registry: precondition: configured as immutable." >&2
  exit 1
fi
SH
chmod +x "${tmp_dir}/oras"
: >"${oras_log}"

if ! (
  cd "${tmp_dir}"
  PATH="${tmp_dir}:${PATH}" \
    ORAS_LOG="${oras_log}" \
    OCI_REGISTRY=registry.test \
    OCI_PROJECT=project \
    "${script}" \
      --bundle "${bundle}" \
      --metadata "${metadata}" \
      --oras "${tmp_dir}/oras" \
      --upload-signature-tool "${tmp_dir}/upload_signature_tool" \
      --commit-sha aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
      --tag v0.1.0
) >"${tmp_dir}/immutable.out" 2>&1; then
  echo "publisher failed when the extra Harbor tag was already immutable" >&2
  cat "${tmp_dir}/immutable.out" >&2
  exit 1
fi
if ! grep -q "already immutable" "${tmp_dir}/immutable.out"; then
  echo "publisher did not explain an immutable extra Harbor tag" >&2
  cat "${tmp_dir}/immutable.out" >&2
  exit 1
fi

cat >"${tmp_dir}/oras" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${ORAS_LOG}"
if [[ " $* " == *" registry.test/project/wasm-plugin-test:sha-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa "* ]]; then
  echo "Error response from registry: precondition: configured as immutable." >&2
  exit 1
fi
SH
chmod +x "${tmp_dir}/oras"

if (
  cd "${tmp_dir}"
  PATH="${tmp_dir}:${PATH}" \
    ORAS_LOG="${oras_log}" \
    OCI_REGISTRY=registry.test \
    OCI_PROJECT=project \
    "${script}" \
      --bundle "${bundle}" \
      --metadata "${metadata}" \
      --oras "${tmp_dir}/oras" \
      --upload-signature-tool "${tmp_dir}/upload_signature_tool" \
      --commit-sha aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
      --tag v0.1.0
) >/dev/null 2>&1; then
  echo "publisher treated an immutable commit tag as a recoverable extra tag" >&2
  exit 1
fi

if (
  cd "${tmp_dir}"
  PATH="${tmp_dir}:${PATH}" \
    ORAS_LOG="${oras_log}" \
    "${script}" \
      --bundle "${bundle}" \
      --metadata "${metadata}" \
      --oras "${tmp_dir}/oras" \
      --upload-signature-tool "${tmp_dir}/upload_signature_tool" \
      --commit-sha not-a-commit
) >/dev/null 2>&1; then
  echo "publisher accepted an invalid external commit" >&2
  exit 1
fi

echo "external commit publication contract verified"
