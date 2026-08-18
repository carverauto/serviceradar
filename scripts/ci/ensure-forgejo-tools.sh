#!/usr/bin/env bash
set -euo pipefail

profile="${1:-base}"

missing=()

require_cmd() {
  local cmd="$1"
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    missing+=("${cmd}")
  fi
}

require_pkg_config() {
  local pkg="$1"
  if ! command -v pkg-config >/dev/null 2>&1 || ! pkg-config --exists "${pkg}"; then
    missing+=("pkg-config:${pkg}")
  fi
}

install_as_root() {
  if [[ "$(id -u)" != "0" ]]; then
    return 1
  fi

  if command -v apt-get >/dev/null 2>&1; then
    if [[ -x ./scripts/cleanup-ci-apt-sources.sh ]]; then
      ./scripts/cleanup-ci-apt-sources.sh
    fi
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$@"
    return 0
  fi

  return 1
}

ensure_base_build_tools() {
  require_cmd gcc
  require_cmd g++
  require_cmd make
  require_cmd pkg-config
  require_cmd protoc
  require_cmd cmake
  require_cmd flex
  require_cmd bison
  require_cmd file
  require_cmd readelf
  require_pkg_config libpcap
}

case "${profile}" in
  base|bazel-build)
    ensure_base_build_tools
    if ((${#missing[@]})); then
      install_as_root build-essential pkg-config libssl-dev libpcap-dev protobuf-compiler cmake flex bison file binutils || true
    fi
    ;;
  service-build)
    ensure_base_build_tools
    require_cmd rpmbuild
    require_cmd rpm2cpio
    require_cmd psql
    if ((${#missing[@]})); then
      install_as_root build-essential pkg-config libssl-dev libpcap-dev protobuf-compiler cmake flex bison file binutils rpm rpm2cpio postgresql-client || true
    fi
    ;;
  skopeo)
    require_cmd skopeo
    if ((${#missing[@]})); then
      install_as_root skopeo || true
    fi
    if ! command -v skopeo >/dev/null 2>&1 && [[ -x ./scripts/install-skopeo.sh ]]; then
      ./scripts/install-skopeo.sh
      missing=()
    fi
    ;;
  *)
    echo "unknown tool profile: ${profile}" >&2
    exit 2
    ;;
esac

missing=()
case "${profile}" in
  base|bazel-build)
    ensure_base_build_tools
    ;;
  service-build)
    ensure_base_build_tools
    require_cmd rpmbuild
    require_cmd rpm2cpio
    require_cmd psql
    ;;
  skopeo)
    require_cmd skopeo
    ;;
esac

if ((${#missing[@]})); then
  printf 'missing required CI tools for profile %s:' "${profile}" >&2
  printf ' %s' "${missing[@]}" >&2
  printf '\n' >&2
  if [[ "$(id -u)" != "0" ]]; then
    echo "This job is running non-root; rebuild the Forgejo CI image with the missing tools instead of installing them at runtime." >&2
  fi
  exit 1
fi
