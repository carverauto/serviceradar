#!/usr/bin/env python3
"""Assert the vendored crate archives are complete and committed.

//third_party/crate_mirror holds one `<name>-<version>.crate` per registry crate in
//:Cargo.lock. //.bazelrc points --distdir at it, so a build resolves those archives
from disk instead of crates.io.

--distdir is a fallback rather than an enforcement: an archive that is missing is
simply downloaded, and the build stays green. That is good for resilience and bad for
noticing, because a half-committed mirror looks exactly like a complete one until
someone builds without network access. This gate is what notices.

It replaces a check built around the older `cargo vendor` tree, which asserted a
`.cargo-checksum.json` and a generated BUILD file per crate directory. Neither exists
now: the mirror is archives only, and rules_rs generates the BUILD files.
"""

from __future__ import annotations

import pathlib
import re
import subprocess
import sys

MIRROR = "third_party/crate_mirror"

# Cargo.lock is generated and its shape is stable: [[package]] tables whose scalar
# fields are `key = "value"` on one line. A `checksum` means a registry crate, which is
# the only kind with an archive to vendor.
_FIELD = re.compile(r'^(name|version|checksum) = "([^"]*)"')


def registry_crates(lock_path: pathlib.Path) -> set[str]:
    packages: list[dict[str, str]] = []
    current: dict[str, str] | None = None
    for line in lock_path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if line == "[[package]]":
            current = {}
            packages.append(current)
            continue
        if current is None:
            continue
        if line.startswith("["):
            current = None
            continue
        match = _FIELD.match(line)
        if match:
            current[match.group(1)] = match.group(2)

    return {
        "{}-{}.crate".format(p["name"], p["version"])
        for p in packages
        if p.get("checksum")
    }


def main() -> int:
    root = pathlib.Path(
        subprocess.run(
            ["git", "rev-parse", "--show-toplevel"],
            check=True,
            capture_output=True,
            text=True,
        ).stdout.strip()
    )

    tracked = {
        pathlib.PurePosixPath(path).name
        for path in subprocess.run(
            ["git", "ls-files", "-z", "--", MIRROR],
            check=True,
            capture_output=True,
            text=True,
            cwd=root,
        ).stdout.split("\0")
        if path.endswith(".crate")
    }

    wanted = registry_crates(root / "Cargo.lock")

    missing = sorted(wanted - tracked)
    extra = sorted(tracked - wanted)

    if missing:
        print(
            "error: {} crate archive(s) in Cargo.lock are not committed under {}".format(
                len(missing), MIRROR
            ),
            file=sys.stderr,
        )
        for name in missing[:20]:
            print("  {}".format(name), file=sys.stderr)
        if len(missing) > 20:
            print("  ... and {} more".format(len(missing) - 20), file=sys.stderr)

    if extra:
        print(
            "error: {} committed archive(s) are no longer in Cargo.lock".format(len(extra)),
            file=sys.stderr,
        )
        for name in extra[:20]:
            print("  {}".format(name), file=sys.stderr)

    if missing or extra:
        print(
            "\nrun `bazel run //third_party/crate_mirror:sync`, then commit "
            "{}".format(MIRROR),
            file=sys.stderr,
        )
        return 1

    print("{} crate archives tracked, matching Cargo.lock".format(len(wanted)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
