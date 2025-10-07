#!/usr/bin/env bash
# Build Kong OSS packages from a pinned upstream commit and stage them into
# packaging/kong/vendor for inclusion in ServiceRadar packages.

set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
KONG_REMOTE="${KONG_REMOTE:-https://github.com/Kong/kong.git}"
KONG_COMMIT="${KONG_COMMIT:-21b0fbaafbfe835afa8998b415628610aa533cb4}"
KONG_CLONE_DIR="${KONG_CLONE_DIR:-${ROOT_DIR}/.cache/kong-source}"
VENDOR_DIR="${KONG_VENDOR_DIR:-${ROOT_DIR}/packaging/kong/vendor}"
BUILD_NAME="${KONG_BUILD_NAME:-kong-release}"
INSTALL_DESTDIR="${KONG_INSTALL_DESTDIR:-/usr/local}"

COMMON_FLAGS=(
  "--config" "release"
  "--//:licensing=false"
  "--//:skip_webui=true"
  "--action_env=BUILD_NAME=${BUILD_NAME}"
  "--action_env=INSTALL_DESTDIR=${INSTALL_DESTDIR}"
)

info() {
  echo "[kong] $*"
}

trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

ensure_clone() {
  mkdir -p "$(dirname "${KONG_CLONE_DIR}")"
  if [[ -d "${KONG_CLONE_DIR}/.git" ]]; then
    info "Updating existing clone in ${KONG_CLONE_DIR}" >&2
    git -C "${KONG_CLONE_DIR}" fetch --tags origin "${KONG_COMMIT}" >/dev/null
  else
    info "Cloning Kong from ${KONG_REMOTE} into ${KONG_CLONE_DIR}" >&2
    git clone "${KONG_REMOTE}" "${KONG_CLONE_DIR}" >/dev/null
    git -C "${KONG_CLONE_DIR}" fetch --tags origin "${KONG_COMMIT}" >/dev/null
  fi

  git -C "${KONG_CLONE_DIR}" reset --hard "${KONG_COMMIT}" >/dev/null
  git -C "${KONG_CLONE_DIR}" clean -fdx >/dev/null
}

ensure_bazel() {
  local bazel_bin="${KONG_CLONE_DIR}/bin/bazel"
  if [[ -x "${bazel_bin}" ]]; then
    info "Using existing bazel wrapper at ${bazel_bin}" >&2
    printf '%s\n' "${bazel_bin}"
    return
  fi

  if ! command -v make >/dev/null 2>&1; then
    echo "[kong] make is required to bootstrap bazelisk" >&2
    exit 1
  fi
  info "Installing bazelisk wrapper via make check-bazel" >&2
  (cd "${KONG_CLONE_DIR}" && make check-bazel >/dev/null)
  if [[ ! -x "${bazel_bin}" ]]; then
    echo "[kong] Failed to provision kong/bin/bazel" >&2
    exit 1
  fi
  printf '%s\n' "${bazel_bin}"
}

run_bazel() {
  local bazel_bin="$1"; shift
  local desc="$1"; shift
  info "$desc"
  (cd "${KONG_CLONE_DIR}" && "${bazel_bin}" build "${COMMON_FLAGS[@]}" "$@")
}

kong_version() {
  if [[ -n "${KONG_VERSION_OVERRIDE:-}" ]]; then
    trim "$KONG_VERSION_OVERRIDE"
    return
  fi
  local script="${KONG_CLONE_DIR}/scripts/grep-kong-version.sh"
  if [[ ! -x "$script" ]]; then
    echo "[kong] Unable to locate ${script}" >&2
    exit 1
  fi
  local version
  version=$(cd "${KONG_CLONE_DIR}" && ./scripts/grep-kong-version.sh)
  trim "$version"
}

map_destination_name() {
  local filename="$1"
  local version="$2"
  case "$filename" in
    kong.amd64.deb) printf 'kong_%s_amd64.deb' "$version" ;;
    kong.arm64.deb) printf 'kong_%s_arm64.deb' "$version" ;;
    kong.el8.amd64.rpm) printf 'kong-%s.el8.amd64.rpm' "$version" ;;
    kong.el8.aarch64.rpm) printf 'kong-%s.el8.aarch64.rpm' "$version" ;;
    kong.el9.amd64.rpm) printf 'kong-%s.el9.amd64.rpm' "$version" ;;
    kong.el9.aarch64.rpm) printf 'kong-%s.el9.aarch64.rpm' "$version" ;;
    *) printf 'kong-%s-%s' "$version" "${filename#kong.}" ;;
  esac
}

stage_artifacts() {
  local version="$1"
  local bazel_out="${KONG_CLONE_DIR}/bazel-bin/pkg"
  if [[ ! -d "$bazel_out" ]]; then
    echo "[kong] Expected Bazel output directory ${bazel_out} not found." >&2
    exit 1
  fi

  mkdir -p "${VENDOR_DIR}"
  find "${VENDOR_DIR}" -maxdepth 1 -type f \( -name 'kong*.rpm' -o -name 'kong*.deb' \) \
    ! -name 'kong-enterprise*' -delete

  local -a staged=()
  while IFS= read -r -d '' artifact; do
    local base dest
    base="$(basename "$artifact")"
    dest="$(map_destination_name "$base" "$version")"
    cp "$artifact" "${VENDOR_DIR}/${dest}"
    staged+=("${dest}")
  done < <(find "$bazel_out" -maxdepth 1 -type f \( -name 'kong*.rpm' -o -name 'kong*.deb' \) -print0)

  if (( ${#staged[@]} == 0 )); then
    echo "[kong] No kong artifacts were produced under ${bazel_out}." >&2
    exit 1
  fi

  info "Staged ${#staged[@]} artifact(s) into ${VENDOR_DIR}:"
  for artifact in "${staged[@]}"; do
    local path="${VENDOR_DIR}/${artifact}"
    local size checksum
    size=$(du -h "$path" | awk '{print $1}')
    checksum=$(sha256sum "$path" | awk '{print $1}')
    printf '         - %s (%s, sha256=%s)\n' "$artifact" "$size" "$checksum"
  done
}

main() {
  ensure_clone
  local bazel_bin
  bazel_bin=$(ensure_bazel)

  if [[ -n "${KONG_EXTRA_BAZEL_FLAGS:-}" ]]; then
    # shellcheck disable=SC2206
    EXTRA_FLAGS=( ${KONG_EXTRA_BAZEL_FLAGS} )
    COMMON_FLAGS+=("${EXTRA_FLAGS[@]}")
  fi

  run_bazel "${bazel_bin}" "Building Kong runtime prerequisites" "//build:kong"
  run_bazel "${bazel_bin}" "Building Kong Debian/RPM packages" \
    ":kong_deb" ":kong_el9" ":kong_el8"

  local version
  version=$(kong_version)
  if [[ -z "$version" ]]; then
    echo "[kong] Unable to determine Kong version" >&2
    exit 1
  fi

  stage_artifacts "$version"
}

main "$@"
