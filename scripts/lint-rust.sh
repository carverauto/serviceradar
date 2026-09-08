#!/usr/bin/env bash
#
# Copyright 2025 Carver Automation Corporation.
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
# Runs the same two clippy passes as .github/workflows/rust-checks.yml, so a clean run here
# means that gate is green. Reachable as `make format`.
#
# Clippy is on cargo rather than Bazel because this repo wires up no clippy aspect: there is
# no rust_clippy target and no --aspects entry in .bazelrc, so `bazel build` has nothing to
# run. That means this lints the source tree rather than the artifact that ships (see
# rust/README_RUST.md) -- for lints that is the right trade.
#
# The one deliberate difference from CI: Socket Firewall is used when present and skipped
# with a warning when it is not. sfw is a network policy wrapper around the dependency
# fetch, so its absence changes which registry traffic is allowed, never which lints fire.
# Failing outright would make this script unusable on a workstation that has not installed
# it, which defeats the point of a local gate.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${repo_root}"

readonly COLOR_BOLD=$'\033[1m'
readonly COLOR_RESET=$'\033[0m'

if ! command -v cargo >/dev/null 2>&1; then
  echo "cargo not found on PATH. Install a stable Rust toolchain with rustup." >&2
  exit 1
fi

if ! cargo clippy --version >/dev/null 2>&1; then
  echo "cargo clippy is unavailable. Install it with: rustup component add clippy" >&2
  exit 1
fi

# Named so the two invocations below read the same as the CI steps they mirror.
cargo_cmd=(cargo)
if command -v sfw >/dev/null 2>&1; then
  cargo_cmd=(sfw cargo)
else
  echo "warning: sfw not found; running cargo directly. CI wraps these calls in Socket" >&2
  echo "         Firewall. Install it with scripts/ci/install-sfw.sh to match exactly." >&2
fi

# third_party/rust_patches/* are workspace members, so --workspace reaches them, but they are
# vendored upstream sources carrying our build patches -- not code this repo authors, and not
# code a lint gate should have an opinion about. They also fail --all-targets on a clean tree
# because their dev-dependencies are undeclared, so linting them would gate every PR on a
# pre-existing upstream defect.
#
# The exclusions are derived from the manifest path rather than listed by name, so a fourth
# fork landing under third_party/rust_patches/ is excluded without anyone remembering to edit
# this script. cargo --exclude takes package names, not paths, which is why the name has to be
# read out of the manifest at all.
excludes=()
for manifest in third_party/rust_patches/*/Cargo.toml; do
  # An unmatched glob stays literal, so check before reading it.
  [ -f "${manifest}" ] || continue

  name="$(sed -n 's/^name[[:space:]]*=[[:space:]]*"\(.*\)".*/\1/p' "${manifest}" | head -n 1)"
  if [ -z "${name}" ]; then
    echo "could not read a package name from ${manifest}" >&2
    exit 1
  fi

  echo "excluding ${name} (${manifest})"
  excludes+=(--exclude "${name}")
done

# One workspace-wide pass rather than one per crate: the crates share a target directory, so
# per-crate invocations rebuild the same dependencies over and over.
printf '%sRunning clippy (workspace)%s\n' "${COLOR_BOLD}" "${COLOR_RESET}"
# ${excludes[@]+...} keeps `set -u` happy if the directory is ever empty.
"${cargo_cmd[@]}" clippy --workspace --all-targets \
  ${excludes[@]+"${excludes[@]}"} \
  -- -D warnings

# rdp-connector-probe is deliberately detached from the workspace -- its own [workspace] table
# and lockfile, see rust/README_RUST.md section 1 -- so a workspace pass does not reach it.
printf '%sRunning clippy (rdp-connector-probe)%s\n' "${COLOR_BOLD}" "${COLOR_RESET}"
(
  cd rust/rdp-connector-probe
  "${cargo_cmd[@]}" clippy --all-targets -- -D warnings
)

printf '%sClippy clean%s\n' "${COLOR_BOLD}" "${COLOR_RESET}"
