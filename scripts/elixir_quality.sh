#!/usr/bin/env bash

set -euo pipefail

# First-party Mix projects under elixir/. Keep in step with Makefile
# ELIXIR_PROJECTS and .github/workflows/elixir-quality.yml.
workspace_projects=(
  elixir/datasvc
  elixir/palisade
  elixir/serviceradar_agent_gateway
  elixir/serviceradar_core
  elixir/serviceradar_core_elx
  elixir/serviceradar_srql
  elixir/web-ng
)

usage() {
  cat <<'EOF'
Usage: scripts/elixir_quality.sh --project <path> [--phoenix] [options]
       scripts/elixir_quality.sh --all [options]

Runs the repository-standard Elixir quality contract for a Mix project.

Options:
  --project <path>              Single Mix project (e.g. elixir/web-ng)
  --all                         Every first-party Mix project under elixir/
  --phoenix                     Also run mix sobelow (Phoenix apps)
  --lint-only                   PR gate: mix format --check-formatted and
                                mix credo --strict. Skips compile, xref,
                                audits, Dialyzer, Sobelow, and NIF builds.
  --skip-audit                  Skip mix hex.audit and mix deps.audit
  --skip-compile                Skip mix compile and mix xref
  --skip-nif                    Skip Rustler NIF compilation
  --skip-dialyzer               Skip mix dialyzer
  --force-check-dialyzer        Pass --force-check to mix dialyzer
  --skip-credo                  Skip mix credo --strict
  --skip-warnings-as-errors     mix compile without --warnings-as-errors
EOF
}

project=""
all_projects="false"
phoenix="false"
lint_only="false"
skip_dialyzer="false"
force_check_dialyzer="false"
skip_credo="false"
skip_warnings_as_errors="false"
skip_audit="false"
skip_compile="false"
skip_nif="false"
skip_sobelow="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project)
      project="${2:-}"
      shift 2
      ;;
    --all)
      all_projects="true"
      shift
      ;;
    --phoenix)
      phoenix="true"
      shift
      ;;
    --lint-only)
      lint_only="true"
      skip_dialyzer="true"
      skip_audit="true"
      skip_compile="true"
      skip_nif="true"
      skip_sobelow="true"
      shift
      ;;
    --skip-audit)
      skip_audit="true"
      shift
      ;;
    --skip-compile)
      skip_compile="true"
      skip_nif="true"
      shift
      ;;
    --skip-nif)
      skip_nif="true"
      shift
      ;;
    --skip-dialyzer)
      skip_dialyzer="true"
      shift
      ;;
    --force-check-dialyzer)
      force_check_dialyzer="true"
      shift
      ;;
    --skip-credo)
      skip_credo="true"
      shift
      ;;
    --skip-warnings-as-errors)
      skip_warnings_as_errors="true"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"

