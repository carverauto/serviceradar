"""Execute release tag validation and prerelease detection without publishing."""

import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = (
    Path(os.environ["TEST_SRCDIR"]) / os.environ["TEST_WORKSPACE"]
    if "TEST_SRCDIR" in os.environ
    else Path(__file__).resolve().parents[2]
)
SCRIPTS = ROOT / "scripts"


class ReleaseTagTest(unittest.TestCase):
    def test_validator_accepts_release_and_legacy_and_dotted_prereleases(self):
        versions = ["0.0.0", "1.4.10"]
        for label in ("pre", "rc", "alpha", "beta"):
            versions.extend(f"1.4.10-{label}{suffix}" for suffix in ("0", "10", ".0", ".1", ".10"))
        for version in versions:
            with self.subTest(version=version):
                result = subprocess.run(
                    [SCRIPTS / "validate-release-tag.sh", f"v{version}"], capture_output=True, text=True
                )
                self.assertEqual(result.returncode, 0, result.stderr)

    def test_validator_rejects_malformed_tags(self):
        for tag in (
            "1.4.10", "v01.4.10", "v1.4.010", "v1.4.10-pre", "v1.4.10-pre01",
            "v1.4.10-pre.", "v1.4.10-pre.01", "v1.4.10-pre..1", "v1.4.10-pre.1.2",
            "v1.4.10-rc.-1", "v1.4.10-preview.1", "v1.4.10\ntag=v9.9.9",
        ):
            with self.subTest(tag=tag):
                result = subprocess.run(
                    [SCRIPTS / "validate-release-tag.sh", tag], capture_output=True, text=True
                )
                self.assertNotEqual(result.returncode, 0, tag)

    def test_release_dry_run_detects_prereleases_and_preserves_checkout(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            remote = root / "remote.git"
            repo = root / "repo"
            subprocess.run(["git", "init", "-q", "--bare", remote], check=True)
            subprocess.run(["git", "init", "-q", repo], check=True)
            subprocess.run(["git", "-C", repo, "remote", "add", "origin", remote], check=True)
            version_file = repo / "VERSION"
            version_file.write_text("1.4.9\n")
            helm = root / "helm"
            helm.write_text("#!/bin/sh\necho 'Error: MANIFEST_UNKNOWN' >&2\nexit 1\n")
            helm.chmod(0o755)
            env = dict(os.environ, SERVICERADAR_HELM_RUNNER=str(helm), OCI_REGISTRY="registry.example.invalid")
            for version in ("1.4.10-pre1", "1.4.10-pre.1", "1.4.10-rc.2", "1.4.10-alpha.3", "1.4.10-beta.10", "1.4.10"):
                with self.subTest(version=version):
                    result = subprocess.run(
                        [SCRIPTS / "cut-release.sh", "--version", version, "--dry-run", "--skip-changelog-check"],
                        cwd=repo, env=env, capture_output=True, text=True,
                    )
                    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                    if "-" in version:
                        self.assertIn(f"Detected pre-release version: {version}", result.stdout)
                        self.assertIn(f"Pre-release preparation complete for v{version}", result.stdout)
                    else:
                        self.assertNotIn("Detected pre-release version", result.stdout)
                        self.assertIn(f"Release preparation complete for v{version}", result.stdout)
                    self.assertEqual(version_file.read_text(), "1.4.9\n")
                    self.assertEqual(subprocess.check_output(["git", "tag"], cwd=repo, text=True), "")


if __name__ == "__main__":
    unittest.main()
