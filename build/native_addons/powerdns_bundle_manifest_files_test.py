#!/usr/bin/env python3

import os
from pathlib import Path, PurePosixPath
import sys
import tarfile
import unittest
import zipfile


REFERENCE_KEYS = {"payload_schema", "display_contract"}


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

    raise FileNotFoundError(f"declared tarball runfile does not exist: {path}")


def manifest_file_references(manifest: str) -> list[tuple[str, str]]:
    references = []

    for raw_line in manifest.splitlines():
        key, separator, raw_value = raw_line.strip().partition(":")
        if not separator or key not in REFERENCE_KEYS:
            continue

        value = raw_value.strip().strip("\"'")
        if value:
            references.append((key, value))

    return references


class PowerDNSBundleManifestFilesTest(unittest.TestCase):
    def test_manifest_referenced_schema_and_display_files_are_packaged(self):
        with zipfile.ZipFile(BUNDLE) as archive:
            zip_members = set(archive.namelist())
            references = manifest_file_references(archive.read("addon.yaml").decode("utf-8"))

        self.assertTrue(references, "addon.yaml declares no payload or display files")

        missing_from_zip = [
            f"{key} {reference!r}"
            for key, reference in references
            if reference not in zip_members
        ]
        self.assertEqual(
            [],
            missing_from_zip,
            "addon.yaml references files absent from the signed ZIP bundle",
        )

        with tarfile.open(TARBALL, "r:gz") as archive:
            tar_members = set(archive.getnames())

        missing_from_tarball = []

        for key, reference in references:
            # Pushed-artifact tarballs are deliberately single-segment because the
            # agent rejects nested paths. The signed ZIP retains the directory path
            # used by web import; the agent tarball carries the same file by basename.
            packaged_name = PurePosixPath(reference).name
            if packaged_name not in tar_members:
                missing_from_tarball.append(
                    f"{key} {reference!r} (expected {packaged_name!r})"
                )

        self.assertEqual(
            [],
            missing_from_tarball,
            "addon.yaml references files absent from the pushed-artifact tarball",
        )


if len(sys.argv) != 3:
    raise SystemExit(
        f"usage: {sys.argv[0]} <powerdns-addon-bundle.zip> <powerdns-addon-tarball>"
    )

BUNDLE, TARBALL = (resolve_runfile(path) for path in sys.argv[1:])
del sys.argv[1:]


if __name__ == "__main__":
    unittest.main()
