#!/usr/bin/env python3
"""What each built-in NATS identity may publish and subscribe.

The oracle is NATS subject matching applied to each user's allow and deny
lists, with the broker's rule that an empty allow list means every subject.

EventWriter stores a batch from logs.normalized.> without running Zen rules, so
the broker has to refuse that subject to every identity but the log collector.
An identity whose feature is off must be refused everything.
"""

import unittest

import yaml

from chart_render import render_document


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
    "media worker enabled": {"mediaWorker.enabled": True},
    "vantage worker enabled": {"vantageWorker.enabled": True},
}


def render_static_users_configmap(values=None):
    """The static-users ConfigMap's data, which core and the broker read."""
    config_map = render_document(
        "templates/nats.yaml", values or {}, namespace="nats-test",
        kind="ConfigMap", name="serviceradar-nats-static-users",
    )
    return config_map["data"]


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

def chart_subject(cn: str) -> str:
    return f"CN={cn},OU=Kubernetes,O=ServiceRadar,L=San Francisco,ST=CA,C=US"


def index_users_by_subject(users: list[dict]) -> dict[str, dict]:
    indexed: dict[str, dict] = {}
    for user in users:
        subject = user["user"]
        if subject in indexed:
            raise AssertionError(f"duplicate static NATS user subject: {subject}")
        indexed[subject] = user
    return indexed


