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

require_file_contains() {
  local path="$1"
  local pattern="$2"
  local description="$3"

  grep -Eq "${pattern}" "${path}" || fail "${path} does not assert ${description}"
}

verify_manifest() {
  local dir="$1"
  local manifest="$2"

  (
    cd "${dir}"
    shasum -a 256 -c "${manifest}" >/dev/null
  ) || fail "sha256 manifest verification failed: ${dir}/${manifest}"
}

verify_known_corpus_dirs() {
  local dir

  # Every corpus lives in //third_party/netprobe_corpora. Anything else there is
  # unreviewed. Scanning for a bare directory name rather than a '*-corpus' suffix
  # is deliberate: a suffix pattern would silently match nothing and pass.
  while IFS= read -r dir; do
    case "${dir}" in
      "${corpora_root}"/p0f | \
      "${corpora_root}"/muonfp | \
      "${corpora_root}"/recog | \
      "${corpora_root}"/satori)
        ;;
      *)
        fail "unexpected fingerprint corpus directory requires license review: ${dir}"
        ;;
    esac
  done < <(find "${corpora_root}" -mindepth 1 -maxdepth 1 -type d | sort)

  # A corpus reintroduced under the crate would escape every check above.
  while IFS= read -r dir; do
    fail "fingerprint corpus must live in ${corpora_root}, not under the crate: ${dir}"
  done < <(find rust/netprobe -maxdepth 1 -type d -name '*-corpus' | sort)
}

verify_satori_data_boundary() {
  local path

  while IFS= read -r path; do
    case "${path}" in
      LICENSE-GPL-2.0.txt | README.md | SHA256SUMS | UPSTREAM-README.md | xml/*.xml)
        ;;
      *)
        fail "Satori corpus must contain only replaceable XML data and license/readme files, found: ${satori_dir}/${path}"
        ;;
    esac
  done < <(cd "${satori_dir}" && find . -type f | sed 's#^\./##' | sort)
}

corpora_root="third_party/netprobe_corpora"
satori_dir="${corpora_root}/satori"
recog_dir="${corpora_root}/recog"
muonfp_dir="${corpora_root}/muonfp"
p0f_dir="${corpora_root}/p0f"

for required in \
  "${p0f_dir}/LICENSE-LGPL-2.1.txt" \
  "${p0f_dir}/p0f.fp" \
  "${p0f_dir}/serviceradar-additions.fp" \
  "${recog_dir}/COPYING" \
  "${recog_dir}/LICENSE" \
  "${recog_dir}/serviceradar-recog-additions.xml" \
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

verify_known_corpus_dirs

require_file_contains "${p0f_dir}/README.md" 'License: GNU LGPL 2\.1' 'LGPL-2.1 provenance for the upstream p0f corpus'
require_file_contains "${p0f_dir}/LICENSE-LGPL-2.1.txt" 'GNU LESSER GENERAL PUBLIC LICENSE' 'the LGPL license text'
require_file_contains "${p0f_dir}/LICENSE-LGPL-2.1.txt" 'Version 2\.1' 'LGPL version 2.1'
require_file_contains "${p0f_dir}/p0f.fp" 'Distributed under.*GNU LGPL' 'the upstream p0f corpus LGPL notice'
require_file_contains "${p0f_dir}/serviceradar-additions.fp" 'License: CC0-1\.0' 'CC0-1.0 provenance for ServiceRadar p0f additions'

require_file_contains "${recog_dir}/README.md" 'License: BSD-2-[Cc]lause' 'BSD-2-Clause provenance for the Recog corpus'
require_file_contains "${recog_dir}/LICENSE" 'License: BSD-2-clause' 'BSD-2-Clause Debian copyright declaration'
require_file_contains "${recog_dir}/COPYING" 'Redistribution and use in source and binary forms' 'BSD-2-Clause redistribution terms'
require_file_contains "${recog_dir}/serviceradar-recog-additions.xml" 'License: CC0-1\.0' 'CC0-1.0 provenance for ServiceRadar Recog additions'
verify_manifest "${recog_dir}" "SHA256SUMS"
verify_manifest "${recog_dir}" "IDENTIFIER_SHA256SUMS"

require_file_contains "${muonfp_dir}/README.md" 'does not contain a standalone MuonFP signature' 'MuonFP no-corpus audit finding'
require_file_contains "${muonfp_dir}/README.md" 'corpus' 'MuonFP corpus audit context'
require_file_contains "${muonfp_dir}/README.md" 'License from repository `LICENSE`: MIT' 'MIT provenance for the MuonFP reference encoder'
require_file_contains "${muonfp_dir}/LICENSE-MIT.txt" 'MIT License' 'the MuonFP MIT license text'

require_file_contains "${satori_dir}/README.md" 'GPLv2' 'GPLv2 provenance for Satori XML data'
require_file_contains "${satori_dir}/README.md" 'Only the XML fingerprint data is vendored' 'the Satori data-only boundary'
require_file_contains "${satori_dir}/LICENSE-GPL-2.0.txt" 'GNU GENERAL PUBLIC LICENSE' 'the GPL license text'
require_file_contains "${satori_dir}/LICENSE-GPL-2.0.txt" 'Version 2, June 1991' 'GPL version 2'
verify_satori_data_boundary
verify_manifest "${satori_dir}" "SHA256SUMS"

recog_xml_count="$(find "${recog_dir}/xml" -maxdepth 1 -type f -name '*.xml' | wc -l | tr -d '[:space:]')"
[[ "${recog_xml_count}" -gt 0 ]] || fail "Recog corpus XML directory is empty"

satori_xml_count="$(find "${satori_dir}/xml" -maxdepth 1 -type f -name '*.xml' | wc -l | tr -d '[:space:]')"
[[ "${satori_xml_count}" -gt 0 ]] || fail "Satori corpus XML directory is empty"

if grep -RInE 'include_(bytes|str)!\([^)]*netprobe_corpora/satori' rust/netprobe >"${tmp_embed}" 2>/dev/null; then
  cat "${tmp_embed}" >&2
  fail "Satori GPLv2 XML must be runtime-loaded as replaceable data, not embedded with include_bytes!/include_str!"
fi

if find rust/netprobe "${corpora_root}" -path '*/target/*' -prune -o -type f \
  \( -iname '*fingerbank*' -o -iname '*nmap*' -o -iname '*npsl*' -o -iname '*prads*' -o -iname '*ja4t*' -o -iname '*ja4h*' -o -iname '*ja4s*' -o -iname '*ja4ssh*' -o -iname '*ja4x*' \) \
  -print -quit | grep -q .; then
  find rust/netprobe "${corpora_root}" -path '*/target/*' -prune -o -type f \
    \( -iname '*fingerbank*' -o -iname '*nmap*' -o -iname '*npsl*' -o -iname '*prads*' -o -iname '*ja4t*' -o -iname '*ja4h*' -o -iname '*ja4s*' -o -iname '*ja4ssh*' -o -iname '*ja4x*' \) \
    -print >&2
  fail "forbidden or unreviewed fingerprint corpus/method file found under rust/netprobe or ${corpora_root}"
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

for crate in fingerbank nmap npsl prads; do
  if grep -E "(^|[^[:alnum:]_-])${crate} v[0-9]" "${tmp_tree}" >/dev/null; then
    echo "forbidden or unreviewed fingerprint dependency found in cargo tree: ${crate}" >&2
    grep -E "(^|[^[:alnum:]_-])${crate} v[0-9]" "${tmp_tree}" >&2
    exit 1
  fi
done

echo "netprobe fingerprint corpus and dependency license guard passed"
