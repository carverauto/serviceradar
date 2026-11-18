"""The pinned Rekor keys and the Cosign version the signer and the web-ng image share.

openspec/changes/restore-signature-tlog-receipts, design.md Decisions 5 and 6.
"""

import base64
import hashlib
import re
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
SIGSTORE = REPO / "docs/sigstore"
# GHSA-whqx-f9j3-ch6m (3.0.4), GHSA-wfqv-66vq-46rm (3.0.5), GHSA-w6c6-c85g-mmv6 (3.0.6),
# GHSA-fx35-mq7g-6g98 (3.1.3).
MINIMUM_COSIGN = (3, 1, 3)


def log_id(pem):
    lines = [line.strip() for line in pem.decode("ascii").splitlines() if line.strip()]
    if lines[0] != "-----BEGIN PUBLIC KEY-----" or lines[-1] != "-----END PUBLIC KEY-----":
        raise AssertionError("not a single PEM public key")
    return hashlib.sha256(base64.b64decode("".join(lines[1:-1]), validate=True)).hexdigest()


def version(text, pattern, where):
    found = set(re.findall(pattern, text))
    if len(found) != 1:
        raise AssertionError(f"{where} names {sorted(found) or 'no'} cosign version(s), expected exactly one")
    return found.pop()


class RekorKeySetTest(unittest.TestCase):
    def test_every_accepted_key_is_named_by_its_log_id(self):
        keys = sorted((SIGSTORE / "rekor-keys").glob("*.pub"))
        self.assertTrue(keys, "docs/sigstore/rekor-keys holds no accepted Rekor key")
        for key in keys:
            with self.subTest(key=key.name):
                self.assertEqual(key.name, log_id(key.read_bytes()) + ".pub")

    def test_signing_log_key_is_a_member_of_the_accepted_set(self):
        signing = (SIGSTORE / "rekor.pub").read_bytes()
        member = SIGSTORE / "rekor-keys" / (log_id(signing) + ".pub")
        self.assertTrue(member.is_file(), "docs/sigstore/rekor.pub is not in docs/sigstore/rekor-keys")
        self.assertEqual(signing, member.read_bytes())


class CosignVersionTest(unittest.TestCase):
    def test_signer_and_web_ng_image_use_the_same_patched_release(self):
        installer = version((REPO / "scripts/install-cosign.sh").read_text(),
                            r'(?:COSIGN_VERSION:-|!= ")(v\d+\.\d+\.\d+)', "scripts/install-cosign.sh")
        image = version((REPO / "MODULE.bazel").read_text(),
                        r'sigstore/cosign/releases/download/(v\d+\.\d+\.\d+)/cosign-linux-', "MODULE.bazel")
        self.assertEqual(installer, image)
        self.assertGreaterEqual(tuple(int(part) for part in installer[1:].split(".")), MINIMUM_COSIGN)


if __name__ == "__main__":
    unittest.main()
