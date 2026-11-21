#!/usr/bin/env python3
"""What each built-in NATS identity may publish and subscribe.

The oracle is NATS subject matching applied to each user's allow and deny
lists, with the broker's rule that an empty allow list means every subject.

EventWriter stores a batch from logs.normalized.> without running Zen rules, so
the broker has to refuse that subject to every identity but the log collector.
An identity whose feature is off must be refused everything.
"""

from pathlib import Path
import json
import os
import shutil
import subprocess
import tempfile
import unittest

import yaml


def _repo_root() -> Path:
    srcdir = os.environ.get("TEST_SRCDIR")
    workspace = os.environ.get("TEST_WORKSPACE")
    if srcdir and workspace:
        candidate = Path(srcdir) / workspace
        if candidate.is_dir():
            return candidate
    return Path(__file__).resolve().parent.parent.parent


CHART_DIR = _repo_root() / "helm" / "serviceradar"


NORMALIZED_SUBJECT = "logs.normalized.syslog"
LOG_COLLECTOR = "CN=serviceradar-log-collector"

# The default rendering leaves the flow and inventory identities with an empty
# allow list; enabling them gives each a scoped list instead.
RENDERINGS = {
    "default": {},
    "flow collector and k8s inventory enabled": {
        "flowCollector.enabled": True,
        "k8sInventory.enabled": True,
    },
}


def render_static_users_configmap(values=None):
    """Consume helm-unittest's snapshot of the static-users ConfigMap."""
    binary = Path(os.environ["SERVICERADAR_HELM_UNITTEST_BINARY"]).resolve()
    with tempfile.TemporaryDirectory(dir=os.environ.get("TEST_TMPDIR")) as tmp:
        chart = Path(tmp) / "chart"
        chart.mkdir()
        for name in (
            "Chart.yaml", "values.yaml", "templates", "charts", "crds",
            "dashboards", "files",
        ):
            source = CHART_DIR / name
            if source.is_dir():
                shutil.copytree(source, chart / name)
            elif source.is_file():
                shutil.copy2(source, chart / name)
        tests = chart / "tests"
        tests.mkdir()
        suite = {
            "suite": "nats static users",
            "templates": ["templates/nats.yaml"],
            "release": {"name": "nats-test", "namespace": "nats-test"},
            "tests": [{
                "it": "static users",
                "set": values or {},
                "documentSelector": {
                    "path": "metadata.name",
                    "value": "serviceradar-nats-static-users",
                },
                "asserts": [{"matchSnapshot": {"path": "data"}}],
            }],
        }
        (tests / "nats_static_users_test.yaml").write_text(json.dumps(suite), encoding="utf-8")
        env = {
            key: value for key, value in os.environ.items()
            if not key.startswith("HELM_")
        }
        rendered = subprocess.run(
            [str(binary), str(chart)],
            env=env,
            capture_output=True,
            text=True,
            timeout=60,
        )
        if rendered.returncode:
            raise AssertionError(f"Helm rendering failed:\n{rendered.stdout}{rendered.stderr}")
        snapshot_path = tests / "__snapshot__" / "nats_static_users_test.yaml.snap"
        with snapshot_path.open(encoding="utf-8") as snapshot:
            snapshots = list(yaml.safe_load(snapshot)["static users"].values())
        if len(snapshots) != 1:
            raise AssertionError(f"expected one emitted snapshot, got {len(snapshots)}")
        return yaml.safe_load(snapshots[0])


def render_static_users(values=None):
    return yaml.safe_load(render_static_users_configmap(values)["static-users.yaml"])


def covers(pattern: str, subject: str) -> bool:
    """NATS subject matching: `*` is one token and `>` is one or more trailing tokens."""
    pattern_tokens = pattern.split(".")
    subject_tokens = subject.split(".")
    for index, token in enumerate(pattern_tokens):
        if token == ">":
            return index == len(pattern_tokens) - 1 and len(subject_tokens) > index
        if index >= len(subject_tokens):
            return False
        if token != "*" and token != subject_tokens[index]:
            return False
    return len(pattern_tokens) == len(subject_tokens)


def may(user: dict, direction: str, subject: str) -> bool:
    """Static NATS semantics: a missing or empty allow list permits every subject, then deny applies."""
    block = user.get(direction) or {}
    allow = block.get("allow") or []
    allowed = not allow or any(covers(pattern, subject) for pattern in allow)
    denied = any(covers(pattern, subject) for pattern in block.get("deny") or [])
    return allowed and not denied


def may_publish(user: dict, subject: str) -> bool:
    return may(user, "publish", subject)


# No identity is granted this subject by name, so only an identity allowed
# every subject can reach it.
UNLISTED_SUBJECT = "unlisted.synthetic.subject"

# The identities the chart means to leave open: the operator tools pod, the
# legacy organization-wide certificate, and the gateway's subscriptions.
OPEN = {
    ("CN=serviceradar-tools", "publish"),
    ("CN=serviceradar-tools", "subscribe"),
    ("O=ServiceRadar", "publish"),
    ("O=ServiceRadar", "subscribe"),
    ("CN=serviceradar-agent-gateway", "subscribe"),
}

