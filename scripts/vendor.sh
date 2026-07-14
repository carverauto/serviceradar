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
# repository-rule/remote path). Re-apply the required source patches here. Each
# application is guarded so re-running is idempotent.
#
# openssl-src: source_dir() must honor RULES_RUST_OPENSSL_SRC_DIR (the crate's baked
# CARGO_MANIFEST_DIR is a stale sandbox path under Bazel), and Configure must ignore
# Bazel's `-no-canonical-prefixes` cc flag. Without this, vendored OpenSSL (used by
# libpq via pq-sys bundled) fails to build.
OPENSSL_SRC_DIR="third_party/crates/openssl-src-300.6.1-3.6.3"
OPENSSL_PATCH="third_party/rust_patches/openssl_src_runfiles_patch"
if [ -d "$OPENSSL_SRC_DIR" ] && ! grep -q "RULES_RUST_OPENSSL_SRC_DIR" "$OPENSSL_SRC_DIR/src/lib.rs"; then
  (cd "$OPENSSL_SRC_DIR" && patch -p1 <"$REPO_ROOT/$OPENSSL_PATCH")
  echo "Applied $OPENSSL_PATCH to $OPENSSL_SRC_DIR"
fi

# pq-src (bundled libpq): on macOS, re-assert -D_FORTIFY_SOURCE=0 at the end of $CFLAGS
# so it overrides Bazel's cc_wrapper `-U_FORTIFY_SOURCE` (applied last by cc-rs), which
# otherwise re-enables the fortify strlcat/strlcpy builtins that conflict with libpq's
# bundled copies. Without this, libpq fails to compile from source under Bazel on macOS.
PQ_SRC_DIR="third_party/crates/pq-src-0.3.11-libpq-18.3"
PQ_PATCH="third_party/rust_patches/pq_src_fortify_patch"
if [ -d "$PQ_SRC_DIR" ] && ! grep -q "_FORTIFY_SOURCE=0" "$PQ_SRC_DIR/build.rs"; then
  (cd "$PQ_SRC_DIR" && patch -p1 <"$REPO_ROOT/$PQ_PATCH")
  echo "Applied $PQ_PATCH to $PQ_SRC_DIR"
fi

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
