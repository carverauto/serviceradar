#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/update-rust-bazel-deps.sh [repin-mode] [verify-target]

Update the root Cargo.lock that feeds the `rust_crates` crate_universe repository,
then refresh MODULE.bazel.lock and verify a representative Rust target.

repin-mode:
  workspace                cargo update --workspace (default)
  full | eager | all       cargo update
  package_name             cargo update -p package_name
  package@1.2.3            cargo update -p package_name --precise 1.2.3
  package@1.2.3=4.5.6      cargo update -p package_name@1.2.3 --precise 4.5.6

verify-target:
  Bazel label to analyze after repinning.
  Default: //rust/srql:srql_lib

Examples:
  scripts/update-rust-bazel-deps.sh
  scripts/update-rust-bazel-deps.sh full
  scripts/update-rust-bazel-deps.sh diesel
  scripts/update-rust-bazel-deps.sh diesel@2.3.7 //rust/srql:srql_lib
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

REPIN_MODE="${1:-workspace}"
VERIFY_TARGET="${2:-//rust/srql:srql_lib}"

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

run_bazel_mod() {
  local tmp_ob
  tmp_ob="$(mktemp -d /tmp/sr-bazel-ob-XXXXXX)"
  bazel --batch --output_base="${tmp_ob}" mod deps --lockfile_mode=update
}

run_bazel_verify() {
  local target="$1"
  local tmp_ob
  tmp_ob="$(mktemp -d /tmp/sr-bazel-ob-XXXXXX)"
  bazel --batch --output_base="${tmp_ob}" build --nobuild "${target}"
}

echo "Updating Cargo.lock with mode: ${REPIN_MODE}"
run_cargo_update "${REPIN_MODE}"

echo "Refreshing MODULE.bazel.lock"
run_bazel_mod

echo "Verifying Bazel analysis for ${VERIFY_TARGET}"
run_bazel_verify "${VERIFY_TARGET}"

echo
echo "Updated files:"
echo "  Cargo.lock"
echo "  MODULE.bazel.lock"
