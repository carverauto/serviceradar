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

"""Keeps the agent's release trust anchor and the control plane's in agreement.

The Ed25519 release-signing PUBLIC key is committed in three places:

    go/pkg/agent/release_signing_key.txt   -> compiled into every agent binary
    helm/serviceradar/values.yaml          -> agentReleasePublicKey, read by the control plane
    helm/serviceradar/values-demo.yaml     -> same, demo overlay

NOTHING ELSE CATCHES A DIVERGENCE. scripts/verify-agent-release-key-stamp.sh compares the agent's
copy against the key derived from the signing SECRET, which says nothing about the charts. So if
the chart copies drift, the control plane happily signs and publishes a release that every
package-managed agent then refuses to install -- and the build, the release job and the deploy
all stay green. The failure surfaces only as agents silently declining updates.
"""

import base64
import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parent
EMBEDDED_KEY = ROOT / "go/pkg/agent/release_signing_key.txt"
CHART_VALUES = (
    ROOT / "helm/serviceradar/values.yaml",
    ROOT / "helm/serviceradar/values-demo.yaml",
)

CHART_KEY = re.compile(r'agentReleasePublicKey:\s*"([^"]+)"')
ED25519_PUBLIC_KEY_BYTES = 32


def embedded_key(text: str) -> str:
    """First non-blank, non-comment line.

    Mirrors parseEmbeddedSigningKey in go/pkg/agent/release_update.go. Kept in step with it: if
    that parser learns a new form, this has to learn it too, or the test passes while the binary
    embeds something else.
    """
    for line in text.splitlines():
        line = line.strip()
        if line and not line.startswith("#"):
            return line

    return ""


class AgentReleaseKeyConsistencyTest(unittest.TestCase):
    def setUp(self):
        self.key = embedded_key(EMBEDDED_KEY.read_text(encoding="utf-8"))

    def test_embedded_key_is_a_usable_ed25519_public_key(self):
        """A malformed key fails closed at runtime, far from here and long after release.

        releaseVerificationKey() rejects it and the agent declines every update, so the cheapest
        place to notice is a build-time assertion on shape.
        """
        self.assertTrue(self.key, f"no key line found in {EMBEDDED_KEY.name}")

        raw = base64.b64decode(self.key, validate=True)
        self.assertEqual(
            len(raw),
            ED25519_PUBLIC_KEY_BYTES,
            "Ed25519 public keys are 32 bytes; this is not one",
        )

    def test_agent_and_control_plane_trust_the_same_key(self):
        for chart in CHART_VALUES:
            found = CHART_KEY.findall(chart.read_text(encoding="utf-8"))

            self.assertEqual(
                len(found),
                1,
                f"{chart.name}: expected exactly one agentReleasePublicKey, found {len(found)}",
            )
            self.assertEqual(
                found[0],
                self.key,
                f"{chart.name} disagrees with {EMBEDDED_KEY.name}. The control plane would "
                f"publish releases that package-managed agents refuse to install, with nothing "
                f"else failing.",
            )


if __name__ == "__main__":
    unittest.main()
