#!/usr/bin/env bash
# Install skopeo for non-root CI runners (GitHub ARC). The old Forgejo image
# baked it in; ensure-forgejo-tools.sh cannot apt-get without root.
#
# Extract via crane. ARC signing runners can write docker login config, but
# they have no dockerd and no container socket.

set -euo pipefail

if command -v skopeo >/dev/null 2>&1; then
  echo "skopeo already on PATH: $(command -v skopeo)"
  exit 0
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

install_root="${RUNNER_TEMP:-${HOME}/.local}/bin"
mkdir -p "${install_root}"
dest="${install_root}/skopeo"
image="${SKOPEO_IMAGE:-quay.io/skopeo/stable:v1.17.0}"

case "$(uname -m)" in
  x86_64|amd64)
    skopeo_platform="linux/amd64"
    ;;
  aarch64|arm64)
    skopeo_platform="linux/arm64"
    ;;
  *)
    echo "Unsupported architecture for skopeo bootstrap: $(uname -m)" >&2
    exit 1
    ;;
esac

resolve_crane() {
  if command -v crane >/dev/null 2>&1; then
    command -v crane
    return 0
  fi
  local crane_bin="${install_root}/crane"
  if [[ -x "${crane_bin}" ]]; then
    printf '%s\n' "${crane_bin}"
    return 0
  fi
  return 1
}

# install-crane.sh owns the crane pin. It installs into the same install_root;
# its own output goes to stderr so this function prints only the binary path.
install_crane() {
  local installer=""
  local candidate
  for candidate in \
    "${script_dir}/install-crane.sh" \
    "${GITHUB_WORKSPACE:-}/scripts/install-crane.sh" \
    "${script_dir}/../scripts/install-crane.sh"; do
    if [[ -f "${candidate}" ]]; then
      installer="${candidate}"
      break
    fi
  done
  if [[ -z "${installer}" ]]; then
    echo "error: install-crane.sh not found next to install-skopeo.sh" >&2
    return 1
  fi
  bash "${installer}" >&2
  printf '%s\n' "${install_root}/crane"
}

crane_bin="$(resolve_crane || true)"
if [[ -z "${crane_bin}" ]]; then
  crane_bin="$(install_crane)"
fi

export_dir="$(mktemp -d)"
trap 'rm -rf "${export_dir}"' EXIT
if ! "${crane_bin}" export --platform "${skopeo_platform}" "${image}" - | tar -C "${export_dir}" -xf -; then
  echo "error: failed to export ${image} with crane" >&2
  exit 1
fi

extracted=""
for candidate in \
  "${export_dir}/usr/bin/skopeo" \
  "${export_dir}/bin/skopeo"; do
  if [[ -f "${candidate}" ]]; then
    extracted="${candidate}"
    break
  fi
done
if [[ -z "${extracted}" ]]; then
  echo "error: ${image} did not contain usr/bin/skopeo or bin/skopeo" >&2
  exit 1
fi

install -m 0755 "${extracted}" "${dest}"

if [[ -n "${GITHUB_PATH:-}" ]]; then
  echo "${install_root}" >> "${GITHUB_PATH}"
fi
export PATH="${install_root}:${PATH}"

"${dest}" --version
