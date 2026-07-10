#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/elixir_quality.sh --project <path> [--phoenix] [--force-check-dialyzer]

Runs the repository-standard Elixir quality contract for a single Mix project.
EOF
}

project=""
phoenix="false"
skip_dialyzer="false"
force_check_dialyzer="false"
skip_credo="false"
skip_warnings_as_errors="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project)
      project="${2:-}"
      shift 2
      ;;
    --phoenix)
      phoenix="true"
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

if [[ -z "${project}" ]]; then
  echo "--project is required" >&2
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

pushd "${project}" >/dev/null

run mix deps.get

mix_env="${MIX_ENV:-dev}"
mix_build_path="${MIX_BUILD_PATH:-_build/${mix_env}}"
srql_build_path="${mix_build_path}/lib/serviceradar_srql"
core_build_path="${mix_build_path}/lib/serviceradar_core"
mix_dependencies="$(mix deps)"

# Restored BEAM caches can retain a priv symlink whose uncached NIF target is
# missing. Repair SRQL before compiling anything that may load core modules.
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

run mix deps.compile

run mix format --check-formatted

if [[ "${skip_warnings_as_errors}" == "true" ]]; then
  run mix compile --no-deps-check
else
  run mix compile --no-deps-check --warnings-as-errors
fi
run mix xref graph --format stats --label compile-connected
if [[ "${skip_credo}" != "true" ]]; then
  run mix credo --strict
fi

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

  printf '%s\n' "${output}" | awk -v ignore_file=".deps_audit_ignore" '
    BEGIN {
      while ((getline line < ignore_file) > 0) {
        sub(/#.*/, "", line)
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)

        if (line != "") {
          ignored[line] = 1
        }
      }
    }

    /^Retired:/ {
      flush_advisory()
      section = "retired"
      next
    }

    /^Advisories:/ {
      flush_advisory()
      section = "advisory"
      next
    }

    section == "retired" && /^  [^[:space:]]+ [^[:space:]]+ - / {
      package = $1

      if (!((package in ignored) || (("package:" package) in ignored) || (("retired:" package) in ignored))) {
        print "::error::unignored hex retired package: " package > "/dev/stderr"
        failed = 1
      }

      next
    }

    section == "advisory" && /^  [^[:space:]]+ [^[:space:]]+ - / {
      flush_advisory()
      advisory = $0
      next
    }

    section == "advisory" && advisory != "" {
      advisory = advisory "\n" $0
      next
    }

    END {
      flush_advisory()
      exit failed
    }

    function flush_advisory(  token, lines) {
      if (advisory == "") {
        return
      }

      for (token in ignored) {
        if (index(advisory, token) > 0) {
          advisory = ""
          return
        }
      }

      split(advisory, lines, "\n")
      print "::error::unignored hex advisory: " lines[1] > "/dev/stderr"
      failed = 1
      advisory = ""
    }
  '
}

run_hex_audit

if mix help deps.audit >/dev/null 2>&1; then
  run mix deps.audit "${deps_audit_args[@]}"
else
  echo
  echo "==> mix deps.audit unavailable; skipping dependency vulnerability audit"
fi

if [[ "${skip_dialyzer}" != "true" ]]; then
  dialyzer_args=()

  if [[ "${force_check_dialyzer}" == "true" ]]; then
    dialyzer_args+=(--force-check)
  fi

  run mix dialyzer "${dialyzer_args[@]}"
fi

if [[ "${phoenix}" == "true" ]]; then
  run mix sobelow
fi

popd >/dev/null
