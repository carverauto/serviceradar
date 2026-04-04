#!/usr/bin/env bash
set -euo pipefail

tinygo_bin=""
main_go=""
out=""
tags_csv=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tinygo)
      tinygo_bin="$2"
      shift 2
      ;;
    --main-go)
      main_go="$2"
      shift 2
      ;;
    --out)
      out="$2"
      shift 2
      ;;
    --tags)
      tags_csv="$2"
      shift 2
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

[[ -n "${tinygo_bin}" ]] || { echo "error: --tinygo is required" >&2; exit 1; }
[[ -n "${main_go}" ]] || { echo "error: --main-go is required" >&2; exit 1; }
[[ -n "${out}" ]] || { echo "error: --out is required" >&2; exit 1; }

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:${PATH:-}"

for prefix in "${PWD}" "$(dirname "${PWD}")" "$(dirname "$(dirname "${PWD}")")"; do
  candidate="${prefix}/external/rules_go++go_sdk+go_sdk/bin/go"
  if [[ -x "${candidate}" ]]; then
    export GOROOT="$(cd "$(dirname "${candidate}")/.." && pwd)"
    export PATH="$(dirname "${candidate}"):${PATH}"
    break
  fi
done

resolve_from_host() {
  command -v "$1" 2>/dev/null || true
}

local_tinygo="$(resolve_from_host tinygo)"
if [[ -z "${local_tinygo}" ]]; then
  for candidate in /opt/homebrew/bin/tinygo /usr/local/bin/tinygo "${HOME:-}/bin/tinygo"; do
    if [[ -x "${candidate}" ]]; then
      local_tinygo="${candidate}"
      break
    fi
  done
fi

if [[ -n "${local_tinygo}" && -x "${local_tinygo}" ]]; then
  tinygo_bin="${local_tinygo}"
elif [[ "${tinygo_bin}" != /* ]]; then
  candidate="${PWD}/${tinygo_bin}"
  if [[ -x "${candidate}" ]]; then
    tinygo_bin="${candidate}"
  fi
fi

if [[ -z "${tinygo_bin}" || ! -x "${tinygo_bin}" ]]; then
  echo "error: unable to resolve a runnable tinygo binary" >&2
  exit 1
fi

plugin_dir="$(cd "$(dirname "${main_go}")" && pwd)"
out="$(cd "$(dirname "${out}")" && pwd)/$(basename "${out}")"
mkdir -p "$(dirname "${out}")"

gocache_dir="${TMPDIR:-/tmp}/serviceradar-tinygo-gocache"
mkdir -p "${gocache_dir}"
export GOCACHE="${GOCACHE:-${gocache_dir}}"
home_dir="${TMPDIR:-/tmp}/serviceradar-tinygo-home"
mkdir -p "${home_dir}"
export HOME="${HOME:-${home_dir}}"

cmd=(
  "${tinygo_bin}"
  build
  -o "${out}"
  -target=wasi
  -gc=leaking
  -scheduler=none
  -no-debug
)

if [[ -n "${tags_csv}" ]]; then
  cmd+=(-tags "${tags_csv}")
fi

(
  cd "${plugin_dir}"
  "${cmd[@]}" ./
)
