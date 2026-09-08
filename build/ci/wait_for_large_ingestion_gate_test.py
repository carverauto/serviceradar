"""Tests for exact-SHA LargeIngestionGate release qualification."""

from __future__ import annotations

import io
import json
import math
import subprocess
import sys
import tempfile
import unittest
from datetime import datetime
from pathlib import Path

from build.ci import large_ingestion_gate as gate
from build.ci import wait_for_large_ingestion_gate as cli


RELEASE = "1" * 40
BASE = "2" * 40
INTRODUCTION = "3" * 40
FEATURE = "4" * 40
MERGE = "5" * 40
PREFIX = "https://carverauto.buildbuddy.io/invocation/"
VALID_URL = PREFIX + "abc123"


class FakeGit:
    def __init__(self):
        self.resolutions = {RELEASE: RELEASE, "origin/staging": BASE}
        self.shallow = False
        self.ancestry = {(RELEASE, BASE): True}
        self.trees = {RELEASE: "a" * 40, BASE: "b" * 40, MERGE: "a" * 40}
        self.first_parent = [BASE]
        self.files = {
            (BASE, "build/ci/large_ingestion_gate_contract.v1"): b"large-ingestion-gate-contract-v1\n",
            (RELEASE, "build/ci/large_ingestion_gate_contract.v1"): b"large-ingestion-gate-contract-v1\n",
            (RELEASE, "elixir/serviceradar_core/BUILD.bazel"): (
                b'ex_unit_test(\n    name = "large_ingestion_release_gate",\n)\n'
            ),
            (RELEASE, "buildbuddy.yaml"): (
                b'actions:\n  - name: "LargeIngestionGate"\n'
            ),
        }
        self.introductions = [INTRODUCTION]

    def resolve(self, revision):
        value = self.resolutions.get(revision)
        if isinstance(value, Exception):
            raise value
        if value is None:
            raise gate.PolicyError("unresolved revision")
        return value

    def is_shallow(self):
        if isinstance(self.shallow, Exception):
            raise self.shallow
        return self.shallow

    def is_ancestor(self, ancestor, descendant):
        value = self.ancestry.get((ancestor, descendant), False)
        if isinstance(value, Exception):
            raise value
        return value

    def tree_sha(self, commit):
        value = self.trees.get(commit)
        if isinstance(value, Exception):
            raise value
        if value is None:
            raise gate.PolicyError("unresolved tree")
        return value

    def first_parent_history(self, base_ref, limit=256):
        if isinstance(self.first_parent, Exception):
            raise self.first_parent
        return list(self.first_parent)[:limit]

    def read_tree_file(self, commit, path):
        value = self.files.get((commit, path))
        if isinstance(value, Exception):
            raise value
        return value

    def marker_introductions(self, base_ref):
        if isinstance(self.introductions, Exception):
            raise self.introductions
        return self.introductions


class CountingStatusSource:
    def __init__(self, snapshots):
        self.snapshots = list(snapshots)
        self.calls = 0

    def snapshot(self, timeout_seconds):
        self.calls += 1
        if not self.snapshots:
            return []
        value = self.snapshots.pop(0)
        if isinstance(value, Exception):
            raise value
        return value


class Factory:
    def __init__(self, source):
        self.source = source
        self.calls = 0
        self.commits = []

    def __call__(self, commit):
        self.calls += 1
        self.commits.append(commit)
        return self.source


class FakeClock:
    def __init__(self, now=0.0):
        self.now = now
        self.sleeps = []

    def monotonic(self):
        return self.now

    def sleep(self, seconds):
        self.sleeps.append(seconds)
        self.now += seconds


def status(
    state="success",
    target_url=VALID_URL,
    created_at="2026-08-23T12:00:00Z",
    status_id=1,
    context="LargeIngestionGate",
):
    timestamp = datetime.fromisoformat(created_at.replace("Z", "+00:00"))
    return gate.CommitStatus(state, context, target_url, timestamp, status_id)


def completed(returncode=0, stdout=b"", stderr=b""):
    return subprocess.CompletedProcess([], returncode, stdout=stdout, stderr=stderr)


class QueueRunner:
    def __init__(self, results):
        self.results = list(results)
        self.calls = []

    def __call__(self, argv, **kwargs):
        self.calls.append((argv, kwargs))
        if not self.results:
            raise AssertionError(f"unexpected subprocess call: {argv}")
        result = self.results.pop(0)
        if isinstance(result, Exception):
            raise result
        return result


