# Copyright 2026 Carver Automation Corporation.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

"""Keeps the first-party Wasm plugin verification key present and in agreement.

The Cosign PUBLIC release key is committed in four places:

    docs/cosign.pub                        -> what users are told to verify against
    elixir/web-ng/config/config.exs        -> compiled-in default, used by Docker Compose,
                                              bare releases, and any chart that leaves the
                                              value below empty
    helm/serviceradar/values.yaml          -> firstPartyPluginImport.cosignPublicKey
    helm/serviceradar/values-demo.yaml     -> same, demo overlay

This guards an EMPTY key as strictly as a divergent one, because empty is the failure that
actually shipped. values.yaml carried `cosignPublicKey: ""` while only the demo overlay set a
real key, and templates/web.yaml omits SERVICERADAR_FIRST_PARTY_PLUGIN_COSIGN_PUBLIC_KEY when
the value is falsy. CosignVerifier then fails closed with :cosign_public_key_not_configured, so
every Helm install that was not demo -- which is every OSS install -- could not import a single
first-party plugin. Nothing else caught it: the chart rendered, the pods went Ready, the plugin
catalog listed all 14 entries, and the failure surfaced only as a toast in the Plugins Manager.
"""

import base64
import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parent
CANONICAL_KEY = ROOT / "docs/cosign.pub"
WEB_NG_CONFIG = ROOT / "elixir/web-ng/config/config.exs"
CHART_VALUES = (
    ROOT / "helm/serviceradar/values.yaml",
    ROOT / "helm/serviceradar/values-demo.yaml",
)

# Matches the PEM block wherever it is embedded -- a YAML block scalar and an Elixir heredoc
# both indent the body, so the indentation is not part of the key.
PEM_BLOCK = re.compile(
    r"-----BEGIN PUBLIC KEY-----(.*?)-----END PUBLIC KEY-----",
    re.DOTALL,
)
# The key is only in force when it is attached to this setting. A stray PEM elsewhere in the
# file must not satisfy the assertion.
CHART_SETTING = re.compile(
    r"^\s*cosignPublicKey:\s*(.*?)(?=^\s{4}\w)",
    re.DOTALL | re.MULTILINE,
)
ELIXIR_SETTING = re.compile(
    r"cosign_public_key:\s*(.*?)cosign_public_key_file:",
    re.DOTALL,
)

# The second trust anchor on the same import path. Cosign proves the OCI artifact came from
# the release pipeline; this Ed25519 key proves the plugin upload inside it did. Both must be
# present or first-party import fails closed, and they failed closed one after the other.
UPLOAD_KEY_ID = "serviceradar-first-party-v1"
UPLOAD_KEY_ID_V2 = "serviceradar-first-party-v2"
ELIXIR_UPLOAD_KEYS = re.compile(
    r'"' + re.escape(UPLOAD_KEY_ID) + r'"\s*=>\s*"([^"]+)"',
)
ELIXIR_UPLOAD_KEYS_V2 = re.compile(
    r'"' + re.escape(UPLOAD_KEY_ID_V2) + r'"\s*=>\s*"([^"]+)"',
)
CHART_UPLOAD_KEYS = re.compile(
    r"PLUGIN_TRUSTED_UPLOAD_SIGNING_KEYS:\s*\"[^\"]*"
    + re.escape(UPLOAD_KEY_ID)
    + r"=([^,\"]+)",
)
CHART_UPLOAD_KEYS_V2 = re.compile(
    r"PLUGIN_TRUSTED_UPLOAD_SIGNING_KEYS:\s*\"[^\"]*"
    + re.escape(UPLOAD_KEY_ID_V2)
    + r"=([^,\"]+)",
)


def normalized_key(blob: str) -> str:
    """The base64 body, stripped of the indentation each embedding adds."""
    match = PEM_BLOCK.search(blob)
    if not match:
        return ""

    return "".join(match.group(1).split())


