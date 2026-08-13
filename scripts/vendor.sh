#!/usr/bin/env bash
#
# Copyright (c) "2026" . Marvin Hansen All Rights Reserved.
#
set -o errexit
set -o nounset
set -o pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# Regenerate all vendored crates under //third_party/crates.
#
# The tree is plain `cargo vendor` output -- crate sources and nothing else. It used to be
# `crates_vendor` output, which wrote a crate_universe BUILD.bazel next to every crate and a
# defs.bzl/crates.bzl hub alongside them; rules_rs generates its own BUILD file per crate and
# its own hub, so those files are gone. `crate.from_cargo(vendor_dir = "third_party/crates")`
# in //MODULE.bazel is what makes rules_rs read this tree: a registry crate found at
# third_party/crates/<name>-<version> is symlinked from here instead of downloaded.
#
# Regular vs system deps. Routine updates (`cargo update` + this script) are expected to
# churn the whole tree -- there is no way to vendor a subset. The four system crates --
# openssl-src, openssl-sys, pq-src, pq-sys -- are instead held still by two mechanisms:
#   1. exact-version pins on openssl-sys/pq-sys in the root Cargo.toml, and
#   2. the version-derived asserts below, which fail this script if either patched crate
#      moves, since both source patches are keyed to an exact upstream version.
# So a system-crate bump is always a deliberate, reviewable act: re-pin and regenerate the
# patch. It can never happen by accident.
#
# Clear the vendor dir ourselves first so a rename (cargo names a directory after the raw
# semver, build metadata and all) cannot leave a stale copy behind next to the new one.
rm -rf third_party/crates

# --versioned-dirs is required, not cosmetic: rules_rs looks the crate up by
# <name>-<version>, and without it cargo writes bare <name> directories that nothing matches
# (and that collide for the crates this workspace has at two versions).
# stdout is the `[source]` snippet for a .cargo/config.toml, which we do not use -- Bazel
# never invokes cargo to build.
cargo vendor --versioned-dirs --locked third_party/crates >/dev/null

# `cargo vendor` writes pristine upstream sources, so the two source patches are applied
# here, to the tree on disk. They are deliberately NOT declared as `crate.annotation(patches
# = ...)` in //MODULE.bazel: rules_rs symlinks a vendored crate's files into its repository,
# and Bazel's native patch implementation rewrites in place through a symlink -- an
# annotation patch would edit this checked-in tree, and edit it again on every refetch.
#
# Both patches are keyed to an exact upstream version. Deriving the directory from
# Cargo.lock (rather than hardcoding it) and hard-asserting is deliberate: a silently
# skipped patch is the worst failure mode available here. pq-src's fix is macOS-only,
# so a skipped patch leaves Linux CI green and breaks a developer's machine later, far
# from the cause. Fail at vendor time instead, where the fix is obvious.

# Resolve a vendored crate dir from Cargo.lock. `cargo vendor --versioned-dirs` names each
# directory after the raw semver, build metadata included, so openssl-src 300.6.1+3.6.3 is
# openssl-src-300.6.1+3.6.3. crates_vendor used to sanitize the '+' to '-'; the sanitized
# spelling is accepted here as a fallback so this script still works against a tree vendored
# before the switch (rules_rs accepts either spelling for the same reason).
vendored_dir() {
  local name="$1" version dir
  version="$(python3 -c '
import re, sys
name = sys.argv[1]
m = re.search(r"\[\[package\]\]\nname = \"%s\"\nversion = \"([^\"]+)\"" % re.escape(name),
              open("Cargo.lock").read())
if not m:
    sys.exit(1)
print(m.group(1))
' "$name")" || {
    echo "ERROR: '$name' not found in Cargo.lock." >&2
    exit 1
  }
  for dir in "third_party/crates/${name}-${version}" \
             "third_party/crates/${name}-${version//+/-}"; do
    if [ -d "$dir" ]; then
      printf '%s' "$dir"
      return 0
    fi
  done
  # Report the name cargo would produce; the caller turns a missing dir into the error.
  printf 'third_party/crates/%s-%s' "$name" "$version"
}

