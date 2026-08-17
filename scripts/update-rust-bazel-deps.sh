#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/update-rust-bazel-deps.sh [update-mode] [verify-target]

Update the root Cargo.lock -- the single source of dependency versions for BOTH cargo
and Bazel -- then regenerate the vendored crate tree and verify with a real Bazel build.

Every step matters:
  1. cargo update      moves the lock
  2. cargo check       catches source breakage early, with --lib --bins --tests
                       (a plain `cargo check` skips test code, and Bazel compiles tests)
  3. bazel run //third_party/crate_mirror:sync refreshes the archives from the new lock
                       and re-applies the openssl-src / pq-src source patches
  4. bazel build       the step that actually decides: a green cargo check does NOT prove
                       the Bazel build (Cargo.lock keeps optional deps cargo never
                       resolves; cargo vendor vendors the whole lock, so Bazel compiles
                       crates cargo prunes)

update-mode:
  workspace                cargo update --workspace (default)
  full | eager | all       cargo update
  package_name             cargo update -p package_name
  package@1.2.3            cargo update -p package_name --precise 1.2.3
  package@1.2.3=4.5.6      cargo update -p package_name@1.2.3 --precise 4.5.6

verify-target:
  Bazel label to build after vendoring.
  Default: //rust/...

Examples:
  scripts/update-rust-bazel-deps.sh
  scripts/update-rust-bazel-deps.sh full
  scripts/update-rust-bazel-deps.sh diesel
  scripts/update-rust-bazel-deps.sh diesel@2.3.7 //rust/srql:srql_lib

Notes:
  - Bump versions in the ROOT Cargo.toml only; crates under /rust/ use { workspace = true }.
  - openssl-sys / pq-sys are exact-pinned because openssl-src / pq-src carry source patches.
    The pins do not reach those build deps, so a `full` update can still move them --
    vendor.sh then FAILS ON PURPOSE. That is not a bug: regenerate the patch, do not skip it.
  - This does not touch MODULE.bazel.lock. The root crate universe is vendored, not a
    from_cargo extension; only the separate RDP-connector extension uses MODULE.bazel, and
    rust/rdp-connector-probe is not a root workspace member, so `cargo update` here cannot
    affect it.
  - See rust/README_RUST.md for the full picture.
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

UPDATE_MODE="${1:-workspace}"
VERIFY_TARGET="${2:-//rust/...}"

# Vendored third-party forks under //third_party/rust_patches are workspace members, but
# their test targets reference dev-dependencies they never declare, so they fail
# `cargo check --tests` on a clean tree. Pre-existing and unrelated to any dep bump; skip
# them so this script reports real breakage only. Bazel does not build them either.
BROKEN_FORKS=(--exclude reqsign-azure-storage --exclude reqsign-google --exclude rperf)

run_cargo_update() {
  local mode="$1"

  case "${mode}" in
    workspace)
      cargo update --workspace
      ;;
    full|eager|all)
      cargo update
      ;;
    *@*=*)
      local pkg_and_current="${mode%%=*}"
      local precise="${mode#*=}"
      cargo update -p "${pkg_and_current}" --precise "${precise}"
      ;;
    *@*)
      local package="${mode%@*}"
      local precise="${mode#*@}"
      cargo update -p "${package}" --precise "${precise}"
      ;;
    *)
      cargo update -p "${mode}"
      ;;
  esac
}

echo "==> 1/4 Updating Cargo.lock (mode: ${UPDATE_MODE})"
run_cargo_update "${UPDATE_MODE}"

echo
echo "==> 2/4 Checking the workspace (lib + bins + tests)"
cargo check --workspace --lib --bins --tests "${BROKEN_FORKS[@]}"

echo
echo "==> 3/4 Regenerating the vendored crate tree (this downloads ~1 GB)"
bazel run //third_party/crate_mirror:sync

echo
echo "==> 4/4 Building ${VERIFY_TARGET} with Bazel"
bazel build "${VERIFY_TARGET}"

cat <<EOF

Done. Updated:
  Cargo.lock
  third_party/crate_mirror/                 (refreshed)

Still worth running before you push:
  cargo test --workspace ${BROKEN_FORKS[*]}
  bazel test //rust/...
EOF
