#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/elixir_quality.sh --project <path> [--phoenix]

Runs the repository-standard Elixir quality contract for a single Mix project.
EOF
}

project=""
phoenix="false"
skip_dialyzer="false"
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
run mix deps.compile
run mix format --check-formatted

if [[ "${skip_warnings_as_errors}" == "true" ]]; then
  run mix compile
else
  run mix compile --warnings-as-errors
fi
run mix xref graph --format stats --label compile-connected
run mix credo --strict
run mix hex.audit

if [[ "${skip_dialyzer}" != "true" ]]; then
  run mix dialyzer
fi

if [[ "${phoenix}" == "true" ]]; then
  run mix sobelow
fi

popd >/dev/null