# apply_vendor_patch <crate> <patch> <marker> <file-to-check>
# Applies <patch> unless <marker> is already present in <file-to-check>, then verifies
# the marker actually landed. Idempotent; loud on any version drift.
apply_vendor_patch() {
  local crate="$1" patch="$2" marker="$3" probe="$4" dir
  dir="$(vendored_dir "$crate")"
  if [ ! -d "$dir" ]; then
    echo "ERROR: expected vendored crate '$dir' is missing." >&2
    echo "       '$crate' changed version, so $patch no longer matches the source." >&2
    echo "       Regenerate the patch against the new upstream source before re-running." >&2
    exit 1
  fi
  if ! grep -q "$marker" "$dir/$probe"; then
    # --batch: never prompt. Without it, a patch that no longer matches can block on
    # stdin and hang CI instead of failing.
    (cd "$dir" && patch -p1 --batch <"$REPO_ROOT/$patch")
    echo "Applied $patch to $dir"
  fi
  if ! grep -q "$marker" "$dir/$probe"; then
    echo "ERROR: $patch did not apply to $dir ('$marker' absent from $probe)." >&2
    exit 1
  fi
}

# openssl-src: source_dir() must honor RULES_RUST_OPENSSL_SRC_DIR (the crate's baked
# CARGO_MANIFEST_DIR is a stale sandbox path under Bazel), and Configure must ignore two
# cc flags it cannot parse: `-no-canonical-prefixes` (rejected outright, exit 255) and the
# separated `-target <triple>` form a clang toolchain emits, which Configure reads as a
# second positional target ("target already defined"). Without this, vendored OpenSSL
# (used by libpq via pq-sys bundled) fails to build.
#
# The marker below only probes the first hunk. errexit plus patch's non-zero exit on a
# rejected hunk is what actually guards the rest.
apply_vendor_patch openssl-src \
  "third_party/rust_patches/openssl_src_runfiles_patch" \
  "RULES_RUST_OPENSSL_SRC_DIR" "src/lib.rs"

# pq-src (bundled libpq): on macOS, re-assert -D_FORTIFY_SOURCE=0 at the end of $CFLAGS
# so it overrides Bazel's cc_wrapper `-U_FORTIFY_SOURCE` (applied last by cc-rs), which
# otherwise re-enables the fortify strlcat/strlcpy builtins that conflict with libpq's
# bundled copies. Without this, libpq fails to compile from source under Bazel on macOS.
apply_vendor_patch pq-src \
  "third_party/rust_patches/pq_src_fortify_patch" \
  "_FORTIFY_SOURCE=0" "build.rs"

# Record the exact Cargo inputs that produced the committed vendor tree. The root
# crate universe no longer has a from_cargo extension in MODULE.bazel, so its input
# hashes do not belong in MODULE.bazel.lock. Native add-on release gates consume
# this deterministic index instead and can reject a stale vendor snapshot without
# re-vendoring the whole workspace in every CI job.
#
# This runs BEFORE the verification build below, and the ordering is deliberate. The
# vendor tree on disk was produced by these inputs whether or not it goes on to compile,
# and this script runs under `set -o errexit`: recording afterwards means a failed build
# leaves a regenerated tree beside a stale index. That combination is worse than either
# problem alone, because the next CI run reports "vendor snapshot is stale" instead of the
# build error that actually needs fixing, and the fix looks like a re-vendor rather than
# the dependency problem it really is.
VENDOR_INPUTS="third_party/crates/.serviceradar-vendor-inputs"
VENDOR_INPUTS_TMP="$(mktemp "${VENDOR_INPUTS}.XXXXXX")"
trap 'rm -f "${VENDOR_INPUTS_TMP}"' EXIT

python3 - "${REPO_ROOT}" >"${VENDOR_INPUTS_TMP}" <<'PY'
import hashlib
import json
import pathlib
import subprocess
import sys

root = pathlib.Path(sys.argv[1]).resolve()
metadata = json.loads(
    subprocess.check_output(
        [
            "cargo",
            "metadata",
            "--locked",
            "--offline",
            "--no-deps",
            "--format-version",
            "1",
        ],
        cwd=root,
        text=True,
    )
)

paths = {root / "Cargo.lock", root / "Cargo.toml"}
paths.update(
    pathlib.Path(package["manifest_path"]).resolve()
    for package in metadata["packages"]
)

for path in sorted(paths):
    relative_path = path.relative_to(root).as_posix()
    digest = hashlib.sha256(path.read_bytes()).hexdigest()
    print(f"FILE:@@//{relative_path} {digest}")
PY

mv "${VENDOR_INPUTS_TMP}" "${VENDOR_INPUTS}"
trap - EXIT
echo "Recorded Cargo vendor inputs in ${VENDOR_INPUTS}"

# Build every crate in the hub with those two patches applied. If a patch is incompatible
# with a newer version, it fails here rather than in whatever target happens to pull the
# crate in first.
#
# @crates//... and not //third_party/crates/... : the vendored tree has no BUILD files any
# more, so it declares no Bazel packages at all. The targets live in the hub rules_rs
# generates from it.
bazel build @crates//...
