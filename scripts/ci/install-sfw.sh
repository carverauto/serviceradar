#!/usr/bin/env bash
set -euo pipefail

version="${SFW_VERSION:-v1.15.0}"
install_dir="${RUNNER_TEMP:-/tmp}/socket-firewall"

case "$(uname -s)-$(uname -m)" in
  Linux-x86_64|Linux-amd64)
    asset="sfw-free-linux-x86_64"
    sha256="c80371910a808ea5c68916c48e5451716a91ca411cf5e422fdbd8119729b742c"
    ;;
  *)
    echo "unsupported Socket Firewall runner platform: $(uname -s)-$(uname -m)" >&2
    exit 1
    ;;
esac

mkdir -p "${install_dir}"
sfw_path="${install_dir}/sfw"

curl -fsSL --retry 3 \
  "https://github.com/SocketDev/sfw-free/releases/download/${version}/${asset}" \
  -o "${sfw_path}"

if command -v sha256sum >/dev/null 2>&1; then
  printf '%s  %s\n' "${sha256}" "${sfw_path}" | sha256sum -c -
else
  actual="$(shasum -a 256 "${sfw_path}" | awk '{print $1}')"
  test "${actual}" = "${sha256}"
fi

chmod +x "${sfw_path}"

if [ -n "${GITHUB_PATH:-}" ]; then
  echo "${install_dir}" >> "${GITHUB_PATH}"
else
  echo "Add ${install_dir} to PATH to use sfw in later steps." >&2
fi

"${sfw_path}" --help