class FirstPartyPluginCosignKeyConsistencyTest(unittest.TestCase):
    def setUp(self):
        self.key = normalized_key(CANONICAL_KEY.read_text(encoding="utf-8"))

    def test_canonical_key_is_a_usable_public_key(self):
        """A malformed key fails closed at import time, far from here."""
        self.assertTrue(self.key, f"no PEM public key found in {CANONICAL_KEY.name}")

        # DER-encoded SubjectPublicKeyInfo. Only asserting it decodes and is non-trivial:
        # cosign itself is the authority on the contents.
        raw = base64.b64decode(self.key, validate=True)
        self.assertGreater(len(raw), 32, "not a plausible DER SubjectPublicKeyInfo")

    def test_chart_ships_the_release_key_by_default(self):
        for chart in CHART_VALUES:
            found = CHART_SETTING.findall(chart.read_text(encoding="utf-8"))

            self.assertEqual(
                len(found),
                1,
                f"{chart.name}: expected exactly one cosignPublicKey, found {len(found)}",
            )
            self.assertEqual(
                normalized_key(found[0]),
                self.key,
                f"{chart.name} does not ship the {CANONICAL_KEY.name} release key. An empty or "
                f"divergent value makes templates/web.yaml omit "
                f"SERVICERADAR_FIRST_PARTY_PLUGIN_COSIGN_PUBLIC_KEY, and every first-party "
                f"plugin import fails with cosign_public_key_not_configured while the deploy "
                f"stays green.",
            )

    def test_web_ng_compiled_default_matches(self):
        """Docker Compose and bare releases set no env var, so this default is all they get."""
        found = ELIXIR_SETTING.findall(WEB_NG_CONFIG.read_text(encoding="utf-8"))

        self.assertEqual(
            len(found),
            1,
            f"{WEB_NG_CONFIG.name}: expected exactly one cosign_public_key, found {len(found)}",
        )
        self.assertEqual(
            normalized_key(found[0]),
            self.key,
            f"{WEB_NG_CONFIG.name} does not carry the {CANONICAL_KEY.name} release key. Helm "
            f"installs would still work via the chart value, so this breaks Docker Compose and "
            f"bare releases only -- the quietest way for it to regress.",
        )


class FirstPartyUploadSigningKeyTest(unittest.TestCase):
    """The upload-signature trust anchor, which fails closed exactly like the Cosign key.

    There is no docs/ copy of this one, so config.exs is the canonical source and the demo
    overlay has to agree with it. Before this test the ONLY copy in the repository was the
    demo overlay's extraEnv, which is why every other install hit
    :trusted_upload_signers_not_configured the moment the Cosign gate was opened.
    """

    def setUp(self):
        found = ELIXIR_UPLOAD_KEYS.findall(WEB_NG_CONFIG.read_text(encoding="utf-8"))
        self.assertEqual(
            len(found),
            1,
            f"{WEB_NG_CONFIG.name}: expected exactly one {UPLOAD_KEY_ID} entry, "
            f"found {len(found)}",
        )
        self.key = found[0]

    def test_default_is_a_usable_ed25519_public_key(self):
        raw = base64.b64decode(self.key, validate=True)
        self.assertEqual(len(raw), 32, "Ed25519 public keys are 32 bytes; this is not one")

    def test_demo_overlay_trusts_the_same_signer(self):
        demo = ROOT / "helm/serviceradar/values-demo.yaml"
        found = CHART_UPLOAD_KEYS.findall(demo.read_text(encoding="utf-8"))

        self.assertEqual(
            len(found),
            1,
            f"{demo.name}: expected exactly one {UPLOAD_KEY_ID} entry, found {len(found)}",
        )
        self.assertEqual(
            found[0],
            self.key,
            f"{demo.name} trusts a different upload signer than the compiled-in default. The "
            f"overlay wins in demo, so demo would keep importing while every other install "
            f"rejected the same release artifacts.",
        )

    def test_demo_overlay_trusts_the_transit_signer(self):
        found_elixir = ELIXIR_UPLOAD_KEYS_V2.findall(WEB_NG_CONFIG.read_text(encoding="utf-8"))
        self.assertEqual(
            len(found_elixir),
            1,
            f"{WEB_NG_CONFIG.name}: expected exactly one {UPLOAD_KEY_ID_V2} entry, "
            f"found {len(found_elixir)}",
        )
        raw = base64.b64decode(found_elixir[0], validate=True)
        self.assertEqual(len(raw), 32, "Ed25519 public keys are 32 bytes; this is not one")

        demo = ROOT / "helm/serviceradar/values-demo.yaml"
        found = CHART_UPLOAD_KEYS_V2.findall(demo.read_text(encoding="utf-8"))
        self.assertEqual(
            len(found),
            1,
            f"{demo.name}: expected exactly one {UPLOAD_KEY_ID_V2} entry, found {len(found)}",
        )
        self.assertEqual(
            found[0],
            found_elixir[0],
            f"{demo.name} is missing the OpenBao Transit upload signer {UPLOAD_KEY_ID_V2}",
        )


if __name__ == "__main__":
    unittest.main()
