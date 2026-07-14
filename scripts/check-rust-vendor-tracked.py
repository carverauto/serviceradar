#!/usr/bin/env python3
"""Fail when Cargo's committed vendor snapshot omits checksum-listed files."""

from __future__ import annotations

import json
import pathlib
import subprocess
import sys


def main() -> int:
    root = pathlib.Path(
        subprocess.check_output(
            ["git", "rev-parse", "--show-toplevel"], text=True
        ).strip()
    )
    vendor_root = root / "third_party" / "crates"
    tracked_output = subprocess.check_output(
        ["git", "ls-files", "-z", "--", "third_party/crates"]
    )
    tracked = {
        pathlib.PurePosixPath(path.decode())
        for path in tracked_output.split(b"\0")
        if path
    }

    checksum_files = sorted(vendor_root.glob("*/.cargo-checksum.json"))
    if not checksum_files:
        print("error: no vendored Cargo checksum manifests found", file=sys.stderr)
        return 1

    missing: list[pathlib.PurePosixPath] = []
    expected = {
        pathlib.PurePosixPath("third_party/crates/.serviceradar-vendor-inputs"),
        pathlib.PurePosixPath("third_party/crates/BUILD.bazel"),
        pathlib.PurePosixPath("third_party/crates/alias_rules.bzl"),
        pathlib.PurePosixPath("third_party/crates/defs.bzl"),
    }
    for checksum_path in checksum_files:
        checksum_relative = pathlib.PurePosixPath(
            checksum_path.relative_to(root).as_posix()
        )
        expected.add(checksum_relative)
        expected.add(checksum_relative.parent / "BUILD.bazel")
        if checksum_relative not in tracked or not checksum_path.is_file():
            missing.append(checksum_relative)

        checksum = json.loads(checksum_path.read_text(encoding="utf-8"))
        for crate_relative in checksum.get("files", {}):
            relative = pathlib.PurePosixPath(
                checksum_path.parent.relative_to(root).as_posix()
            ) / pathlib.PurePosixPath(crate_relative)
            expected.add(relative)
            if relative not in tracked or not (root / relative).is_file():
                missing.append(relative)

    if missing:
        print(
            "error: Cargo vendor snapshot omits checksum-listed files:",
            file=sys.stderr,
        )
        for relative in sorted(set(missing)):
            print(f"  {relative}", file=sys.stderr)
        print(
            "run scripts/vendor.sh, then commit the complete "
            "third_party/crates tree",
            file=sys.stderr,
        )
        return 1

    unexpected = sorted(tracked - expected)
    if unexpected:
        print(
            "error: Cargo vendor snapshot contains files absent from its "
            "checksum manifests:",
            file=sys.stderr,
        )
        for relative in unexpected:
            print(f"  {relative}", file=sys.stderr)
        return 1

    print(
        f"Cargo vendor snapshot is complete: {len(checksum_files)} crate manifests"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