if [[ "${all_projects}" == "true" ]]; then
  if [[ -n "${project}" ]]; then
    echo "--all and --project cannot be combined" >&2
    exit 1
  fi

  child_args=()
  if [[ "${lint_only}" == "true" ]]; then
    child_args+=(--lint-only)
  else
    [[ "${skip_audit}" == "true" ]] && child_args+=(--skip-audit)
    [[ "${skip_compile}" == "true" ]] && child_args+=(--skip-compile)
    [[ "${skip_nif}" == "true" ]] && child_args+=(--skip-nif)
    [[ "${skip_dialyzer}" == "true" ]] && child_args+=(--skip-dialyzer)
    [[ "${force_check_dialyzer}" == "true" ]] && child_args+=(--force-check-dialyzer)
    [[ "${skip_credo}" == "true" ]] && child_args+=(--skip-credo)
    [[ "${skip_warnings_as_errors}" == "true" ]] && child_args+=(--skip-warnings-as-errors)
  fi

  status=0
  for workspace_project in "${workspace_projects[@]}"; do
    args=(--project "${workspace_project}")
    if [[ "${workspace_project}" == "elixir/web-ng" ]]; then
      args+=(--phoenix)
    fi
    if [[ ${#child_args[@]} -gt 0 ]]; then
      args+=("${child_args[@]}")
    fi

    echo
    echo "======== ${workspace_project} ========"
    if ! "${script_dir}/elixir_quality.sh" "${args[@]}"; then
      status=1
    fi
  done
  exit "${status}"
fi

if [[ -z "${project}" ]]; then
  echo "--project is required (or pass --all)" >&2
  usage >&2
  exit 1
fi

if [[ ! -d "${project}" ]]; then
  echo "Project directory not found: ${project}" >&2
  exit 1
fi

run() {
  echo
  echo "==> $*"
  "$@"
}

if [[ "${skip_nif}" == "true" ]]; then
  export SERVICERADAR_SKIP_NIF_COMPILATION=1
fi

pushd "${project}" >/dev/null

run mix deps.get

mix_env="${MIX_ENV:-dev}"
mix_build_path="${MIX_BUILD_PATH:-_build/${mix_env}}"
srql_build_path="${mix_build_path}/lib/serviceradar_srql"
core_build_path="${mix_build_path}/lib/serviceradar_core"
mix_dependencies="$(mix deps)"

# Restored BEAM caches can retain a priv symlink whose uncached NIF target is
# missing. Repair SRQL before compiling anything that may load core modules.
# Lint-only / --skip-nif never loads those NIFs, so a dangling symlink is not
# a reason to force a cargo rebuild.
if [[ "${skip_nif}" != "true" ]]; then
  if grep -q '^\* serviceradar_srql ' <<<"${mix_dependencies}" &&
    { [[ -d "${srql_build_path}" ]] || [[ -d "${core_build_path}" ]]; } &&
    [[ ! -f "${srql_build_path}/priv/native/srql_nif.so" ]]; then
    run mix deps.compile serviceradar_srql --force --include-children
  fi

  if grep -q '^\* serviceradar_core ' <<<"${mix_dependencies}" &&
    [[ -d "${core_build_path}" ]] &&
    { [[ ! -f "${core_build_path}/priv/native/anomaly_disposition_nif.so" ]] ||
      [[ ! -f "${core_build_path}/priv/native/zen_nif.so" ]]; }; then
    run mix deps.compile serviceradar_core --force
  fi
fi

run mix deps.compile

run mix format --check-formatted

if [[ "${skip_compile}" != "true" ]]; then
  if [[ "${skip_warnings_as_errors}" == "true" ]]; then
    run mix compile --no-deps-check
  else
    run mix compile --no-deps-check --warnings-as-errors
  fi
  run mix xref graph --format stats --label compile-connected
fi

if [[ "${skip_credo}" != "true" ]]; then
  run mix credo --strict
fi

if [[ "${skip_audit}" != "true" ]]; then
  deps_audit_args=()
  if [[ -f ".deps_audit_ignore" ]]; then
    deps_audit_args+=(--ignore-file .deps_audit_ignore)
  fi

  run_hex_audit() {
    echo
    echo "==> mix hex.audit"

    local output
    local status

    set +e
    output="$(mix hex.audit 2>&1)"
    status=$?
    set -e

    printf '%s\n' "${output}"

    if [[ "${status}" -eq 0 ]]; then
      return 0
    fi

    if [[ ! -f ".deps_audit_ignore" ]]; then
      return "${status}"
    fi

    printf '%s\n' "${output}" | awk -v ignore_file=".deps_audit_ignore" \
      -f "${repo_root}/scripts/lib/hex-audit-filter.awk"
  }

  run_hex_audit

  if mix help deps.audit >/dev/null 2>&1; then
    # mix deps.audit FAILS OPEN. MixAudit.Repo clones/pulls the advisory database
    # at runtime and discards git's exit status; if the fetch fails and nothing is
    # cached, Path.wildcard returns [] and the audit reports "No vulnerabilities
    # found." with exit 0. On a fresh CI runner that turns one network blip into a
    # silently green security gate. Fetch it ourselves with a checked status, and
    # prove it actually matches, before believing a clean result.
    run "${repo_root}/scripts/elixir_dep_audit.sh" --ensure-advisory-db

    # ${deps_audit_args[@]+...} keeps `set -u` happy when the project has no
    # .deps_audit_ignore and the array is empty. Bash 4.4+ allows the bare
    # expansion, but macOS ships bash 3.2, where it aborts with "unbound
    # variable" -- which made this gate unrunnable locally on a Mac for exactly
    # the projects that have mix_audit but no waiver file. Same idiom as
    # scripts/lint-rust.sh.
    run mix deps.audit ${deps_audit_args[@]+"${deps_audit_args[@]}"}
  else
    echo
    echo "==> mix deps.audit unavailable; skipping dependency vulnerability audit"
  fi
fi

if [[ "${skip_dialyzer}" != "true" ]]; then
  dialyzer_args=()

  if [[ "${force_check_dialyzer}" == "true" ]]; then
    dialyzer_args+=(--force-check)
  fi

  run mix dialyzer "${dialyzer_args[@]}"
fi

if [[ "${phoenix}" == "true" && "${skip_sobelow}" != "true" ]]; then
  run mix sobelow
fi

popd >/dev/null
