#!/usr/bin/env bash
set -euo pipefail

if [[ "$#" -ne 1 ]]; then
  echo "usage: $0 <check-native-addon-version-bumps.sh>" >&2
  exit 2
fi

guard_source="$1"
fixture="$(mktemp -d "${TMPDIR:-/tmp}/native-addon-version-gate.XXXXXX")"
trap 'rm -rf "${fixture}"' EXIT

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
  "${fixture}/addons/anomaly-addon" \
  "${fixture}/addons/rdp-adapter" \
  "${fixture}/rust/anomaly-addon/src/tests" \
  "${fixture}/addons/otel-collector" \
  "${fixture}/addons/bumblebee-scan" \
  "${fixture}/go/pkg/bumblebee" \
  "${fixture}/rust/rdp-adapter" \
  "${fixture}/rust/rdp-connector-probe" \
  "${fixture}/rust/otel-addon" \
  "${fixture}/rust/otel/src" \
  "${fixture}/scripts" \
  "${fixture}/third_party/crate_mirror"
cp "${guard_source}" "${fixture}/scripts/check-native-addon-version-bumps.sh"
chmod +x "${fixture}/scripts/check-native-addon-version-bumps.sh"

cd "${fixture}"
git init -q
git config user.email "native-addon-gate-test@serviceradar.invalid"
git config user.name "ServiceRadar test"

printf 'version: 0.1.0\n' >addons/rdp-adapter/addon.yaml
printf 'version: 0.3.0\n' >addons/anomaly-addon/addon.yaml
printf '[package]\nname = "serviceradar-anomaly-addon"\nversion = "0.3.0"\n' \
  >rust/anomaly-addon/Cargo.toml
printf '[package]\nname = "serviceradar-rdp-adapter"\nversion = "0.1.0"\n' \
  >rust/rdp-adapter/Cargo.toml
printf 'root-lock-v1\n' >Cargo.lock
printf '[package]\nname = "serviceradar-rdp-connector-probe"\nversion = "0.1.0"\n' \
  >rust/rdp-connector-probe/Cargo.toml
printf 'connector-lock-v1\n' >rust/rdp-connector-probe/Cargo.lock
printf 'version: 0.1.0\n' >addons/otel-collector/addon.yaml
printf '[package]\nname = "otel-addon"\nversion = "0.1.0"\n' >rust/otel-addon/Cargo.toml
mkdir -p rust/otel/src
printf 'pub fn collector() {}\n' >rust/otel/src/lib.rs
printf 'version: 0.1.0\n' >addons/bumblebee-scan/addon.yaml
printf 'package bumblebee\n' >go/pkg/bumblebee/runner.go
git add .
git commit -qm "base"
base_commit="$(git rev-parse HEAD)"

# A Rust add-on payload change requires an addon.yaml bump -- and nothing else.
#
# The crate [package] version and the root vendor snapshot are deliberately NOT dragged
# along. This case used to assert the opposite: that the gate failed closed until
# the vendored tree's input index recorded the new Cargo.lock and Cargo.toml hashes. The
# only way to satisfy that was a full re-vendor, which rewrites 625 crate
# directories and discards the Bazel cache for every Rust target -- to restate a version
# string that changes no third-party crate. So the second half asserts the bump passes with
# rust/rdp-adapter/Cargo.toml still at 0.1.0 and the vendor snapshot untouched.
printf 'pub fn adapter_runtime() {}\n' >rust/rdp-adapter/handler.rs
git add .
git commit -qm "change rdp payload without bumping"
expect_failure \
  "rdp native add-on payload changed" \
  scripts/check-native-addon-version-bumps.sh "${base_commit}" HEAD

printf 'version: 0.1.1\n' >addons/rdp-adapter/addon.yaml
git add addons/rdp-adapter/addon.yaml
git commit -qm "bump rdp add-on manifest only"
scripts/check-native-addon-version-bumps.sh "${base_commit}" HEAD >/dev/null

