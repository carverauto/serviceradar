#!/usr/bin/env python3
"""Only the log collector may publish already-normalized log batches.

EventWriter stores a batch from logs.normalized.> without running Zen rules, so
the broker has to refuse that subject to every other identity. The oracle is
NATS subject matching applied to each built-in user's allow and deny lists.
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


def render_static_users():
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
        return yaml.safe_load(yaml.safe_load(snapshots[0])["static-users.yaml"])


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


def may_publish(user: dict, subject: str) -> bool:
    publish = user.get("publish") or {}
    allowed = any(covers(pattern, subject) for pattern in publish.get("allow") or [])
    denied = any(covers(pattern, subject) for pattern in publish.get("deny") or [])
    return allowed and not denied


class NormalizedLogSubjectTest(unittest.TestCase):
    def test_only_the_log_collector_may_publish_normalized_logs(self):
        users = render_static_users()
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


if __name__ == "__main__":
    unittest.main()
