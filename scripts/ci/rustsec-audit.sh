#!/usr/bin/env bash
# RustSec audit of every Cargo.lock in the repository.
#
# usage: scripts/ci/rustsec-audit.sh <advisory-db-dir>
#
# Fails on any RustSec vulnerability, any warning (unmaintained, unsound, yanked) that is
# not listed in ignores_for() below, and on any lockfile whose yanked check could not run.
#
# Why this exists. The previous CI step audited only rust/rdp-connector-probe/Cargo.lock,
# so advisories against the root workspace and the other standalone crates accumulated
# unseen. It also passed --no-fetch, and cargo-audit couples the crates.io index refresh
# to the advisory-db fetch: with --no-fetch it only reads the local index cache, which is
# empty on a fresh runner, so every package logged "couldn't check if the package is
# yanked" as a non-fatal message and the yanked check silently never ran.
#
# This script therefore:
#   * discovers lockfiles with `git ls-files`, so a new standalone crate is audited
#     without anyone editing this file;
#   * lets cargo-audit fetch (advisory db into <advisory-db-dir>, and the crates.io
#     sparse index entries it needs for the yanked check);
#   * treats a yanked check that could not run as a failure, not as a pass.
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 <advisory-db-dir>" >&2
  exit 2
fi
advisory_db="$1"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${REPO_ROOT}"

if ! command -v cargo-audit >/dev/null 2>&1; then
  echo "cargo-audit is not on PATH; refusing to report an audit that did not run" >&2
  exit 1
fi

# Accepted advisories, per lockfile. Every entry needs a reason a reviewer can check:
# what pulls the crate in, and why the advisory is not reachable or has no fix. Remove an
# entry when its crate leaves the lockfile or a fixed version becomes available.
ignores_for() {
  case "$1" in
    Cargo.lock)
      # rkyv 0.7.46: optional dependency of rust_decimal whose `rkyv` feature nothing
      #   enables; `cargo tree --target all -e all -i rkyv` prints nothing, so it is never
      #   compiled. The fix is only in rkyv 0.8.
      echo RUSTSEC-2026-0235
      # rsa 0.9.10 (Marvin timing side channel): no fixed release exists. Reached only
      #   through zen-engine -> reqsign, the cloud request-signing used by zen function
      #   nodes' HTTP auth providers.
      echo RUSTSEC-2023-0071
      # time 0.3.46: the fix (0.3.47) cannot be taken. async-nats' blanket
      #   `impl<Kind> From<Kind> for Error<Kind>` fails to compile (E0119) against
      #   time >= 0.3.47, which is why the root Cargo.toml caps time below 0.3.47. The
      #   advisory covers parsing with the Rfc2822 well-known format only; no first-party
      #   code parses RFC 2822, and the in-graph dependents only format it.
      echo RUSTSEC-2026-0009
      # zip 8.6.0, pinned by zen-engine (`zip = "8"` through its latest release). All
      #   three advisories are in ZipArchive::extract / ZipStreamReader::extract;
      #   zen-engine only reads .json entries into memory and never extracts to disk.
      echo RUSTSEC-2026-0367
      echo RUSTSEC-2026-0368
      echo RUSTSEC-2026-0369
      # net2 (unmaintained): mio 0.6 inside the vendored rperf patch crate.
      echo RUSTSEC-2020-0016
      # rustls-pemfile (unmaintained): a direct dependency; replacing it with the
      #   rustls-pki-types PEM API is a source change tracked separately.
      echo RUSTSEC-2025-0134
      # smartstring (unmaintained): swc_ecma_parser inside zen-engine.
      echo RUSTSEC-2026-0249
      # diesel-async 0.7.4 (unsound): the defect is in the MySQL backend's date/time
      #   handling; srql enables only the `postgres` backend. The fix is 0.9.0, a
      #   breaking upgrade of srql's database layer tracked separately.
      echo RUSTSEC-2026-0138
      ;;
    elixir/web-ng/native/srql_nif/Cargo.lock)
      # Same rustls-pemfile and diesel-async reasoning as the root lockfile; this crate
      # builds rust/srql from source.
      echo RUSTSEC-2025-0134
      echo RUSTSEC-2026-0138
      ;;
    rust/netprobe/ebpf/Cargo.lock)
      # anyhow 1.0.102 (unsound downcast_mut after context): only aya-build, the host
      #   build script of aya-ebpf, uses it; it is not in the shipped eBPF object. The
      #   fix means re-vendoring third_party/netprobe_ebpf_vendor, which is tied to the
      #   pinned nightly (see that directory's README).
      echo RUSTSEC-2026-0190
      ;;
    rust/rdp-connector-probe/Cargo.lock)
      # Reviewed IronRDP family: blocking/connector 0.10.0, core 0.2.1, graphics/pdu
      # 0.9.0, session 0.11.0.
      # rsa Marvin timing issue via connector 0.10.0 -> sspi 0.21.1 -> picky
      #   7.0.0-rc.25; no fixed upgrade is available in this IronRDP family.
      echo RUSTSEC-2023-0071
      # atomic-polyfill is unmaintained, in connector 0.10.0's forced sspi/scard build
      #   subtree; ServiceRadar rejects smart-card redirection at runtime.
      echo RUSTSEC-2023-0089
      ;;
  esac
}

