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

# A COMPARISON OF A COMMIT WITH ITSELF CHECKS NOTHING, and passing is the worst possible
# answer: the step reports green and the payload rule is simply not applied.
#
# That is not hypothetical. On `push: branches: [staging]` there is no GITHUB_BASE_REF, so
# the caller's base_ref fell back to `staging` -- which on that event IS the commit just
# pushed. The gate diffed staging against itself and returned 0 even for 80c1c0fa45, the
# commit that shipped a changed bumblebee payload under an unchanged version.
#
# Fail loudly instead. A caller that cannot name a meaningful base has a bug in the caller.
if [[ "$(git rev-parse "${BASE_REF}^{commit}")" == "$(git rev-parse "${HEAD_REF}^{commit}")" ]]; then
  cat >&2 <<EOF
error: base and head are the same commit ($(git rev-parse --short "${HEAD_REF}^{commit}"))

There is no diff to inspect, so this check would pass without examining anything. Pass the
commit the change is being compared AGAINST -- the target branch for a pull request, or the
previous tip for a push.
EOF
  exit 1
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

# NOTE: there is deliberately no cargo_version_path().
#
# This gate used to require each Rust add-on's crate [package] version to mirror
# addons/<id>/addon.yaml, and to require the vendor snapshot to record the resulting
# Cargo.lock and Cargo.toml hashes. That coupling was inert and expensive:
#
#   * The crate version was decoration. These crates are binaries with no `publish` key
#     that nothing in the workspace depends on as a library; Cargo only requires the field
#     to be present. It reaches the generated vendor tree solely as alias labels
#     (serviceradar-netprobe-<version>) pointing at packages crates_vendor never emits.
#   * But mirroring it into Cargo.toml edited a manifest, which changed Cargo.lock, which
#     invalidated the vendored tree's input index, whose documented fix rewrote 625 crate
#     directories and discarded the Bazel cache
#     for every Rust target, to restate a version that changed no third-party crate.
#
# addons/<id>/addon.yaml is now the single source of truth. bazel_version_path() below
# still cross-checks the BUILD.bazel version constant, because that one genuinely stamps
# the built binary and is Bazel-side, so keeping it in step costs nothing.
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
      # The vendor tree is what -Z build-std compiles netprobe_ebpf.o against, so it
      # determines the shipped object's bytes just as much as rust/netprobe does. A
      # nightly bump touches neither addons/netprobe nor rust/netprobe, and without
      # it here the gate would let a changed artifact ship under an unchanged
      # version -- the false negative it exists to prevent.
      # rust/afpacket is compiled INTO this binary (the AF_PACKET capture ring),
      # exactly as rust/addon-sdk is, so a change there changes the shipped
      # bytes. Without it the gate would let an afpacket-only fix ship under an
      # unchanged add-on version -- the same false negative the vendor-tree note
      # above describes. path_is_test_only already exempts rust/*/tests/*, so
      # rust/afpacket/tests/live_capture.rs does not force a spurious bump.
      case "${path}" in
        addons/netprobe/*|rust/netprobe/*|rust/addon-sdk/*) return 0 ;;
        rust/afpacket/*) return 0 ;;
        third_party/netprobe_ebpf_vendor/*) return 0 ;;
      esac
      ;;
    powerdns)
      # rust/addon-sdk is compiled INTO this binary, so a change there changes
      # the shipped artifact exactly as a change to the add-on's own crate does.
      # Without it the gate has a false negative: SDK code that alters several
      # add-ons at once, under unchanged versions for all of them.
      case "${path}" in
        addons/powerdns/*|rust/powerdns/*|rust/addon-sdk/*) return 0 ;;
      esac
      ;;
    workload-identity)
      case "${path}" in
        addons/workload-identity/*|rust/workload-identity/*) return 0 ;;
      esac
      ;;
    bumblebee)
      case "${path}" in
        addons/bumblebee-scan/*|go/cmd/bumblebee-scan/*|go/pkg/bumblebee/*) return 0 ;;
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
      # rust/addon-sdk is compiled INTO this binary, so a change there changes
      # the shipped artifact exactly as a change to the add-on's own crate does.
      # Without it the gate has a false negative: SDK code that alters several
      # add-ons at once, under unchanged versions for all of them.
      case "${path}" in
        addons/anomaly-addon/*|rust/anomaly-addon/*|rust/addon-sdk/*) return 0 ;;
      esac
      ;;
    otel-collector)
      # rust/addon-sdk is compiled INTO this binary, so a change there changes
      # the shipped artifact exactly as a change to the add-on's own crate does.
      # Without it the gate has a false negative: SDK code that alters several
      # add-ons at once, under unchanged versions for all of them.
      case "${path}" in
        addons/otel-collector/*|rust/otel-addon/*|rust/otel/*|rust/addon-sdk/*) return 0 ;;
      esac
      ;;
  esac

  return 1
}

path_is_test_only() {
  local path="$1"

  # Rust unit/integration tests are compiled only into rust_test targets and
  # never into the signed native add-on bundle. Treating them as payload forces
  # operators to approve a new package version whose runtime bytes are
  # unchanged. Production sources under src/ remain version-gated.
  case "${path}" in
    rust/*/src/tests/*|rust/*/tests/*) return 0 ;;
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
  git diff --no-renames "${BASE_REF}" "${HEAD_REF}" -- build/native_addons/addon_inventory.bzl |
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

changed_paths="$(git diff --name-only --no-renames "${BASE_REF}" "${HEAD_REF}")"
required_bumps=""
version_checks=""
inventory_changed=false
inventory_mapped=false

while IFS= read -r path; do
  [[ -n "${path}" ]] || continue

  if [[ "${path}" == "build/native_addons/addon_inventory.bzl" ]]; then
    inventory_changed=true
    continue
  fi

  # Large crate-vendor refreshes can contain thousands of third_party paths.
  # None can map to an add-on payload directly, so avoid running every add-on
  # path matcher for unrelated repository subtrees.
  case "${path}" in
    addons/*|rust/*|go/cmd/*|go/pkg/*) ;;
    *) continue ;;
  esac

  while IFS= read -r addon; do
    if path_belongs_to_addon "${addon}" "${path}" && ! path_is_test_only "${path}"; then
      required_bumps="${required_bumps}${addon}"$'\n'
      version_checks="${version_checks}${addon}"$'\n'
    fi

    if [[ "${path}" == "$(manifest_path "${addon}")" ]]; then
      version_checks="${version_checks}${addon}"$'\n'
    fi

    bazel_path="$(bazel_version_path "${addon}" 2>/dev/null || true)"
    if [[ -n "${bazel_path}" && "${path}" == "${bazel_path}" ]]; then
      version_checks="${version_checks}${addon}"$'\n'
    fi
  done < <(addon_ids)

  # The RDP helper resolves its connector/CredSSP graph from the isolated
  # rdp_connector_crates universe, so that universe's manifest and lockfile are rdp payload
  # even though neither lives under rust/rdp-adapter.
  case "${path}" in
    rust/rdp-connector-probe/Cargo.lock|rust/rdp-connector-probe/Cargo.toml)
      required_bumps="${required_bumps}rdp"$'\n'
      version_checks="${version_checks}rdp"$'\n'
      ;;
  esac
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


# NO MODULE.bazel.lock STALENESS CHECK.
#
# There used to be one here, asserting that MODULE.bazel.lock recorded a
# `FILE:@@//rust/rdp-connector-probe/Cargo.{lock,toml} <sha256>` line, so release packaging
# resolved the connector graph from a reviewed pin. It worked under crate_universe, which
# is a non-reproducible module extension: Bazel therefore recorded its file inputs.
#
# rules_rs' crate extension returns extension_metadata(reproducible = True), and Bazel does
# not record results for a reproducible extension at all. 2a9c1eb04b ("migrate Rust to
# rules_rs") consequently dropped both lines from the lockfile, and no
# `bazel mod deps --lockfile_mode=update` can put them back -- verified, it is a no-op.
# The check has been unsatisfiable ever since and only stayed quiet because nothing had
# touched the probe manifest.
#
# The property it protected still holds by a different mechanism. A reproducible extension
# is a pure function of its inputs, and the input here is rust/rdp-connector-probe/Cargo.lock
# -- committed, diffed in review, and the same file the case above makes rdp payload. The
# lockfile recording was a crate_universe implementation detail, not the guarantee itself.

while IFS= read -r addon; do
  [[ -n "${addon}" ]] || continue

  manifest="$(manifest_path "${addon}")"
  addon_version="$(version_from_yaml "${HEAD_REF}" "${manifest}" || true)"

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
