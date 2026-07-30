#!/usr/bin/env bash
# Refresh third_party/crates/.serviceradar-vendor-inputs WITHOUT re-vendoring.
#
# Why this exists
# ---------------
# The native add-on version gate requires that snapshot to record the current sha256 of
# Cargo.lock, the root Cargo.toml, and every workspace member manifest. Bumping an add-on's
# [package] version -- which that same gate demands whenever the add-on's source changes --
# changes two of those hashes, so the gate then fails for a stale snapshot.
#
# scripts/vendor.sh does regenerate the snapshot, but only as the last step of rebuilding the
# whole vendored tree: it `rm -rf`s third_party/crates, re-runs crates_vendor, reapplies the
# openssl-src and pq-src patches, and finishes with `bazel build //third_party/crates/...`.
# That rewrites 625 crate directories, which invalidates the Bazel cache for effectively every
# Rust target -- an enormous price for a version string that changed no third-party crate.
#
# So this script does only the final step, and refuses to run when a real re-vendor is
# actually needed.
#
# WHEN NOT TO USE THIS
# --------------------
# If you added, removed, or changed the version of a *third-party* dependency, the vendored
# tree itself is out of date and only scripts/vendor.sh can fix it. The guard below catches
# the common form of that mistake by checking that every non-workspace package in Cargo.lock
# still has a vendored directory. It is a backstop, not a proof: it cannot detect a crate
# whose contents changed while keeping the same name and version. When in doubt, run
# scripts/vendor.sh.
#
# Usage:
#   scripts/refresh-rust-vendor-inputs.sh            # verify, then rewrite the snapshot
#   scripts/refresh-rust-vendor-inputs.sh --check    # report drift only, never write

set -euo pipefail

mode="write"
case "${1:-}" in
  --check) mode="check" ;;
  "") ;;
  *)
    echo "usage: $0 [--check]" >&2
    exit 2
    ;;
esac

repo_root="$(git rev-parse --show-toplevel)"
cd "${repo_root}"

if ! command -v cargo >/dev/null 2>&1; then
  echo "error: cargo is required to enumerate workspace manifests." >&2
  exit 1
fi

MODE="${mode}" python3 - <<'PY'
import hashlib
import json
import os
import pathlib
import re
import subprocess
import sys

mode = os.environ["MODE"]
root = pathlib.Path.cwd()
snapshot = root / "third_party" / "crates" / ".serviceradar-vendor-inputs"
vendor_root = root / "third_party" / "crates"

# --- Guard: does the committed vendored tree still cover Cargo.lock? -------------------
# Cargo vendors a crate into <name>-<version>/, replacing semver build metadata '+' with '-'
# (openssl-src-300.6.1+3.6.3 -> openssl-src-300.6.1-3.6.3). A package carrying a `source`
# key is third-party; workspace members and path dependencies have none and are never
# vendored.
lock_text = (root / "Cargo.lock").read_text()
third_party = []
for block in lock_text.split("[[package]]"):
    name = re.search(r'^name = "(.+)"$', block, re.M)
    version = re.search(r'^version = "(.+)"$', block, re.M)
    if name and version and re.search(r"^source = ", block, re.M):
        third_party.append((name.group(1), version.group(1)))

missing = [
    f"{name}-{version}"
    for name, version in third_party
    if not (vendor_root / f"{name}-{version}".replace("+", "-")).is_dir()
]

if missing:
    print(
        "error: the committed vendor tree does not cover Cargo.lock; "
        f"{len(missing)} package(s) have no vendored directory:",
        file=sys.stderr,
    )
    for entry in missing[:10]:
        print(f"  {entry}", file=sys.stderr)
    if len(missing) > 10:
        print(f"  ... and {len(missing) - 10} more", file=sys.stderr)
    print(
        "\nA third-party dependency changed, so the vendored tree itself is stale and this\n"
        "script cannot fix it. Run scripts/vendor.sh and commit the refreshed tree.",
        file=sys.stderr,
    )
    raise SystemExit(1)

# --- Recompute the snapshot, byte-for-byte as scripts/vendor.sh does -------------------
metadata = json.loads(
    subprocess.check_output(
        ["cargo", "metadata", "--locked", "--offline", "--no-deps", "--format-version", "1"],
        cwd=root,
        text=True,
    )
)

paths = {root / "Cargo.lock", root / "Cargo.toml"}
paths.update(pathlib.Path(p["manifest_path"]).resolve() for p in metadata["packages"])

# Emission order must match scripts/vendor.sh, which iterates `sorted(paths)` -- i.e. sorts
# pathlib.Path objects by their parts, not the rendered labels. The two disagree: as strings
# "@@//rust/otel-addon/..." sorts before "@@//rust/otel/..." because '-' (0x2D) precedes '/'
# (0x2F), while as paths "otel" precedes "otel-addon". Sorting the wrong one produces a
# snapshot that is correct but reorders lines, which is pure diff noise against vendor.sh.
ordered = []
expected = {}
for path in sorted(paths):
    relative = path.relative_to(root).as_posix()
    label = f"@@//{relative}"
    digest = hashlib.sha256(path.read_bytes()).hexdigest()
    ordered.append(label)
    expected[label] = digest

committed = {}
if snapshot.exists():
    for line in snapshot.read_text().splitlines():
        if not line.strip():
            continue
        _, _, rest = line.partition(":")
        label, _, digest = rest.partition(" ")
        committed[label] = digest

stale = sorted(k for k in expected if committed.get(k) != expected[k])
removed = sorted(k for k in committed if k not in expected)

if not stale and not removed:
    print(f"vendor input snapshot is current ({len(expected)} entries)")
    raise SystemExit(0)

for label in stale:
    was = committed.get(label)
    prefix = "added  " if was is None else "stale  "
    was_text = "absent" if was is None else f"{was[:16]}.."
    print(f"  {prefix} {label}\n           {was_text} -> {expected[label][:16]}..")
for label in removed:
    print(f"  removed {label}")

if mode == "check":
    print(
        f"\n{len(stale) + len(removed)} entry/entries drifted. "
        "Run scripts/refresh-rust-vendor-inputs.sh to update.",
        file=sys.stderr,
    )
    raise SystemExit(1)

snapshot.write_text(
    "\n".join(f"FILE:{label} {expected[label]}" for label in ordered) + "\n"
)
print(f"\nrewrote {snapshot.relative_to(root)} ({len(expected)} entries)")
PY