# A directory holding .cargo-checksum.json is a `cargo vendor` copy of a dependency's
# source. Cargo never resolves a dependency's own Cargo.lock, so those lockfiles describe
# nothing that is built; third_party/netprobe_ebpf_vendor/ carries dozens of them.
lockfiles=()
skipped=0
while IFS= read -r lockfile; do
  if [[ -f "$(dirname "${lockfile}")/.cargo-checksum.json" ]]; then
    skipped=$((skipped + 1))
    continue
  fi
  lockfiles+=("${lockfile}")
done < <(git ls-files -- '*Cargo.lock')

if [[ ${#lockfiles[@]} -eq 0 ]]; then
  echo "no Cargo.lock files found; refusing to report an audit of nothing" >&2
  exit 1
fi

echo "auditing ${#lockfiles[@]} lockfile(s); skipping ${skipped} vendored-dependency lockfile(s)"

summary="${GITHUB_STEP_SUMMARY:-/dev/null}"
{
  echo "## RustSec audit"
  echo
  echo "| Lockfile | Result | Accepted advisories |"
  echo "| --- | --- | --- |"
} >> "${summary}"

log="$(mktemp)"
trap 'rm -f "${log}"' EXIT

index_attempts=4
failed=()
for lockfile in "${lockfiles[@]}"; do
  args=()
  ignored=()
  while IFS= read -r id; do
    [[ -n "${id}" ]] || continue
    args+=(--ignore "${id}")
    ignored+=("${id}")
  done < <(ignores_for "${lockfile}")

  # A cold crates.io index makes some yanked-check lookups time out. Entries that did
  # arrive stay cached in CARGO_HOME, so a retry only refetches the ones that failed.
  for attempt in $(seq 1 "${index_attempts}"); do
    echo
    echo "=== ${lockfile} (attempt ${attempt}/${index_attempts})"
    status=0
    cargo audit --db "${advisory_db}" --file "${lockfile}" --deny warnings \
      ${args[@]+"${args[@]}"} > "${log}" 2>&1 || status=$?
    cat "${log}"

    result="pass"
    if [[ ${status} -ne 0 ]]; then
      result="FAIL (cargo audit exit ${status})"
    fi
    # cargo-audit reports an index it could not read as a message, not as a failure, and
    # carries on: the yanked check then silently covers nothing.
    if grep -Eq "couldn't (check if the package is yanked|update crates.io index)" "${log}"; then
      result="FAIL (yanked check could not run)"
      continue
    fi
    break
  done
  if [[ "${result}" != "pass" ]]; then
    failed+=("${lockfile}: ${result}")
  fi

  echo "| \`${lockfile}\` | ${result} | ${ignored[*]:-none} |" >> "${summary}"
done

if [[ -d "${advisory_db}/.git" ]]; then
  echo
  echo "advisory-db: $(git -C "${advisory_db}" log -1 --format='%H %cI')"
  echo >> "${summary}"
  echo "advisory-db commit: \`$(git -C "${advisory_db}" log -1 --format='%H')\`" >> "${summary}"
fi

if [[ ${#failed[@]} -ne 0 ]]; then
  echo
  echo "RustSec audit failed:" >&2
  printf '  %s\n' "${failed[@]}" >&2
  exit 1
fi

echo
echo "RustSec audit passed for ${#lockfiles[@]} lockfile(s)"
