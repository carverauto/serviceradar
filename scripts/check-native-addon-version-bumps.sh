#!/usr/bin/env bash
# Fails PRs that change a first-party native add-on payload without advancing
# that add-on's manifest version. Also checks version sources that feed Rust
# add-on bundles stay aligned, so operators do not see a package version that
# differs from the binary-reported version.
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

sha256_from_ref_path() {
  local ref="$1" path="$2"

  if command -v sha256sum >/dev/null 2>&1; then
    git show "${ref}:${path}" 2>/dev/null | sha256sum | awk '{print $1}'
  else
    git show "${ref}:${path}" 2>/dev/null | shasum -a 256 | awk '{print $1}'
  fi
}

module_lock_has_file_hash() {
  local ref="$1" path="$2" expected_hash="$3"
  local module_lock

  module_lock="$(git show "${ref}:MODULE.bazel.lock" 2>/dev/null)" || return 1
  grep -Fq "FILE:@@//${path} ${expected_hash}" <<<"${module_lock}"
}

addon_ids() {
  cat <<'EOF'
netprobe
powerdns
workload-identity
bumblebee
scalibr-endpoint-inventory
rdp
anomaly
otel-collector
EOF
}

manifest_path() {
  case "$1" in
    sample) echo "addons/sample-addon/addon.yaml" ;;
    rust-sample) echo "addons/rust-sample-addon/addon.yaml" ;;
    netprobe) echo "addons/netprobe/addon.yaml" ;;
    powerdns) echo "addons/powerdns/addon.yaml" ;;
    workload-identity) echo "addons/workload-identity/addon.yaml" ;;
    bumblebee) echo "addons/bumblebee-scan/addon.yaml" ;;
    scalibr-endpoint-inventory) echo "addons/scalibr-endpoint-inventory/addon.yaml" ;;
    rdp) echo "addons/rdp-adapter/addon.yaml" ;;
    anomaly) echo "addons/anomaly-addon/addon.yaml" ;;
    otel-collector) echo "addons/otel-collector/addon.yaml" ;;
    *) return 1 ;;
  esac
}

cargo_version_path() {
  case "$1" in
    rust-sample) echo "rust/addon-sdk/Cargo.toml" ;;
    netprobe) echo "rust/netprobe/Cargo.toml" ;;
    powerdns) echo "rust/powerdns/Cargo.toml" ;;
    workload-identity) echo "rust/workload-identity/Cargo.toml" ;;
    rdp) echo "rust/rdp-adapter/Cargo.toml" ;;
    anomaly) echo "rust/anomaly-addon/Cargo.toml" ;;
    otel-collector) echo "rust/otel-addon/Cargo.toml" ;;
    *) return 1 ;;
  esac
}

bazel_version_path() {
  case "$1" in
    netprobe) echo "rust/netprobe/BUILD.bazel" ;;
    *) return 1 ;;
  esac
}

bazel_version_constant() {
  case "$1" in
    netprobe) echo "NETPROBE_VERSION" ;;
    *) return 1 ;;
  esac
}