class ApplicabilityTest(unittest.TestCase):
    def markerless_git(self):
        fake = FakeGit()
        fake.files.pop((RELEASE, gate.MARKER_PATH))
        return fake

    def test_strict_pre_introduction_ancestor_is_historical(self):
        fake = self.markerless_git()
        fake.ancestry[(INTRODUCTION, RELEASE)] = False
        fake.ancestry[(RELEASE, INTRODUCTION)] = True
        self.assertFalse(gate.determine_applicability(fake, RELEASE, "origin/staging"))

    def test_introduction_ancestor_of_markerless_release_is_deletion(self):
        fake = self.markerless_git()
        fake.ancestry[(INTRODUCTION, RELEASE)] = True
        with self.assertRaisesRegex(gate.PolicyError, "delet"):
            gate.determine_applicability(fake, RELEASE, "origin/staging")

    def test_introduction_equality_with_markerless_release_is_deletion(self):
        fake = self.markerless_git()
        fake.introductions = [RELEASE]
        fake.ancestry[(RELEASE, RELEASE)] = True
        with self.assertRaisesRegex(gate.PolicyError, "delet"):
            gate.determine_applicability(fake, RELEASE, "origin/staging")

    def test_markerless_unrelated_release_is_divergent(self):
        fake = self.markerless_git()
        with self.assertRaisesRegex(gate.PolicyError, "divergent"):
            gate.determine_applicability(fake, RELEASE, "origin/staging")

    def test_base_marker_absent_or_malformed_fails(self):
        for value in (None, b"wrong\n"):
            with self.subTest(value=value):
                fake = FakeGit()
                if value is None:
                    fake.files.pop((BASE, gate.MARKER_PATH))
                else:
                    fake.files[(BASE, gate.MARKER_PATH)] = value
                with self.assertRaisesRegex(gate.PolicyError, "base marker"):
                    gate.determine_applicability(fake, RELEASE, "origin/staging")

    def test_introduction_absent_repeated_or_malformed_fails(self):
        for introductions in ([], [INTRODUCTION, FEATURE], ["not-a-sha"]):
            with self.subTest(introductions=introductions):
                fake = FakeGit()
                fake.introductions = introductions
                with self.assertRaisesRegex(gate.PolicyError, "introduction"):
                    gate.determine_applicability(fake, RELEASE, "origin/staging")

    def test_shallow_or_unresolved_history_fails(self):
        shallow = FakeGit()
        shallow.shallow = True
        unresolved_release = FakeGit()
        unresolved_release.resolutions[RELEASE] = gate.PolicyError("unresolved release")
        unresolved_base = FakeGit()
        unresolved_base.resolutions["origin/staging"] = gate.PolicyError("unresolved base")
        for fake in (shallow, unresolved_release, unresolved_base):
            with self.subTest(fake=fake):
                with self.assertRaises(gate.PolicyError):
                    gate.determine_applicability(fake, RELEASE, "origin/staging")

    def test_release_resolution_must_equal_supplied_full_sha(self):
        fake = FakeGit()
        fake.resolutions[RELEASE] = FEATURE
        with self.assertRaisesRegex(gate.PolicyError, "immutable"):
            gate.determine_applicability(fake, RELEASE, "origin/staging")

    def test_release_must_be_reachable_from_base(self):
        fake = FakeGit()
        fake.ancestry[(RELEASE, BASE)] = False
        with self.assertRaisesRegex(gate.PolicyError, "reachable"):
            gate.determine_applicability(fake, RELEASE, "origin/staging")

    def test_ancestry_adapter_error_is_not_reinterpreted(self):
        fake = FakeGit()
        fake.ancestry[(RELEASE, BASE)] = gate.PolicyError("unexpected ancestry exit")
        with self.assertRaisesRegex(gate.PolicyError, "unexpected ancestry exit"):
            gate.determine_applicability(fake, RELEASE, "origin/staging")

    def test_marker_present_requires_target_and_action_before_status_factory(self):
        for missing_path in (gate.TARGET_PATH, gate.ACTION_PATH):
            with self.subTest(path=missing_path):
                fake = FakeGit()
                fake.files.pop((RELEASE, missing_path))
                factory = Factory(CountingStatusSource([[status()]]))
                with self.assertRaises(gate.PolicyError):
                    gate.wait_for_gate(
                        fake, factory, FakeClock(), RELEASE, "origin/staging", 1800, 15, PREFIX
                    )
                self.assertEqual(0, factory.calls)

    def test_comment_only_and_lookalike_target_declarations_fail_before_status(self):
        invalid_targets = (
            b'# name = "large_ingestion_release_gate"\n',
            b'other_name = "large_ingestion_release_gate"\n',
            b'name = "large_ingestion_release_gate_lookalike"\n',
        )
        for source in invalid_targets:
            with self.subTest(source=source):
                fake = FakeGit()
                fake.files[(RELEASE, "elixir/serviceradar_core/BUILD.bazel")] = source
                factory = Factory(CountingStatusSource([[status()]]))
                with self.assertRaisesRegex(gate.PolicyError, "Bazel target"):
                    gate.wait_for_gate(
                        fake, factory, FakeClock(), RELEASE, "origin/staging", 1800, 15, PREFIX
                    )
                self.assertEqual(0, factory.calls)

    def test_starlark_multiline_string_target_lookalike_fails_before_status(self):
        fake = FakeGit()
        fake.files[(RELEASE, "elixir/serviceradar_core/BUILD.bazel")] = b'''notice = """
name = "large_ingestion_release_gate"
"""
'''
        factory = Factory(CountingStatusSource([[status()]]))
        with self.assertRaisesRegex(gate.PolicyError, "Bazel target"):
            gate.wait_for_gate(
                fake, factory, FakeClock(), RELEASE, "origin/staging", 1800, 15, PREFIX
            )
        self.assertEqual(0, factory.calls)

    def test_comment_only_and_lookalike_action_declarations_fail_before_status(self):
        invalid_actions = (
            b'# - name: "LargeIngestionGate"\n',
            b'display_name: "LargeIngestionGate"\n',
            b'- name: "LargeIngestionGateLookalike"\n',
        )
        for source in invalid_actions:
            with self.subTest(source=source):
                fake = FakeGit()
                fake.files[(RELEASE, "buildbuddy.yaml")] = source
                factory = Factory(CountingStatusSource([[status()]]))
                with self.assertRaisesRegex(gate.PolicyError, "action"):
                    gate.wait_for_gate(
                        fake, factory, FakeClock(), RELEASE, "origin/staging", 1800, 15, PREFIX
                    )
                self.assertEqual(0, factory.calls)

    def test_yaml_block_scalar_action_lookalike_fails_before_status(self):
        fake = FakeGit()
        fake.files[(RELEASE, "buildbuddy.yaml")] = b'''actions:
  - name: "OtherAction"
    steps:
      - run: |
          echo "inactive declaration follows"
          - name: "LargeIngestionGate"
'''
        factory = Factory(CountingStatusSource([[status()]]))
        with self.assertRaisesRegex(gate.PolicyError, "action"):
            gate.wait_for_gate(
                fake, factory, FakeClock(), RELEASE, "origin/staging", 1800, 15, PREFIX
            )
        self.assertEqual(0, factory.calls)

    def test_malformed_target_or_action_source_fails_before_status(self):
        malformed = (
            (
                "elixir/serviceradar_core/BUILD.bazel",
                b'ex_unit_test(\n    name = "large_ingestion_release_gate",\n',
            ),
            (
                "buildbuddy.yaml",
                b'actions:\n\t- name: "LargeIngestionGate"\n',
            ),
        )
        for path, source in malformed:
            with self.subTest(path=path):
                fake = FakeGit()
                fake.files[(RELEASE, path)] = source
                factory = Factory(CountingStatusSource([[status()]]))
                with self.assertRaises(gate.PolicyError):
                    gate.wait_for_gate(
                        fake, factory, FakeClock(), RELEASE, "origin/staging", 1800, 15, PREFIX
                    )
                self.assertEqual(0, factory.calls)

    def test_marker_bearing_feature_commit_before_first_parent_merge_is_applicable(self):
        fake = FakeGit()
        fake.ancestry[(RELEASE, INTRODUCTION)] = True
        fake.ancestry[(INTRODUCTION, RELEASE)] = False
        self.assertTrue(gate.determine_applicability(fake, RELEASE, "origin/staging"))


