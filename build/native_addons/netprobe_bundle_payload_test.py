#!/usr/bin/env python3

import hashlib
import os
from pathlib import Path
import sys
import tarfile
import unittest


BINARY_NAME = "serviceradar-netprobe"
BINARY_MODE = 0o755
EBPF_OBJECT_NAME = "netprobe_ebpf.o"
EBPF_OBJECT_MODE = 0o644


def resolve_runfile(path: str) -> Path:
    candidate = Path(path)
    if candidate.is_file():
        return candidate

    test_srcdir = os.environ.get("TEST_SRCDIR")
    test_workspace = os.environ.get("TEST_WORKSPACE")
    if test_srcdir and test_workspace:
        candidate = Path(test_srcdir) / test_workspace / path
        if candidate.is_file():
            return candidate

    raise FileNotFoundError(f"declared runfile does not exist: {path}")


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def sha256_member(archive: tarfile.TarFile, member: tarfile.TarInfo) -> str:
    source = archive.extractfile(member)
    if source is None:
        raise AssertionError(f"regular tar member {member.name!r} has no payload")

    digest = hashlib.sha256()
    with source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


class NetprobeBundlePayloadTest(unittest.TestCase):
    def assert_payload_matches_runfile(
        self,
        archive: tarfile.TarFile,
        name: str,
        mode: int,
        declared_runfile: Path,
    ) -> None:
        matches = [member for member in archive.getmembers() if member.name == name]
        self.assertEqual(1, len(matches), f"tarball must contain exactly one {name!r}")

        member = matches[0]
        self.assertTrue(member.isfile(), f"tarball member {name!r} must be a regular file")
        self.assertEqual(
            mode,
            member.mode & 0o7777,
            f"tarball member {name!r} has the wrong mode",
        )
        self.assertEqual(
            declared_runfile.stat().st_size,
            member.size,
            f"tarball member {name!r} size differs from its declared runfile",
        )
        self.assertEqual(
            sha256_file(declared_runfile),
            sha256_member(archive, member),
            f"tarball member {name!r} SHA-256 differs from its declared runfile",
        )

    def test_netprobe_runtime_payload_matches_declared_build_outputs(self):
        with tarfile.open(TARBALL, "r:gz") as archive:
            self.assert_payload_matches_runfile(
                archive,
                BINARY_NAME,
                BINARY_MODE,
                STATIC_BINARY,
            )
            self.assert_payload_matches_runfile(
                archive,
                EBPF_OBJECT_NAME,
                EBPF_OBJECT_MODE,
                EBPF_OBJECT,
            )


if len(sys.argv) != 4:
    raise SystemExit(
        f"usage: {sys.argv[0]} <netprobe-tarball> <static-binary> <ebpf-object>"
    )

TARBALL, STATIC_BINARY, EBPF_OBJECT = (
    resolve_runfile(path) for path in sys.argv[1:]
)
del sys.argv[1:]


if __name__ == "__main__":
    unittest.main()
