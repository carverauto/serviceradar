"""The pinned Rekor keys and the Cosign version the signer and the web-ng image share.

openspec/changes/restore-signature-tlog-receipts, design.md Decisions 5 and 6.
"""

import base64
import hashlib
import json
import os
import platform
import re
import subprocess
import tarfile
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
SIGSTORE = REPO / "docs/sigstore"
IMAGE_SIGSTORE = "usr/share/serviceradar/sigstore"
ALLOWLIST = SIGSTORE / "pre-cutover-first-party-digests.json"
# The pre-cutover allowlist is frozen (design.md, Decision 9): generated once from every
# Wasm plugin and native add-on index published before the cutover release and never
# regenerated or extended. Changing this hash is changing what imports without a receipt.
FROZEN_ALLOWLIST_SHA256 = "55c904103d4b22a3bb08f0e7405e808f88b40e763710d61c48decb4b7ad644df"
# GHSA-whqx-f9j3-ch6m (3.0.4), GHSA-wfqv-66vq-46rm (3.0.5), GHSA-w6c6-c85g-mmv6 (3.0.6),
# GHSA-fx35-mq7g-6g98 (3.1.3).
MINIMUM_COSIGN = (3, 1, 3)


def log_id(pem):
    lines = [line.strip() for line in pem.decode("ascii").splitlines() if line.strip()]
    if lines[0] != "-----BEGIN PUBLIC KEY-----" or lines[-1] != "-----END PUBLIC KEY-----":
        raise AssertionError("not a single PEM public key")
    return hashlib.sha256(base64.b64decode("".join(lines[1:-1]), validate=True)).hexdigest()


def pinned_cosign():
    machine = platform.machine().lower()
    repository = {"x86_64": "cosign_linux_amd64", "amd64": "cosign_linux_amd64",
                  "aarch64": "cosign_linux_arm64", "arm64": "cosign_linux_arm64"}[machine]
    for dirpath, _dirnames, filenames in os.walk(os.environ["TEST_SRCDIR"], followlinks=True):
        if repository in dirpath and "downloaded" in filenames:
            return Path(dirpath) / "downloaded"
    raise FileNotFoundError("declared cosign runfile is unavailable")


CURL_STUB = """#!/bin/bash
url="" out=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
printf '%s\\n' "${url}" >> "${CURL_RECORD}"
cp "${PINNED_COSIGN}" "${out}"
"""


class RekorKeySetTest(unittest.TestCase):
    def test_every_accepted_key_is_named_by_its_log_id(self):
        keys = sorted((SIGSTORE / "rekor-keys").glob("*.pub"))
        self.assertTrue(keys, "docs/sigstore/rekor-keys holds no accepted Rekor key")
        for key in keys:
            with self.subTest(key=key.name):
                self.assertEqual(key.name, log_id(key.read_bytes()) + ".pub")

    def test_pre_cutover_keys_are_named_by_log_id_and_never_accepted(self):
        accepted = {key.name for key in (SIGSTORE / "rekor-keys").glob("*.pub")}
        for key in sorted((SIGSTORE / "pre-cutover-rekor-keys").glob("*.pub")):
            with self.subTest(key=key.name):
                self.assertEqual(key.name, log_id(key.read_bytes()) + ".pub")
                self.assertNotIn(key.name, accepted)

    def test_signing_log_key_is_a_member_of_the_accepted_set(self):
        signing = (SIGSTORE / "rekor.pub").read_bytes()
        member = SIGSTORE / "rekor-keys" / (log_id(signing) + ".pub")
        self.assertTrue(member.is_file(), "docs/sigstore/rekor.pub is not in docs/sigstore/rekor-keys")
        self.assertEqual(signing, member.read_bytes())


def image_sigstore_files():
    """Regular files the web-ng image's sigstore layer installs, by path under IMAGE_SIGSTORE."""
    files = {}
    with tarfile.open(REPO / "docker/images/web_ng_sigstore_layer.tar") as archive:
        for member in archive.getmembers():
            name = member.name.lstrip("./")
            if member.isfile() and name.startswith(IMAGE_SIGSTORE + "/"):
                files[name[len(IMAGE_SIGSTORE) + 1:]] = archive.extractfile(member).read()
    return files


class WebNgImageTrustTest(unittest.TestCase):
    def test_image_ships_exactly_the_committed_rekor_keys_and_allowlist(self):
        shipped = image_sigstore_files()
        committed = {f"rekor-keys/{key.name}": key.read_bytes() for key in (SIGSTORE / "rekor-keys").glob("*.pub")}
        committed["pre-cutover-first-party-digests.json"] = ALLOWLIST.read_bytes()
        self.assertEqual(sorted(shipped), sorted(committed))
        for name, content in committed.items():
            with self.subTest(file=name):
                self.assertEqual(shipped[name], content)


class PreCutoverAllowlistTest(unittest.TestCase):
    def test_allowlist_is_frozen(self):
        self.assertEqual(hashlib.sha256(ALLOWLIST.read_bytes()).hexdigest(), FROZEN_ALLOWLIST_SHA256)

    def test_allowlist_holds_only_artifact_digests(self):
        digests = json.loads(ALLOWLIST.read_text())["digests"]
        self.assertTrue(digests)
        self.assertEqual(digests, sorted(set(digests)))
        for digest in digests:
            self.assertRegex(digest, r"\Asha256:[0-9a-f]{64}\Z")


class CosignVersionTest(unittest.TestCase):
    def test_signer_installer_installs_the_web_ng_image_cosign_at_a_patched_release(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            stub_dir = root / "stub"
            stub_dir.mkdir()
            curl = stub_dir / "curl"
            curl.write_text(CURL_STUB)
            curl.chmod(0o755)
            record = root / "curl-urls"
            env = {key: value for key, value in os.environ.items()
                   if key not in ("COSIGN_VERSION", "COSIGN_SHA256", "GITHUB_PATH")}
            env.update(PATH=f"{stub_dir}:{env.get('PATH', '/usr/bin:/bin')}", RUNNER_TEMP=str(root / "runner"),
                       CURL_RECORD=str(record), PINNED_COSIGN=str(pinned_cosign()))
            result = subprocess.run(["bash", str(REPO / "scripts/install-cosign.sh")], env=env,
                                    capture_output=True, text=True, timeout=60)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            installed = subprocess.run([str(root / "runner/bin/cosign"), "version"],
                                       capture_output=True, text=True, timeout=30)
            self.assertEqual(installed.returncode, 0, installed.stdout + installed.stderr)
            found = re.search(r"^GitVersion:\s+(v(\d+)\.(\d+)\.(\d+))\s*$",
                              installed.stdout + installed.stderr, re.MULTILINE)
            self.assertIsNotNone(found, installed.stdout + installed.stderr)
            self.assertGreaterEqual(tuple(int(part) for part in found.groups()[1:]), MINIMUM_COSIGN)
            urls = record.read_text().splitlines()
            self.assertEqual(len(urls), 1, urls)
            self.assertIn(f"/releases/download/{found.group(1)}/", urls[0])


if __name__ == "__main__":
    unittest.main()