class StatusPolicyTest(unittest.TestCase):
    def test_policy_constants_match_the_permanent_external_contract(self):
        self.assertEqual("build/ci/large_ingestion_gate_contract.v1", gate.MARKER_PATH)
        self.assertEqual(b"large-ingestion-gate-contract-v1\n", gate.MARKER_BYTES)
        self.assertEqual("elixir/serviceradar_core/BUILD.bazel", gate.TARGET_PATH)
        self.assertEqual(b'name = "large_ingestion_release_gate"', gate.TARGET_TEXT)
        self.assertEqual("buildbuddy.yaml", gate.ACTION_PATH)
        self.assertEqual(b'name: "LargeIngestionGate"', gate.ACTION_TEXT)
        self.assertEqual("LargeIngestionGate", gate.STATUS_CONTEXT)
        self.assertEqual("carverauto.buildbuddy.io", gate.BUILDBUDDY_HOST)
        self.assertEqual("/invocation/", gate.INVOCATION_PATH)
        self.assertEqual(
            "https://carverauto.buildbuddy.io/invocation/", gate.TARGET_URL_PREFIX
        )

    def test_latest_uses_timestamp_then_id_not_response_order(self):
        older = status(created_at="2026-08-23T11:59:59Z", status_id=99)
        newer_low_id = status(state="pending", status_id=1)
        newer_high_id = status(state="failure", status_id=2)
        self.assertEqual(newer_high_id, gate.latest_status([newer_high_id, older, newer_low_id]))

    def test_url_accepts_exact_buildbuddy_invocation(self):
        self.assertEqual(VALID_URL, gate.validate_target_url(VALID_URL, PREFIX))

    def test_url_rejects_spoofs_and_malformed_values(self):
        invalid = (
            "http://carverauto.buildbuddy.io/invocation/abc",
            "https://carverauto.buildbuddy.io/invocation/",
            "https://carverauto.buildbuddy.io/invocations/abc",
            "https://carverauto.buildbuddy.io.evil.example/invocation/abc",
            "https://evil.example/carverauto.buildbuddy.io/invocation/abc",
            "https://carverauto.buildbuddy.io@evil.example/invocation/abc",
            "https://evil.example@carverauto.buildbuddy.io/invocation/abc",
            "not a URL",
            "",
            VALID_URL + " ",
            VALID_URL + "\t",
            VALID_URL + "\nhttps://evil.example/",
        )
        for candidate in invalid:
            with self.subTest(candidate=candidate):
                with self.assertRaises(gate.PolicyError):
                    gate.validate_target_url(candidate, PREFIX)

    def test_url_rejects_raw_whitespace_or_controls_before_parsing(self):
        for candidate, configured in (
            (VALID_URL + "\n", PREFIX),
            (VALID_URL.replace("abc123", "abc\t123"), PREFIX),
            (VALID_URL, PREFIX + "\n"),
            (VALID_URL, PREFIX.replace("invocation", "invocation\t")),
        ):
            with self.subTest(candidate=candidate, configured=configured):
                with self.assertRaisesRegex(gate.PolicyError, "whitespace or control"):
                    gate.validate_target_url(candidate, configured)

    def test_configured_prefix_cannot_weaken_fixed_policy(self):
        for prefix in (
            "http://carverauto.buildbuddy.io/invocation/",
            "https://evil.example/invocation/",
            "https://carverauto.buildbuddy.io/",
            PREFIX + "nested/",
        ):
            with self.subTest(prefix=prefix):
                with self.assertRaises(gate.PolicyError):
                    gate.validate_target_url(VALID_URL, prefix)


