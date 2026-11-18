#!/usr/bin/env bash
#
# Attach this run's signing ledger to the draft GitHub release of a tag run:
#
#   attach-signing-ledger.sh <ledger path> <release tag>
#
# The workflow artifact (retained 90 days) is the copy the transparency-log monitor
# reads; this release asset is the long-lived forensic record. A published release is
# immutable, so a re-run after publication keeps only the artifact and says so.

set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "usage: $0 <ledger path> <release tag>" >&2
  exit 2
fi

ledger="$1"
release_tag="$2"
token="${GITHUB_TOKEN:-${GH_TOKEN:-}}"

if [[ ! -s "${ledger}" ]]; then
  echo "No signatures were recorded in this run; no signing ledger to attach."
  exit 0
fi
if [[ -z "${token}" ]]; then
  echo "error: GITHUB_TOKEN or GH_TOKEN is required to attach the signing ledger" >&2
  exit 1
fi

workflow_file="${GITHUB_WORKFLOW_REF:-${GITHUB_WORKFLOW:-workflow}}"
workflow_file="${workflow_file%%@*}"
workflow_file="${workflow_file##*/}"
workflow_file="${workflow_file%.yml}"
asset_name="signing-ledger-${workflow_file}-${GITHUB_JOB:-job}-${GITHUB_RUN_ID:?}-${GITHUB_RUN_ATTEMPT:?}.jsonl"
api_base="https://api.github.com/repos/${GITHUB_REPOSITORY:?}"
gh_headers=(
  -H "Accept: application/vnd.github+json"
  -H "Authorization: Bearer ${token}"
  -H "X-GitHub-Api-Version: 2022-11-28"
)

# /releases/tags/{tag} hides drafts, so list first.
release_json="$(curl -sSf "${gh_headers[@]}" "${api_base}/releases?per_page=100" \
  | jq -c --arg tag "${release_tag}" 'first(.[] | select(.tag_name == $tag)) // empty')"
if [[ -z "${release_json}" ]]; then
  echo "warning: no release ${release_tag} yet; the signing ledger is kept as a workflow artifact only" >&2
  exit 0
fi
if [[ "$(jq -r '.draft' <<<"${release_json}")" != "true" ]]; then
  echo "warning: release ${release_tag} is published and immutable; the signing ledger is kept as a workflow artifact only" >&2
  exit 0
fi

release_id="$(jq -r '.id' <<<"${release_json}")"
existing_asset_id="$(jq -r --arg name "${asset_name}" '.assets[]? | select(.name == $name) | .id' <<<"${release_json}" | head -n1)"
if [[ -n "${existing_asset_id}" ]]; then
  curl -sSf -X DELETE "${gh_headers[@]}" "${api_base}/releases/assets/${existing_asset_id}" >/dev/null
fi

curl -sSf -X POST "${gh_headers[@]}" \
  -H "Content-Type: application/x-ndjson" \
  --data-binary "@${ledger}" \
  "https://uploads.github.com/repos/${GITHUB_REPOSITORY}/releases/${release_id}/assets?name=${asset_name}" >/dev/null
echo "Attached ${asset_name} to draft release ${release_tag}."
