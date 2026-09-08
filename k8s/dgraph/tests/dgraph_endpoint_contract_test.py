"""The endpoint a caller dials must be a name the server's certificate carries.

Three files have to agree, in three different languages, and nothing else checks them:

  config/environments/<env>.textproto   the host every client resolves through ConfigManager
  k8s/dgraph/<env>/certificate.yaml     the SANs cert-manager issues
  k8s/dgraph/<env>/values.yaml          the namespace those names live in

TLS verification is against the name DIALED, not the address reached, so a host that is not a
SAN fails the handshake at runtime -- after deploy, in whichever environment was edited last,
with an error that names neither file. The mismatch is invisible to `helm template`, to the
Rust type system, and to every test that does not read both files at once.

CI also fetches the private CA over HTTPS terminated by the LAN shared gateway's public
Let's Encrypt cert. Scratch images already trust that issuer; wrapping the custom CA in the
same CA is the circular case the audits reject. The URL, HTTPRoute hostname, namespace
gateway label, and BuildBuddy RFC1918 allowlist have to agree or the fetch is either
plaintext or black-holed by the executor SSRF filter.
"""

import re
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
K8S = REPO / "k8s" / "dgraph"
ENVIRONMENTS = REPO / "config" / "environments"

# Deployed environments only. `localhost` runs Dgraph on a dev machine in plaintext and has no
# certificate to agree with; asserting a SAN for it would be asserting a file that should not
# exist.
ENV_TO_DEPLOYMENT = {
    "ci": "ci",
    "demo": "demo",
    "saas": "demo",
}

# Public-zone name on lan-shared-gateway. Let's Encrypt will not issue for
# *.svc.cluster.local; scratch images already have the public roots.
CI_CA_BUNDLE_URL = "https://dgraph-ci-ca.carverauto.dev/ca.crt"
CI_CA_HOSTNAME = "dgraph-ci-ca.carverauto.dev"
LAN_GATEWAY_VIP = "192.168.6.87/32"


def dgraph_host_and_port(env):
    """The `host` and `port` from the environment's `dgraph { ... }` block."""
    text = (ENVIRONMENTS / f"{env}.textproto").read_text()
    block = re.search(r"^dgraph \{.*?^\}", text, re.S | re.M)
    assert block, f"{env}.textproto has no dgraph block"
    host = re.search(r'host:\s*"([^"]+)"', block.group(0))
    port = re.search(r"port:\s*(\d+)", block.group(0))
    assert host and port, f"{env}.textproto dgraph block lacks host or port"
    return host.group(1), int(port.group(1))


def alpha_certificate(deployment):
    """The leaf Certificate document, as (common_name, [dns_names]).

    Parsed as text rather than with a YAML library: the helm gates in this tree do the same,
    and it keeps the test free of a dependency that would have to be vendored for one regex.
    """
    text = (K8S / deployment / "certificate.yaml").read_text()
    docs = text.split("\n---\n")
    leaf = [d for d in docs if re.search(r"^\s+name:\s*dgraph-alpha-tls\s*$", d, re.M)]
    assert len(leaf) == 1, f"{deployment}/certificate.yaml has {len(leaf)} dgraph-alpha-tls docs"
    doc = leaf[0]

    common_name = re.search(r"^\s+commonName:\s*(\S+)\s*$", doc, re.M)
    assert common_name, f"{deployment} leaf certificate has no commonName"

    # Line-based rather than one regex: the lists carry comments, and a pattern that assumed
    # items followed `dnsNames:` immediately read the CI certificate as having none.
    dns_names = []
    collecting = False
    for line in doc.splitlines():
        stripped = line.strip()
        if not collecting:
            collecting = stripped == "dnsNames:"
            continue
        if not stripped or stripped.startswith("#"):
            continue
        if stripped.startswith("- "):
            dns_names.append(stripped[2:].strip().strip('"'))
            continue
        break  # a sibling key ends the list
    assert dns_names, f"{deployment} leaf certificate has no dnsNames"
    return common_name.group(1), dns_names