class PollingTest(unittest.TestCase):
    def run_gate(self, snapshots, timeout=1800, poll=15):
        fake = FakeGit()
        source = CountingStatusSource(snapshots)
        factory = Factory(source)
        clock = FakeClock()
        result = gate.wait_for_gate(
            fake, factory, clock, RELEASE, "origin/staging", timeout, poll, PREFIX
        )
        return result, source, factory, clock

    def test_missing_and_pending_timeout_at_fake_1800_second_deadline(self):
        for snapshot in ([], [status(state="pending")]):
            with self.subTest(snapshot=snapshot):
                fake = FakeGit()
                source = CountingStatusSource([snapshot] * 121)
                clock = FakeClock()
                with self.assertRaisesRegex(gate.PolicyError, "timed out"):
                    gate.wait_for_gate(
                        fake, Factory(source), clock, RELEASE, "origin/staging", 1800, 15, PREFIX
                    )
                self.assertEqual(1800, clock.now)
                self.assertEqual(120, source.calls)
                self.assertTrue(all(value == 15 for value in clock.sleeps))

    def test_success_returned_after_deadline_is_rejected(self):
        fake = FakeGit()
        clock = FakeClock()

        class SlowSuccessSource:
            def snapshot(self, timeout_seconds=None):
                clock.now = 1801
                return [status()]

        with self.assertRaisesRegex(gate.PolicyError, "timed out"):
            gate.wait_for_gate(
                fake,
                Factory(SlowSuccessSource()),
                clock,
                RELEASE,
                "origin/staging",
                1800,
                15,
                PREFIX,
            )

    def test_gh_runner_receives_remaining_monotonic_budget_each_snapshot(self):
        pending = [[{
            "state": "pending",
            "context": "LargeIngestionGate",
            "target_url": "",
            "created_at": "2026-08-23T12:00:00Z",
            "id": 1,
        }]]
        success = [[{
            "state": "success",
            "context": "LargeIngestionGate",
            "target_url": VALID_URL,
            "created_at": "2026-08-23T12:01:00Z",
            "id": 2,
        }]]
        runner = QueueRunner([
            completed(stdout=json.dumps(pending).encode()),
            completed(stdout=json.dumps(success).encode()),
        ])
        result = gate.wait_for_gate(
            FakeGit(),
            lambda sha: gate.GhStatusClient(
                "carverauto/serviceradar", sha, "test-token", runner, {"PATH": "/bin"}
            ),
            FakeClock(),
            RELEASE,
            "origin/staging",
            30,
            15,
            PREFIX,
        )
        self.assertEqual("QUALIFIED", result.message)
        self.assertEqual([30, 15], [call[1]["timeout"] for call in runner.calls])

    def test_hung_gh_snapshot_timeout_is_a_policy_error(self):
        runner = QueueRunner([subprocess.TimeoutExpired(["gh", "api"], 12.5)])
        source = gate.GhStatusClient(
            "carverauto/serviceradar", RELEASE, "test-token", runner, {"PATH": "/bin"}
        )
        with self.assertRaisesRegex(gate.PolicyError, "timed out"):
            gate.wait_for_gate(
                FakeGit(), Factory(source), FakeClock(), RELEASE, "origin/staging", 12.5, 5, PREFIX
            )

    def test_nonfinite_timeout_or_poll_is_rejected_before_status_construction(self):
        for timeout, poll in (
            (math.nan, 15),
            (math.inf, 15),
            (1800, math.nan),
            (1800, math.inf),
        ):
            with self.subTest(timeout=timeout, poll=poll):
                factory = Factory(CountingStatusSource([[status()]]))
                with self.assertRaisesRegex(gate.PolicyError, "finite positive"):
                    gate.wait_for_gate(
                        FakeGit(), factory, FakeClock(), RELEASE, "origin/staging",
                        timeout, poll, PREFIX,
                    )
                self.assertEqual(0, factory.calls)

    def test_older_success_does_not_mask_newer_pending(self):
        newer = status(state="pending", created_at="2026-08-23T12:01:00Z", status_id=2)
        older = status(state="success", created_at="2026-08-23T12:00:00Z", status_id=1)
        fake = FakeGit()
        clock = FakeClock()
        with self.assertRaisesRegex(gate.PolicyError, "timed out"):
            gate.wait_for_gate(
                fake, Factory(CountingStatusSource([[newer, older]] * 3)), clock,
                RELEASE, "origin/staging", 30, 15, PREFIX,
            )

    def test_terminal_failure_error_and_unknown_fail_immediately(self):
        for state_name in ("failure", "error", "cancelled"):
            with self.subTest(state=state_name):
                fake = FakeGit()
                source = CountingStatusSource([[status(state=state_name)]])
                clock = FakeClock()
                with self.assertRaises(gate.PolicyError):
                    gate.wait_for_gate(
                        fake, Factory(source), clock, RELEASE, "origin/staging", 1800, 15, PREFIX
                    )
                self.assertEqual(1, source.calls)
                self.assertEqual([], clock.sleeps)

    def test_success_after_pending_uses_fake_sleep(self):
        result, source, factory, clock = self.run_gate(
            [[status(state="pending")], [], [status()]]
        )
        self.assertEqual("QUALIFIED", result.message)
        self.assertEqual(VALID_URL, result.target_url)
        self.assertEqual(1, factory.calls)
        self.assertEqual(3, source.calls)
        self.assertEqual([15, 15], clock.sleeps)

    def test_historical_result_does_not_construct_status_source(self):
        fake = FakeGit()
        fake.files.pop((RELEASE, gate.MARKER_PATH))
        fake.ancestry[(RELEASE, INTRODUCTION)] = True
        factory = Factory(CountingStatusSource([]))
        result = gate.wait_for_gate(
            fake, factory, FakeClock(), RELEASE, "origin/staging", 1800, 15, PREFIX
        )
        self.assertEqual(gate.HISTORICAL_NOT_APPLICABLE, result.message)
        self.assertEqual(0, factory.calls)

    def merge_git(self):
        fake = FakeGit()
        fake.resolutions["origin/staging"] = MERGE
        fake.ancestry[(RELEASE, MERGE)] = True
        fake.first_parent = [MERGE, BASE]
        fake.trees[MERGE] = fake.trees[RELEASE]
        fake.files[(MERGE, gate.MARKER_PATH)] = fake.files[(BASE, gate.MARKER_PATH)]
        return fake

    def test_same_tree_merge_success_qualifies_while_tag_sha_is_still_pending(self):
        fake = self.merge_git()
        self.assertEqual((RELEASE, MERGE), gate.qualification_commits(fake, RELEASE, "origin/staging"))
        sources = {
            RELEASE: CountingStatusSource([[status(state="pending")]] * 3),
            MERGE: CountingStatusSource([[], [status()]]),
        }
        factory = type("F", (), {"calls": []})()

        def make_source(sha):
            factory.calls.append(sha)
            return sources[sha]

        result = gate.wait_for_gate(
            fake, make_source, FakeClock(), RELEASE, "origin/staging", 1800, 15, PREFIX
        )
        self.assertEqual("QUALIFIED", result.message)
        self.assertEqual(VALID_URL, result.target_url)
        self.assertEqual([RELEASE, MERGE], factory.calls)

    def test_tag_sha_failure_does_not_fail_while_merge_sha_is_pending(self):
        fake = self.merge_git()
        sources = {
            RELEASE: CountingStatusSource([[status(state="failure")]] * 3),
            MERGE: CountingStatusSource([[status(state="pending")], [status()]]),
        }

        def make_source(sha):
            return sources[sha]

        result = gate.wait_for_gate(
            fake, make_source, FakeClock(), RELEASE, "origin/staging", 1800, 15, PREFIX
        )
        self.assertEqual("QUALIFIED", result.message)

    def test_later_different_tree_descendant_is_ignored(self):
        fake = self.merge_git()
        tip = "6" * 40
        fake.resolutions["origin/staging"] = tip
        fake.ancestry[(RELEASE, tip)] = True
        fake.trees[tip] = "c" * 40
        fake.first_parent = [tip, MERGE, BASE]
        fake.files[(tip, gate.MARKER_PATH)] = fake.files[(BASE, gate.MARKER_PATH)]
        self.assertEqual((RELEASE, MERGE), gate.qualification_commits(fake, RELEASE, "origin/staging"))