path_belongs_to_addon() {
  local addon="$1" path="$2"

  case "${addon}" in
    sample)
      case "${path}" in
        addons/sample-addon/*|go/cmd/serviceradar-sample-addon/*) return 0 ;;
      esac
      ;;
    rust-sample)
      case "${path}" in
        addons/rust-sample-addon/*|rust/addon-sdk/*) return 0 ;;
      esac
      ;;
    netprobe)
      case "${path}" in
        addons/netprobe/*|rust/netprobe/*) return 0 ;;
      esac
      ;;
    powerdns)
      case "${path}" in
        addons/powerdns/*|rust/powerdns/*) return 0 ;;
      esac
      ;;
    workload-identity)
      case "${path}" in
        addons/workload-identity/*|rust/workload-identity/*) return 0 ;;
      esac
      ;;
    bumblebee)
      case "${path}" in
        addons/bumblebee-scan/*|go/cmd/bumblebee-scan/*) return 0 ;;
      esac
      ;;
    scalibr-endpoint-inventory)
      case "${path}" in
        addons/scalibr-endpoint-inventory/*|go/cmd/scalibr-endpoint-inventory/*|go/pkg/scalibrinventory/*|go/pkg/endpointinventory/*) return 0 ;;
      esac
      ;;
    rdp)
      case "${path}" in
        addons/rdp-adapter/*|rust/rdp-adapter/*) return 0 ;;
      esac
      ;;
    anomaly)
      case "${path}" in
        addons/anomaly-addon/*|rust/anomaly-addon/*) return 0 ;;
      esac
      ;;
    otel-collector)
      case "${path}" in
        addons/otel-collector/*|rust/otel-addon/*) return 0 ;;
      esac
      ;;
  esac

  return 1
}

inventory_stanza() {
  local ref="$1" addon="$2"
  python3 - "${ref}" "${addon}" <<'PY'
import subprocess
import sys

ref, addon = sys.argv[1:3]
try:
    data = subprocess.check_output(
        ["git", "show", f"{ref}:build/native_addons/addon_inventory.bzl"],
        stderr=subprocess.DEVNULL,
        text=True,
    )
except subprocess.CalledProcessError:
    sys.exit(0)

lines = data.splitlines()
needle = f'"addon_id": "{addon}"'
line_index = next((i for i, line in enumerate(lines) if needle in line), None)
if line_index is None:
    sys.exit(0)

start = line_index
while start >= 0 and lines[start].strip() != "{":
    start -= 1
if start < 0:
    sys.exit(0)

depth = 0
for end in range(start, len(lines)):
    depth += lines[end].count("{")
    depth -= lines[end].count("}")
    if depth == 0:
        print("\n".join(lines[start : end + 1]))
        sys.exit(0)
PY
}

inventory_stanza_changed() {
  local addon="$1"
  [[ "$(inventory_stanza "${BASE_REF}" "${addon}")" != "$(inventory_stanza "${HEAD_REF}" "${addon}")" ]]
}

# True when the addon_inventory.bzl diff introduces new or modified bundle
# content (i.e. added non-comment, non-blank lines). A diff that is purely
# deletions (retiring an add-on bundle) does not add anything to the signed
# import index for a surviving add-on, so it does not require a version bump.
inventory_adds_content() {
  git diff "${BASE_REF}" "${HEAD_REF}" -- build/native_addons/addon_inventory.bzl |
    awk '
      /^\+\+\+/ { next }
      /^\+/ {
        line = substr($0, 2)
        sub(/^[[:space:]]+/, "", line)
        if (line == "" || line ~ /^#/) next
        found = 1
        exit
      }
      END { exit(found ? 0 : 1) }
    '
}

version_changed() {
  local addon="$1" manifest old_version new_version
  manifest="$(manifest_path "${addon}")"
  old_version="$(version_from_yaml "${BASE_REF}" "${manifest}" || true)"
  new_version="$(version_from_yaml "${HEAD_REF}" "${manifest}" || true)"

  [[ -n "${new_version}" && "${old_version}" != "${new_version}" ]]
}

changed_paths="$(git diff --name-only "${BASE_REF}" "${HEAD_REF}")"
required_bumps=""
version_checks=""
rust_bazel_lock_checks=""
inventory_changed=false
inventory_mapped=false

while IFS= read -r path; do
  [[ -n "${path}" ]] || continue

  if [[ "${path}" == "build/native_addons/addon_inventory.bzl" ]]; then
    inventory_changed=true
    continue
  fi

  while IFS= read -r addon; do
    if path_belongs_to_addon "${addon}" "${path}"; then
      required_bumps="${required_bumps}${addon}"$'\n'
      version_checks="${version_checks}${addon}"$'\n'
    fi

    if [[ "${path}" == "$(manifest_path "${addon}")" ]]; then
      version_checks="${version_checks}${addon}"$'\n'
    fi

    cargo_path="$(cargo_version_path "${addon}" 2>/dev/null || true)"
    if [[ -n "${cargo_path}" && "${path}" == "${cargo_path}" ]]; then
      version_checks="${version_checks}${addon}"$'\n'
      rust_bazel_lock_checks="${rust_bazel_lock_checks}${addon}"$'\n'
    fi

    bazel_path="$(bazel_version_path "${addon}" 2>/dev/null || true)"
    if [[ -n "${bazel_path}" && "${path}" == "${bazel_path}" ]]; then
      version_checks="${version_checks}${addon}"$'\n'
    fi
  done < <(addon_ids)
done <<<"${changed_paths}"

  if [[ "${inventory_changed}" == true ]]; then
  while IFS= read -r addon; do
    if inventory_stanza_changed "${addon}"; then
      inventory_mapped=true
      required_bumps="${required_bumps}${addon}"$'\n'
      version_checks="${version_checks}${addon}"$'\n'
    fi
  done < <(addon_ids)

  if [[ "${inventory_mapped}" == false ]] && inventory_adds_content; then
    bumped_any=false
    while IFS= read -r addon; do
      if version_changed "${addon}"; then
        bumped_any=true
      fi
    done < <(addon_ids)

    if [[ "${bumped_any}" == false ]]; then
      cat >&2 <<EOF
error: build/native_addons/addon_inventory.bzl changed, but no first-party native add-on version changed

Bundle inventory changes affect the signed artifact contents/import index. Bump
the relevant addons/*/addon.yaml version so release import creates a distinct
approved package and agents can receive the new artifact.
EOF
      exit 1
    fi
  fi
fi

