#!/usr/bin/env bash
# Install skopeo for non-root CI runners (GitHub ARC). The old Forgejo image
# baked it in; ensure-forgejo-tools.sh cannot apt-get without root.

set -euo pipefail

if command -v skopeo >/dev/null 2>&1; then
  echo "skopeo already on PATH: $(command -v skopeo)"
  exit 0
fi

install_root="${RUNNER_TEMP:-${HOME}/.local}/bin"
mkdir -p "${install_root}"
dest="${install_root}/skopeo"
image="${SKOPEO_IMAGE:-quay.io/skopeo/stable:v1.17.0}"

if ! command -v docker >/dev/null 2>&1; then
  echo "skopeo is missing and docker is not available to extract ${image}" >&2
  exit 1
fi

cid="$(docker create "${image}")"
trap 'docker rm -f "${cid}" >/dev/null 2>&1 || true' EXIT
if ! docker cp "${cid}:/usr/bin/skopeo" "${dest}"; then
  docker cp "${cid}:/bin/skopeo" "${dest}"
fi
chmod 0755 "${dest}"

if [[ -n "${GITHUB_PATH:-}" ]]; then
  echo "${install_root}" >> "${GITHUB_PATH}"
fi
export PATH="${install_root}:${PATH}"

"${dest}" --version