# The shipped RDP helper resolves its connector/CredSSP graph from the separate
# rdp_connector_crates universe, so that universe's manifest and lockfile are rdp payload
# even though neither lives under rust/rdp-adapter. Changing them alone must still demand a
# manifest bump.
#
# There is deliberately no MODULE.bazel.lock staleness case here any more; see the long note
# in the gate for why that check became unsatisfiable under rules_rs.
# A FRESH BASE, deliberately. The gate compares base..HEAD cumulatively, and rdp's manifest
# already moved 0.1.0 -> 0.1.1 earlier in this fixture; measuring from base_commit would see
# that bump and pass regardless of what this case does.
connector_base="$(git rev-parse HEAD)"
printf '[package]\nname = "serviceradar-rdp-connector-probe"\nversion = "0.1.0"\ndescription = "updated graph"\n' \
  >rust/rdp-connector-probe/Cargo.toml
printf 'connector-lock-v2\n' >rust/rdp-connector-probe/Cargo.lock
git add .
git commit -qm "change connector universe without bumping rdp"
expect_failure \
  "rdp native add-on payload changed" \
  scripts/check-native-addon-version-bumps.sh "${connector_base}" HEAD

printf 'version: 0.1.2\n' >addons/rdp-adapter/addon.yaml
git add addons/rdp-adapter/addon.yaml
git commit -qm "bump rdp for the connector universe change"
scripts/check-native-addon-version-bumps.sh "${connector_base}" HEAD >/dev/null

# Test-only Rust sources do not change the signed add-on runtime payload and
# therefore must not force a fake package-version bump.
printf '#[test]\nfn regression_only() {}\n' >rust/anomaly-addon/src/tests/regression.rs
git add rust/anomaly-addon/src/tests/regression.rs
git commit -qm "add anomaly regression test"
scripts/check-native-addon-version-bumps.sh "${base_commit}" HEAD >/dev/null

# The adjacent production source remains protected by the same version gate.
printf 'pub fn runtime_change() {}\n' >rust/anomaly-addon/src/runtime_change.rs
git add rust/anomaly-addon/src/runtime_change.rs
git commit -qm "change anomaly runtime"
expect_failure \
  "anomaly native add-on payload changed" \
  scripts/check-native-addon-version-bumps.sh "${base_commit}" HEAD
git rm -q rust/anomaly-addon/src/runtime_change.rs
git commit -qm "restore anomaly runtime"
scripts/check-native-addon-version-bumps.sh "${base_commit}" HEAD >/dev/null

# The OTEL add-on binary includes the local collector crate. A change there
# changes the signed payload just as surely as a change under rust/otel-addon,
# so it must require a manifest version bump.
printf 'pub fn collector() { /* changed payload */ }\n' >rust/otel/src/lib.rs
git add rust/otel/src/lib.rs
git commit -qm "change shared otel collector payload"
expect_failure \
  "otel-collector native add-on payload changed but addons/otel-collector/addon.yaml stayed at 0.1.0" \
  scripts/check-native-addon-version-bumps.sh "${base_commit}" HEAD
printf 'pub fn collector() {}\n' >rust/otel/src/lib.rs
git add rust/otel/src/lib.rs
git commit -qm "restore shared otel collector payload"
scripts/check-native-addon-version-bumps.sh "${base_commit}" HEAD >/dev/null

# The Bumblebee add-on binary depends on the shared scanner package, not just
# its command wrapper. Changes there must be versioned as a new signed package.
printf 'package bumblebee\n\nfunc ChangedPayload() {}\n' >go/pkg/bumblebee/runner.go
git add go/pkg/bumblebee/runner.go
git commit -qm "change bumblebee scanner payload"
expect_failure \
  "bumblebee native add-on payload changed but addons/bumblebee-scan/addon.yaml stayed at 0.1.0" \
  scripts/check-native-addon-version-bumps.sh "${base_commit}" HEAD

echo "native add-on version gate tests passed"