required_bumps="$(printf '%s' "${required_bumps}" | sort -u | sed '/^$/d')"
version_checks="$(printf '%s' "${version_checks}" | sort -u | sed '/^$/d')"
rust_bazel_lock_checks="$(printf '%s' "${rust_bazel_lock_checks}" | sort -u | sed '/^$/d')"

while IFS= read -r addon; do
  [[ -n "${addon}" ]] || continue

  manifest="$(manifest_path "${addon}")"
  old_version="$(version_from_yaml "${BASE_REF}" "${manifest}" || true)"
  new_version="$(version_from_yaml "${HEAD_REF}" "${manifest}" || true)"

  if [[ -z "${new_version}" ]]; then
    echo "error: ${manifest} has no version at ${HEAD_REF}" >&2
    exit 1
  fi

  if [[ -n "${old_version}" && "${old_version}" == "${new_version}" ]]; then
    cat >&2 <<EOF
error: ${addon} native add-on payload changed but ${manifest} stayed at ${new_version}

Bump ${manifest} when that add-on's source, config, unit, or bundle inventory
changes so release import creates a distinct approved package and agents can
receive the new artifact.
EOF
    exit 1
  fi
done <<<"${required_bumps}"

while IFS= read -r addon; do
  [[ -n "${addon}" ]] || continue

  cargo_path="$(cargo_version_path "${addon}")"
  missing_lock_hashes=""

  for lock_input_path in "Cargo.lock" "${cargo_path}"; do
    expected_hash="$(sha256_from_ref_path "${HEAD_REF}" "${lock_input_path}")"

    if ! module_lock_has_file_hash "${HEAD_REF}" "${lock_input_path}" "${expected_hash}"; then
      missing_lock_hashes="${missing_lock_hashes}  ${lock_input_path}: ${expected_hash}"$'\n'
    fi
  done

  if [[ -z "${missing_lock_hashes}" ]]; then
    continue
  fi

  cat >&2 <<EOF
error: ${addon} Rust add-on metadata changed but MODULE.bazel.lock is stale
${missing_lock_hashes}
${cargo_path} changed, but Bazel crate_universe lock metadata does not record
the current Cargo input hash(es) above.

Rust native add-on packages are built through Bazel crate_universe metadata. Run:
  bazel --batch mod deps --lockfile_mode=update

Then commit the refreshed MODULE.bazel.lock so release packaging uses the same
Cargo package metadata as the source tree.
EOF
  exit 1
done <<<"${rust_bazel_lock_checks}"

while IFS= read -r addon; do
  [[ -n "${addon}" ]] || continue

  manifest="$(manifest_path "${addon}")"
  addon_version="$(version_from_yaml "${HEAD_REF}" "${manifest}" || true)"

  cargo_path="$(cargo_version_path "${addon}" 2>/dev/null || true)"
  if [[ -n "${cargo_path}" ]]; then
    cargo_version="$(version_from_toml "${HEAD_REF}" "${cargo_path}" || true)"

    if [[ -z "${addon_version}" || -z "${cargo_version}" ]]; then
      echo "error: unable to read ${addon} version sources" >&2
      echo "  ${manifest}: ${addon_version:-<missing>}" >&2
      echo "  ${cargo_path}: ${cargo_version:-<missing>}" >&2
      exit 1
    fi

    if [[ "${addon_version}" != "${cargo_version}" ]]; then
      cat >&2 <<EOF
error: ${addon} version sources are out of sync
  ${manifest}: ${addon_version}
  ${cargo_path}: ${cargo_version}

Keep these aligned so the add-on package and binary version describe the same
artifact.
EOF
      exit 1
    fi
  fi

  bazel_path="$(bazel_version_path "${addon}" 2>/dev/null || true)"
  if [[ -n "${bazel_path}" ]]; then
    bazel_constant="$(bazel_version_constant "${addon}")"
    bazel_version="$(version_from_bazel_constant "${HEAD_REF}" "${bazel_path}" "${bazel_constant}" || true)"

    if [[ -z "${addon_version}" || -z "${bazel_version}" ]]; then
      echo "error: unable to read ${addon} Bazel version source" >&2
      echo "  ${manifest}: ${addon_version:-<missing>}" >&2
      echo "  ${bazel_path} ${bazel_constant}: ${bazel_version:-<missing>}" >&2
      exit 1
    fi

    if [[ "${addon_version}" != "${bazel_version}" ]]; then
      cat >&2 <<EOF
error: ${addon} version sources are out of sync
  ${manifest}: ${addon_version}
  ${bazel_path} ${bazel_constant}: ${bazel_version}

Keep these aligned so the add-on package, Bazel build metadata, and binary
version all describe the same artifact.
EOF
      exit 1
    fi
  fi
done <<<"${version_checks}"

echo "native add-on version bump check passed"
