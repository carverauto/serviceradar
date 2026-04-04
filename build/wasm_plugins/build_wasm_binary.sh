#!/usr/bin/env bash
set -euo pipefail

tinygo_bin=""
tinygo_darwin_arm64_bin=""
tinygo_darwin_amd64_bin=""
tinygo_linux_arm64_bin=""
tinygo_linux_amd64_bin=""
main_go=""
out=""
tags_csv=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tinygo)
      tinygo_bin="$2"
      shift 2
      ;;
    --tinygo-darwin-arm64)
      tinygo_darwin_arm64_bin="$2"
      shift 2
      ;;
    --tinygo-darwin-amd64)
      tinygo_darwin_amd64_bin="$2"
      shift 2
      ;;
    --tinygo-linux-arm64)
      tinygo_linux_arm64_bin="$2"
      shift 2
      ;;
    --tinygo-linux-amd64)
      tinygo_linux_amd64_bin="$2"
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

resolve_relative_candidate() {
  local candidate="$1"
  if [[ -z "${candidate}" ]]; then
    return 0
  fi
  if [[ "${candidate}" != /* ]]; then
    candidate="${PWD}/${candidate}"
  fi
  if [[ -x "${candidate}" ]]; then
    printf '%s\n' "${candidate}"
  fi
}

preferred_tinygo_for_host() {
  local os arch
  os="$(uname -s)"
  arch="$(uname -m)"

  case "${os}/${arch}" in
    Darwin/arm64)
      printf '%s\n' "${tinygo_darwin_arm64_bin}"
      ;;
    Darwin/x86_64)
      printf '%s\n' "${tinygo_darwin_amd64_bin}"
      ;;
    Linux/aarch64|Linux/arm64)
      printf '%s\n' "${tinygo_linux_arm64_bin}"
      ;;
    Linux/x86_64|Linux/amd64)
      printf '%s\n' "${tinygo_linux_amd64_bin}"
      ;;
  esac
}

resolved_tinygo="$(resolve_relative_candidate "${tinygo_bin}")"
if [[ -n "${resolved_tinygo}" ]]; then
  tinygo_bin="${resolved_tinygo}"
else
  resolved_tinygo="$(resolve_relative_candidate "$(preferred_tinygo_for_host)")"
  if [[ -n "${resolved_tinygo}" ]]; then
    tinygo_bin="${resolved_tinygo}"
  fi
fi

if [[ "${tinygo_bin}" != /* ]]; then
  candidate="${PWD}/${tinygo_bin}"
  if [[ -x "${candidate}" ]]; then
    tinygo_bin="${candidate}"
  fi
fi

if [[ -z "${tinygo_bin}" || ! -x "${tinygo_bin}" ]]; then
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