# Identities that exist only for a feature the default rendering leaves off.
DISABLED_BY_DEFAULT = (
    "CN=serviceradar-flow-collector",
    "CN=serviceradar-netflow-collector",
    "CN=serviceradar-k8s-inventory",
)


class ChartIdentityInventoryTest(unittest.TestCase):
    def test_inventory_names_each_issued_nats_client_subject_once(self):
        subjects = yaml.safe_load(render_static_users_configmap()["chart-identities.yaml"])
        self.assertIsInstance(subjects, list)
        clients = (
            "tools", "web-ng", "core", "agent-gateway", "datasvc", "agent",
            "log-collector", "trapd", "flow-collector", "bmp-collector",
            "falcosidekick", "trivy-sidecar", "k8s-inventory",
        )
        self.assertCountEqual(subjects, [
            f"CN=serviceradar-{client},OU=Kubernetes,O=ServiceRadar,L=San Francisco,ST=CA,C=US"
            for client in clients
        ])


class OpenIdentityTest(unittest.TestCase):
    def test_only_the_intended_identities_reach_a_subject_nobody_listed(self):
        for rendering, values in RENDERINGS.items():
            with self.subTest(rendering=rendering):
                reached = {
                    (user["user"].split(",")[0], direction)
                    for user in render_static_users(values)
                    for direction in ("publish", "subscribe")
                    if may(user, direction, UNLISTED_SUBJECT)
                }
                self.assertEqual(reached, OPEN)

    def test_an_identity_whose_feature_is_off_is_refused_everything(self):
        users = {user["user"].split(",")[0]: user for user in render_static_users()}
        for name in DISABLED_BY_DEFAULT:
            for direction in ("publish", "subscribe"):
                for subject in (
                    UNLISTED_SUBJECT, "flows.raw.netflow", "inventory.k8s.nodes",
                    "_INBOX.reply", "$JS.API.INFO", "$SYS.REQ.SERVER.PING",
                ):
                    with self.subTest(user=name, direction=direction, subject=subject):
                        self.assertFalse(may(users[name], direction, subject))


class NormalizedLogSubjectTest(unittest.TestCase):
    def test_only_the_log_collector_may_publish_normalized_logs(self):
        for rendering, values in RENDERINGS.items():
            with self.subTest(rendering=rendering):
                users = render_static_users(values)
                self.assertGreater(len(users), 10)
                publishers = sorted(
                    user["user"] for user in users if may_publish(user, NORMALIZED_SUBJECT)
                )
                self.assertEqual(len(publishers), 1, publishers)
                self.assertTrue(publishers[0].startswith(LOG_COLLECTOR + ","), publishers)

    def test_the_identities_that_lost_it_keep_their_other_log_subjects(self):
        # The deny is narrow: these identities still publish the logs they did.
        users = {user["user"].split(",")[0]: user for user in render_static_users()}
        for name, subject in (
            ("CN=serviceradar-core", "logs.internal.audit"),
            ("CN=serviceradar-agent", "logs.syslog"),
            ("CN=serviceradar-tools", "logs.syslog"),
            (LOG_COLLECTOR, "logs.syslog"),
        ):
            with self.subTest(user=name, subject=subject):
                self.assertTrue(may_publish(users[name], subject))


class RumBeaconAndPolicyPermissionsTest(unittest.TestCase):
    def test_rum_collectors_and_core_hold_expected_rum_permissions(self):
        users = {user["user"].split(",")[0]: user for user in render_static_users()}
        for collector in ("CN=serviceradar-log-collector", "CN=serviceradar-otel"):
            with self.subTest(collector=collector):
                self.assertTrue(may_publish(users[collector], "rum.beacons.prop-01"))
                self.assertTrue(may_publish(users[collector], "metrics.rum.prop-01"))
                self.assertTrue(may_publish(users[collector], "config.rum.policy.snapshot"))
                self.assertTrue(may(users[collector], "subscribe", "config.rum.policy.updates"))

        core = users["CN=serviceradar-core"]
        self.assertTrue(may_publish(core, "config.rum.policy.updates"))
        self.assertTrue(may(core, "subscribe", "config.rum.policy.snapshot"))
        self.assertTrue(may(core, "subscribe", "rum.beacons.prop-01"))

    def test_unrelated_identities_cannot_publish_rum_beacons(self):
        users = {user["user"].split(",")[0]: user for user in render_static_users()}
        for identity in (
            "CN=serviceradar-agent",
            "CN=serviceradar-flowgger",
            "CN=serviceradar-trapd",
        ):
            with self.subTest(identity=identity):
                self.assertFalse(may_publish(users[identity], "rum.beacons.prop-01"))
                self.assertFalse(may_publish(users[identity], "metrics.rum.prop-01"))


if __name__ == "__main__":
    unittest.main()
