#!/usr/bin/env bash
#
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
#
# Dependency vulnerability audit for every Elixir project in the workspace.
#
# This exists alongside the per-project audit in scripts/elixir_quality.sh, and
# closes two gaps that one cannot:
#
#   1. TIME. Pull-request Elixir Quality is format + Credo only. An advisory
#      published tomorrow against a dependency nobody touches is never
#      detected by a path-filtered PR gate. This script is meant to run
#      on a schedule, where the trigger is the calendar rather than a diff.
#
#   2. FAIL-OPEN. See ensure_advisory_db below. This is the important one.
#
# Projects are DISCOVERED rather than listed. The quality gate's seven hardcoded
# names happen to be complete today; this keeps them complete without anyone
# remembering to add the eighth.
#
# It deliberately does NOT compile anything. mix_audit reads mix.lock, so the
# whole workspace can be audited without a single dependency being built.

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"

# Pinned so a scheduled run cannot change tools underneath us without a commit.
# This does NOT pin the advisory data: MixAudit.Repo fetches that from git at
# runtime, so a pinned tool still sees today's advisories. That separation is
# what makes a scheduled run worth doing at all.
MIX_AUDIT_VERSION="${MIX_AUDIT_VERSION:-2.1.5}"

ADVISORY_REPO="https://github.com/mirego/elixir-security-advisories.git"
# Hardcoded in MixAudit.Repo.path/0; not configurable, so we mirror it exactly.
ADVISORY_DIR="${HOME}/.local/share/elixir-security-advisories-mirego"

# The canary. coherence is abandoned upstream (no release since 2019), is not a
# dependency of anything here, and its advisory has a closed version range that
# will never move. A synthetic lockfile pinning a vulnerable version therefore
# MUST produce a finding -- if it does not, the audit is broken, not clean.
CANARY_PACKAGE="coherence"
CANARY_VERSION="0.5.1"
CANARY_ADVISORY="GHSA-mrq8-53r4-3j5m"

usage() {
  cat <<'EOF'
Usage: scripts/elixir_dep_audit.sh [options]

Audits every Elixir project's mix.lock for known security advisories.

Options:
  --ensure-advisory-db   Fetch and self-test the advisory database, then exit.
                         Used by scripts/elixir_quality.sh to close the
                         fail-open hole before it trusts `mix deps.audit`.
  --with-retired         Also run `mix hex.audit` per project to report retired
                         packages. Requires `mix deps.get` per project, so it is
                         off by default and enabled for scheduled runs.
  --project <path>       Audit only this project (repeatable).
  -h, --help             Show this help.
EOF
}

ensure_only="false"
with_retired="false"
declare -a only_projects=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ensure-advisory-db) ensure_only="true"; shift ;;
    --with-retired) with_retired="true"; shift ;;
    --project) only_projects+=("${2:-}"); shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

log() { printf '%s\n' "$*"; }
group() { printf '::group::%s\n' "$*"; }
endgroup() { printf '::endgroup::\n'; }
err() { printf '::error::%s\n' "$*" >&2; }

# --- advisory database ------------------------------------------------------

# mix_audit's MixAudit.Repo.advisories/0 does:
#
#     System.cmd("git", ["pull", "--rebase", "--quiet", "origin", "main"])
#
# and ignores the result, then globs `packages/**/*.yml`. When the clone has
# never happened and the fetch fails, that glob returns [] -- zero advisories --
# and every project audits "clean" with exit 0. The failure mode is invisible:
# a green check that proves nothing was loaded, not that nothing was found.
#
# So: fetch with a CHECKED exit status, then prove the loaded database actually
# produces a finding for a package whose vulnerability is not in question. A
# count of .yml files is not enough -- it would pass with a database that parsed
# into nothing, or a tool whose matching broke.
ensure_advisory_db() {
  group "advisory database"

  if [[ -d "${ADVISORY_DIR}/.git" ]]; then
    log "==> refreshing ${ADVISORY_DIR}"
    if ! git -C "${ADVISORY_DIR}" fetch --quiet origin main ||
      ! git -C "${ADVISORY_DIR}" reset --quiet --hard origin/main; then
      err "could not refresh the advisory database from ${ADVISORY_REPO}"
      err "refusing to audit against a stale database; this is the failure mix_audit would have swallowed"
      endgroup
      return 1
    fi
  else
    log "==> cloning ${ADVISORY_REPO}"
    rm -rf "${ADVISORY_DIR}"
    mkdir -p "$(dirname "${ADVISORY_DIR}")"
    if ! git clone --quiet "${ADVISORY_REPO}" "${ADVISORY_DIR}"; then
      err "could not clone the advisory database from ${ADVISORY_REPO}"
      err "with no database, mix_audit reports every project clean; failing instead"
      endgroup
      return 1
    fi
  fi

  local count
  count="$(find "${ADVISORY_DIR}/packages" -name '*.yml' 2>/dev/null | wc -l | tr -d ' ')"
  log "==> ${count} advisories at $(git -C "${ADVISORY_DIR}" rev-parse --short HEAD)"

  if [[ "${count}" -eq 0 ]]; then
    err "advisory database is empty; every audit below would report a false clean"
    endgroup
    return 1
  fi

  ensure_mix_audit
  canary_self_test || { endgroup; return 1; }

  endgroup
}

