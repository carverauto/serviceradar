#!/usr/bin/env bash
set -euo pipefail

if [[ "$#" -lt 1 || "$#" -gt 2 ]]; then
  echo "usage: $0 <release-tag> [commit-ish]" >&2
  exit 1
fi

tag="$1"
tag_ref="refs/tags/${tag}"
source_ref="${2:-${tag_ref}}"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

"${script_dir}/validate-release-tag.sh" "${tag}"

if ! tag_commit="$(git rev-parse --verify "${tag_ref}^{commit}" 2>/dev/null)"; then
  echo "release tag does not resolve to a commit: ${tag}" >&2
  exit 1
fi

if ! release_commit="$(git rev-parse --verify "${source_ref}^{commit}" 2>/dev/null)"; then
  echo "release source does not resolve to a commit: ${source_ref}" >&2
  exit 1
fi
if [[ "${release_commit}" != "${tag_commit}" ]]; then
  echo "release source ${release_commit} is not the target of ${tag} (${tag_commit})" >&2
  exit 1
fi

read_release_file() {
  local path="$1"
  local value

  if ! value="$(git show "${release_commit}:${path}" 2>/dev/null)"; then
    echo "release source ${release_commit} is missing ${path}" >&2
    return 1
  fi

  printf '%s' "${value}"
}

strip_yaml_scalar_quotes() {
  local value="$1"
  value="${value#\"}"
  value="${value%\"}"
  value="${value#\'}"
  value="${value%\'}"
  printf '%s' "${value}"
}

expected_version="${tag#v}"
file_version="$(read_release_file VERSION)"
if [[ "${file_version}" == *$'\n'* || "${file_version}" == *$'\r'* ]]; then
  echo "VERSION must contain exactly one line at ${release_commit}" >&2
  exit 1
fi

chart_yaml="$(read_release_file helm/serviceradar/Chart.yaml)"
chart_version="$(
  awk '$1 == "version:" { print $2; exit }' <<<"${chart_yaml}"
)"
chart_app_version="$(
  awk '$1 == "appVersion:" { print $2; exit }' <<<"${chart_yaml}"
)"
chart_version="$(strip_yaml_scalar_quotes "${chart_version}")"
chart_app_version="$(strip_yaml_scalar_quotes "${chart_app_version}")"

if [[ -z "${file_version}" || -z "${chart_version}" || -z "${chart_app_version}" ]]; then
  echo "release metadata is incomplete at ${release_commit}" >&2
  echo "VERSION=${file_version:-<missing>} chart.version=${chart_version:-<missing>} chart.appVersion=${chart_app_version:-<missing>}" >&2
  exit 1
fi

if [[ "${file_version}" != "${expected_version}" ]]; then
  echo "VERSION (${file_version}) does not match release tag ${tag} (${expected_version})" >&2
  exit 1
fi
if [[ "${chart_version}" != "${expected_version}" ]]; then
  echo "Helm chart version (${chart_version}) does not match release tag ${tag} (${expected_version})" >&2
  exit 1
fi
if [[ "${chart_app_version}" != "${expected_version}" ]]; then
  echo "Helm appVersion (${chart_app_version}) does not match release tag ${tag} (${expected_version})" >&2
  exit 1
fi

printf 'tag=%s\nversion=%s\ncommit=%s\n' "${tag}" "${expected_version}" "${release_commit}"
