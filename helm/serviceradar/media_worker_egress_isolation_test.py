#!/usr/bin/env python3
"""The media worker's own policy is the only chart policy that governs its egress.

NetworkPolicy allows are additive: a pod may open any connection that some
policy selecting it allows. So on a CNI that enforces egress policy, the worker
is kept off PostgreSQL, the pooler and everything else outside its allowlist
exactly when the only egress-governing policy selecting it is its own, and that
policy allows no PostgreSQL traffic to the namespace.

For the default, demo, tenant and HA values with the worker enabled, this test
renders every template, evaluates every Kubernetes and Calico policy's selector
against the worker pod's labels (matchLabels, matchExpressions, an empty
selector, and Calico selector expressions), and checks both properties.
"""

from pathlib import Path
import re
import unittest

from chart_render import CHART_DIR, render_templates

NAMESPACE = "sr-iso"
WORKER_POLICY = "serviceradar-media-worker"
# The worker pod's labels, from templates/media-worker.yaml.
WORKER_LABELS = {
    "app": "serviceradar-media-worker",
    "app.kubernetes.io/name": "serviceradar-media-worker",
    "app.kubernetes.io/component": "media-worker",
    "app.kubernetes.io/part-of": "serviceradar-media",
}
POSTGRES_PORT = 5432

ENABLED_WORKER = {
    "mediaWorker.enabled": True,
    "mediaWorker.runtimeClassName": "nvidia",
    "mediaWorker.image.repository": "registry.carverauto.dev/serviceradar/serviceradar-media-worker-cuda",
    "mediaWorker.image.tag": "sha-0123456789abcdef0123456789abcdef01234567",
    "mediaWorker.models.existingClaim": "synthetic-models",
    "mediaWorker.auth.existingSecret": "synthetic-media-worker-auth",
    "mediaWorker.auth.deploymentRef": "00000000-0000-4000-8000-000000000006",
    "mediaWorker.auth.generation": "1",
    "webNg.controlPlaneRuntime.mediaWorker.enabled": True,
    "webNg.controlPlaneRuntime.mediaWorker.existingSecret": "synthetic-media-worker-auth",
    "webNg.controlPlaneRuntime.mediaWorker.deploymentRef": "00000000-0000-4000-8000-000000000006",
    "webNg.controlPlaneRuntime.mediaWorker.generation": "1",
    # Room for the worker's fixed JetStream streams is a separate check.
    "nats.jetstream.allowOvercommit": True,
}

OVERLAYS = {
    "default": ([], {}),
    "demo": (["values-demo.yaml"], {}),
    # tenant-2g cannot hold the worker's results stream; the chart refuses it.
    "tenant": (["values-tenant.yaml"], {"nats.jetstream.profile": "compact"}),
    "ha": (["values-ha.yaml"], {}),
}


# --- Kubernetes label selectors ------------------------------------------------

def label_selector_matches(selector, labels):
    """metav1.LabelSelector semantics; an empty selector matches every pod."""
    selector = selector or {}
    for key, value in (selector.get("matchLabels") or {}).items():
        if labels.get(key) != value:
            return False
    for expr in selector.get("matchExpressions") or []:
        key, op, values = expr["key"], expr["operator"], expr.get("values") or []
        present = key in labels
        if op == "In" and not (present and labels[key] in values):
            return False
        if op == "NotIn" and present and labels[key] in values:
            return False
        if op == "Exists" and not present:
            return False
        if op == "DoesNotExist" and present:
            return False
    return True


# --- Calico selector expressions -------------------------------------------------

TOKEN = re.compile(r"\s*(all\(\)|has\(([^)]+)\)|&&|\|\||==|!=|!|\(|\)|'[^']*'|\"[^\"]*\"|[A-Za-z0-9_./-]+)")


