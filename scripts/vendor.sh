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
# Regular vs system deps. Routine updates (`cargo update` + this script) are expected
# to churn the whole tree -- crates_vendor resolves //:Cargo.lock as one universe, and
# there is no way to vendor a subset (no exclude attr, and a second crates_vendor
# target would duplicate rather than isolate). The four system crates -- openssl-src,
# openssl-sys, pq-src, pq-sys -- are instead held still by two mechanisms:
#   1. exact-version pins on openssl-sys/pq-sys in the root Cargo.toml, and
#   2. the version-derived asserts below, which fail this script if any of the four
#      moves, since both source patches are keyed to an exact upstream version.
# So a system-crate bump is always a deliberate, reviewable act: re-pin, regenerate the
# patch, update third_party/BUILD.bazel's labels. It can never happen by accident.
#
# Clear the vendor dir ourselves first: crates_vendor's own recursive delete is
# unreliable on macOS and intermittently aborts with
# `Failed to delete .../third_party/crates: Directory not empty (os error 66)`,
# leaving a half-deleted (broken) tree. Removing it up-front makes the run
# deterministic on Linux and macOS alike.
rm -rf third_party/crates

# Run the vendor command to download all deps
command bazel run //third_party:crates_vendor

# crates_vendor (local mode) applies BUILD-file annotations but does NOT apply the
# annotation `patches` to the on-disk vendored sources (that only happens on the
# repository-rule/remote path). Re-apply the required source patches here.
#
# Both patches are keyed to an exact upstream version. Deriving the directory from
# Cargo.lock (rather than hardcoding it) and hard-asserting is deliberate: a silently
# skipped patch is the worst failure mode available here. pq-src's fix is macOS-only,
# so a skipped patch leaves Linux CI green and breaks a developer's machine later, far
# from the cause. Fail at vendor time instead, where the fix is obvious.

# Resolve a vendored crate dir from Cargo.lock. crates_vendor names each directory
# <name>-<version> and sanitizes '+' to '-' (openssl-src 300.6.1+3.6.3 becomes
# openssl-src-300.6.1-3.6.3).
vendored_dir() {
  local name="$1" version
  version="$(python3 -c '
import re, sys
name = sys.argv[1]
m = re.search(r"\[\[package\]\]\nname = \"%s\"\nversion = \"([^\"]+)\"" % re.escape(name),
              open("Cargo.lock").read())
if not m:
    sys.exit(1)
print(m.group(1).replace("+", "-"))
' "$name")" || {
    echo "ERROR: '$name' not found in Cargo.lock." >&2
    exit 1
  }
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
    echo "       Regenerate the patch against the new upstream source (and update any" >&2
    echo "       hardcoded version labels in third_party/BUILD.bazel) before re-running." >&2
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
# CARGO_MANIFEST_DIR is a stale sandbox path under Bazel), and Configure must ignore
# Bazel's `-no-canonical-prefixes` cc flag. Without this, vendored OpenSSL (used by
# libpq via pq-sys bundled) fails to build.
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

# third_party/BUILD.bazel hardcodes the openssl-src package path in openssl-sys'
# build_script_data/env labels. Those are a separate copy of the version, so assert
# they still point at what we just vendored.
OPENSSL_SRC_PKG="$(basename "$(vendored_dir openssl-src)")"
if ! grep -q "$OPENSSL_SRC_PKG" third_party/BUILD.bazel; then
  echo "ERROR: third_party/BUILD.bazel does not reference '$OPENSSL_SRC_PKG'." >&2
  echo "       openssl-src moved; update the hardcoded labels in that file." >&2
  exit 1
fi

# Repair two cargo-bazel rendering bugs in the generated files. Both are upstream bugs
# in how crates_vendor renders, not something the vendored sources can express, so they
# have to be fixed after the fact -- and re-fixed on every vendor run, since the files
# are regenerated. Each step asserts its own assumptions instead of editing blindly.
python3 - <<'PY'
import pathlib
import re
import sys

crates = pathlib.Path("third_party/crates")

# (1) Build metadata ('+') in a version is sanitized to '-' for the on-disk directory
# and for alias `actual` labels, but NOT for the package path emitted into defs.bzl.
# Any direct dependency whose version carries build metadata (e.g. toml
# 1.1.3+spec-1.1.0) therefore renders a label pointing at a package that cannot exist.
defs = crates / "defs.bzl"
text = defs.read_text()


def sanitize(match):
    package = match.group(1).replace("+", "-")
    if not (crates / package).is_dir():
        sys.exit(f"ERROR: defs.bzl references '{package}', which was not vendored.")
    return f"//third_party/crates/{package}:"


patched, count = re.subn(r'//third_party/crates/([^:"\s]*\+[^:"\s]*):', sanitize, text)
if count:
    defs.write_text(patched)
    print(f"Sanitized {count} '+' package label(s) in {defs}")

# (2) A "weak" optional-dependency reference in a feature definition (`dep?/feature`,
# meaning "only if dep is already enabled") is rendered as a real Bazel dep edge even
# when the gating feature is off. oneio's `rustls` feature names `rust-s3?/sync-rustls-tls`
# while its `s3` feature stays off, so Bazel builds a rust-s3 -> aws-creds -> rust-ini
# chain that Cargo never resolves. Those crates are rendered with no crate_features, so
# ordered-multimap loses its default `std` and rust-ini fails to compile.
#
# This disappears entirely once arancini-lib stops pulling bgpkit-parser with default
# features (that is what drags oneio in) -- at which point oneio leaves Cargo.lock and
# this step no-ops. Until then, drop the edge that Cargo itself does not have.
oneio = next(iter(sorted(crates.glob("oneio-*"))), None)
if oneio is not None:
    build = oneio / "BUILD.bazel"
    content = build.read_text()
    library = re.search(r"rust_library\(.*?\n\)", content, re.S)
    if library and re.search(r'^\s+"s3",$', library.group(0), re.M):
        sys.exit(
            "ERROR: oneio now enables its 's3' feature, so the rust-s3 dep edge is "
            "legitimate. Remove this fixup instead of silently stripping a real dep."
        )
    stripped, hits = re.subn(
        r'^\s+"//third_party/crates/rust-s3-[^:]+:s3",\n', "", content, flags=re.M
    )
    if hits:
        build.write_text(stripped)
        print(f"Removed {hits} unreachable rust-s3 dep edge(s) from {build}")
PY

# Build all vendored deps with those two patches applied;
# In case the patch is incompatible with a newer version, it will fail here.
bazel build  //third_party/crates/...

# Record the exact Cargo inputs that produced the committed vendor tree. The root
# crate universe no longer has a from_cargo extension in MODULE.bazel, so its input
# hashes do not belong in MODULE.bazel.lock. Native add-on release gates consume
# this deterministic index instead and can reject a stale vendor snapshot without
# re-vendoring the whole workspace in every CI job.
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
