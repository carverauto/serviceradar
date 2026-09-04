#!/usr/bin/env bash
set -euo pipefail

tinygo_bin=""
go_bin=""
go_darwin_arm64_bin=""
go_darwin_amd64_bin=""
go_linux_arm64_bin=""
go_linux_amd64_bin=""
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
    --go-bin)
      go_bin="$2"
      shift 2
      ;;
    --go-darwin-arm64)
      go_darwin_arm64_bin="$2"
      shift 2
      ;;
    --go-darwin-amd64)
      go_darwin_amd64_bin="$2"
      shift 2
      ;;
    --go-linux-arm64)
      go_linux_arm64_bin="$2"
      shift 2
      ;;
    --go-linux-amd64)
      go_linux_amd64_bin="$2"
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

preferred_go_for_host() {
  local os arch
  os="$(uname -s)"
  arch="$(uname -m)"

  case "${os}/${arch}" in
    Darwin/arm64)
      printf '%s\n' "${go_darwin_arm64_bin}"
      ;;
    Darwin/x86_64)
      printf '%s\n' "${go_darwin_amd64_bin}"
      ;;
    Linux/aarch64|Linux/arm64)
      printf '%s\n' "${go_linux_arm64_bin}"
      ;;
    Linux/x86_64|Linux/amd64)
      printf '%s\n' "${go_linux_amd64_bin}"
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

resolved_go_bin="$(resolve_relative_candidate "$(preferred_go_for_host)")"
if [[ -n "${resolved_go_bin}" ]]; then
  go_bin="${resolved_go_bin}"
fi

resolved_go_bin="$(resolve_relative_candidate "${go_bin}")"
if [[ -n "${resolved_go_bin}" ]]; then
  go_bin="${resolved_go_bin}"
  export GOROOT="$(cd "$(dirname "${go_bin}")/.." && pwd)"
  export PATH="$(dirname "${go_bin}"):${PATH}"
else
  for prefix in "${PWD}" "$(dirname "${PWD}")" "$(dirname "$(dirname "${PWD}")")"; do
    candidate="${prefix}/external/go_sdk/bin/go"
    if [[ -x "${candidate}" ]]; then
      export GOROOT="$(cd "$(dirname "${candidate}")/.." && pwd)"
      export PATH="$(dirname "${candidate}"):${PATH}"
      break
    fi
  done
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
export TINYGOROOT="${TINYGOROOT:-$(cd "$(dirname "${tinygo_bin}")/.." && pwd)}"

plugin_dir="$(cd "$(dirname "${main_go}")" && pwd)"
out="$(cd "$(dirname "${out}")" && pwd)/$(basename "${out}")"
mkdir -p "$(dirname "${out}")"

# Keep mutable Go and TinyGo state action-local. Interrupted sandboxed builds
# can otherwise leave shared module or WASI library trees present but incomplete.
tinygo_state_dir="$(mktemp -d "${TMPDIR:-/tmp}/serviceradar-tinygo-state.XXXXXX")"
cleanup_tinygo_state() {
  chmod -R u+w "${tinygo_state_dir}" 2>/dev/null || true
  rm -rf "${tinygo_state_dir}" || true
}
trap cleanup_tinygo_state EXIT
export HOME="${HOME:-${tinygo_state_dir}/home}"
export GOCACHE="${GOCACHE:-${tinygo_state_dir}/go-build}"
export GOMODCACHE="${GOMODCACHE:-${tinygo_state_dir}/go-mod}"
mkdir -p "${HOME}" "${GOCACHE}" "${GOMODCACHE}"

# serviceradar-sdk-go is not served by proxy.golang.org -- every version 404s on
# /@v/list, not just the newest -- so the module has to be fetched straight from
# GitHub and cannot be verified against sum.golang.org, whose lookup 404s for the
# same reason. Without this, tinygo's module load fails with
# "verifying module: ... 404 Not Found" and the wasm plugin genrules go red.
#
# This does NOT disable checksum verification. go.sum still records the hash for
# every module including this one, and a mismatch still fails the build; what
# GOPRIVATE changes is WHERE the expected hash comes from -- the committed go.sum
# rather than the public transparency log. That distinction is the whole reason
# the v0.3.0 breakage was caught: the checksum check did its job.
export GOFLAGS="${GOFLAGS:--mod=mod}"
export GOPRIVATE="${GOPRIVATE:-github.com/carverauto/*}"

cmd=(
  "${tinygo_bin}"
  build
  -o "${out}"
  -target=wasi
  -gc=conservative
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
