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
DEFAULT_BAZELISK_VERSION="1.25.0"

COMMON_FLAGS=(
  "--config" "release"
  "--//:licensing=false"
  "--//:skip_webui=true"
  "--action_env=BUILD_NAME=${BUILD_NAME}"
  "--action_env=INSTALL_DESTDIR=${INSTALL_DESTDIR}"
  "--verbose_failures"
  "--repo_env=PATH=${PATH}"
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

bazelisk_version_from_kong() {
  local version_line version
  version_line=$(grep -Em1 '^[[:space:]]*BAZEL?ISK_VERSION' "${KONG_CLONE_DIR}/Makefile" 2>/dev/null || true)
  if [[ -n "$version_line" ]]; then
    version=$(trim "${version_line#*=}")
  fi
  printf '%s' "${version:-${DEFAULT_BAZELISK_VERSION}}"
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

ensure_cc() {
  if command -v "${CC:-}" >/dev/null 2>&1; then
    info "Using C compiler from CC=${CC}" >&2
    return
  fi

  if command -v gcc >/dev/null 2>&1; then
    CC="$(command -v gcc)"
    export CC
    info "Using gcc at ${CC}" >&2
    return
  fi

  if command -v clang >/dev/null 2>&1; then
    CC="$(command -v clang)"
    export CC
    info "Using clang at ${CC}" >&2
    return
  fi

  if command -v cc >/dev/null 2>&1; then
    CC="$(command -v cc)"
    export CC
    info "Using cc at ${CC}" >&2
    return
  fi

  if command -v apt-get >/dev/null 2>&1; then
    info "Installing gcc via apt-get (build-essential)" >&2
    if command -v sudo >/dev/null 2>&1; then
      sudo apt-get update -y >/dev/null
      sudo apt-get install -y build-essential >/dev/null
    else
      apt-get update -y >/dev/null
      apt-get install -y build-essential >/dev/null
    fi
    if command -v gcc >/dev/null 2>&1; then
      CC="$(command -v gcc)"
      export CC
      info "Using gcc at ${CC}" >&2
      return
    fi
  fi

  if command -v yum >/dev/null 2>&1; then
    info "Installing gcc via yum" >&2
    yum install -y gcc >/dev/null
    if command -v gcc >/dev/null 2>&1; then
      CC="$(command -v gcc)"
      export CC
      info "Using gcc at ${CC}" >&2
      return
    fi
  fi

  if command -v dnf >/dev/null 2>&1; then
    info "Installing gcc via dnf" >&2
    dnf install -y gcc >/dev/null
    if command -v gcc >/dev/null 2>&1; then
      CC="$(command -v gcc)"
      export CC
      info "Using gcc at ${CC}" >&2
      return
    fi
  fi

  if command -v apk >/dev/null 2>&1; then
    info "Installing gcc via apk" >&2
    apk add --no-progress --update gcc build-base >/dev/null
    if command -v gcc >/dev/null 2>&1; then
      CC="$(command -v gcc)"
      export CC
      info "Using gcc at ${CC}" >&2
      return
    fi
  fi

  echo "[kong] No C compiler found (gcc/clang/cc). Install one or set CC before running this script." >&2
  exit 1
}

ensure_zlib() {
  if pkg-config --exists zlib 2>/dev/null || [[ -f /usr/include/zlib.h || -f /usr/local/include/zlib.h ]]; then
    info "Found zlib development files" >&2
    return
  fi

  if command -v apt-get >/dev/null 2>&1; then
    info "Installing zlib via apt-get (zlib1g-dev)" >&2
    if command -v sudo >/dev/null 2>&1; then
      sudo apt-get update -y >/dev/null
      sudo apt-get install -y zlib1g-dev >/dev/null
    else
      apt-get update -y >/dev/null
      apt-get install -y zlib1g-dev >/dev/null
    fi
    return
  fi

  if command -v yum >/dev/null 2>&1; then
    info "Installing zlib via yum (zlib-devel)" >&2
    yum install -y zlib-devel >/dev/null
    return
  fi

  if command -v dnf >/dev/null 2>&1; then
    info "Installing zlib via dnf (zlib-devel)" >&2
    dnf install -y zlib-devel >/dev/null
    return
  fi

  if command -v apk >/dev/null 2>&1; then
    info "Installing zlib via apk (zlib-dev)" >&2
    apk add --no-progress --update zlib-dev >/dev/null
    return
  fi

  echo "[kong] zlib development headers not found. Install zlib-dev (or equivalent) or supply pkg-config zlib before running." >&2
  exit 1
}

configure_remote_exec() {
  if [[ -z "${BUILDBUDDY_ORG_API_KEY:-}" ]]; then
    return
  fi

  REMOTE_CONFIGURED=1
  local remote_rc="${KONG_CLONE_DIR}/.bazelrc.remote"
  info "Configuring BuildBuddy remote execution for Kong build" >&2
  umask 077
  cat <<'EOF' > "${remote_rc}"
build --bes_results_url=https://carverauto.buildbuddy.io/invocation/
build --bes_backend=grpcs://carverauto.buildbuddy.io
build --remote_cache=grpcs://carverauto.buildbuddy.io
build --remote_executor=grpcs://carverauto.buildbuddy.io
build --remote_timeout=10m
build --remote_download_minimal
build --remote_upload_local_results
build --jobs=100
build --strategy=ExpandTemplate=local
build --strategy=NpmPackageExtract=local
build --strategy=CopyDirectory=local
EOF
  printf 'common --remote_header=x-buildbuddy-api-key=%s\n' "${BUILDBUDDY_ORG_API_KEY}" >> "${remote_rc}"
}

ensure_bazel() {
  local bazel_bin="${KONG_CLONE_DIR}/bin/bazel"
  if [[ -x "${bazel_bin}" ]]; then
    info "Using existing bazel wrapper at ${bazel_bin}" >&2
    printf '%s\n' "${bazel_bin}"
    return
  fi

  if command -v bazelisk >/dev/null 2>&1; then
    info "Using bazelisk from PATH" >&2
    mkdir -p "$(dirname "${bazel_bin}")"
    ln -sf "$(command -v bazelisk)" "${bazel_bin}"
    printf '%s\n' "${bazel_bin}"
    return
  fi

  if command -v bazel >/dev/null 2>&1; then
    info "Using bazel from PATH" >&2
    mkdir -p "$(dirname "${bazel_bin}")"
    ln -sf "$(command -v bazel)" "${bazel_bin}"
    printf '%s\n' "${bazel_bin}"
    return
  fi

  download_bazelisk() {
    local dest="$1"
    local os machine version url attempt
    os=$(uname | tr '[:upper:]' '[:lower:]')
    machine=$(uname -m)
    case "$machine" in
      aarch64) machine="arm64" ;;
      x86_64) machine="amd64" ;;
    esac
    version=$(bazelisk_version_from_kong)
    url="https://github.com/bazelbuild/bazelisk/releases/download/v${version}/bazelisk-${os}-${machine}"
    mkdir -p "$(dirname "${dest}")"
    for attempt in {1..4}; do
      info "Downloading bazelisk v${version} for ${os}/${machine} (attempt ${attempt})" >&2
      if curl -sSfL "${url}" -o "${dest}"; then
        chmod +x "${dest}"
        return 0
      fi
      sleep $((attempt * 2))
    done
    return 1
  }

  if command -v make >/dev/null 2>&1; then
    info "Installing bazelisk wrapper via make check-bazel" >&2
    if (cd "${KONG_CLONE_DIR}" && make check-bazel >/dev/null); then
      :
    else
      info "make check-bazel failed, falling back to direct bazelisk download" >&2
      download_bazelisk "${bazel_bin}"
    fi
  else
    info "Installing bazelisk (make not available)" >&2
    download_bazelisk "${bazel_bin}"
  fi
  if [[ ! -x "${bazel_bin}" ]]; then
    echo "[kong] Failed to provision kong/bin/bazel" >&2
    exit 1
  fi
  printf '%s\n' "${bazel_bin}"
}

