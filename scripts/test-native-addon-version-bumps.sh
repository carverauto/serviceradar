#!/usr/bin/env bash
set -euo pipefail

if [[ "$#" -ne 1 ]]; then
  echo "usage: $0 <check-native-addon-version-bumps.sh>" >&2
  exit 2
fi

guard_source="$1"
fixture="$(mktemp -d "${TMPDIR:-/tmp}/native-addon-version-gate.XXXXXX")"
trap 'rm -rf "${fixture}"' EXIT

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

write_vendor_inputs() {
  {
    printf 'FILE:@@//Cargo.lock %s\n' "$(sha256_file Cargo.lock)"
    printf 'FILE:@@//rust/rdp-adapter/Cargo.toml %s\n' \
      "$(sha256_file rust/rdp-adapter/Cargo.toml)"
  } >third_party/crates/.serviceradar-vendor-inputs
}

write_module_lock() {
  {
    printf 'FILE:@@//rust/rdp-connector-probe/Cargo.lock %s\n' \
      "$(sha256_file rust/rdp-connector-probe/Cargo.lock)"
    printf 'FILE:@@//rust/rdp-connector-probe/Cargo.toml %s\n' \
      "$(sha256_file rust/rdp-connector-probe/Cargo.toml)"
  } >MODULE.bazel.lock
}

expect_failure() {
  local expected="$1" output
  shift

  if output="$("$@" 2>&1)"; then
    echo "error: command unexpectedly passed: $*" >&2
    exit 1
  fi

  if ! grep -Fq "${expected}" <<<"${output}"; then
    echo "error: expected failure did not contain: ${expected}" >&2
    echo "${output}" >&2
    exit 1
  fi
}

mkdir -p \
  "${fixture}/addons/rdp-adapter" \
  "${fixture}/rust/rdp-adapter" \
  "${fixture}/rust/rdp-connector-probe" \
  "${fixture}/scripts" \
  "${fixture}/third_party/crates"
cp "${guard_source}" "${fixture}/scripts/check-native-addon-version-bumps.sh"
chmod +x "${fixture}/scripts/check-native-addon-version-bumps.sh"

cd "${fixture}"
git init -q
git config user.email "native-addon-gate-test@serviceradar.invalid"
git config user.name "ServiceRadar test"

printf 'version: 0.1.0\n' >addons/rdp-adapter/addon.yaml
printf '[package]\nname = "serviceradar-rdp-adapter"\nversion = "0.1.0"\n' \
  >rust/rdp-adapter/Cargo.toml
printf 'root-lock-v1\n' >Cargo.lock
printf '[package]\nname = "serviceradar-rdp-connector-probe"\nversion = "0.1.0"\n' \
  >rust/rdp-connector-probe/Cargo.toml
printf 'connector-lock-v1\n' >rust/rdp-connector-probe/Cargo.lock
write_vendor_inputs
write_module_lock
git add .
git commit -qm "base"
base_commit="$(git rev-parse HEAD)"

# Root Rust add-on metadata must fail closed until the committed vendor-input
# index describes the same Cargo inputs.
printf 'version: 0.1.1\n' >addons/rdp-adapter/addon.yaml
printf '[package]\nname = "serviceradar-rdp-adapter"\nversion = "0.1.1"\n' \
  >rust/rdp-adapter/Cargo.toml
printf 'root-lock-v2\n' >Cargo.lock
git add .
git commit -qm "stale root vendor index"
expect_failure \
  "vendor snapshot is stale" \
  scripts/check-native-addon-version-bumps.sh "${base_commit}" HEAD

write_vendor_inputs
git add third_party/crates/.serviceradar-vendor-inputs
git commit -qm "refresh root vendor index"
scripts/check-native-addon-version-bumps.sh "${base_commit}" HEAD >/dev/null

# The shipped RDP helper consumes the separate connector universe. Its manifest
# and lockfile must continue to be pinned by MODULE.bazel.lock independently of
# the root vendor index.
printf 'version: 0.1.2\n' >addons/rdp-adapter/addon.yaml
printf '[package]\nname = "serviceradar-rdp-adapter"\nversion = "0.1.2"\n' \
  >rust/rdp-adapter/Cargo.toml
printf '[package]\nname = "serviceradar-rdp-connector-probe"\nversion = "0.1.0"\ndescription = "updated graph"\n' \
  >rust/rdp-connector-probe/Cargo.toml
printf 'connector-lock-v2\n' >rust/rdp-connector-probe/Cargo.lock
write_vendor_inputs
git add .
git commit -qm "stale connector module lock"
expect_failure \
  "RDP connector metadata changed but MODULE.bazel.lock is stale" \
  scripts/check-native-addon-version-bumps.sh "${base_commit}" HEAD

write_module_lock
git add MODULE.bazel.lock
git commit -qm "refresh connector module lock"
scripts/check-native-addon-version-bumps.sh "${base_commit}" HEAD >/dev/null

echo "native add-on Rust dependency metadata gate tests passed"
