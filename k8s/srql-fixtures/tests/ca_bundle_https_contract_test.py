"""CI must fetch the SRQL fixture CA over HTTPS terminated by a public issuer.

The publisher itself stays HTTP behind Envoy. Clients dial a public-zone name on
lan-shared-gateway so the first hop verifies against the public roots already in
scratch images. Wrapping this fetch in a cert issued by the fixture CA is the
circular case the audits reject.
"""

import re
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
K8S = REPO / "k8s" / "srql-fixtures"
ENVIRONMENTS = REPO / "config" / "environments"
CI_CA_BUNDLE_URL = "https://srql-fixture-ca.carverauto.dev/ca.crt"
CI_CA_HOSTNAME = "srql-fixture-ca.carverauto.dev"
LAN_GATEWAY_VIP = "192.168.6.87/32"
HTTP_CLIENT_URLS = (
    "http://srql-fixture-ca-incluster.srql-fixtures.svc.cluster.local/ca.crt",
)


def database_block():
    text = (ENVIRONMENTS / "ci.textproto").read_text()
    block = re.search(r"^database \{.*?^\}", text, re.S | re.M)
    if block is None:
        raise AssertionError("ci.textproto has no database block")
    return block.group(0)


class SrqlFixtureCaHttpsContract(unittest.TestCase):
    def test_ci_fetches_the_fixture_ca_over_public_https(self):
        url = re.search(r'ca_bundle_url:\s*"([^"]+)"', database_block())
        self.assertIsNotNone(url, "ci database block has no ca_bundle_url")
        self.assertEqual(url.group(1), CI_CA_BUNDLE_URL)
        self.assertTrue(url.group(1).startswith("https://"), url.group(1))

    def test_httproute_uses_the_config_hostname(self):
        route = (K8S / "httproute-ca.yaml").read_text()
        self.assertIn(f"hostname: {CI_CA_HOSTNAME}", route)
        self.assertIn(f"- {CI_CA_HOSTNAME}", route)
        self.assertIn("name: lan-shared-gateway", route)
        self.assertIn("namespace: lan-edge", route)
        self.assertIn("sectionName: https-carverauto", route)
        self.assertIn("name: srql-fixture-ca-incluster", route)
        self.assertIn('cloudflare-proxied: "false"', route)

    def test_namespace_may_attach_to_the_lan_gateway(self):
        ns = (K8S / "namespace.yaml").read_text()
        self.assertIn('carverauto.com/lan-gateway-access: "true"', ns)

    def test_client_defaults_are_not_plain_http(self):
        # ClusterIP HTTP remains the Envoy backend. It must not be the URL scripts,
        # workflows, or config tell clients to dial.
        for path in (
            REPO / "buildbuddy.yaml",
            REPO / "buildbuddy_setup_fixture_env.sh",
            REPO / "scripts" / "ci" / "configure-srql-fixture.sh",
            ENVIRONMENTS / "ci.textproto",
        ):
            text = path.read_text()
            for url in HTTP_CLIENT_URLS:
                self.assertNotIn(
                    url,
                    text,
                    f"{path.relative_to(REPO)} still tells clients to fetch the CA over HTTP",
                )

    def test_buildbuddy_allows_the_lan_gateway_vip(self):
        for name in ("values.yaml", "values-workflows.yaml"):
            with self.subTest(values=name):
                text = (REPO / "k8s" / "buildbuddy" / name).read_text()
                self.assertIn(LAN_GATEWAY_VIP, text, name)


if __name__ == "__main__":
    unittest.main()
