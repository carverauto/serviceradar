#!/usr/bin/env bash
# Run the CI gates that fail for reasons a local `cargo test` / `mix test` never shows.
#
# Each of these has burned a full CI round trip at least once, and each fails for a reason you
# cannot see from a normal build:
#
#   1. native add-on version bumps  -- an add-on's source changed without a version bump
#   2. rust vendor tree completeness-- the committed vendor tree omits checksum-listed files
#   3. web-ng precommit             -- mix format / credo
#   4. native add-on build gates    -- manifest validation + inventory consistency, which
#                                      otherwise only fail during the RELEASE publish, long
#                                      after the change that broke them merged
#
# IMPORTANT: gate 1 reads COMMITTED state through git refs, not your working tree. Run this
# after committing and before pushing. A dirty tree is reported below, because a gate passing
# against a commit that lacks your latest edit means nothing.
#
# Usage:
#   scripts/ci/pre-push.sh              # check everything, report a summary
#   scripts/ci/pre-push.sh --no-bazel   # skip gates 3 and 4 (the slow ones)
#   scripts/ci/pre-push.sh --base <ref> # compare against something other than origin/staging
#
# Every gate runs even if an earlier one fails, so one invocation shows you the whole list
# rather than making you fix them one CI run at a time.

set -uo pipefail

BASE_REF="origin/staging"
RUN_BAZEL=1

while [ $# -gt 0 ]; do
  case "$1" in
    --no-bazel) RUN_BAZEL=0 ;;
    --base)
      shift
      [ $# -gt 0 ] || { echo "--base needs a ref" >&2; exit 2; }
      BASE_REF="$1"
      ;;
    -h | --help)
      sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "unknown argument: $1 (see --help)" >&2
      exit 2
      ;;
  esac
  shift
done

repo_root="$(git rev-parse --show-toplevel)"
cd "${repo_root}"

declare -a PASSED=() FAILED=() SKIPPED=()

run_gate() {
  local name="$1"
  shift
  printf '\n\033[1m==> %s\033[0m\n' "${name}"
  if "$@"; then
    PASSED+=("${name}")
  else
    FAILED+=("${name}")
  fi
}

# --- preflight ------------------------------------------------------------------------
if [ -n "$(git status --porcelain)" ]; then
  cat >&2 <<'EOF'
warning: the working tree is dirty.

The add-on version-bump gate reads committed state through git refs, so it will not see
uncommitted edits. Commit first, or treat a pass here as meaningless.
EOF
fi

head_sha="$(git rev-parse HEAD)"
base_remote="${BASE_REF%%/*}"
base_branch="${BASE_REF#*/}"
if [ "${base_remote}" != "${BASE_REF}" ]; then
  echo "fetching ${base_branch} from ${base_remote}..."
  git fetch --no-tags "${base_remote}" "${base_branch}" >/dev/null 2>&1 ||
    echo "warning: could not fetch ${BASE_REF}; comparing against whatever is cached" >&2
fi

echo "base: ${BASE_REF}    head: ${head_sha}"

# --- the gates ------------------------------------------------------------------------
run_gate "1. native add-on version bumps" \
  bash scripts/check-native-addon-version-bumps.sh "${BASE_REF}" "${head_sha}"

run_gate "2. rust vendor tree completeness" \
  python3 scripts/check-rust-vendor-tracked.py

if [ "${RUN_BAZEL}" -eq 1 ]; then
  run_gate "3. web-ng precommit (mix format + credo)" \
    bazel test --config=ci //elixir/web-ng:precommit

  run_gate "4. native add-on build gates" \
    bazel test --config=ci //build/native_addons:build_gates_test
else
  SKIPPED+=("3. web-ng precommit (--no-bazel)" "4. native add-on build gates (--no-bazel)")
fi

# --- summary --------------------------------------------------------------------------
printf '\n\033[1m===== summary =====\033[0m\n'
for g in "${PASSED[@]-}"; do [ -n "${g}" ] && printf '  \033[32mPASS\033[0m  %s\n' "${g}"; done
for g in "${SKIPPED[@]-}"; do [ -n "${g}" ] && printf '  \033[33mSKIP\033[0m  %s\n' "${g}"; done
for g in "${FAILED[@]-}"; do [ -n "${g}" ] && printf '  \033[31mFAIL\033[0m  %s\n' "${g}"; done

if [ "${#FAILED[@]}" -gt 0 ]; then
  cat >&2 <<'EOF'

Not ready to push. Common repairs:
  gate 1  bump addons/<id>/addon.yaml -- that manifest is the single source of truth. Only
          netprobe additionally pins NETPROBE_VERSION in rust/netprobe/BUILD.bazel, which
          must match. Crate [package] versions are deliberately NOT part of this.
  gate 2  //third_party/crate_mirror:sync  (a real third-party dependency change)
  gate 3  the test log prints the exact formatting diff it wants
EOF
  exit 1
fi

printf '\nAll gates passed.\n'
