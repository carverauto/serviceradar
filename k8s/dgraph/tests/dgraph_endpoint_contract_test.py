"""The endpoint a caller dials must be a name the server's certificate carries.

Three files have to agree, in three different languages, and nothing else checks them:

  config/environments/<env>.textproto   the host every client resolves through ConfigManager
  k8s/dgraph/<env>/certificate.yaml     the SANs cert-manager issues
  k8s/dgraph/<env>/values.yaml          the namespace those names live in

TLS verification is against the name DIALED, not the address reached, so a host that is not a
SAN fails the handshake at runtime -- after deploy, in whichever environment was edited last,
with an error that names neither file. The mismatch is invisible to `helm template`, to the
Rust type system, and to every test that does not read both files at once.
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


if __name__ == "__main__":
    unittest.main()