def calico_selector_matches(expression, labels):
    """Calico selector subset the chart renders: all(), has(), ==, !=, !, &&, ||, ()."""
    tokens = []
    pos = 0
    while pos < len(expression):
        match = TOKEN.match(expression, pos)
        if not match:
            if expression[pos:].strip():
                raise AssertionError(f"unparsed Calico selector at {expression[pos:]!r}")
            break
        tokens.append(match.group(1))
        pos = match.end()
    index = 0

    def peek():
        return tokens[index] if index < len(tokens) else None

    def take():
        nonlocal index
        index += 1
        return tokens[index - 1]

    def parse_or():
        value = parse_and()
        while peek() == "||":
            take()
            value = parse_and() or value
        return value

    def parse_and():
        value = parse_unary()
        while peek() == "&&":
            take()
            value = parse_unary() and value
        return value

    def parse_unary():
        token = take()
        if token == "!":
            return not parse_unary()
        if token == "(":
            value = parse_or()
            if take() != ")":
                raise AssertionError(f"unbalanced Calico selector {expression!r}")
            return value
        if token == "all()":
            return True
        if token.startswith("has("):
            return token[4:-1].strip() in labels
        operator = take()
        literal = take().strip("'\"")
        if operator == "==":
            return labels.get(token) == literal
        if operator == "!=":
            return labels.get(token) != literal
        raise AssertionError(f"unsupported Calico operator {operator!r} in {expression!r}")

    result = parse_or()
    if index != len(tokens):
        raise AssertionError(f"trailing tokens in Calico selector {expression!r}")
    return result


# --- Policies ----------------------------------------------------------------------

def is_kubernetes_policy(doc):
    return doc.get("kind") == "NetworkPolicy" and doc.get("apiVersion", "").startswith("networking.k8s.io/")


def is_calico_policy(doc):
    return doc.get("kind") in ("NetworkPolicy", "GlobalNetworkPolicy") and doc.get("apiVersion", "").startswith("projectcalico.org/")


def governs_worker_egress(doc):
    spec = doc.get("spec") or {}
    namespace = (doc.get("metadata") or {}).get("namespace")
    if is_kubernetes_policy(doc):
        if namespace not in (None, NAMESPACE):
            return False
        has_egress = "Egress" in (spec.get("policyTypes") or []) or "egress" in spec
        return has_egress and label_selector_matches(spec.get("podSelector"), WORKER_LABELS)
    if is_calico_policy(doc):
        if doc["kind"] == "NetworkPolicy" and namespace not in (None, NAMESPACE):
            return False
        has_egress = "Egress" in (spec.get("types") or []) or "egress" in spec
        return has_egress and calico_selector_matches(spec.get("selector") or "all()", WORKER_LABELS)
    return False


def rule_allows_postgres_in_namespace(rule):
    """A Kubernetes egress rule that lets the worker reach TCP 5432 on namespace pods."""
    ports = rule.get("ports")
    if ports:
        reaches_port = any(
            (port.get("protocol") or "TCP") == "TCP"
            and (
                not isinstance(port.get("port"), int)  # a named port or no port
                or port["port"] <= POSTGRES_PORT <= (port.get("endPort") or port["port"])
            )
            for port in ports
        )
    else:
        reaches_port = True
    if not reaches_port:
        return False
    peers = rule.get("to")
    if not peers:
        return True  # every destination
    for peer in peers:
        if "ipBlock" in peer:
            continue  # cluster-external addresses; the worker's own uses exclude RFC1918
        namespace_selector = peer.get("namespaceSelector")
        if namespace_selector is None or label_selector_matches(
            namespace_selector, {"kubernetes.io/metadata.name": NAMESPACE}
        ):
            return True
    return False


class MediaWorkerEgressIsolationTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        templates = sorted(
            f"templates/{path.name}" for path in (CHART_DIR / "templates").glob("*.yaml")
        )
        cls.policies = {}
        for overlay, (files, extra) in OVERLAYS.items():
            rendered = render_templates(
                templates,
                {**ENABLED_WORKER, **extra},
                namespace=NAMESPACE,
                values_files=[CHART_DIR / name for name in files],
                combined=True,
            )
            cls.policies[overlay] = [
                doc for docs in rendered.values() for doc in docs
                if is_kubernetes_policy(doc) or is_calico_policy(doc)
            ]

    def test_only_the_workers_own_policy_governs_its_egress(self):
        for overlay, policies in self.policies.items():
            with self.subTest(overlay=overlay):
                governing = sorted(
                    f'{doc["kind"]}/{doc["metadata"]["name"]}'
                    for doc in policies if governs_worker_egress(doc)
                )
                self.assertEqual(governing, [f"NetworkPolicy/{WORKER_POLICY}"])

    def test_the_workers_own_policy_allows_no_postgres_in_the_namespace(self):
        for overlay, policies in self.policies.items():
            with self.subTest(overlay=overlay):
                (own,) = [
                    doc for doc in policies
                    if is_kubernetes_policy(doc) and doc["metadata"]["name"] == WORKER_POLICY
                ]
                offending = [
                    rule for rule in own["spec"].get("egress") or []
                    if rule_allows_postgres_in_namespace(rule)
                ]
                self.assertEqual(offending, [])

    def test_the_overlays_exercise_the_broad_policies(self):
        # The demo overlay renders both match-all policies the worker must stay out
        # of; without them the isolation check above would pass vacuously.
        names = {doc["metadata"]["name"] for doc in self.policies["demo"]}
        self.assertIn("serviceradar-egress", names)
        self.assertIn("serviceradar-egress-log-deny", names)


class SelectorEvaluationTest(unittest.TestCase):
    """The evaluators the isolation check depends on, against worked examples."""

    def test_label_selectors(self):
        self.assertTrue(label_selector_matches({}, WORKER_LABELS))
        self.assertTrue(label_selector_matches(None, WORKER_LABELS))
        self.assertFalse(label_selector_matches(
            {"matchLabels": {"app.kubernetes.io/part-of": "serviceradar"}}, WORKER_LABELS))
        self.assertFalse(label_selector_matches(
            {"matchExpressions": [{"key": "app", "operator": "NotIn", "values": ["serviceradar-media-worker"]}]},
            WORKER_LABELS))
        self.assertTrue(label_selector_matches(
            {"matchExpressions": [{"key": "cnpg.io/podRole", "operator": "NotIn", "values": ["instance"]}]},
            WORKER_LABELS))
        self.assertFalse(label_selector_matches(
            {"matchExpressions": [{"key": "cnpg.io/podRole", "operator": "Exists"}]}, WORKER_LABELS))

    def test_calico_selectors(self):
        self.assertTrue(calico_selector_matches("all()", WORKER_LABELS))
        self.assertFalse(calico_selector_matches(
            "((all()) && app != 'serviceradar-nvr') && app != 'serviceradar-media-worker'", WORKER_LABELS))
        self.assertTrue(calico_selector_matches("(all()) && app != 'serviceradar-nvr'", WORKER_LABELS))
        self.assertFalse(calico_selector_matches("app.kubernetes.io/part-of == 'serviceradar'", WORKER_LABELS))
        self.assertTrue(calico_selector_matches("has(app) && !has(cnpg.io/cluster)", WORKER_LABELS))

    def test_postgres_rule_detection(self):
        same_namespace_pods = {"podSelector": {}}
        self.assertTrue(rule_allows_postgres_in_namespace({"to": [same_namespace_pods]}))
        self.assertTrue(rule_allows_postgres_in_namespace(
            {"to": [same_namespace_pods], "ports": [{"protocol": "TCP", "port": 5430, "endPort": 5440}]}))
        self.assertFalse(rule_allows_postgres_in_namespace(
            {"to": [same_namespace_pods], "ports": [{"protocol": "TCP", "port": 4222}]}))
        self.assertFalse(rule_allows_postgres_in_namespace(
            {"to": [{"ipBlock": {"cidr": "0.0.0.0/0"}}], "ports": [{"protocol": "TCP", "port": 443}]}))
        self.assertFalse(rule_allows_postgres_in_namespace(
            {"to": [{"namespaceSelector": {"matchLabels": {"kubernetes.io/metadata.name": "kube-system"}}}],
             "ports": [{"protocol": "TCP", "port": 5432}]}))


if __name__ == "__main__":
    unittest.main()
