#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${repo_root}"

tmp_tree="$(mktemp "${TMPDIR:-/tmp}/netprobe-cargo-tree.XXXXXX")"
trap 'rm -f "${tmp_tree}"' EXIT

cargo_runner=(cargo)
if command -v sfw >/dev/null 2>&1; then
  cargo_runner=(sfw cargo)
fi

"${cargo_runner[@]}" tree \
  -p serviceradar-netprobe \
  --locked \
  --all-features > "${tmp_tree}"

for crate in huginn-net ja4t ja4h ja4s ja4ssh ja4x; do
  if grep -E "(^|[^[:alnum:]_-])${crate} v[0-9]" "${tmp_tree}" >/dev/null; then
    echo "forbidden fingerprint dependency found in cargo tree: ${crate}" >&2
    grep -E "(^|[^[:alnum:]_-])${crate} v[0-9]" "${tmp_tree}" >&2
    exit 1
  fi
done

echo "netprobe fingerprint dependency license guard passed"
