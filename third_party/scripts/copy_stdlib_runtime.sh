#!/bin/bash
# Copy runtime .a files from OPAM stdlib to tools_opam generated stdlib
# This is needed because tools_opam's emit_ocamlsdk.c doesn't include lib*.a files yet

set -e

# Find the OPAM stdlib location
OPAM_STDLIB=$(opam var lib 2>/dev/null)/ocaml
if [ ! -d "$OPAM_STDLIB" ]; then
    echo "Error: OPAM stdlib not found at $OPAM_STDLIB"
    echo "Make sure OPAM is initialized with OCaml 5.2.0"
    exit 1
fi

# Find the bazel output base
OUTPUT_BASE=$(bazel info output_base 2>/dev/null)
if [ -z "$OUTPUT_BASE" ]; then
    echo "Error: Could not determine bazel output_base"
    exit 1
fi

TARGET_STDLIB="$OUTPUT_BASE/external/tools_opam++opam+opam.ocamlsdk/stdlib/lib"

if [ ! -d "$TARGET_STDLIB" ]; then
    echo "Target stdlib not found: $TARGET_STDLIB"
    echo "Run a bazel build first to generate it"
    exit 1
fi

echo "Copying runtime .a files from $OPAM_STDLIB to $TARGET_STDLIB"
cp -v "$OPAM_STDLIB"/lib*.a "$TARGET_STDLIB/" 2>/dev/null || {
    echo "Error: No lib*.a files found in $OPAM_STDLIB"
    exit 1
}

echo "Done! Runtime libraries copied."
ls "$TARGET_STDLIB"/lib*.a 2>/dev/null | wc -l | xargs echo "Copied files:"
