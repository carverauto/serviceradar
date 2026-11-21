#!/usr/bin/env bash
# Build the CUDA variant of serviceradar-media-worker outside Bazel.
#
# Bazel RBE is amd64-only and has no CUDA toolkit, so this one binary is built natively
# on an arm64 runner inside the pinned NVIDIA CUDA devel image
# (.github/workflows/publish-media-worker-cuda.yml). The build needs no GPU and no
# credentials. Subcommands:
#
#   fetch-toolchain <dir>   Download the pinned Rust components (needs curl; run on a
#                           runner that has it -- the CUDA devel image does not).
#   build <toolchain-dir> <out-dir>
#                           Install the toolchain into $HOME, vendor the crates, build with
#                           `--features cuda --locked`, and write the binary, the CUDA
#                           runtime libraries it needs, manifest.json and SHA256SUMS.
#
# Crates come from the checked-in mirror (the archives Bazel uses), never from crates.io,
# so the build makes no package-registry fetch. Environment:
#   CUDA_BUILDER_IMAGE the builder image reference, recorded in manifest.json.
#   CARGO_TARGET_DIR   default $HOME/media-worker-cuda-target.

set -euo pipefail

RUST_VERSION="1.98.0"
RUST_HOST="aarch64-unknown-linux-gnu"
# sha256 of https://static.rust-lang.org/dist/<component>-${RUST_VERSION}-${RUST_HOST}.tar.gz
RUST_COMPONENT_SHA256=(
  "rustc b6fdb37bc08e320bd92381e13d7311837f04a98423b8a5b678a5eb5e87c978ca"
  "cargo e271c3c5d50336259a166e68b60ba792a64278ab117686183be3e51a0958d34b"
  "rust-std a2eece726a579de1f554a2c3bcc62410226b0be55736f57c2b5430c1bc71b98f"
)
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
BINARY_NAME="serviceradar-media-worker"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

die() {
  printf 'build-media-worker-cuda: %s\n' "$*" >&2
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

fetch_toolchain() {
  local dir="$1" entry component expected archive
  require curl
  check_toolchain_pin
  require_empty_dir "${dir}"
  for entry in "${RUST_COMPONENT_SHA256[@]}"; do
    read -r component expected <<<"${entry}"
    archive="$(component_archive "${component}")"
    curl --proto '=https' --tlsv1.2 -fsSL --retry 3 \
      -o "${dir}/${archive}" "https://static.rust-lang.org/dist/${archive}"
    [[ "$(sha256_of "${dir}/${archive}")" == "${expected}" ]] \
      || die "checksum mismatch for ${archive}"
  done
  echo "fetched Rust ${RUST_VERSION} components for ${RUST_HOST} into ${dir}"
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

# Prints "name version checksum" for every crates.io package in Cargo.lock. Only
# [[package]] tables count: [[patch.unused]] names a crate the build never uses.
registry_packages() {
  awk '
    function flush() { if (in_package && name != "" && registry) print name, version, checksum }
    /^\[/ { flush(); in_package = ($0 == "[[package]]")
             name = ""; version = ""; checksum = ""; registry = 0; next }
    !in_package { next }
    /^name = /     { gsub(/"/, "", $3); name = $3 }
    /^version = /  { gsub(/"/, "", $3); version = $3 }
    /^checksum = / { gsub(/"/, "", $3); checksum = $3 }
    /^source = "registry\+https:\/\/github.com\/rust-lang\/crates.io-index"/ { registry = 1 }
    END { flush() }
  ' "${REPO_ROOT}/Cargo.lock"
}

vendor_crates() {
  local dir="$1" name version checksum archive count=0
  local mirror="${REPO_ROOT}/third_party/crate_mirror"
  mkdir -p "${dir}"
  while read -r name version checksum; do
    archive="${mirror}/${name}-${version}.crate"
    [[ -f "${archive}" ]] \
      || die "${name} ${version} is in Cargo.lock but not in third_party/crate_mirror; run bazel run //third_party/crate_mirror:sync"
    [[ "$(sha256_of "${archive}")" == "${checksum}" ]] \
      || die "${archive} does not match the Cargo.lock checksum"
    tar -xzf "${archive}" -C "${dir}"
    # Cargo checks `package` against Cargo.lock; an empty file map skips per-file checks.
    printf '{"files":{},"package":"%s"}' "${checksum}" > "${dir}/${name}-${version}/.cargo-checksum.json"
    count=$((count + 1))
  done < <(registry_packages)
  ((count > 0)) || die "no registry packages found in Cargo.lock"
  echo "vendored ${count} crates from third_party/crate_mirror into ${dir}"
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
  local toolchain_dir="$1" out="$2"
  require_empty_dir "${out}"
  [[ "${GITHUB_SHA:-}" =~ ^[0-9a-f]{40}$ ]] || die "GITHUB_SHA must be the full commit SHA"
  [[ "${CUDA_BUILDER_IMAGE:-}" == "docker.io/nvidia/cuda@sha256:b7ae301dea2c162444795462ce17a05f6a516e5a75944b57af5b88540a1a2266" ]] \
    || die "CUDA_BUILDER_IMAGE must identify the pinned CUDA 13.0.3 devel image"
  require nvcc tar gzip sha256sum ldd cc awk
  [[ -n "${HOME:-}" && -d "${HOME}" ]] || die "HOME must name an existing writable directory"

  local prefix="${HOME}/rust-${RUST_VERSION}"
  install_toolchain "${toolchain_dir}" "${prefix}"
  export PATH="${prefix}/bin:${PATH}"
  export CARGO_HOME="${HOME}/cargo-home"
  rustc --version | grep -qF "rustc ${RUST_VERSION} " || die "installed rustc is not ${RUST_VERSION}"

  local vendor_dir
  vendor_dir="$(mktemp -d "${HOME}/media-worker-cuda-vendor.XXXXXXXX")"
  trap 'rm -rf -- "${vendor_dir}"' EXIT
  vendor_crates "${vendor_dir}"

  # The repository's cross-compile linker name; a native arm64 builder may only have cc.
  if ! command -v aarch64-linux-gnu-gcc >/dev/null 2>&1; then
    export CARGO_TARGET_AARCH64_UNKNOWN_LINUX_GNU_LINKER=cc
  fi
  export CUDA_COMPUTE_CAP=121
  export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-${HOME}/media-worker-cuda-target}"
  # No git binary in the builder image: let cargo use its built-in client for the
  # one git dependency in Cargo.lock.
  export CARGO_NET_GIT_FETCH_WITH_CLI=false

  (
    cd "${REPO_ROOT}"
    cargo build --release --locked \
      --config "source.crates-io.replace-with=\"serviceradar-crate-mirror\"" \
      --config "source.serviceradar-crate-mirror.directory=\"${vendor_dir}\"" \
      -p serviceradar-media-worker --features cuda --bin "${BINARY_NAME}"
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
  write_manifest "${out}"
  (
    cd "${out}"
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
  fetch-toolchain) [[ $# -eq 2 ]] || usage; fetch_toolchain "$2" ;;
  build) [[ $# -eq 3 ]] || usage; build "$2" "$3" ;;
  *) usage ;;
esac