mix_audit_bin=""

ensure_mix_audit() {
  if [[ -n "${mix_audit_bin}" ]]; then
    return 0
  fi

  local escripts="${MIX_HOME:-${HOME}/.mix}/escripts"

  if [[ ! -x "${escripts}/mix_audit" ]]; then
    log "==> installing mix_audit ${MIX_AUDIT_VERSION}"
    mix escript.install --force hex mix_audit "${MIX_AUDIT_VERSION}" >/dev/null
  fi

  mix_audit_bin="${escripts}/mix_audit"
}

# Proves the tool + database combination can still find a known vulnerability.
# Without this, "No vulnerabilities found." is unfalsifiable.
canary_self_test() {
  local dir
  dir="$(mktemp -d)"

  cat >"${dir}/mix.lock" <<EOF
%{
  "${CANARY_PACKAGE}": {:hex, :${CANARY_PACKAGE}, "${CANARY_VERSION}", "0", [:mix], [], "hexpm", "0"},
}
EOF

  local output
  output="$("${mix_audit_bin}" --path "${dir}" 2>&1 || true)"
  rm -rf "${dir}"

  if grep -q "${CANARY_ADVISORY}" <<<"${output}"; then
    log "==> self-test ok (${CANARY_PACKAGE} ${CANARY_VERSION} -> ${CANARY_ADVISORY})"
    return 0
  fi

  err "advisory self-test FAILED: ${CANARY_PACKAGE} ${CANARY_VERSION} should match ${CANARY_ADVISORY}"
  err "the audit cannot detect anything in this state; treat every clean result below as meaningless"
  printf '%s\n' "${output}" >&2
  return 1
}

# --- project discovery ------------------------------------------------------

discover_projects() {
  if [[ ${#only_projects[@]} -gt 0 ]]; then
    printf '%s\n' ${only_projects[@]+"${only_projects[@]}"}
    return
  fi

  find "${repo_root}/elixir" -maxdepth 2 -name mix.exs -print0 |
    xargs -0 -n1 dirname |
    sort
}

# --- audits -----------------------------------------------------------------

declare -a failed_projects=()
declare -a skipped_projects=()

audit_advisories() {
  local project="$1"
  local name
  name="$(basename "${project}")"

  if [[ ! -f "${project}/mix.lock" ]]; then
    log "-- ${name}: no mix.lock, nothing to audit"
    skipped_projects+=("${name}")
    return 0
  fi

  local -a args=(--path "${project}")
  if [[ -f "${project}/.deps_audit_ignore" ]]; then
    args+=(--ignore-file "${project}/.deps_audit_ignore")
  fi

  if "${mix_audit_bin}" "${args[@]}"; then
    log "-- ${name}: clean"
    return 0
  fi

  err "${name}: unwaived security advisory in mix.lock"
  failed_projects+=("${name}")
  return 0
}

audit_retired() {
  local project="$1"
  local name
  name="$(basename "${project}")"

  # hex.audit needs the dependency tree resolved on disk (it reports retirement
  # status per resolved dep), but NOT compiled.
  if ! (cd "${project}" && mix deps.get >/dev/null 2>&1); then
    err "${name}: mix deps.get failed; cannot check retired packages"
    failed_projects+=("${name}")
    return 0
  fi

  local output status
  set +e
  output="$(cd "${project}" && mix hex.audit 2>&1)"
  status=$?
  set -e

  if [[ "${status}" -eq 0 ]]; then
    log "-- ${name}: no retired packages"
    return 0
  fi

  if [[ ! -f "${project}/.deps_audit_ignore" ]]; then
    printf '%s\n' "${output}"
    err "${name}: retired package or advisory with no waiver file"
    failed_projects+=("${name}")
    return 0
  fi

  # Same filter the PR gate uses, so a waiver means the same thing in both.
  if printf '%s\n' "${output}" |
    awk -v ignore_file="${project}/.deps_audit_ignore" \
      -f "${repo_root}/scripts/lib/hex-audit-filter.awk"; then
    log "-- ${name}: retired packages all waived"
    return 0
  fi

  failed_projects+=("${name}")
  return 0
}

# --- main -------------------------------------------------------------------

ensure_advisory_db

if [[ "${ensure_only}" == "true" ]]; then
  exit 0
fi

# `mapfile` is bash 4+; macOS ships bash 3.2, where this script has to stay
# runnable by hand. Same reason scripts/elixir_quality.sh avoids bare `${a[@]}`.
projects=()
while IFS= read -r line; do
  [[ -n "${line}" ]] && projects+=("${line}")
done < <(discover_projects)

group "security advisories (mix.lock)"
for project in "${projects[@]}"; do
  audit_advisories "${project}"
done
endgroup

if [[ "${with_retired}" == "true" ]]; then
  group "retired packages (mix hex.audit)"
  for project in "${projects[@]}"; do
    audit_retired "${project}"
  done
  endgroup
fi

log ""
log "audited ${#projects[@]} project(s)"
if [[ ${#skipped_projects[@]} -gt 0 ]]; then
  log "skipped (no mix.lock): ${skipped_projects[*]-}"
fi

if [[ ${#failed_projects[@]} -gt 0 ]]; then
  err "dependency audit failed for: ${failed_projects[*]-}"
  exit 1
fi

log "all projects clean"
