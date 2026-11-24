#!/usr/bin/env bash
# Build the CUDA crane-serve binary for serviceradar-camera-vlm-cuda outside Bazel.
#
# Bazel RBE is amd64-only and has no CUDA toolkit, so crane-serve (upstream
# lucasjinreal/Crane, MIT) is built natively on an arm64 runner inside the pinned
# NVIDIA CUDA devel image (.github/workflows/publish-camera-vlm-cuda.yml). The build
# needs no GPU and no credentials. Subcommands:
#
#   fetch-inputs <dir>      Download the pinned Rust components and the pinned Crane
#                           source tarball, pre-populate a self-contained CARGO_HOME
#                           via `cargo fetch`, and write the archives to <dir> (needs
#                           curl, git, and cargo; run on a runner that has them --
#                           the CUDA devel image does not).
#   build <inputs-dir> <out-dir>
#                           Install the toolchain into $HOME, unpack the Crane source
#                           and pre-populated CARGO_HOME, build `crane-serve` with
#                           `--features cuda --offline --locked`, and write the binary,
#                           the CUDA runtime libraries it needs, third-party notices,
#                           manifest.json, and SHA256SUMS.
#
# Environment:
#   CUDA_BUILDER_IMAGE the builder image reference, recorded in manifest.json.
#   CARGO_TARGET_DIR   default $HOME/camera-vlm-cuda-target.

set -euo pipefail

RUST_VERSION="1.98.0"
RUST_HOST="aarch64-unknown-linux-gnu"
# sha256 of https://static.rust-lang.org/dist/<component>-${RUST_VERSION}-${RUST_HOST}.tar.gz
RUST_COMPONENT_SHA256=(
  "rustc b6fdb37bc08e320bd92381e13d7311837f04a98423b8a5b678a5eb5e87c978ca"
  "cargo e271c3c5d50336259a166e68b60ba792a64278ab117686183be3e51a0958d34b"
  "rust-std a2eece726a579de1f554a2c3bcc62410226b0be55736f57c2b5430c1bc71b98f"
)
# Pinned upstream lucasjinreal/Crane commit and source tarball sha256.
CRANE_REPO="https://github.com/lucasjinreal/Crane"
CRANE_COMMIT="55835189af0848a180e6ed70313d59272e7c92a1"
CRANE_TARBALL_URL="${CRANE_REPO}/archive/${CRANE_COMMIT}.tar.gz"
CRANE_TARBALL_SHA256="07a2abbdff4cb78c5e7bf9da535213121417f99cd5afe064d5e53c3e3c75288b"
CRANE_INPUTS_ARCHIVE="crane-inputs-${CRANE_COMMIT}.tar.gz"

# CUDA libraries the binary loads besides libcuda.so.1, which the NVIDIA container
# runtime injects from the host driver. Anything else `ldd` resolves under the CUDA
# toolkit is added too; an unresolved library other than libcuda fails the build.
CUDA_RUNTIME_LIBRARIES=(
  libcublas.so.13
  libcublasLt.so.13
  libcurand.so.10
  libnvrtc.so.13
  libnvrtc-builtins.so.13.0
  libcudart.so.13
)
BINARY_NAME="crane-serve"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

die() {
  printf 'build-camera-vlm-cuda: %s\n' "$*" >&2
  exit 1
}

require() {
  local tool
  for tool in "$@"; do
    command -v "${tool}" >/dev/null 2>&1 || die "required tool not found: ${tool}"
  done
}

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

component_archive() {
  printf '%s-%s-%s.tar.gz' "$1" "${RUST_VERSION}" "${RUST_HOST}"
}

check_toolchain_pin() {
  local channel
  channel="$(sed -n 's/^channel = "\(.*\)"$/\1/p' "${REPO_ROOT}/rust-toolchain.toml")"
  [[ "${channel}" == "${RUST_VERSION}" ]] \
    || die "rust-toolchain.toml pins ${channel}, this script pins ${RUST_VERSION}; update both together"
}