class GhStatusClientTest(unittest.TestCase):
    def make_client(self, payload, returncode=0):
        runner = QueueRunner([completed(returncode, json.dumps(payload).encode(), b"failure detail")])
        client = gate.GhStatusClient(
            "carverauto/serviceradar", RELEASE, "top-secret", runner, {"PATH": "/bin"}
        )
        return client, runner

    def test_exact_argv_slurp_shape_token_isolation_and_shell_false(self):
        payload = [[
            {"state": "success", "context": "Other", "target_url": "", "created_at": "bad", "id": False},
        ], [
            {"state": "success", "context": gate.STATUS_CONTEXT, "target_url": VALID_URL,
             "created_at": "2026-08-23T12:00:00Z", "id": 8},
        ]]
        client, runner = self.make_client(payload)
        statuses = client.snapshot(30)
        self.assertEqual([8], [item.id for item in statuses])
        argv, kwargs = runner.calls[0]
        self.assertEqual(
            ["gh", "api", "--paginate", "--slurp", f"/repos/carverauto/serviceradar/commits/{RELEASE}/statuses?per_page=100"],
            argv,
        )
        self.assertIs(False, kwargs["shell"])
        self.assertTrue(kwargs["capture_output"])
        self.assertEqual("top-secret", kwargs["env"]["GH_TOKEN"])
        self.assertTrue(kwargs["env"]["PATH"].startswith("/usr/local/bin:/usr/bin:/bin:"))
        self.assertIn("/bin", kwargs["env"]["PATH"])
        self.assertNotIn("top-secret", repr(argv))
        self.assertNotIn("top-secret", repr(kwargs.get("errors")))

    def test_home_local_bin_is_prepended_when_home_is_set(self):
        payload = [[
            {"state": "success", "context": gate.STATUS_CONTEXT, "target_url": VALID_URL,
             "created_at": "2026-08-23T12:00:00Z", "id": 8},
        ]]
        runner = QueueRunner([completed(stdout=json.dumps(payload).encode())])
        client = gate.GhStatusClient(
            "carverauto/serviceradar", RELEASE, "top-secret", runner,
            {"PATH": "/bin", "HOME": "/tmp/release-home"},
        )
        client.snapshot(30)
        path = runner.calls[0][1]["env"]["PATH"]
        self.assertEqual(
            "/tmp/release-home/.local/bin:/usr/local/bin:/usr/bin:/bin:/bin",
            path,
        )

    def test_pagination_newer_later_page_is_visible_to_latest_selection(self):
        payload = [[
            {"state": "success", "context": gate.STATUS_CONTEXT, "target_url": VALID_URL,
             "created_at": "2026-08-23T12:00:00Z", "id": 8},
        ], [
            {"state": "pending", "context": gate.STATUS_CONTEXT, "target_url": "",
             "created_at": "2026-08-23T12:01:00Z", "id": 9},
        ]]
        client, _ = self.make_client(payload)
        self.assertEqual("pending", gate.latest_status(client.snapshot(30)).state)

    def test_nonzero_invalid_json_and_wrong_page_shapes_fail(self):
        cases = (
            (1, [[ ]]),
            (0, b"not-json"),
            (0, b"\xff"),
            (0, []),
            (0, [{"state": "success"}]),
            (0, [[{}], {"mixed": True}]),
        )
        for returncode, payload in cases:
            with self.subTest(returncode=returncode, payload=payload):
                raw = payload if isinstance(payload, bytes) else json.dumps(payload).encode()
                runner = QueueRunner([completed(returncode, raw, b"top-secret")])
                client = gate.GhStatusClient(
                    "carverauto/serviceradar", RELEASE, "top-secret", runner, {"PATH": "/bin"}
                )
                with self.assertRaises(gate.PolicyError) as caught:
                    client.snapshot(30)
                self.assertNotIn("top-secret", str(caught.exception))

    def test_malformed_matching_status_records_fail(self):
        base = {
            "state": "success", "context": gate.STATUS_CONTEXT, "target_url": VALID_URL,
            "created_at": "2026-08-23T12:00:00Z", "id": 1,
        }
        malformed = []
        for field in base:
            record = dict(base)
            record.pop(field)
            malformed.append(record)
        malformed.extend([
            {**base, "created_at": "not-a-date"},
            {**base, "created_at": "2026-08-23T12:00:00"},
            {**base, "id": True},
            {**base, "id": "1"},
        ])
        for record in malformed:
            with self.subTest(record=record):
                client, _ = self.make_client([[record]])
                with self.assertRaises(gate.PolicyError):
                    client.snapshot(30)


