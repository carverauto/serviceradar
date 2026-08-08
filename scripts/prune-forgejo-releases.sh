#!/usr/bin/env bash
# Copyright 2026 Carver Automation Corporation.
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

# prune-forgejo-releases.sh — drop old fat release assets from Forgejo.
#
# Keeps the newest N "fat" releases (total attachment size above a threshold)
# for carverauto/serviceradar and deletes older ones. Git tags are left intact;
# only Forgejo release records + attached deb/rpm assets are removed.
#
# Usage:
#   FORGEJO_TOKEN=... scripts/prune-forgejo-releases.sh [--dry-run] [--keep N]
#
# Env:
#   FORGEJO_URL          default https://code.carverauto.dev
#   FORGEJO_REPOSITORY   default carverauto/serviceradar
#   FORGEJO_TOKEN / GITEA_TOKEN / GITHUB_TOKEN / GH_TOKEN  (required unless dry-run)
#   PRUNE_KEEP           default 10 (overridden by --keep)
#   PRUNE_MIN_BYTES      default 104857600 (100 MiB) — "fat" release threshold
#   PRUNE_DELETE_DRAFTS  default true — also delete draft fat releases outside keep set

set -euo pipefail

keep="${PRUNE_KEEP:-10}"
min_bytes="${PRUNE_MIN_BYTES:-104857600}"
delete_drafts="${PRUNE_DELETE_DRAFTS:-true}"
dry_run=false

usage() {
  cat <<'EOF' >&2
usage: prune-forgejo-releases.sh [--dry-run] [--keep N] [--min-bytes N] [--keep-drafts]

Keeps the newest N fat Forgejo releases (total assets > min-bytes) and deletes
older fat releases. Thin releases (sha-* tags, tiny assets) are left alone.
Git tags are never deleted.
EOF
  exit 2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      dry_run=true
      shift
      ;;
    --keep)
      keep="${2:?--keep requires a value}"
      shift 2
      ;;
    --min-bytes)
      min_bytes="${2:?--min-bytes requires a value}"
      shift 2
      ;;
    --keep-drafts)
      delete_drafts=false
      shift
      ;;
    -h|--help)
      usage
      ;;
    *)
      echo "unknown argument: $1" >&2
      usage
      ;;
  esac
done

if ! [[ "${keep}" =~ ^[0-9]+$ ]] || (( keep < 1 )); then
  echo "--keep must be a positive integer (got ${keep})" >&2
  exit 1
fi
if ! [[ "${min_bytes}" =~ ^[0-9]+$ ]]; then
  echo "--min-bytes must be a non-negative integer (got ${min_bytes})" >&2
  exit 1
fi

forgejo_url="${FORGEJO_URL:-https://code.carverauto.dev}"
forgejo_repo="${FORGEJO_REPOSITORY:-carverauto/serviceradar}"
forgejo_token="${FORGEJO_TOKEN:-${GITEA_TOKEN:-${GITHUB_TOKEN:-${GH_TOKEN:-}}}}"

if [[ -z "${forgejo_token}" && "${dry_run}" != "true" ]]; then
  echo "FORGEJO_TOKEN (or GITEA_TOKEN/GITHUB_TOKEN/GH_TOKEN) is required unless --dry-run" >&2
  exit 1
fi

auth_args=()
if [[ -n "${forgejo_token}" ]]; then
  auth_args=(-H "Authorization: token ${forgejo_token}")
fi

api() {
  local method="$1"
  local path="$2"
  shift 2
  curl -sS -X "${method}" \
    -H "Accept: application/json" \
    "${auth_args[@]}" \
    "${forgejo_url}/api/v1/repos/${forgejo_repo}${path}" \
    "$@"
}

# Paginate releases. Forgejo treats draft=true as "drafts only" and the default
# list as published-only, so we fetch both and merge by release id.
tmp_pages="$(mktemp -d)"
trap 'rm -rf "${tmp_pages}"' EXIT
page_idx=0
for draft_flag in false true; do
  page=1
  while true; do
    page_idx=$((page_idx + 1))
    page_file="${tmp_pages}/page-${page_idx}.json"
    api GET "/releases?draft=${draft_flag}&limit=50&page=${page}" >"${page_file}"
    count="$(jq 'length' <"${page_file}")"
    if [[ "${count}" == "0" ]]; then
      rm -f "${page_file}"
      break
    fi
    if (( count < 50 )); then
      break
    fi
    page=$((page + 1))
  done
done

shopt -s nullglob
page_files=("${tmp_pages}"/page-*.json)
shopt -u nullglob
if (( ${#page_files[@]} == 0 )); then
  releases_json='[]'
else
  # Deduplicate by id in case a release appears in both lists.
  releases_json="$(jq -s 'add | unique_by(.id)' "${page_files[@]}")"
fi

# Rank fat releases newest-first; emit id, tag, draft, size, rank.
mapfile -t fat_rows < <(
  jq -r --argjson min "${min_bytes}" '
    [.[]
      | select((.assets // []) | map(.size // 0) | add > $min)
      | {
          id,
          tag: .tag_name,
          draft: (.draft // false),
          created: (.created_at // .published_at // ""),
          bytes: ((.assets // []) | map(.size // 0) | add)
        }
    ]
    | sort_by(.created) | reverse
    | to_entries[]
    | [.value.id, .value.tag, (.value.draft|tostring), .value.bytes, (.key + 1)]
    | @tsv
  ' <<<"${releases_json}"
)

total_fat="${#fat_rows[@]}"
echo "Found ${total_fat} fat release(s) (assets > ${min_bytes} bytes); keeping newest ${keep}."

if (( total_fat == 0 )); then
  echo "Nothing to prune."
  exit 0
fi

deleted=0
kept=0
skipped=0

for row in "${fat_rows[@]}"; do
  IFS=$'\t' read -r id tag draft bytes rank <<<"${row}"
  size_mib=$(( bytes / 1024 / 1024 ))

  if (( rank <= keep )); then
    echo "KEEP  rank=${rank} tag=${tag} draft=${draft} size=${size_mib}MiB id=${id}"
    kept=$((kept + 1))
    continue
  fi

  if [[ "${draft}" == "true" && "${delete_drafts}" != "true" ]]; then
    echo "SKIP  draft tag=${tag} size=${size_mib}MiB id=${id} (--keep-drafts)"
    skipped=$((skipped + 1))
    continue
  fi

  if [[ "${dry_run}" == "true" ]]; then
    echo "DRY   delete tag=${tag} draft=${draft} size=${size_mib}MiB id=${id}"
    deleted=$((deleted + 1))
    continue
  fi

  code="$(
    curl -sS -o /tmp/prune-forgejo-del.out -w '%{http_code}' -X DELETE \
      -H "Accept: application/json" \
      "${auth_args[@]}" \
      "${forgejo_url}/api/v1/repos/${forgejo_repo}/releases/${id}"
  )"
  if [[ "${code}" == "204" || "${code}" == "200" || "${code}" == "404" ]]; then
    echo "DEL   tag=${tag} draft=${draft} size=${size_mib}MiB id=${id} http=${code}"
    deleted=$((deleted + 1))
  else
    echo "FAIL  tag=${tag} id=${id} http=${code} body=$(head -c 200 /tmp/prune-forgejo-del.out)" >&2
    exit 1
  fi
done

echo "Prune complete: kept=${kept} deleted=${deleted} skipped=${skipped} dry_run=${dry_run}"