require_empty_dir() (
  local dir="$1"
  mkdir -p -- "${dir}"
  shopt -s dotglob nullglob
  set -- "${dir}"/*
  (( $# == 0 )) || die "output directory must be empty: ${dir}"
)

fetch_inputs() {
  local dir="$1" entry component expected archive work src_tar src_dir
  require_empty_dir "${dir}"
  require curl tar gzip cargo
  check_toolchain_pin

  for entry in "${RUST_COMPONENT_SHA256[@]}"; do
    read -r component expected <<<"${entry}"
    archive="$(component_archive "${component}")"
    curl --proto '=https' --tlsv1.2 -fsSL --retry 3 \
      -o "${dir}/${archive}" "https://static.rust-lang.org/dist/${archive}"
    [[ "$(sha256_of "${dir}/${archive}")" == "${expected}" ]] \
      || die "checksum mismatch for ${archive}"
  done

  work="$(mktemp -d)"
  trap 'rm -rf -- "${work}"' RETURN
  src_tar="${work}/crane-${CRANE_COMMIT}.tar.gz"
  curl --proto '=https' --tlsv1.2 -fsSL --retry 3 \
    -o "${src_tar}" "${CRANE_TARBALL_URL}"
  [[ "$(sha256_of "${src_tar}")" == "${CRANE_TARBALL_SHA256}" ]] \
    || die "checksum mismatch for Crane source tarball ${CRANE_COMMIT}"

  tar -xzf "${src_tar}" -C "${work}"
  src_dir="${work}/Crane-${CRANE_COMMIT}"
  [[ -d "${src_dir}" ]] || die "expected Crane-${CRANE_COMMIT} directory in source tarball"

  mkdir -p "${work}/cargo-home"
  (
    cd "${src_dir}"
    CARGO_HOME="${work}/cargo-home" cargo fetch
    CARGO_HOME="${work}/cargo-home" cargo metadata --offline --locked --format-version 1 >/dev/null
  )
  tar -czf "${dir}/${CRANE_INPUTS_ARCHIVE}" -C "${work}" "Crane-${CRANE_COMMIT}" "cargo-home"
  echo "fetched Rust ${RUST_VERSION} (${RUST_HOST}) and Crane ${CRANE_COMMIT} inputs into ${dir}"
}

install_toolchain() {
  local dir="$1" prefix="$2" entry component expected archive work
  check_toolchain_pin
  work="$(mktemp -d)"
  for entry in "${RUST_COMPONENT_SHA256[@]}"; do
    read -r component expected <<<"${entry}"
    archive="$(component_archive "${component}")"
    [[ -f "${dir}/${archive}" ]] || die "missing toolchain archive ${dir}/${archive}"
    [[ "$(sha256_of "${dir}/${archive}")" == "${expected}" ]] \
      || die "checksum mismatch for ${archive}"
    tar -xzf "${dir}/${archive}" -C "${work}"
    bash "${work}/${archive%.tar.gz}/install.sh" --prefix="${prefix}" --disable-ldconfig >/dev/null
  done
  rm -rf "${work}"
}

collect_cuda_libraries() {
  local binary="$1" libdir="$2" toolkit="$3" dependencies line name path missing=()
  local -A wanted=()
  dependencies="$(ldd "${binary}")" || die "ldd failed to inspect ${binary}"
  for name in "${CUDA_RUNTIME_LIBRARIES[@]}"; do wanted["${name}"]=1; done
  while read -r line; do
    if [[ "${line}" =~ ^([^[:space:]]+)\ =\>\ not\ found ]]; then
      [[ "${BASH_REMATCH[1]}" == "libcuda.so.1" ]] || missing+=("${BASH_REMATCH[1]}")
    elif [[ "${line}" =~ ^([^[:space:]]+)\ =\>\ "${toolkit}"(/|-[0-9]) ]]; then
      # Never ship a driver library (e.g. a cuda-compat libcuda): it must come from the
      # host through the NVIDIA container runtime, matching the host kernel module.
      [[ "${BASH_REMATCH[1]}" == libcuda.so* || "${BASH_REMATCH[1]}" == libnvidia-* ]] && continue
      name="${BASH_REMATCH[1]}"
      if [[ "${name}" == libnvrtc-builtins.so.* && "${name}" != libnvrtc-builtins.so.13.0 ]]; then
        die "unexpected NVRTC builtins dependency: ${name}"
      fi
      wanted["${name}"]=1
    fi
  done <<<"${dependencies}"
  ((${#missing[@]} == 0)) || die "unresolved shared libraries: ${missing[*]}"
  mkdir -p "${libdir}"
  for name in "${!wanted[@]}"; do
    path="${toolkit}/lib64/${name}"
    [[ -e "${path}" ]] || die "CUDA runtime library not found in the builder image: ${path}"
    cp -L "${path}" "${libdir}/${name}"
    chmod 0644 "${libdir}/${name}"
  done
}

json_string() {
  local value="${1//\\/\\\\}"
  printf '"%s"' "${value//\"/\\\"}"
}

write_manifest() {
  local out="$1" file first=1
  {
    printf '{\n'
    printf '  "schema": 1,\n'
    printf '  "commit": %s,\n' "$(json_string "${GITHUB_SHA}")"
    printf '  "crane_commit": %s,\n' "$(json_string "${CRANE_COMMIT}")"
    printf '  "binary": {"path": %s, "sha256": %s},\n' \
      "$(json_string "${BINARY_NAME}")" "$(json_string "$(sha256_of "${out}/${BINARY_NAME}")")"
    printf '  "cargo_features": ["cuda"],\n'
    printf '  "cuda_compute_cap": %s,\n' "$(json_string "${CUDA_COMPUTE_CAP}")"
    printf '  "builder_image": %s,\n' "$(json_string "${CUDA_BUILDER_IMAGE}")"
    printf '  "toolchain": {"rustc": %s, "cargo": %s, "nvcc": %s, "cc": %s},\n' \
      "$(json_string "$(rustc --version)")" \
      "$(json_string "$(cargo --version)")" \
      "$(json_string "$(nvcc --version | tail -n 1)")" \
      "$(json_string "$(cc --version | head -n 1)")"
    printf '  "libraries": {'
    for file in "${out}"/lib/*; do
      ((first)) || printf ','
      first=0
      printf '\n    %s: %s' "$(json_string "$(basename "${file}")")" "$(json_string "$(sha256_of "${file}")")"
    done
    printf '\n  }\n}\n'
  } > "${out}/manifest.json"
}

build() (
  local inputs_dir="$1" out="$2"
  require_empty_dir "${out}"
  [[ "${GITHUB_SHA:-}" =~ ^[0-9a-f]{40}$ ]] || die "GITHUB_SHA must be the full commit SHA"
  [[ "${CUDA_BUILDER_IMAGE:-}" == "docker.io/nvidia/cuda@sha256:b7ae301dea2c162444795462ce17a05f6a516e5a75944b57af5b88540a1a2266" ]] \
    || die "CUDA_BUILDER_IMAGE must identify the pinned CUDA 13.0.3 devel image"
  require nvcc tar gzip sha256sum ldd cc awk
  [[ -n "${HOME:-}" && "${HOME}" != "/" && -d "${HOME}" && -w "${HOME}" ]] \
    || die "HOME must name an existing writable directory (not /)"

  local prefix="${HOME}/rust-${RUST_VERSION}"
  install_toolchain "${inputs_dir}" "${prefix}"
  export PATH="${prefix}/bin:${PATH}"
  rustc --version | grep -qF "rustc ${RUST_VERSION} " || die "installed rustc is not ${RUST_VERSION}"

  local crane_inputs_tar="${inputs_dir}/${CRANE_INPUTS_ARCHIVE}"
  [[ -f "${crane_inputs_tar}" ]] || die "missing Crane inputs archive: ${crane_inputs_tar}"

  local src_work src_dir
  src_work="$(mktemp -d "${HOME}/camera-vlm-cuda-src.XXXXXXXX")"
  trap 'rm -rf -- "${src_work}"' EXIT
  tar -xzf "${crane_inputs_tar}" -C "${src_work}"
  src_dir="${src_work}/Crane-${CRANE_COMMIT}"
  [[ -d "${src_dir}" ]] || die "expected Crane-${CRANE_COMMIT} directory in ${crane_inputs_tar}"
  [[ -d "${src_work}/cargo-home" ]] || die "expected cargo-home directory in ${crane_inputs_tar}"
  export CARGO_HOME="${src_work}/cargo-home"
  export CARGO_NET_GIT_FETCH_WITH_CLI=false

  if ! command -v aarch64-linux-gnu-gcc >/dev/null 2>&1; then
    export CARGO_TARGET_AARCH64_UNKNOWN_LINUX_GNU_LINKER=cc
  fi
  export CUDA_COMPUTE_CAP=121
  export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-${HOME}/camera-vlm-cuda-target}"

  (
    cd "${src_dir}"
    cargo build --release --offline --locked \
      -p crane-serve --features cuda --bin "${BINARY_NAME}"
  )

  install -m 0755 "${CARGO_TARGET_DIR}/release/${BINARY_NAME}" "${out}/${BINARY_NAME}"
  collect_cuda_libraries "${out}/${BINARY_NAME}" "${out}/lib" /usr/local/cuda
  local package notice
  mkdir "${out}/third-party"
  for package in libcublas-13-0 libcurand-13-0 cuda-nvrtc-13-0 cuda-cudart-13-0; do
    notice="/usr/share/doc/${package}/copyright"
    [[ -s "${notice}" ]] || die "missing CUDA redistribution notice: ${notice}"
    install -m 0644 "${notice}" "${out}/third-party/${package}.copyright"
  done
  [[ -s "${src_dir}/LICENSE" ]] || die "missing Crane LICENSE file"
  install -m 0644 "${src_dir}/LICENSE" "${out}/third-party/crane.LICENSE"

  write_manifest "${out}"
  (
    cd "${out}"
    # find excludes SHA256SUMS, so the pipeline never reads the file being written.
    # shellcheck disable=SC2094
    find . -type f ! -name SHA256SUMS | sed 's|^\./||' | LC_ALL=C sort | xargs sha256sum > SHA256SUMS
  )
  echo "built ${out}:"
  cat "${out}/SHA256SUMS"
)

usage() {
  sed -n '2,/^$/{ /^#/p; }' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit 2
}

[[ "${BASH_SOURCE[0]}" == "$0" ]] || return 0
case "${1:-}" in
  fetch-inputs) [[ $# -eq 2 ]] || usage; fetch_inputs "$2" ;;
  build) [[ $# -eq 3 ]] || usage; build "$2" "$3" ;;
  *) usage ;;
esac