class DgraphEndpointContract(unittest.TestCase):
    def test_every_deployed_host_is_a_certificate_san(self):
        for env, deployment in ENV_TO_DEPLOYMENT.items():
            with self.subTest(env=env):
                host, _ = dgraph_host_and_port(env)
                _, dns_names = alpha_certificate(deployment)
                self.assertIn(
                    host,
                    dns_names,
                    f"config/environments/{env}.textproto dials {host}, which "
                    f"k8s/dgraph/{deployment}/certificate.yaml does not certify. TLS verifies "
                    f"the name dialed, so this fails the handshake at runtime. SANs: {dns_names}",
                )

    def test_host_names_the_namespace_the_release_is_deployed_into(self):
        # The SAN and the config agreeing is not enough on its own: both could name a namespace
        # nothing is deployed into. deploy-dgraph.sh is what binds environment to namespace.
        deploy = (K8S / "deploy-dgraph.sh").read_text()
        namespaces = dict(re.findall(r"^\s+(ci|demo)\)\s+deploy\s+\S+\s+(\S+)\s*;;", deploy, re.M))
        self.assertEqual(
            set(namespaces), {"ci", "demo"}, "deploy-dgraph.sh no longer deploys both environments"
        )

        for env, deployment in ENV_TO_DEPLOYMENT.items():
            with self.subTest(env=env):
                host, _ = dgraph_host_and_port(env)
                expected_suffix = f".{namespaces[deployment]}.svc.cluster.local"
                self.assertTrue(
                    host.endswith(expected_suffix),
                    f"{env} dials {host}, but deploy-dgraph.sh puts {deployment} in namespace "
                    f"{namespaces[deployment]}, so the name resolves to nothing",
                )

    def test_deployed_environments_verify_the_certificate(self):
        # A host that matches the SAN buys nothing if the mode does not verify. This is the
        # assertion that would have caught the earlier design, where CI ran sslmode=require.
        for env in ENV_TO_DEPLOYMENT:
            with self.subTest(env=env):
                block = re.search(
                    r"^dgraph \{.*?^\}",
                    (ENVIRONMENTS / f"{env}.textproto").read_text(),
                    re.S | re.M,
                )
                self.assertIn(
                    "DGRAPH_TLS_MODE_VERIFY_CA",
                    block.group(0),
                    f"{env} does not verify the Dgraph certificate",
                )

    def test_alpha_grpc_port_is_the_one_the_config_dials(self):
        # 9080 is Alpha's external gRPC port. 8080 is HTTP and 7080 is internal-only; dialing
        # either with a gRPC client fails in a way that looks like a TLS problem.
        for env in ENV_TO_DEPLOYMENT:
            with self.subTest(env=env):
                _, port = dgraph_host_and_port(env)
                self.assertEqual(port, 9080, f"{env} does not dial Alpha's gRPC port")

    def test_ci_fetches_the_private_ca_over_public_https(self):
        # Plain HTTP is the hole the audits keep reducing every other hardening to. The
        # publisher stays HTTP behind Envoy; the URL clients dial must be HTTPS so the first
        # hop verifies against the public roots already in the scratch image.
        block = re.search(
            r"^dgraph \{.*?^\}",
            (ENVIRONMENTS / "ci.textproto").read_text(),
            re.S | re.M,
        )
        self.assertIsNotNone(block, "ci.textproto has no dgraph block")
        url = re.search(r'ca_bundle_url:\s*"([^"]+)"', block.group(0))
        self.assertIsNotNone(url, "ci dgraph block has no ca_bundle_url")
        self.assertEqual(url.group(1), CI_CA_BUNDLE_URL)
        self.assertTrue(url.group(1).startswith("https://"), url.group(1))

    def test_ci_ca_httproute_uses_the_config_hostname(self):
        route = (K8S / "ci" / "httproute-ca.yaml").read_text()
        self.assertIn(f"hostname: {CI_CA_HOSTNAME}", route)
        self.assertIn(f"- {CI_CA_HOSTNAME}", route)
        self.assertIn("name: lan-shared-gateway", route)
        self.assertIn("namespace: lan-edge", route)
        self.assertIn("sectionName: https-carverauto", route)
        self.assertIn("name: dgraph-ca-incluster", route)
        self.assertIn("cloudflare-proxied: \"false\"", route)

    def test_ci_namespace_may_attach_to_the_lan_gateway(self):
        ns = (K8S / "ci" / "namespace.yaml").read_text()
        self.assertIn('carverauto.com/lan-gateway-access: "true"', ns)

    def test_buildbuddy_allows_the_lan_gateway_vip(self):
        # BuildBuddy rejects RFC1918 unless it is listed. 192.168.6.87 is the LAN
        # shared-gateway VIP; without this allow, HTTPS CA fetches from workflow
        # actions are Connection refused and look like a dead publisher.
        for name in ("values.yaml", "values-workflows.yaml"):
            with self.subTest(values=name):
                text = (REPO / "k8s" / "buildbuddy" / name).read_text()
                self.assertIn(LAN_GATEWAY_VIP, text, name)


if __name__ == "__main__":
    unittest.main()
