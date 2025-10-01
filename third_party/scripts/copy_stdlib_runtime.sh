#!/bin/bash
# Copy runtime .a files from bundled stdlib to tools_opam generated stdlib

set -e

SOURCE_STDLIB="/home/mfreeman/serviceradar/third_party/ocaml_stdlib"
TARGET_STDLIB="/home/mfreeman/.cache/bazel/_bazel_mfreeman/143b5407c57bdd27ce95d15d640f6773/external/tools_opam++opam+opam.ocamlsdk/stdlib/lib"

if [ ! -d "$TARGET_STDLIB" ]; then
    echo "Target stdlib not found: $TARGET_STDLIB"
    echo "Run a bazel build first to generate it"
    exit 1
fi

echo "Copying runtime .a files from $SOURCE_STDLIB to $TARGET_STDLIB"
cp -v "$SOURCE_STDLIB"/lib*.a "$TARGET_STDLIB/" 2>/dev/null || echo "No lib*.a files to copy"

echo "Done! Runtime libraries copied."
ls "$TARGET_STDLIB"/lib*.a 2>/dev/null || echo "Warning: No lib*.a files in target"