dump_luarocks_logs() {
  local -a candidates=()
  if [[ -d "${KONG_CLONE_DIR}/bazel-out" ]]; then
    while IFS= read -r -d '' path; do
      candidates+=("$path")
    done < <(find "${KONG_CLONE_DIR}/bazel-out" -name 'luarocks_make.log' -print0 2>/dev/null || true)
  fi
  if [[ -d "${HOME}/.cache/bazel" ]]; then
    while IFS= read -r -d '' path; do
      candidates+=("$path")
    done < <(find "${HOME}/.cache/bazel" -name 'luarocks_make.log' -print0 2>/dev/null || true)
  fi

  if (( ${#candidates[@]} > 0 )); then
    info "Dumping luarocks_make.log from failed build for debugging" >&2
    for candidate in "${candidates[@]}"; do
      printf '---- %s ----\n' "$candidate"
      tail -n 200 "$candidate" || true
    done
  fi
}

run_bazel_once() {
  local bazel_bin="$1"; shift
  local desc="$1"; shift
  info "$desc"
  (cd "${KONG_CLONE_DIR}" && "${bazel_bin}" build "${COMMON_FLAGS[@]}" "$@")
}

run_bazel() {
  local bazel_bin="$1"; shift
  local desc="$1"; shift
  if run_bazel_once "$bazel_bin" "$desc" "$@"; then
    return
  fi

  dump_luarocks_logs

  if [[ "${REMOTE_CONFIGURED:-0}" == "1" && "${KONG_DISABLE_REMOTE_FALLBACK:-}" != "1" ]]; then
    info "Retrying Bazel build locally without remote execution" >&2
    local saved_flags=("${COMMON_FLAGS[@]}")
    COMMON_FLAGS+=(
      "--remote_executor="
      "--remote_cache="
      "--noremote_accept_cached"
      "--noremote_upload_local_results"
      "--jobs=8"
    )
    if run_bazel_once "$bazel_bin" "$desc (local fallback)" "$@"; then
      return
    fi
    COMMON_FLAGS=("${saved_flags[@]}")
    dump_luarocks_logs
  fi

  return 1
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
  ensure_cc
  ensure_zlib
  configure_remote_exec
  local bazel_bin
  bazel_bin=$(ensure_bazel)

  if [[ -n "${CC:-}" ]]; then
    COMMON_FLAGS+=("--repo_env=CC=${CC}")
  fi

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
