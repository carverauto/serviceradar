"""Populate //third_party/crate_mirror from Cargo.lock.

Run it as a Bazel target, never by hand:

    bazel run //third_party/crate_mirror:sync

This is the vendoring step. It is a `bazel run` tool rather than a build action on
purpose: it fetches over the network and writes into the source tree, so it belongs in
the same category as gazelle. A build action that mutated the workspace would be the
hole in the dependency graph that everything else here exists to avoid.

What it produces is a directory of `<name>-<version>.crate` archives -- the exact
files Cargo's own registry cache holds, and the exact basenames Bazel's `--distdir`
matches on. //.bazelrc points --distdir at it, so every registry crate resolves from
the checked-in copy and the network is only consulted for something missing.

Each archive is verified against the `checksum` field Cargo already recorded in
Cargo.lock, so a corrupt or substituted download fails here rather than silently
becoming a build input.
"""

import hashlib
import os
import re
import sys
import urllib.request

# Matches the first URL //third_party/patches or rules_rs emits for crates.io. Keep the
# two in step: if rules_rs asks for a different name, --distdir stops matching and the
# mirror silently stops being used -- the build still works, it just downloads.
_URL = "https://static.crates.io/crates/{name}/{name}-{version}.crate"


# Parsed by hand rather than with tomllib: the Python toolchain Bazel supplies predates
# 3.11. Cargo.lock is a generated file with a fixed, simple shape -- a sequence of
# [[package]] tables whose scalar fields are always `key = "value"` on one line -- so a
# line scanner is sufficient and adds no dependency.
_FIELD = re.compile(r'^(name|version|checksum) = "([^"]*)"')

# Every `cargo_lock = "<label>"` a from_cargo tag names in //MODULE.bazel.
_CARGO_LOCK_LABEL = re.compile(r'^\s*cargo_lock\s*=\s*"([^"]+)"', re.MULTILINE)


def lockfiles(workspace):
    """Return every Cargo.lock that feeds a rules_rs hub, workspace-relative.

    Derived from //MODULE.bazel rather than hardcoded, because that file is what decides
    which hubs exist. There is more than one: //rust/rdp-connector-probe is deliberately
    detached from the workspace with its own [workspace] table and its own lockfile, so
    the root Cargo.lock does not mention any of its dependencies.

    Reading only the root lockfile is exactly the bug this replaced. `cargo vendor`
    operated on the root workspace, the mirror inherited that boundary, and 140 of the RDP
    connector universe's 304 registry crates were therefore never vendored -- downloaded
    from crates.io on every build instead, because --distdir misses quietly.
    """
    module = os.path.join(workspace, "MODULE.bazel")
    with open(module, "r", encoding="utf-8") as handle:
        contents = handle.read()

    paths = []
    for label in _CARGO_LOCK_LABEL.findall(contents):
        # "//pkg:Cargo.lock" -> "pkg/Cargo.lock"; "//:Cargo.lock" -> "Cargo.lock".
        package, _, name = label.lstrip("/").partition(":")
        path = os.path.join(package, name) if package else name
        if path not in paths:
            paths.append(path)

    if not paths:
        sys.exit(
            "no cargo_lock labels found in MODULE.bazel; the mirror would be emptied"
        )
    return paths


def _archives(lock_path):
    """Yield (filename, url, sha256) for every registry crate in the lockfile."""
    packages = []
    current = None
    with open(lock_path, "r", encoding="utf-8") as handle:
        for line in handle:
            line = line.strip()
            if line == "[[package]]":
                current = {}
                packages.append(current)
                continue
            if current is None:
                continue
            if line.startswith("["):
                # A new table that is not [[package]] ends the current package.
                current = None
                continue
            match = _FIELD.match(line)
            if match:
                current[match.group(1)] = match.group(2)

    for package in packages:
        checksum = package.get("checksum")
        if not checksum:
            # No checksum means a path or git dependency: it has no registry archive,
            # and it is already in the repository or pinned by commit.
            continue
        name, version = package["name"], package["version"]
        yield (
            "{}-{}.crate".format(name, version),
            _URL.format(name=name, version=version),
            checksum,
        )


def _sha256(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def main():
    workspace = os.environ.get("BUILD_WORKSPACE_DIRECTORY")
    if not workspace:
        sys.exit("Run this with `bazel run //third_party/crate_mirror:sync`.")

    mirror = os.path.join(workspace, "third_party", "crate_mirror")
    os.makedirs(mirror, exist_ok=True)

    # Deduplicated across hubs by filename: two lockfiles that pin the same crate at the
    # same version want the same archive, and --distdir matches on basename alone.
    by_filename = {}
    for lock in lockfiles(workspace):
        for filename, url, checksum in _archives(os.path.join(workspace, lock)):
            previous = by_filename.get(filename)
            if previous and previous[2] != checksum:
                # crates.io is immutable, so one name+version cannot legitimately carry
                # two checksums. Rather than pick one, stop: --distdir keys on the
                # basename, so whichever archive won would silently feed both hubs.
                sys.exit(
                    "conflicting checksums for {}\n  {}\n  {}".format(
                        filename, previous[2], checksum
                    )
                )
            by_filename[filename] = (filename, url, checksum)
        print("  {} crates from {}".format(len(by_filename), lock))

    wanted = sorted(by_filename.values())
    expected = set(by_filename)

    fetched = verified = 0
    for filename, url, checksum in wanted:
        path = os.path.join(mirror, filename)

        if os.path.exists(path):
            # Re-verify rather than trust the name: a truncated download from an
            # interrupted run would otherwise sit in the tree looking correct.
            if _sha256(path) == checksum:
                verified += 1
                continue
            print("  corrupt, refetching: {}".format(filename))
            os.remove(path)

        urllib.request.urlretrieve(url, path)
        actual = _sha256(path)
        if actual != checksum:
            os.remove(path)
            sys.exit(
                "checksum mismatch for {}\n  Cargo.lock: {}\n  downloaded: {}".format(
                    filename, checksum, actual
                )
            )
        fetched += 1
        print("  fetched: {}".format(filename))

    # Archives for crates no longer in the lockfile are dead weight, and leaving them
    # makes the mirror grow without bound across dependency bumps.
    stale = [
        name
        for name in os.listdir(mirror)
        if name.endswith(".crate") and name not in expected
    ]
    for name in sorted(stale):
        os.remove(os.path.join(mirror, name))
        print("  removed stale: {}".format(name))

    print(
        "\n{} crates: {} already present, {} fetched, {} stale removed".format(
            len(wanted), verified, fetched, len(stale)
        )
    )


if __name__ == "__main__":
    main()
