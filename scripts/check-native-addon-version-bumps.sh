#!/usr/bin/env bash
# Fails PRs that change a native add-on payload without advancing the add-on
# version. Also checks the version sources that feed the netprobe bundle stay
# aligned, so operators do not see a package version that differs from the
# binary-reported version.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASE_REF="${1:-${BASE_REF:-origin/staging}}"
HEAD_REF="${2:-${HEAD_REF:-HEAD}}"

cd "${REPO_ROOT}"

if ! git rev-parse --verify "${BASE_REF}^{commit}" >/dev/null 2>&1; then
  echo "error: base ref not found: ${BASE_REF}" >&2
  exit 2
fi

if ! git rev-parse --verify "${HEAD_REF}^{commit}" >/dev/null 2>&1; then
  echo "error: head ref not found: ${HEAD_REF}" >&2
  exit 2
fi

version_from_yaml() {
  local ref="$1" path="$2"
  git show "${ref}:${path}" 2>/dev/null |
    awk -F: '/^[[:space:]]*version[[:space:]]*:/ {
      value=$2
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
      gsub(/^["'\'']|["'\'']$/, "", value)
      print value
      exit
    }'
}

version_from_toml() {
  local ref="$1" path="$2"
  git show "${ref}:${path}" 2>/dev/null |
    awk -F= '
      /^[[:space:]]*\[package\][[:space:]]*$/ { in_package=1; next }
      /^[[:space:]]*\[/ && in_package { exit }
      in_package && /^[[:space:]]*version[[:space:]]*=/ {
        value=$2
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
        gsub(/^["'\'']|["'\'']$/, "", value)
        print value
        exit
      }
    '
}

version_from_bazel_constant() {
  local ref="$1" path="$2" constant="$3"
  git show "${ref}:${path}" 2>/dev/null |
    awk -F= -v constant="${constant}" '
      $1 ~ "^[[:space:]]*" constant "[[:space:]]*$" {
        value=$2
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
        gsub(/^["'\'']|["'\'']$/, "", value)
        print value
        exit
      }
    '
}

changed_paths="$(git diff --name-only "${BASE_REF}" "${HEAD_REF}")"
requires_netprobe_bump=false
checks_netprobe_versions=false

while IFS= read -r path; do
  case "${path}" in
    rust/netprobe/*|addons/netprobe/config.schema.json|addons/netprobe/serviceradar-netprobe.service|build/native_addons/addon_inventory.bzl)
      requires_netprobe_bump=true
      checks_netprobe_versions=true
      ;;
    addons/netprobe/addon.yaml|rust/netprobe/Cargo.toml|rust/netprobe/BUILD.bazel)
      checks_netprobe_versions=true
      ;;
  esac
done <<<"${changed_paths}"

if [[ "${requires_netprobe_bump}" == true ]]; then
  old_version="$(version_from_yaml "${BASE_REF}" addons/netprobe/addon.yaml || true)"
  new_version="$(version_from_yaml "${HEAD_REF}" addons/netprobe/addon.yaml || true)"

  if [[ -z "${new_version}" ]]; then
    echo "error: addons/netprobe/addon.yaml has no version at ${HEAD_REF}" >&2
    exit 1
  fi

  if [[ "${old_version}" == "${new_version}" ]]; then
    cat >&2 <<EOF
error: netprobe native add-on payload changed but addons/netprobe/addon.yaml stayed at ${new_version}

Watched payload paths:
  rust/netprobe/**
  addons/netprobe/config.schema.json
  addons/netprobe/serviceradar-netprobe.service
  build/native_addons/addon_inventory.bzl

Bump addons/netprobe/addon.yaml when any of those change so release import
creates a distinct approved package and agents can receive the new artifact.
EOF
    exit 1
  fi
fi

if [[ "${checks_netprobe_versions}" == true ]]; then
  addon_version="$(version_from_yaml "${HEAD_REF}" addons/netprobe/addon.yaml || true)"
  cargo_version="$(version_from_toml "${HEAD_REF}" rust/netprobe/Cargo.toml || true)"
  bazel_version="$(version_from_bazel_constant "${HEAD_REF}" rust/netprobe/BUILD.bazel NETPROBE_VERSION || true)"

  if [[ -z "${addon_version}" || -z "${cargo_version}" || -z "${bazel_version}" ]]; then
    echo "error: unable to read all netprobe version sources" >&2
    echo "  addon.yaml: ${addon_version:-<missing>}" >&2
    echo "  Cargo.toml: ${cargo_version:-<missing>}" >&2
    echo "  BUILD.bazel NETPROBE_VERSION: ${bazel_version:-<missing>}" >&2
    exit 1
  fi

  if [[ "${addon_version}" != "${cargo_version}" || "${addon_version}" != "${bazel_version}" ]]; then
    cat >&2 <<EOF
error: netprobe version sources are out of sync
  addons/netprobe/addon.yaml: ${addon_version}
  rust/netprobe/Cargo.toml: ${cargo_version}
  rust/netprobe/BUILD.bazel NETPROBE_VERSION: ${bazel_version}

Keep these aligned so the add-on package, Bazel build metadata, and binary
version all describe the same artifact.
EOF
    exit 1
  fi
fi

echo "native add-on version bump check passed"
