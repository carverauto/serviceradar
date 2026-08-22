#!/usr/bin/env bash
# Copies a built add-on bundle out of runfiles to a destination path.
#
# Exists so nobody reaches into bazel-out, which //.bazelrc deliberately hides
# (--experimental_convenience_symlinks=clean) and whose path encodes the
# configuration that produced it. Same rationale as
# //config/manager_config/rust:update_embedded_instances, which also copies from
# runfiles rather than from a hand-resolved output path.
#
#   bazel run //build/native_addons:stage_netprobe_addon -- /tmp/netprobe.tar.gz
set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "usage: bazel run //build/native_addons:stage_netprobe_addon -- <destination>" >&2
  exit 2
fi

dest="$1"
src="${BUNDLE_RUNFILE:?BUNDLE_RUNFILE not set by the rule}"

if [ ! -f "$src" ]; then
  echo "bundle not found in runfiles: $src" >&2
  exit 1
fi

mkdir -p "$(dirname "$dest")"
cp -f "$src" "$dest"
echo "staged $(basename "$src") -> $dest"
