#!/usr/bin/env bash
# The release publisher builds every Wasm push target before it authenticates,
# then `bazel run`s each one. Release CI builds with --remote_download_minimal,
# so unless both passes download the push targets' outputs and runfiles, the run
# finds publish_plugin.sh's upload_signature_tool as a dangling symlink and the
# publish fails (v1.4.96).
set -euo pipefail

if [[ -n "${TEST_SRCDIR:-}" && -n "${TEST_WORKSPACE:-}" ]]; then
  repo_root="${TEST_SRCDIR}/${TEST_WORKSPACE}"
else
  repo_root="$(git rev-parse --show-toplevel)"
fi

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

calls="${tmp_dir}/bazel-calls"
fake_bazel="${tmp_dir}/bazel"
cat >"${fake_bazel}" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"${calls}"
if [[ "\$1" == query ]]; then
  printf '//build/wasm_plugins:first_bundle_push\n//build/wasm_plugins:second_bundle_push\n'
fi
EOF
chmod +x "${fake_bazel}"

export BAZEL_BIN="${fake_bazel}"
unset BAZEL_BUILD_FLAGS

"${repo_root}/scripts/push_all_wasm_plugins.sh" --build-only >/dev/null
"${repo_root}/scripts/push_all_wasm_plugins.sh" --tag v0.0.0-test >/dev/null

expect_call() {
  if ! grep -qxF -- "$1" "${calls}"; then
    echo "missing bazel call: $1" >&2
    echo "recorded calls:" >&2
    cat "${calls}" >&2
    exit 1
  fi
}

expect_call "build --remote_download_toplevel //build/wasm_plugins:first_bundle_push //build/wasm_plugins:second_bundle_push"
expect_call "run --remote_download_toplevel //build/wasm_plugins:first_bundle_push -- --tag v0.0.0-test"
expect_call "run --remote_download_toplevel //build/wasm_plugins:second_bundle_push -- --tag v0.0.0-test"

echo "Wasm push targets download their runfiles in both publish passes"
