#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${repo_root}"
tmp_tree=""
tmp_embed="$(mktemp "${TMPDIR:-/tmp}/netprobe-satori-embed.XXXXXX")"
trap 'rm -f "${tmp_tree:-}" "${tmp_embed:-}"' EXIT

fail() {
  echo "netprobe fingerprint license guard failed: $*" >&2
  exit 1
}

satori_dir="rust/netprobe/satori-corpus"
recog_dir="rust/netprobe/recog-corpus"
muonfp_dir="rust/netprobe/muonfp-corpus"
p0f_dir="rust/netprobe/p0f-corpus"

for required in \
  "${p0f_dir}/LICENSE-LGPL-2.1.txt" \
  "${p0f_dir}/p0f.fp" \
  "${p0f_dir}/serviceradar-additions.fp" \
  "${recog_dir}/COPYING" \
  "${recog_dir}/LICENSE" \
  "${recog_dir}/SHA256SUMS" \
  "${recog_dir}/IDENTIFIER_SHA256SUMS" \
  "${muonfp_dir}/LICENSE-MIT.txt" \
  "${muonfp_dir}/SPEC.md" \
  "${muonfp_dir}/reference-fingerprint.rs" \
  "${satori_dir}/LICENSE-GPL-2.0.txt" \
  "${satori_dir}/UPSTREAM-README.md" \
  "${satori_dir}/SHA256SUMS"; do
  [[ -f "${required}" ]] || fail "missing required fingerprint corpus license/source file: ${required}"
done

recog_xml_count="$(find "${recog_dir}/xml" -maxdepth 1 -type f -name '*.xml' | wc -l | tr -d '[:space:]')"
[[ "${recog_xml_count}" -gt 0 ]] || fail "Recog corpus XML directory is empty"

satori_xml_count="$(find "${satori_dir}/xml" -maxdepth 1 -type f -name '*.xml' | wc -l | tr -d '[:space:]')"
[[ "${satori_xml_count}" -gt 0 ]] || fail "Satori corpus XML directory is empty"

if grep -RInE 'include_(bytes|str)!\([^)]*satori-corpus' rust/netprobe >"${tmp_embed}" 2>/dev/null; then
  cat "${tmp_embed}" >&2
  fail "Satori GPLv2 XML must be runtime-loaded as replaceable data, not embedded with include_bytes!/include_str!"
fi

tmp_tree="$(mktemp "${TMPDIR:-/tmp}/netprobe-cargo-tree.XXXXXX")"

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