class GitRepositoryTest(unittest.TestCase):
    def test_workspace_root_is_resolved_by_argv_git(self):
        workspace = Path("/tmp/workspace")
        runner = QueueRunner([completed(stdout=b"/tmp/workspace\n")])
        repository = gate.GitRepository(workspace, runner)
        self.assertEqual(workspace.resolve(), repository.worktree_root())
        argv, kwargs = runner.calls[0]
        self.assertEqual(
            ["git", "-C", str(workspace), "rev-parse", "--show-toplevel"], argv
        )
        self.assertIs(False, kwargs["shell"])

    def test_every_git_invocation_has_workspace_prefix_and_success_paths(self):
        workspace = Path("/tmp/workspace")
        runner = QueueRunner([
            completed(stdout=(RELEASE + "\n").encode()),
            completed(stdout=b"false\n"),
            completed(returncode=0),
            completed(stdout=b"100644 blob deadbeef\tbuild/ci/large_ingestion_gate_contract.v1\0"),
            completed(stdout=gate.MARKER_BYTES),
            completed(stdout=(INTRODUCTION + "\n").encode()),
        ])
        repository = gate.GitRepository(workspace, runner)
        self.assertEqual(RELEASE, repository.resolve(RELEASE))
        self.assertFalse(repository.is_shallow())
        self.assertTrue(repository.is_ancestor(RELEASE, BASE))
        self.assertEqual(gate.MARKER_BYTES, repository.read_tree_file(RELEASE, gate.MARKER_PATH))
        self.assertEqual([INTRODUCTION], repository.marker_introductions("origin/staging"))
        self.assertEqual(
            [
                ["git", "-C", "/tmp/workspace", "rev-parse", "--verify", "1111111111111111111111111111111111111111^{commit}"],
                ["git", "-C", "/tmp/workspace", "rev-parse", "--is-shallow-repository"],
                ["git", "-C", "/tmp/workspace", "merge-base", "--is-ancestor", "1111111111111111111111111111111111111111", "2222222222222222222222222222222222222222"],
                ["git", "-C", "/tmp/workspace", "ls-tree", "-z", "--full-tree", "1111111111111111111111111111111111111111", "--", "build/ci/large_ingestion_gate_contract.v1"],
                ["git", "-C", "/tmp/workspace", "show", "1111111111111111111111111111111111111111:build/ci/large_ingestion_gate_contract.v1"],
                ["git", "-C", "/tmp/workspace", "log", "--first-parent", "--reverse", "--diff-filter=A", "--format=%H", "origin/staging", "--", "build/ci/large_ingestion_gate_contract.v1"],
            ],
            [argv for argv, _ in runner.calls],
        )
        for argv, kwargs in runner.calls:
            self.assertEqual(["git", "-C", "/tmp/workspace"], argv[:3])
            self.assertIs(False, kwargs["shell"])
            self.assertTrue(kwargs["capture_output"])

    def test_successful_ambiguous_revision_warning_fails_closed(self):
        runner = QueueRunner([
            completed(
                stdout=b"1111111111111111111111111111111111111111\n",
                stderr=b"warning: refname 'origin/staging' is ambiguous.\n",
            )
        ])
        repository = gate.GitRepository(Path("/tmp/workspace"), runner)
        with self.assertRaisesRegex(gate.PolicyError, "ambiguous"):
            repository.resolve("origin/staging")
        self.assertEqual(
            ["git", "-C", "/tmp/workspace", "rev-parse", "--verify", "origin/staging^{commit}"],
            runner.calls[0][0],
        )

    def test_expected_false_and_unexpected_ancestry_exit(self):
        false_runner = QueueRunner([completed(returncode=1)])
        repository = gate.GitRepository(Path("/tmp/workspace"), false_runner)
        self.assertFalse(repository.is_ancestor(RELEASE, BASE))
        bad_runner = QueueRunner([completed(returncode=2, stderr=b"details")])
        repository = gate.GitRepository(Path("/tmp/workspace"), bad_runner)
        with self.assertRaisesRegex(gate.PolicyError, "ancestry"):
            repository.is_ancestor(RELEASE, BASE)

    def test_missing_tree_file_is_distinct_from_read_failure(self):
        missing_runner = QueueRunner([completed(stdout=b"")])
        repository = gate.GitRepository(Path("/tmp/workspace"), missing_runner)
        self.assertIsNone(repository.read_tree_file(RELEASE, gate.MARKER_PATH))
        failed_runner = QueueRunner([completed(returncode=128, stderr=b"failure")])
        repository = gate.GitRepository(Path("/tmp/workspace"), failed_runner)
        with self.assertRaises(gate.PolicyError):
            repository.read_tree_file(RELEASE, gate.MARKER_PATH)

    def test_tree_sha_and_first_parent_history_argv(self):
        tree = "a" * 40
        runner = QueueRunner([
            completed(stdout=(tree + "\n").encode()),
            completed(stdout=(MERGE + "\n" + BASE + "\n").encode()),
        ])
        repository = gate.GitRepository(Path("/tmp/workspace"), runner)
        self.assertEqual(tree, repository.tree_sha(RELEASE))
        self.assertEqual([MERGE, BASE], repository.first_parent_history("origin/staging"))
        self.assertEqual(
            [
                ["git", "-C", "/tmp/workspace", "rev-parse", "--verify", RELEASE + "^{tree}"],
                ["git", "-C", "/tmp/workspace", "rev-list", "--first-parent", "--max-count=256", "origin/staging"],
            ],
            [argv for argv, _ in runner.calls],
        )