# Identities that exist only for a feature the default rendering leaves off.
DISABLED_BY_DEFAULT = (
    chart_subject("serviceradar-flow-collector"),
    chart_subject("serviceradar-netflow-collector"),
    chart_subject("serviceradar-k8s-inventory"),
    chart_subject("serviceradar-media-worker"),
    chart_subject("serviceradar-vantage-worker"),
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
        users = index_users_by_subject(render_static_users())
        for subject_dn in DISABLED_BY_DEFAULT:
            for direction in ("publish", "subscribe"):
                for subject in (
                    UNLISTED_SUBJECT, "flows.raw.netflow", "inventory.k8s.nodes",
                    "_INBOX.reply", "$JS.API.INFO", "$SYS.REQ.SERVER.PING",
                ):
                    with self.subTest(user=subject_dn, direction=direction, subject=subject):
                        self.assertFalse(may(users[subject_dn], direction, subject))


class VisualIndexJobPermissionsTest(unittest.TestCase):
    def test_core_may_publish_live_and_backfill_jobs(self):
        users = {user["user"].split(",")[0]: user for user in render_static_users()}
        for subject in ("media.jobs.visual_index.v1", "media.jobs.visual_index.backfill.v1"):
            with self.subTest(subject=subject):
                self.assertTrue(may_publish(users["CN=serviceradar-core"], subject))


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


MEDIA_WORKER = chart_subject("serviceradar-media-worker")
VANTAGE_WORKER = chart_subject("serviceradar-vantage-worker")
CORE = chart_subject("serviceradar-core")
WEB_NG = chart_subject("serviceradar-web-ng")
JOBS_STREAM = "CAMERA_MEDIA_JOBS"
LIVE_CONSUMER = "camera_visual_index_worker_v1_live"
BACKFILL_CONSUMER = "camera_visual_index_worker_v1_backfill"
VANTAGE_VLM_LIVE_CONSUMER = "camera_vantage_vlm_worker_v1_live"
VANTAGE_VLM_BACKFILL_CONSUMER = "camera_vantage_vlm_worker_v1_backfill"
LIVE_JOBS = "media.jobs.visual_index.v1"
BACKFILL_JOBS = "media.jobs.visual_index.backfill.v1"
VANTAGE_VLM_JOBS = "media.jobs.vantage.vlm.v1"
VANTAGE_VLM_BACKFILL_JOBS = "media.jobs.vantage.vlm.backfill.v1"
VANTAGE_CAP_JOBS = "media.jobs.vantage.vantage_alpr_v1.v1"
VANTAGE_CAP_BACKFILL_JOBS = "media.jobs.vantage.vantage_alpr_v1.backfill.v1"
VANTAGE_LIVE_TAP = "media.live.vantage.vantage_bay_guidance_v1.v1"
VANTAGE_RESULTS = "media.results.vantage.v1"
VANTAGE_HEARTBEAT = "media.workers.heartbeat.v1"
# Camera.SemanticSearch requests on the embedder's id and version.
TEXT_EMBED_REQUEST = "media.rpc.visual_text_embed.v1.siglip-b16-384.2026.1"
# The worker's own inboxes (SERVICERADAR_MEDIA_WORKER_NATS_INBOX_PREFIX), and an
# inbox of the kind EventWriter pulls telemetry into.
WORKER_INBOX = "_INBOX.media-worker.Zk3x9.1"
VANTAGE_WORKER_INBOX = "_INBOX.vantage-worker.Zk3x9.1"
OTHER_INBOX = "_INBOX.Qa71c.4"


class MediaWorkerPermissionsTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.enabled_cm = render_static_users_configmap({"mediaWorker.enabled": True})
        cls.disabled_cm = render_static_users_configmap()
        cls.enabled = index_users_by_subject(yaml.safe_load(cls.enabled_cm["static-users.yaml"]))
        cls.disabled = index_users_by_subject(yaml.safe_load(cls.disabled_cm["static-users.yaml"]))

    def test_static_user_subjects_match_full_certificate_subjects(self):
        enabled_identities = yaml.safe_load(self.enabled_cm["chart-identities.yaml"])
        disabled_identities = yaml.safe_load(self.disabled_cm["chart-identities.yaml"])
        for subject in (MEDIA_WORKER, CORE, WEB_NG):
            self.assertIn(subject, self.enabled)
            self.assertIn(subject, self.disabled)
            self.assertIn(subject, enabled_identities)
        self.assertNotIn(MEDIA_WORKER, disabled_identities)

    def test_the_worker_can_run_its_job_loop_and_answer_searches_only_while_enabled(self):
        # What rust/media-worker/src/worker.rs sends through async-nats: stream
        # get-or-create, durable consumer get-or-create (named, with its filter),
        # pulls, acks, result and metrics publishes, and replies to requesters.
        # Disabled, the same identity (say, a certificate left from an earlier
        # enablement) is refused every one of them.
        publish = (
            f"$JS.API.STREAM.INFO.{JOBS_STREAM}",
            f"$JS.API.STREAM.CREATE.{JOBS_STREAM}",
            f"$JS.API.STREAM.UPDATE.{JOBS_STREAM}",
            "$JS.API.STREAM.INFO.CAMERA_MEDIA_RESULTS",
            "$JS.API.STREAM.CREATE.CAMERA_MEDIA_RESULTS",
            "$JS.API.STREAM.UPDATE.CAMERA_MEDIA_RESULTS",
            f"$JS.API.CONSUMER.INFO.{JOBS_STREAM}.{LIVE_CONSUMER}",
            f"$JS.API.CONSUMER.CREATE.{JOBS_STREAM}.{LIVE_CONSUMER}.{LIVE_JOBS}",
            f"$JS.API.CONSUMER.MSG.NEXT.{JOBS_STREAM}.{LIVE_CONSUMER}",
            f"$JS.ACK.{JOBS_STREAM}.{LIVE_CONSUMER}.1.17.9.1700000000000000000.0",
            f"$JS.API.CONSUMER.INFO.{JOBS_STREAM}.{BACKFILL_CONSUMER}",
            f"$JS.API.CONSUMER.CREATE.{JOBS_STREAM}.{BACKFILL_CONSUMER}.{BACKFILL_JOBS}",
            f"$JS.API.CONSUMER.MSG.NEXT.{JOBS_STREAM}.{BACKFILL_CONSUMER}",
            f"$JS.ACK.{JOBS_STREAM}.{BACKFILL_CONSUMER}.1.3.3.1700000000000000000.0",
            f"$JS.API.CONSUMER.INFO.{JOBS_STREAM}.{VANTAGE_VLM_LIVE_CONSUMER}",
            f"$JS.API.CONSUMER.CREATE.{JOBS_STREAM}.{VANTAGE_VLM_LIVE_CONSUMER}.{VANTAGE_VLM_JOBS}",
            f"$JS.API.CONSUMER.MSG.NEXT.{JOBS_STREAM}.{VANTAGE_VLM_LIVE_CONSUMER}",
            f"$JS.ACK.{JOBS_STREAM}.{VANTAGE_VLM_LIVE_CONSUMER}.1.5.5.1700000000000000000.0",
            f"$JS.API.CONSUMER.INFO.{JOBS_STREAM}.{VANTAGE_VLM_BACKFILL_CONSUMER}",
            f"$JS.API.CONSUMER.CREATE.{JOBS_STREAM}.{VANTAGE_VLM_BACKFILL_CONSUMER}.{VANTAGE_VLM_BACKFILL_JOBS}",
            f"$JS.API.CONSUMER.MSG.NEXT.{JOBS_STREAM}.{VANTAGE_VLM_BACKFILL_CONSUMER}",
            f"$JS.ACK.{JOBS_STREAM}.{VANTAGE_VLM_BACKFILL_CONSUMER}.1.6.6.1700000000000000000.0",
            "media.results.visual_index.v1",
            VANTAGE_RESULTS,
            "telemetry.media_worker.metrics.v1",
            # The embedding reply goes to web-ng's reply subject.
            OTHER_INBOX,
        )
        subscribe = (TEXT_EMBED_REQUEST, WORKER_INBOX)
        for rendering, users, expected in (
            ("enabled", self.enabled, True),
            ("disabled", self.disabled, False),
        ):
            worker = users[MEDIA_WORKER]
            for subject in publish:
                with self.subTest(rendering=rendering, publish=subject):
                    self.assertEqual(may_publish(worker, subject), expected)
            for subject in subscribe:
                with self.subTest(rendering=rendering, subscribe=subject):
                    self.assertEqual(may(worker, "subscribe", subject), expected)

    def test_the_worker_reaches_no_other_stream_and_dispatches_nothing(self):
        worker = self.enabled[MEDIA_WORKER]
        for subject in (
            LIVE_JOBS,
            VANTAGE_VLM_JOBS,
            VANTAGE_CAP_JOBS,
            f"$JS.API.STREAM.DELETE.{JOBS_STREAM}",
            "$JS.API.STREAM.PURGE.CAMERA_MEDIA_RESULTS",
            "$JS.API.CONSUMER.CREATE.CAMERA_MEDIA_RESULTS.synthetic_projector.media.results.visual_index.v1",
            "$JS.API.CONSUMER.CREATE.CAMERA_MEDIA_RESULTS.synthetic_projector.media.results.vantage.v1",
            f"$JS.API.CONSUMER.DELETE.{JOBS_STREAM}.{LIVE_CONSUMER}",
            f"$JS.API.CONSUMER.DELETE.{JOBS_STREAM}.{VANTAGE_VLM_LIVE_CONSUMER}",
            f"$JS.API.CONSUMER.DELETE.{JOBS_STREAM}.{VANTAGE_VLM_BACKFILL_CONSUMER}",
            "$JS.API.CONSUMER.MSG.NEXT.events.synthetic_consumer",
            "$JS.ACK.events.synthetic_consumer.1.1.1.1.0",
            "$KV.serviceradar-datasvc.synthetic-key",
            "events.synthetic",
            "logs.internal.synthetic",
        ):
            with self.subTest(publish=subject):
                self.assertFalse(may_publish(worker, subject))
        # Deliveries for other services' inboxes (EventWriter pulls telemetry
        # into _INBOX.<id>) must not reach the worker.
        for subject in (
            LIVE_JOBS,
            VANTAGE_VLM_JOBS,
            "media.results.visual_index.v1",
            VANTAGE_RESULTS,
            "events.synthetic",
            OTHER_INBOX,
        ):
            with self.subTest(subscribe=subject):
                self.assertFalse(may(worker, "subscribe", subject))

    def test_core_dispatches_jobs_and_web_ng_searches_only_while_the_worker_is_on(self):
        for rendering, users, expected in (
            ("enabled", self.enabled, True),
            ("disabled", self.disabled, False),
        ):
            core = users[CORE]
            web = users[WEB_NG]
            for subject in (
                LIVE_JOBS,
                BACKFILL_JOBS,
                VANTAGE_VLM_JOBS,
                VANTAGE_CAP_JOBS,
                VANTAGE_CAP_BACKFILL_JOBS,
                VANTAGE_LIVE_TAP,
            ):
                with self.subTest(rendering=rendering, core=subject):
                    self.assertTrue(may_publish(core, subject))
            self.assertTrue(may(core, "subscribe", VANTAGE_HEARTBEAT))
            with self.subTest(rendering=rendering, web=TEXT_EMBED_REQUEST):
                self.assertEqual(may_publish(web, TEXT_EMBED_REQUEST), expected)
        self.assertFalse(may_publish(self.enabled[WEB_NG], LIVE_JOBS))
        self.assertFalse(may_publish(self.enabled[WEB_NG], VANTAGE_VLM_JOBS))


class VantageWorkerPermissionsTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.enabled_cm = render_static_users_configmap({"vantageWorker.enabled": True})
        cls.disabled_cm = render_static_users_configmap()
        cls.enabled = index_users_by_subject(yaml.safe_load(cls.enabled_cm["static-users.yaml"]))
        cls.disabled = index_users_by_subject(yaml.safe_load(cls.disabled_cm["static-users.yaml"]))

    def test_vantage_worker_chart_identity_is_gated(self):
        enabled_identities = yaml.safe_load(self.enabled_cm["chart-identities.yaml"])
        disabled_identities = yaml.safe_load(self.disabled_cm["chart-identities.yaml"])
        self.assertIn(VANTAGE_WORKER, enabled_identities)
        self.assertNotIn(VANTAGE_WORKER, disabled_identities)

    def test_vantage_worker_least_privilege_permissions(self):
        publish = (
            VANTAGE_HEARTBEAT,
            VANTAGE_RESULTS,
            "telemetry.vantage_worker.metrics.v1",
            f"$JS.API.STREAM.INFO.{JOBS_STREAM}",
            "$JS.API.STREAM.INFO.CAMERA_MEDIA_RESULTS",
            f"$JS.API.CONSUMER.INFO.{JOBS_STREAM}.vantage_alpr_v1_live",
            f"$JS.API.CONSUMER.CREATE.{JOBS_STREAM}.vantage_alpr_v1_live.{VANTAGE_CAP_JOBS}",
            f"$JS.API.CONSUMER.CREATE.{JOBS_STREAM}.vantage_alpr_v1_backfill.{VANTAGE_CAP_BACKFILL_JOBS}",
            f"$JS.API.CONSUMER.MSG.NEXT.{JOBS_STREAM}.vantage_alpr_v1_live",
            f"$JS.ACK.{JOBS_STREAM}.vantage_alpr_v1_live.1.2.3.1700000000000000000.0",
            OTHER_INBOX,
        )
        subscribe = (VANTAGE_LIVE_TAP, VANTAGE_WORKER_INBOX)

        for rendering, users, expected in (
            ("enabled", self.enabled, True),
            ("disabled", self.disabled, False),
        ):
            worker = users[VANTAGE_WORKER]
            for subject in publish:
                with self.subTest(rendering=rendering, publish=subject):
                    self.assertEqual(may_publish(worker, subject), expected)
            for subject in subscribe:
                with self.subTest(rendering=rendering, subscribe=subject):
                    self.assertEqual(may(worker, "subscribe", subject), expected)

    def test_vantage_worker_cannot_touch_unrelated_streams_or_dispatches(self):
        worker = self.enabled[VANTAGE_WORKER]
        media_worker_consumers = (
            (LIVE_CONSUMER, LIVE_JOBS),
            (BACKFILL_CONSUMER, BACKFILL_JOBS),
            (VANTAGE_VLM_LIVE_CONSUMER, VANTAGE_VLM_JOBS),
            (VANTAGE_VLM_BACKFILL_CONSUMER, VANTAGE_VLM_BACKFILL_JOBS),
        )
        forbidden_publish = [
            VANTAGE_CAP_JOBS,
            LIVE_JOBS,
            f"$JS.API.STREAM.CREATE.{JOBS_STREAM}",
            f"$JS.API.STREAM.UPDATE.{JOBS_STREAM}",
            f"$JS.API.STREAM.DELETE.{JOBS_STREAM}",
            "$JS.API.STREAM.CREATE.CAMERA_MEDIA_RESULTS",
            "$JS.API.STREAM.UPDATE.CAMERA_MEDIA_RESULTS",
            "$JS.API.STREAM.PURGE.CAMERA_MEDIA_RESULTS",
            f"$JS.API.CONSUMER.CREATE.{JOBS_STREAM}.vantage_vlm_hijack.{VANTAGE_VLM_JOBS}",
            f"$JS.API.CONSUMER.CREATE.{JOBS_STREAM}.vantage_vlm_hijack.{VANTAGE_VLM_BACKFILL_JOBS}",
            "$JS.API.CONSUMER.CREATE.CAMERA_MEDIA_RESULTS.proj.media.results.vantage.v1",
            f"$JS.API.CONSUMER.DELETE.{JOBS_STREAM}.vantage_alpr_v1_live",
            "$KV.serviceradar-datasvc.synthetic-key",
            "events.synthetic",
            "logs.normalized.synthetic",
        ]
        for consumer, filter_subject in media_worker_consumers:
            forbidden_publish.extend(
                [
                    f"$JS.API.CONSUMER.INFO.{JOBS_STREAM}.{consumer}",
                    f"$JS.API.CONSUMER.CREATE.{JOBS_STREAM}.{consumer}.{filter_subject}",
                    f"$JS.API.CONSUMER.MSG.NEXT.{JOBS_STREAM}.{consumer}",
                    f"$JS.ACK.{JOBS_STREAM}.{consumer}.1.2.3.1700000000000000000.0",
                ]
            )
        for subject in forbidden_publish:
            with self.subTest(publish=subject):
                self.assertFalse(may_publish(worker, subject))

        for subject in (
            VANTAGE_CAP_JOBS,
            VANTAGE_RESULTS,
            VANTAGE_HEARTBEAT,
            "events.synthetic",
            OTHER_INBOX,
        ):
            with self.subTest(subscribe=subject):
                self.assertFalse(may(worker, "subscribe", subject))


if __name__ == "__main__":
    unittest.main()