class CliTest(unittest.TestCase):
    def valid_argv(self):
        return [
            "--repository", "carverauto/serviceradar",
            "--commit", RELEASE,
            "--base-ref", "origin/staging",
            "--token-env", "GH_TOKEN",
            "--timeout-seconds", "1800",
            "--poll-seconds", "15",
            "--target-url-prefix", PREFIX,
        ]

    def test_missing_or_invalid_workspace_fails(self):
        environments = (
            {"GH_TOKEN": "secret"},
            {"GH_TOKEN": "secret", "BUILD_WORKSPACE_DIRECTORY": "/definitely/missing"},
        )
        for environment in environments:
            with self.subTest(environment=environment):
                out, err = io.StringIO(), io.StringIO()
                code = cli.run_cli(self.valid_argv(), environment, out, err, QueueRunner([]))
                self.assertNotEqual(0, code)

    def test_missing_token_and_invalid_full_sha_fail_sanitized(self):
        cases = (
            (self.valid_argv(), {"BUILD_WORKSPACE_DIRECTORY": "/tmp"}),
            ([value if value != RELEASE else "short" for value in self.valid_argv()],
             {"BUILD_WORKSPACE_DIRECTORY": "/tmp", "GH_TOKEN": "secret"}),
        )
        for argv, environment in cases:
            with self.subTest(argv=argv):
                out, err = io.StringIO(), io.StringIO()
                code = cli.run_cli(argv, environment, out, err, QueueRunner([]))
                self.assertNotEqual(0, code)
                self.assertNotIn("secret", out.getvalue() + err.getvalue())

    def test_argument_validation_rejects_unsafe_values(self):
        replacements = {
            "carverauto/serviceradar": "bad repo",
            "origin/staging": "",
            "GH_TOKEN": "",
            "1800": "0",
            "15": "-1",
            PREFIX: "https://evil.example/invocation/",
        }
        for old, new in replacements.items():
            with self.subTest(value=new):
                argv = [new if value == old else value for value in self.valid_argv()]
                code = cli.run_cli(
                    argv,
                    {"BUILD_WORKSPACE_DIRECTORY": "/tmp", "GH_TOKEN": "secret"},
                    io.StringIO(), io.StringIO(), QueueRunner([]),
                )
                self.assertNotEqual(0, code)

    def test_nonfinite_timeout_and_poll_are_rejected_with_sanitized_cli_errors(self):
        cases = (
            ("1800", "nan"),
            ("1800", "inf"),
            ("nan", "15"),
            ("inf", "15"),
        )
        for timeout, poll in cases:
            with self.subTest(timeout=timeout, poll=poll):
                argv = self.valid_argv()
                argv[argv.index("--timeout-seconds") + 1] = timeout
                argv[argv.index("--poll-seconds") + 1] = poll
                out, err = io.StringIO(), io.StringIO()
                code = cli.run_cli(
                    argv,
                    {"BUILD_WORKSPACE_DIRECTORY": "/tmp", "GH_TOKEN": "test-token"},
                    out,
                    err,
                    QueueRunner([]),
                )
                self.assertEqual(1, code)
                self.assertIn("finite positive", err.getvalue())
                self.assertNotIn("test-token", out.getvalue() + err.getvalue())

    def test_git_root_failure_is_sanitized_and_does_not_log_token(self):
        with tempfile.TemporaryDirectory() as temporary:
            workspace = Path(temporary)
            (workspace / ".git").mkdir()
            runner = QueueRunner([completed(returncode=2, stderr=b"secret")])
            out, err = io.StringIO(), io.StringIO()
            code = cli.run_cli(
                self.valid_argv(),
                {"BUILD_WORKSPACE_DIRECTORY": temporary, "GH_TOKEN": "secret"},
                out,
                err,
                runner,
            )
            self.assertNotEqual(0, code)
            self.assertNotIn("secret", out.getvalue() + err.getvalue())


if __name__ == "__main__":
    unittest.main(testRunner=unittest.TextTestRunner(stream=sys.stdout, verbosity=2))
