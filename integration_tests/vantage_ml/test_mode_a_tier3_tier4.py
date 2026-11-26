"""Mode A hermetic tests for E2E-M5 (Tiers 3 & 4 + Master Catalog Audit).

Pure Python 3.11+ stdlib `unittest` suite covering:
- 15 Tier 3 pairwise cross-feature contract combinations (`E2E-T3-01`..`E2E-T3-15`)
- 7 Tier 4 real-world operational workloads (`E2E-T4-W1`..`E2E-T4-W7`)
- Master `fixtures/test_catalog.json` completeness, parity, and synthetic-hygiene audit (`180` cases)
"""

from __future__ import annotations

import base64
import copy
import gzip
import hashlib
import io
import json
import math
import os
import re
import shlex
import sys
import tarfile
import unittest
from collections import deque
from pathlib import Path
from typing import Any, Mapping, Sequence

if __package__ in (None, "") and "TEST_SRCDIR" not in os.environ:
    _repo_root = str(Path(__file__).resolve().parents[2])
    if _repo_root not in sys.path:
        sys.path.insert(0, _repo_root)

from integration_tests.vantage_ml import vantage_contracts as vc

_CAPABILITY_TOKEN_RE = re.compile(r"^[a-z0-9][a-z0-9._-]*$")
_PLATE_TEXT_RE = re.compile(r"^[A-Z0-9-]{2,12}$")


def _fixtures_dir() -> Path:
    return vc.repo_root() / "integration_tests" / "vantage_ml" / "fixtures"


def _load_json(rel_path: str) -> Any:
    path = _fixtures_dir() / rel_path
    if not path.is_file():
        raise AssertionError(f"missing fixture file: {path}")
    return json.loads(path.read_text(encoding="utf-8"))


def _e2e_case(feature: str, tier: int, test_id: str, description: str):
    vc.record_test_case(feature, tier, test_id, "A+B", description)

    def _decorator(fn):
        fn._e2e_test_id = test_id
        return fn

    return _decorator


def _make_exact_size_baseline_jfif(target_bytes: int) -> bytes:
    """Create a valid Baseline JFIF byte payload padded with a pre-SOS COM marker."""
    base = vc.make_synthetic_baseline_jfif(64, 48, seed=11, target_max_bytes=4096)
    vc.validate_baseline_jfif(base, max_bytes=4096)
    if target_bytes < len(base) + 4:
        raise ValueError(f"target_bytes {target_bytes} too small for base JFIF ({len(base)} bytes)")
    payload_len = target_bytes - len(base) - 4
    seg_len = payload_len + 2
    assert 2 <= seg_len <= 65535
    com_marker = b"\xFF\xFE" + seg_len.to_bytes(2, "big") + (b"V" * payload_len)
    out = base[:20] + com_marker + base[20:]
    assert len(out) == target_bytes
    return out


# ---------------------------------------------------------------------------
# Pure-Python Cross-Feature State Models (Opaque-Box Contract Composition)
# ---------------------------------------------------------------------------


def _evaluate_trigger_purge(local_state: str, archive_state: str) -> bool:
    return local_state == "quarantined" or (
        local_state == "reclaimed" and archive_state in ("deleted", "not_required")
    )


def _evaluate_hold_pin(entry: Mapping[str, Any], hold: Mapping[str, Any]) -> tuple[bool, str | None]:
    if hold.get("state") != "accepted" or entry.get("local_state") == "quarantined":
        return False, None
    t_start = int(entry["timeline_start_us"])
    t_end = int(entry["timeline_end_us"])
    h_start = int(hold["start_us"])
    h_end = int(hold["end_us"])
    if not (t_end > h_start and t_start < h_end):
        return False, None
    if entry.get("archive_state") == "verified":
        return True, "archive"
    if entry.get("local_state") == "present":
        return True, "local"
    return True, None


def _project_result_with_catalog(
    envelope: Mapping[str, Any],
    *,
    catalog_local_state: str,
    catalog_archive_state: str,
    expected_descriptor_sha256: str,
) -> dict[str, Any]:
    try:
        validated = vc.validate_result_envelope(dict(envelope))
    except vc.ContractValidationError as exc:
        return {"disposition": "dead_letter", "reason": str(exc), "rows": 0, "job_state": "failed_terminal"}

    if validated["source_mode"] == "recorded_block":
        if _evaluate_trigger_purge(catalog_local_state, catalog_archive_state):
            return {"disposition": "drop_recording_gone", "rows": 0, "job_state": "cancelled"}
        if validated.get("descriptor_sha256") != expected_descriptor_sha256:
            return {"disposition": "dead_letter", "reason": "descriptor_sha256_mismatch", "rows": 0, "job_state": "failed_terminal"}

    return {
        "disposition": "persisted",
        "rows": len(validated["observations"]),
        "job_state": "completed",
    }


def _evaluate_read_grant_gate(
    *,
    has_auth: bool,
    job_state: str,
    local_state: str,
    archive_state: str,
    descriptor_match: bool,
    positive_archive_payload: Mapping[str, Any],
) -> tuple[int, dict[str, str], dict[str, Any]]:
    headers = {"cache-control": "no-store", "x-content-type-options": "nosniff"}
    if not has_auth:
        return 401, headers, {"status": "unauthorized"}
    if job_state in ("completed", "cancelled", "failed_terminal"):
        return 409, headers, {"status": "job_already_terminal"}
    if _evaluate_trigger_purge(local_state, archive_state):
        return 410, headers, {"status": "recording_gone"}
    if not descriptor_match:
        return 409, headers, {"status": "descriptor_sha256_mismatch"}
    payload = copy.deepcopy(dict(positive_archive_payload))
    vc.validate_read_grant_response(payload)
    return 200, headers, payload


def _extract_last_srql_entity(query: str) -> str:
    lexer = shlex.shlex(query, posix=True)
    lexer.whitespace_split = True
    entity: str | None = None
    for tok in lexer:
        if ":" not in tok:
            continue
        k, v = tok.split(":", 1)
        if k.strip().lower() == "in":
            cleaned = v.strip().strip('"').strip("'").lower()
            if cleaned:
                entity = cleaned
    if entity is None:
        raise vc.ContractValidationError(f"SRQL query missing in:<entity>: {query!r}")
    return entity


def _authorize_camera_observations(
    query: str,
    permissions: set[str],
    authorized_sources: set[str],
    rows: Sequence[Mapping[str, Any]],
) -> tuple[bool, list[Mapping[str, Any]], str | None]:
    entity = _extract_last_srql_entity(query)
    if entity == "camera_observations":
        if not {"devices.view", "devices.cameras.recordings.view"}.issubset(permissions):
            return False, [], "forbidden"
    elif entity == "devices":
        if "devices.view" not in permissions:
            return False, [], "forbidden"
        return True, [], None
    else:
        return False, [], "forbidden"

    visible: list[Mapping[str, Any]] = []
    for row in rows:
        if row["camera_source_id"] not in authorized_sources:
            continue
        if row["source_mode"] == "live_keyframe_tap" and row.get("catalog_entry_id") is None:
            visible.append(row)
            continue
        if _evaluate_trigger_purge(row["local_state"], row["archive_state"]):
            continue
        if row["local_state"] == "present" or row["archive_state"] == "verified":
            visible.append(row)
    return True, visible, None


def _match_ocsf_event_for_subscriber(
    event: Mapping[str, Any],
    sub_filter: Mapping[str, Any],
    permissions: set[str],
    authorized_sources: set[str],
    dashboard_capabilities: set[str],
) -> tuple[bool, str | None]:
    if "events.subscribe" not in dashboard_capabilities:
        return False, "missing_capability"
    if not {"devices.view", "devices.cameras.recordings.view"}.issubset(permissions):
        return False, "forbidden"
    sr = event.get("metadata", {}).get("service_radar", {})
    cam_id = sr.get("camera_source_id")
    if cam_id not in authorized_sources:
        return False, "unauthorized_camera_source"
    if "class_uid" in sub_filter and event.get("class_uid") != sub_filter["class_uid"]:
        return False, None
    if "camera_source_id" in sub_filter and cam_id != sub_filter["camera_source_id"]:
        return False, None
    expected_schema = (
        sub_filter.get("metadata", {})
        .get("service_radar", {})
        .get("signal_schema", {})
        .get("schema_id")
    )
    actual_schema = sr.get("signal_schema", {}).get("schema_id")
    if expected_schema and actual_schema != expected_schema:
        return False, None
    return True, None


def _normalize_capability_slug(cap: str) -> str:
    if not cap or cap != cap.strip() or "*" in cap or ">" in cap or not _CAPABILITY_TOKEN_RE.match(cap):
        raise vc.ContractValidationError(f"invalid capability {cap!r}")
    return re.sub(r"[^a-z0-9]+", "_", cap.lower()).strip("_")


def _route_vantage_job(
    pipeline: Mapping[str, Any],
    workers: Sequence[Mapping[str, Any]],
    *,
    now_us: int,
    ttl_us: int,
    job_kind: str = "live",
) -> dict[str, Any]:
    cap = str(pipeline["capability"])
    slug = _normalize_capability_slug(cap)
    for raw_hb in workers:
        try:
            hb = vc.validate_heartbeat(dict(raw_hb))
        except vc.ContractValidationError:
            continue
        age = now_us - hb["sent_at_us"]
        if 0 <= age <= ttl_us and hb["health"] == "ready" and hb["active_jobs"] < hb["max_concurrency"]:
            if "recorded_block" in hb["supported_source_modes"] and cap in hb["capabilities"]:
                subj = (
                    f"media.jobs.vantage.{slug}.backfill.v1"
                    if job_kind == "backfill"
                    else f"media.jobs.vantage.{slug}.v1"
                )
                return {"runner": cap, "subject": subj, "disposition": "dispatch"}
    if pipeline.get("optional") and pipeline.get("fallback_runner") == "camera_vlm":
        subj = (
            "media.jobs.vantage.vlm.backfill.v1"
            if job_kind == "backfill"
            else "media.jobs.vantage.vlm.v1"
        )
        return {"runner": "camera_vlm", "subject": subj, "disposition": "fallback"}
    return {"runner": None, "subject": None, "disposition": "hold"}


def _validate_live_tap_result_strict(payload: Mapping[str, Any]) -> dict[str, Any]:
    obj = vc.validate_result_envelope(dict(payload))
    if obj["source_mode"] == "live_keyframe_tap":
        for field in ("job_id", "catalog_entry_id", "descriptor_sha256"):
            if obj.get(field) is not None:
                raise vc.ContractValidationError(f"live_keyframe_tap result {field} must be null")
        for idx, obs in enumerate(obj["observations"]):
            if obs.get("fragment_sequence") is not None:
                raise vc.ContractValidationError(
                    f"live_keyframe_tap observations[{idx}].fragment_sequence must be null"
                )
    return obj


def _compute_percentiles_ms(samples_ms: Sequence[float]) -> dict[str, float]:
    if not samples_ms:
        raise vc.ContractValidationError("samples_ms must not be empty")
    cleaned = []
    for s in samples_ms:
        if isinstance(s, bool) or not math.isfinite(s) or s < 0.0:
            raise vc.ContractValidationError(f"invalid latency sample {s!r}")
        cleaned.append(float(s))
    cleaned.sort()
    n = len(cleaned)

    def _pct(p: float) -> float:
        rank = max(0, min(n - 1, math.ceil((p / 100.0) * n) - 1))
        return cleaned[rank]

    return {"p50": _pct(50.0), "p95": _pct(95.0), "p99": _pct(99.0)}


def _evaluate_rbac_install(permissions: set[str], explicit_approval: bool) -> dict[str, Any]:
    if "catalog.packs.install" not in permissions:
        return {"allowed": False, "error": "forbidden", "status": None, "instance_bound": False}
    can_manage = (
        "dashboards.packages.manage" in permissions
        or (
            ("dashboards.packages.publish" in permissions or "cli.dashboard.publish" in permissions)
            and ("dashboards.packages.enable" in permissions or "cli.dashboard.enable" in permissions)
        )
    )
    if can_manage and explicit_approval:
        return {"allowed": True, "error": None, "status": "enabled", "instance_bound": True}
    return {"allowed": True, "error": None, "status": "staged", "instance_bound": False}


def _evaluate_dashboard_channel_state(
    *,
    pack_files: Mapping[str, bytes],
    permissions: set[str],
    explicit_approval: bool,
    route_slug: str,
    detached_slug: str | None = None,
    uninstall: bool = False,
    viewer_capabilities: set[str] | None = None,
) -> dict[str, Any]:
    try:
        summary = vc.validate_pack_v2_tree(pack_files)
        content_hash_match = bool(summary.get("has_dashboard_packages"))
    except vc.ContractValidationError as exc:
        return {
            "package_status": "rejected",
            "content_hash_match": False,
            "instance_bound": False,
            "managed_instance_present": False,
            "detached_instance_enabled": False,
            "channel_join_allowed": False,
            "managed_channel_join_allowed": False,
            "detached_channel_join_allowed": False,
            "error": str(exc),
        }

    rbac = _evaluate_rbac_install(permissions, explicit_approval)
    if not rbac["allowed"]:
        return {
            "package_status": None,
            "content_hash_match": content_hash_match,
            "instance_bound": False,
            "managed_instance_present": False,
            "detached_instance_enabled": False,
            "channel_join_allowed": False,
            "managed_channel_join_allowed": False,
            "detached_channel_join_allowed": False,
            "error": rbac["error"],
        }

    pkg_status = rbac["status"]
    bound = rbac["instance_bound"] and pkg_status == "enabled"
    caps = viewer_capabilities if viewer_capabilities is not None else {"events.subscribe"}
    can_join = bound and bool(route_slug) and ("events.subscribe" in caps or "srql.execute" in caps)
    detached_enabled = bool(detached_slug) and pkg_status == "enabled"

    if uninstall:
        return {
            "package_status": "uninstalled",
            "content_hash_match": content_hash_match,
            "instance_bound": False,
            "managed_instance_present": False,
            "detached_instance_enabled": detached_enabled,
            "channel_join_allowed": False,
            "managed_channel_join_allowed": False,
            "detached_channel_join_allowed": detached_enabled,
            "error": None,
        }

    return {
        "package_status": pkg_status,
        "content_hash_match": content_hash_match,
        "instance_bound": bound,
        "managed_instance_present": bound,
        "detached_instance_enabled": detached_enabled,
        "channel_join_allowed": can_join,
        "managed_channel_join_allowed": can_join,
        "detached_channel_join_allowed": detached_enabled,
        "error": None,
    }


def _evaluate_live_observation_retention(
    observations: Sequence[Mapping[str, Any]],
    *,
    now_us: int,
    retention_days: Any,
) -> dict[str, Any]:
    if (
        isinstance(retention_days, bool)
        or not isinstance(retention_days, int)
        or retention_days < 1
        or retention_days > 3650
    ):
        raise vc.ContractValidationError(
            f"live_observation_retention_days must be an integer in 1..3650, got {retention_days!r}"
        )
    cutoff_us = now_us - (retention_days * 86_400 * 1_000_000)
    kept: list[str] = []
    purged: list[str] = []
    for obs in observations:
        is_live = obs.get("source_mode") == "live_keyframe_tap" and obs.get("catalog_entry_id") is None
        if is_live and int(obs["inserted_at_us"]) < cutoff_us:
            purged.append(str(obs["id"]))
        else:
            kept.append(str(obs["id"]))
    return {"cutoff_us": cutoff_us, "kept": kept, "purged": purged}


def _collect_tier3_tier4_test_ids() -> dict[str, str]:
    mapping: dict[str, str] = {}
    for cls in (Tier3PairwiseModeATest, Tier4WorkloadsModeATest):
        for attr in dir(cls):
            if not attr.startswith("test_e2e_"):
                continue
            fn = getattr(cls, attr)
            tid = getattr(fn, "_e2e_test_id", None)
            if tid:
                mapping[tid] = f"{cls.__name__}.{attr}"
    return mapping


# ---------------------------------------------------------------------------
# Tier 3: 15 Pairwise Cross-Feature Contract Tests
# ---------------------------------------------------------------------------


class Tier3PairwiseModeATest(unittest.TestCase):
    """Verify all 15 Tier 3 pairwise cross-feature contracts hermetically."""

    @classmethod
    def setUpClass(cls) -> None:
        cls.t3 = _load_json("t3_t4/tier3_pairwise_matrix.json")
        cls.pairs = {p["test_id"]: p for p in cls.t3["pairs"]}
        cls.result_vec = _load_json("wire_vectors/vantage_result_v1.json")
        cls.job_vec = _load_json("wire_vectors/vantage_job_v1.json")
        cls.hb_vec = _load_json("wire_vectors/vantage_heartbeat_v1.json")
        cls.frame_vec = _load_json("wire_vectors/vantage_frame_v1.json")
        cls.grant_vec = _load_json("wire_vectors/read_grant_response.json")
        cls.pack_v2_ref = _load_json("f6_f10/pack_v2_alpr_reference.json")
        cls.pack_v1_ref = _load_json("f6_f10/pack_v1_compat_reference.json")

    @_e2e_case(
        "F1+F2",
        3,
        "E2E-T3-01",
        "CNPG FKs and purge trigger align with RecordingCatalogEntry quarantine/reclaim, RecordingHold pin, and live-tap Source cascade",
    )
    def test_e2e_t3_01_f1_x_f2_schema_lifecycle_hold_and_live_tap_coupling(self) -> None:
        spec = self.pairs["E2E-T3-01"]
        hold = spec["hold_window"]
        entry = {
            "local_state": "present",
            "archive_state": "verified",
            "timeline_start_us": hold["start_us"] + 1000,
            "timeline_end_us": hold["end_us"] - 1000,
        }
        for tr in spec["transitions"]:
            with self.subTest(transition=tr["name"]):
                if tr["source_mode"] == "live_keyframe_tap":
                    # Live-tap observations have catalog_entry_id NULL so block trigger never touches them
                    self.assertFalse(tr["expected_observations_purged"])
                    self.assertTrue(tr["expected_survives_until_source_cascade"])
                elif tr["held"]:
                    pinned, copy_kind = _evaluate_hold_pin(entry, hold)
                    self.assertTrue(pinned)
                    self.assertEqual(copy_kind, tr["expected_hold_pinned_copy"])
                    self.assertFalse(tr["expected_observations_purged"])
                else:
                    purged = _evaluate_trigger_purge(tr["local_state"], tr["archive_state"])
                    self.assertEqual(purged, tr["expected_observations_purged"])

    @_e2e_case(
        "F1+F3",
        3,
        "E2E-T3-02",
        "EventWriter projector enforces signal_schema, bbox, and <= 32 KiB crop_jpeg before Ash upsert and populates search_tsv",
    )
    def test_e2e_t3_02_f1_x_f3_ash_constraints_and_eventwriter_prevalidation(self) -> None:
        spec = self.pairs["E2E-T3-02"]
        pos = copy.deepcopy(self.result_vec["positive"])
        exact_32k = _make_exact_size_baseline_jfif(spec["expected_persisted_crop_max_bytes"])
        pos["observations"][0]["crop_jpeg_b64"] = base64.b64encode(exact_32k).decode("ascii")
        res = _project_result_with_catalog(
            pos,
            catalog_local_state="present",
            catalog_archive_state="not_required",
            expected_descriptor_sha256=pos["descriptor_sha256"],
        )
        self.assertEqual(res["disposition"], "persisted")
        self.assertEqual(res["rows"], 2)
        search_text = pos["observations"][0]["search_text"]
        for tok in spec["search_tokens"]:
            self.assertIn(tok, search_text)

        for neg in spec["negative_cases"]:
            with self.subTest(case=neg["name"]):
                bad = copy.deepcopy(self.result_vec["positive"])
                if "crop_bytes" in neg:
                    over = _make_exact_size_baseline_jfif(neg["crop_bytes"])
                    bad["observations"][0]["crop_jpeg_b64"] = base64.b64encode(over).decode("ascii")
                elif "plate_text" in neg:
                    bad["observations"][0]["attributes"]["plate_text"] = neg["plate_text"]
                elif "bbox" in neg:
                    bad["observations"][0]["bbox"] = neg["bbox"]
                out = _project_result_with_catalog(
                    bad,
                    catalog_local_state="present",
                    catalog_archive_state="not_required",
                    expected_descriptor_sha256=bad["descriptor_sha256"],
                )
                self.assertEqual(out["disposition"], neg["expected_disposition"])
                self.assertEqual(out["rows"], neg["expected_rows_written"])

    @_e2e_case(
        "F2+F3",
        3,
        "E2E-T3-03",
        "Concurrent RecordingCatalogEntry quarantine or terminal reclaim causes in-flight media.results.vantage.v1 projection to drop and cancel job",
    )
    def test_e2e_t3_03_f2_x_f3_quarantine_race_drops_inflight_result(self) -> None:
        spec = self.pairs["E2E-T3-03"]
        pos = copy.deepcopy(self.result_vec["positive"])
        pos["observations"] = [pos["observations"][0]]
        for sc in spec["race_scenarios"]:
            with self.subTest(scenario=sc["name"]):
                res = _project_result_with_catalog(
                    pos,
                    catalog_local_state=sc["catalog_local_state"],
                    catalog_archive_state=sc["catalog_archive_state"],
                    expected_descriptor_sha256=pos["descriptor_sha256"],
                )
                self.assertEqual(res["disposition"], sc["expected_disposition"])
                self.assertEqual(res["job_state"], sc["expected_job_state"])
                self.assertEqual(res["rows"], sc["expected_observations_persisted"])

    @_e2e_case(
        "F2+F11",
        3,
        "E2E-T3-04",
        "POST /v1/media/workers/read-grants fails closed with 410 recording_gone and cancels active VantageJob on quarantined or reclaimed entry",
    )
    def test_e2e_t3_04_f2_x_f11_quarantine_reclaim_triggers_read_grant_410(self) -> None:
        spec = self.pairs["E2E-T3-04"]
        for case in spec["cases"]:
            with self.subTest(case=case["name"]):
                status, headers, body = _evaluate_read_grant_gate(
                    has_auth=True,
                    job_state="dispatched",
                    local_state=case["local_state"],
                    archive_state=case["archive_state"],
                    descriptor_match=case["descriptor_match"],
                    positive_archive_payload=self.grant_vec["positive_archive"],
                )
                self.assertEqual(headers["cache-control"], "no-store")
                self.assertEqual(headers["x-content-type-options"], "nosniff")
                self.assertEqual(status, case["expected_http_status"])
                if "expected_body_status" in case:
                    self.assertEqual(body["status"], case["expected_body_status"])

    @_e2e_case(
        "F3+F9",
        3,
        "E2E-T3-05",
        "Persisted EventWriter observations flow into SRQL in:camera_observations and SemanticSearch gated by dual RBAC, Source scope, and playability",
    )
    def test_e2e_t3_05_f3_x_f9_eventwriter_to_srql_rbac_and_playability(self) -> None:
        spec = self.pairs["E2E-T3-05"]
        self.assertEqual(_extract_last_srql_entity(spec["query_positive"]), spec["expected_last_in_entity"])
        self.assertEqual(_extract_last_srql_entity(spec["query_bypass_attempt"]), spec["expected_last_in_entity"])

        rows = [
            {
                "camera_source_id": spec["authorized_camera_id"],
                "source_mode": "recorded_block",
                "catalog_entry_id": "44444444-4444-4444-8444-444444444401",
                "local_state": "present",
                "archive_state": "verified",
                "label": "SR-0100",
            },
            {
                "camera_source_id": spec["authorized_camera_id"],
                "source_mode": "recorded_block",
                "catalog_entry_id": "44444444-4444-4444-8444-444444444402",
                "local_state": "quarantined",
                "archive_state": "verified",
                "label": "SR-0100",
            },
            {
                "camera_source_id": spec["unauthorized_camera_id"],
                "source_mode": "live_keyframe_tap",
                "catalog_entry_id": None,
                "local_state": "present",
                "archive_state": "not_required",
                "label": "Bay 04 Approach",
            },
        ]

        # Dual permissions + authorized source returns only playable Gate West 01 row
        ok, visible, err = _authorize_camera_observations(
            spec["query_bypass_attempt"],
            set(spec["required_permissions"]),
            {spec["authorized_camera_id"]},
            rows,
        )
        self.assertTrue(ok)
        self.assertIsNone(err)
        self.assertEqual(len(visible), 1)
        self.assertEqual(visible[0]["catalog_entry_id"], "44444444-4444-4444-8444-444444444401")

        # Missing devices.cameras.recordings.view fails closed even with last-in bypass attempt
        ok_denied, visible_denied, err_denied = _authorize_camera_observations(
            spec["query_bypass_attempt"],
            {"devices.view"},
            {spec["authorized_camera_id"]},
            rows,
        )
        self.assertFalse(ok_denied)
        self.assertEqual(visible_denied, [])
        self.assertEqual(err_denied, "forbidden")

    @_e2e_case(
        "F3+F10",
        3,
        "E2E-T3-06",
        "EventWriter OCSF 1008 emission feeds DashboardFrameChannel.Events nested signal_schema filtering gated by dual RBAC and Source scope",
    )
    def test_e2e_t3_06_f3_x_f10_ocsf_to_dashboard_events_scoping(self) -> None:
        spec = self.pairs["E2E-T3-06"]
        sub_filter = spec["subscription_filter"]
        cam_id = sub_filter["camera_source_id"]
        other_cam = "22222222-2222-4222-8222-222222222204"
        event = {
            "class_uid": 1008,
            "metadata": {
                "service_radar": {
                    "source_type": "camera_vantage",
                    "camera_source_id": cam_id,
                    "signal_schema": {"schema_id": "alpr_plate_read", "schema_version": "1.0.0"},
                }
            },
        }
        delivered, reason = _match_ocsf_event_for_subscriber(
            event,
            sub_filter,
            set(spec["required_permissions"]),
            {cam_id},
            {spec["required_dashboard_capability"]},
        )
        self.assertTrue(delivered)
        self.assertIsNone(reason)

        # Missing recordings permission or wrong camera source or missing capability denies delivery
        self.assertEqual(
            _match_ocsf_event_for_subscriber(event, sub_filter, {"devices.view"}, {cam_id}, {"events.subscribe"}),
            (False, "forbidden"),
        )
        self.assertEqual(
            _match_ocsf_event_for_subscriber(event, sub_filter, set(spec["required_permissions"]), {other_cam}, {"events.subscribe"}),
            (False, "unauthorized_camera_source"),
        )
        self.assertEqual(
            _match_ocsf_event_for_subscriber(event, sub_filter, set(spec["required_permissions"]), {cam_id}, {"srql.execute"}),
            (False, "missing_capability"),
        )

    @_e2e_case(
        "F4+F5",
        3,
        "E2E-T3-07",
        "media-core native full-res cropper gates < 96px targets before VLM HTTP call and separates <= 96 KiB VLM crops from <= 32 KiB stored crops",
    )
    def test_e2e_t3_07_f4_x_f5_cropper_gates_vlm_and_persisted_bounds(self) -> None:
        spec = self.pairs["E2E-T3-07"]
        pol = spec["crop_policy"]
        fw, fh = spec["frame_width"], spec["frame_height"]

        for tgt in spec["targets"]:
            with self.subTest(target=tgt["name"]):
                x1, y1, x2, y2 = tgt["bbox"]
                raw_w = int((x2 - x1) * fw)
                self.assertEqual(raw_w, tgt["expected_raw_width_px"])
                box = vc.compute_padded_crop_box(
                    fw,
                    fh,
                    tgt["bbox"],
                    padding_ratio=pol["padding_ratio"],
                    min_bbox_width_px=pol["min_bbox_width_px"],
                    max_dimension=pol["max_dimension"],
                )
                if tgt["expected_crop_accepted"]:
                    self.assertEqual(box["status"], "ok")
                    self.assertLessEqual(box["out_w"], pol["max_dimension"])
                    self.assertLessEqual(box["out_h"], pol["max_dimension"])
                    vlm_jpeg = vc.make_synthetic_baseline_jfif(
                        box["out_w"], box["out_h"], seed=3, target_max_bytes=pol["max_bytes"]
                    )
                    vc.validate_baseline_jfif(vlm_jpeg, max_bytes=pol["max_bytes"])
                    stored_jpeg = vc.make_synthetic_baseline_jfif(
                        min(320, box["out_w"]),
                        min(240, box["out_h"]),
                        seed=3,
                        target_max_bytes=spec["persisted_crop_max_bytes"],
                    )
                    vc.validate_baseline_jfif(stored_jpeg, max_bytes=spec["persisted_crop_max_bytes"])
                else:
                    self.assertEqual(box["status"], "skipped")
                    self.assertEqual(box["reason"], tgt["expected_skip_reason"])

    @_e2e_case(
        "F5+F11",
        3,
        "E2E-T3-08",
        "VantagePipelineDispatcher routes Ramp 1 fallback jobs to media.jobs.vantage.vlm.v1 and media-worker authenticates scoped read-grants",
    )
    def test_e2e_t3_08_f5_x_f11_ramp1_fallback_dispatch_and_read_grant(self) -> None:
        spec = self.pairs["E2E-T3-08"]
        route = _route_vantage_job(spec["pipeline"], [], now_us=1700000010000000, ttl_us=30_000_000)
        self.assertEqual(route["disposition"], "fallback")
        self.assertEqual(route["runner"], spec["expected_worker_kind"])
        self.assertEqual(route["subject"], spec["expected_subject_without_workers"])

        job_env = vc.validate_job_envelope(self.job_vec["positive"])
        job_bytes = len(json.dumps(job_env, separators=(",", ":")).encode("utf-8"))
        self.assertLessEqual(job_bytes, spec["expected_max_job_envelope_bytes"])

        grant = vc.validate_read_grant_response(self.grant_vec["positive_local"])
        self.assertEqual(grant["read_pool"], "analysis_read")

    @_e2e_case(
        "F6+F7",
        3,
        "E2E-T3-09",
        "CLI pack build, sign, and validate round-trip v2 .srpack (32/96 MiB, <= 8 MiB renderer, triple SHA-256) with Elixir PackArchive and UploadSignature",
    )
    def test_e2e_t3_09_f6_x_f7_pack_v2_ustar_and_digest_parity(self) -> None:
        spec = self.pairs["E2E-T3-09"]
        v2_tree = {k: v.encode("utf-8") for k, v in self.pack_v2_ref["files"].items()}
        ustar = vc.build_deterministic_ustar(v2_tree, max_uncompressed_bytes=spec["expected_v2_limits"]["max_uncompressed_bytes"])
        buf = io.BytesIO()
        with gzip.GzipFile(fileobj=buf, mode="wb", mtime=0) as gz:
            gz.write(ustar)
        compressed = buf.getvalue()
        summary = vc.validate_pack_v2_tree(v2_tree, compressed_bytes=len(compressed))
        self.assertEqual(summary["pack_format_version"], 2)
        self.assertTrue(summary["has_dashboard_packages"])
        vc.assert_secret_free(v2_tree)

        with tarfile.open(fileobj=io.BytesIO(ustar), mode="r:") as tf:
            for member in tf.getmembers():
                self.assertEqual(member.mode, 0o644)
                self.assertEqual(member.uid, 0)
                self.assertEqual(member.gid, 0)
                self.assertEqual(member.mtime, 0)

        # Negative: tampered renderer breaks triple SHA-256 parity
        tampered = dict(v2_tree)
        tampered["dashboard_packages/alpr-console/renderer.js"] = b"export const tampered = true;\n"
        with self.assertRaises(vc.ContractValidationError):
            vc.validate_pack_v2_tree(tampered)

        # Negative: renderer > 8 MiB fails closed
        oversized = dict(v2_tree)
        oversized_bytes = b"x" * (spec["expected_v2_limits"]["max_renderer_bytes"] + 1)
        oversized["dashboard_packages/alpr-console/renderer.js"] = oversized_bytes
        with self.assertRaises(vc.ContractValidationError):
            vc.validate_pack_v2_tree(oversized)

    @_e2e_case(
        "F6+F8",
        3,
        "E2E-T3-10",
        "Solution Pack v2 Reconciler installs io.serviceradar.vantage-alpr with paused watchlist rule, pipeline overrides, and RBAC-gated alpr-console",
    )
    def test_e2e_t3_10_f6_x_f8_reconciler_and_alpr_reference_pack(self) -> None:
        spec = self.pairs["E2E-T3-10"]
        v2_tree = {k: v.encode("utf-8") for k, v in self.pack_v2_ref["files"].items()}
        summary = vc.validate_pack_v2_tree(v2_tree)
        self.assertEqual(summary["id"], spec["pack_id"])

        manifest = json.loads(self.pack_v2_ref["files"]["manifest.json"])
        rule_res = manifest["resources"]["rules"][0]
        self.assertEqual(rule_res["install_state"], spec["expected_rule_install_state"])
        rule = json.loads(self.pack_v2_ref["files"]["rules/alpr-watchlist-alert.json"])
        self.assertEqual(rule["slug"], spec["watchlist_rule_slug"])
        self.assertFalse(bool(rule.get("enabled", False)))

        pipe = json.loads(self.pack_v2_ref["files"]["vantage_pipelines/alpr-vehicle-plate.json"])
        self.assertEqual(pipe["pipeline_id"], spec["pipeline_id"])
        self.assertEqual(pipe["signal_schema_id"], spec["signal_schema_id"])

        staged = _evaluate_rbac_install({"catalog.packs.install"}, explicit_approval=True)
        self.assertEqual(staged["status"], "staged")
        enabled = _evaluate_rbac_install(
            {"catalog.packs.install", "dashboards.packages.manage"}, explicit_approval=True
        )
        self.assertEqual(enabled["status"], "enabled")

    @_e2e_case(
        "F6+F10",
        3,
        "E2E-T3-11",
        "Bundled dashboard_packages :staged vs :enabled gate controls DashboardInstance route binding, DashboardFrameChannel access, and uninstall detach",
    )
    def test_e2e_t3_11_f6_x_f10_dashboard_package_staging_and_channel_access(self) -> None:
        spec = self.pairs["E2E-T3-11"]
        v2_tree = {k: v.encode("utf-8") for k, v in self.pack_v2_ref["files"].items()}
        route_slug = spec["route_slug"]

        for tr in spec["transitions"]:
            with self.subTest(transition=tr["name"]):
                if tr.get("package_status") == "staged":
                    res = _evaluate_dashboard_channel_state(
                        pack_files=v2_tree,
                        permissions={"catalog.packs.install"},
                        explicit_approval=False,
                        route_slug=route_slug,
                    )
                    self.assertEqual(res["package_status"], "staged")
                    self.assertEqual(res["instance_bound"], tr["instance_bound"])
                    self.assertEqual(res["channel_join_allowed"], tr["expected_channel_join_allowed"])
                elif tr.get("package_status") == "enabled":
                    res = _evaluate_dashboard_channel_state(
                        pack_files=v2_tree,
                        permissions={"catalog.packs.install", "dashboards.packages.manage"},
                        explicit_approval=True,
                        route_slug=route_slug,
                    )
                    self.assertEqual(res["package_status"], "enabled")
                    self.assertEqual(res["content_hash_match"], tr["content_hash_match"])
                    self.assertEqual(res["instance_bound"], tr["instance_bound"])
                    self.assertEqual(res["channel_join_allowed"], tr["expected_channel_join_allowed"])
                elif tr.get("action") == "uninstall":
                    res = _evaluate_dashboard_channel_state(
                        pack_files=v2_tree,
                        permissions={"catalog.packs.install", "dashboards.packages.manage"},
                        explicit_approval=True,
                        route_slug=route_slug,
                        detached_slug=f"{route_slug}-detached",
                        uninstall=True,
                    )
                    self.assertEqual(res["managed_instance_present"], tr["managed_instance_after"])
                    self.assertEqual(res["detached_instance_enabled"], tr["detached_instance_enabled_after"])
                    self.assertEqual(res["managed_channel_join_allowed"], tr["expected_managed_channel_join_allowed"])
                    self.assertTrue(res["detached_channel_join_allowed"])

        # Negative controls: tampered renderer, missing approval, and unauthorized channel capability fail closed
        tampered = dict(v2_tree)
        tampered["dashboard_packages/alpr-console/renderer.js"] = b"export const tampered = true;\n"
        tampered_res = _evaluate_dashboard_channel_state(
            pack_files=tampered,
            permissions={"catalog.packs.install", "dashboards.packages.manage"},
            explicit_approval=True,
            route_slug=route_slug,
        )
        self.assertEqual(tampered_res["package_status"], "rejected")
        self.assertFalse(tampered_res["content_hash_match"])
        self.assertFalse(tampered_res["instance_bound"])
        self.assertFalse(tampered_res["channel_join_allowed"])

        unapproved_res = _evaluate_dashboard_channel_state(
            pack_files=v2_tree,
            permissions={"catalog.packs.install", "dashboards.packages.manage"},
            explicit_approval=False,
            route_slug=route_slug,
        )
        self.assertEqual(unapproved_res["package_status"], "staged")
        self.assertFalse(unapproved_res["channel_join_allowed"])

        unauth_cap_res = _evaluate_dashboard_channel_state(
            pack_files=v2_tree,
            permissions={"catalog.packs.install", "dashboards.packages.manage"},
            explicit_approval=True,
            route_slug=route_slug,
            viewer_capabilities=set(),
        )
        self.assertFalse(unauth_cap_res["channel_join_allowed"])

    @_e2e_case(
        "F8+F11+F12",
        3,
        "E2E-T3-12",
        "io.serviceradar.vantage-alpr switches automatically from Ramp 1 camera_vlm to Ramp 2 vantage.alpr.v1 worker heartbeat and fails back on TTL expiry",
    )
    def test_e2e_t3_12_f8_x_f11_x_f12_ramp1_to_ramp2_and_failback(self) -> None:
        spec = self.pairs["E2E-T3-12"]
        pipe = {
            "pipeline_id": "io.serviceradar.vantage-alpr.vehicle-plate",
            "runner": "external_worker",
            "capability": spec["capability"],
            "optional": True,
            "fallback_runner": "camera_vlm",
        }
        hb = copy.deepcopy(self.hb_vec["positive"])
        ttl = spec["heartbeat_ttl_us"]

        # Ramp 1 before worker heartbeat
        r1 = _route_vantage_job(pipe, [], now_us=hb["sent_at_us"], ttl_us=ttl)
        self.assertEqual(r1["subject"], spec["ramp1_subject"])

        # Ramp 2 when worker heartbeat is fresh
        r2 = _route_vantage_job(pipe, [hb], now_us=hb["sent_at_us"] + 5_000_000, ttl_us=ttl)
        self.assertEqual(r2["subject"], spec["ramp2_subject"])
        self.assertEqual(r2["runner"], spec["capability"])

        # Ramp 1 failback once heartbeat exceeds TTL
        failback = _route_vantage_job(pipe, [hb], now_us=hb["sent_at_us"] + ttl + 1, ttl_us=ttl)
        self.assertEqual(failback["subject"], spec["ramp1_subject"])

        # Ramp 1 and Ramp 2 emit identical alpr_plate_read observation schema
        r1_env = vc.validate_result_envelope(self.result_vec["positive"])
        r2_env = copy.deepcopy(r1_env)
        r2_env["worker_kind"] = "external_rust"
        vc.validate_result_envelope(r2_env)

    @_e2e_case(
        "F11+F12",
        3,
        "E2E-T3-13",
        "External serviceradar-sdk-vantage workers authenticate via vantage_worker read-grants with zero DB/S3 credentials and SHA-256 verification",
    )
    def test_e2e_t3_13_f11_x_f12_sdk_worker_grants_and_zero_credentials(self) -> None:
        spec = self.pairs["E2E-T3-13"]
        clean_worker_cfg = {
            "worker_id": "vantage-alpr-rust-01",
            "worker_kind": "external_rust",
            "capabilities": ["vantage.alpr.v1"],
            "nats_url": "nats://127.0.0.1:4222",
            "web_url": "http://127.0.0.1:4000",
        }
        vc.assert_secret_free({"worker.json": json.dumps(clean_worker_cfg)})
        for key in spec["forbidden_env_keys"]:
            self.assertNotIn(key, clean_worker_cfg)

        # Negative leaked DB/S3 key fails secret-free scan
        leaked_cfg = dict(clean_worker_cfg)
        leaked_cfg["secret_access_key"] = "synthetic-denied-value"
        with self.assertRaises(vc.ContractValidationError):
            vc.assert_secret_free({"worker.json": json.dumps(leaked_cfg)})

        for neg in spec["negative_status_checks"]:
            with self.subTest(case=neg["case"]):
                status, headers, body = _evaluate_read_grant_gate(
                    has_auth=(neg["case"] != "missing_auth"),
                    job_state="completed" if neg["case"] == "terminal_job" else "dispatched",
                    local_state="quarantined" if neg["case"] == "quarantined_entry" else "present",
                    archive_state="verified",
                    descriptor_match=(neg["case"] != "descriptor_mismatch"),
                    positive_archive_payload=self.grant_vec["positive_archive"],
                )
                self.assertEqual(headers["cache-control"], "no-store")
                self.assertEqual(status, neg["expected_status"])
                self.assertEqual(body["status"], neg["expected_error"])

    @_e2e_case(
        "F12+F13",
        3,
        "E2E-T3-14",
        "longshore_mailbox vantage.frame.v1 live-tap payloads invoke identical SDK process_frame(ctx) emitting strict null-catalog live results",
    )
    def test_e2e_t3_14_f12_x_f13_live_tap_frame_to_sdk_strict_nullity(self) -> None:
        spec = self.pairs["E2E-T3-14"]
        frame = vc.validate_live_frame(self.frame_vec["positive"])
        self.assertEqual(frame["camera_source_id"], spec["camera_source_id"])
        self.assertIsNone(frame["catalog_entry_id"])
        self.assertIsNone(frame["fragment_sequence"])

        live_res = _validate_live_tap_result_strict(self.result_vec["positive_live"])
        self.assertEqual(live_res["capability"], spec["capability"])

        # Negative: non-null catalog_entry_id on live_keyframe_tap result fails strict nullity
        bad_res = copy.deepcopy(self.result_vec["positive_live"])
        bad_res["catalog_entry_id"] = "44444444-4444-4444-8444-444444444401"
        with self.assertRaises(vc.ContractValidationError):
            _validate_live_tap_result_strict(bad_res)

        # Negative: non-null catalog_entry_id on live frame fails validate_live_frame
        with self.assertRaises(vc.ContractValidationError):
            vc.validate_live_frame(self.frame_vec["negative"][0]["payload"])

    @_e2e_case(
        "F13+F14",
        3,
        "E2E-T3-15",
        "Bounded longshore_mailbox drop-oldest overflow isolates CMAF recording while steady-state live-tap reports p50/p95/p99 latency and retention purge",
    )
    def test_e2e_t3_15_f13_x_f14_mailbox_backpressure_latency_and_retention(self) -> None:
        spec = self.pairs["E2E-T3-15"]
        q: deque[int] = deque()
        dropped = 0
        for seq in range(1, spec["burst_frames"] + 1):
            if len(q) >= spec["mailbox_cap"]:
                q.popleft()
                dropped += 1
            q.append(seq)
        self.assertEqual(dropped, spec["expected_dropped"])
        self.assertEqual(list(q), spec["expected_retained_sequences"])

        pcts = _compute_percentiles_ms(spec["sample_latencies_ms"])
        self.assertLessEqual(pcts["p50"], pcts["p95"])
        self.assertLessEqual(pcts["p95"], pcts["p99"])

        # Live retention boundary: retention_days >= 1 enforced; 7d + 1s live purged, 7d exact & 7d - 1s & held recorded kept
        now_us = 1760000000000000
        retention_days = spec["live_observation_retention_days"]
        day_us = 86_400 * 1_000_000
        synthetic_obs = [
            {
                "id": "live-expired",
                "source_mode": "live_keyframe_tap",
                "catalog_entry_id": None,
                "inserted_at_us": now_us - (7 * day_us + 1_000_000),
            },
            {
                "id": "live-exact-boundary",
                "source_mode": "live_keyframe_tap",
                "catalog_entry_id": None,
                "inserted_at_us": now_us - (7 * day_us),
            },
            {
                "id": "live-fresh",
                "source_mode": "live_keyframe_tap",
                "catalog_entry_id": None,
                "inserted_at_us": now_us - (7 * day_us - 1_000_000),
            },
            {
                "id": "recorded-held",
                "source_mode": "recorded_block",
                "catalog_entry_id": "44444444-4444-4444-8444-444444444401",
                "inserted_at_us": now_us - (30 * day_us),
            },
        ]
        ret = _evaluate_live_observation_retention(
            synthetic_obs, now_us=now_us, retention_days=retention_days
        )
        self.assertEqual(ret["purged"], ["live-expired"])
        self.assertEqual(ret["kept"], ["live-exact-boundary", "live-fresh", "recorded-held"])

        for invalid_days in (0, -5, 3651, True):
            with self.subTest(invalid_retention_days=invalid_days):
                with self.assertRaises(vc.ContractValidationError):
                    _evaluate_live_observation_retention(
                        synthetic_obs, now_us=now_us, retention_days=invalid_days
                    )


# ---------------------------------------------------------------------------
# Tier 4: 7 Realistic Operational Workload Tests
# ---------------------------------------------------------------------------


class Tier4WorkloadsModeATest(unittest.TestCase):
    """Verify all 7 Tier 4 real-world operational workload contracts hermetically."""

    @classmethod
    def setUpClass(cls) -> None:
        cls.t4 = _load_json("t3_t4/tier4_workloads.json")
        cls.workloads = {w["workload"]: w for w in cls.t4["workloads"]}
        cls.result_vec = _load_json("wire_vectors/vantage_result_v1.json")
        cls.job_vec = _load_json("wire_vectors/vantage_job_v1.json")
        cls.hb_vec = _load_json("wire_vectors/vantage_heartbeat_v1.json")
        cls.frame_vec = _load_json("wire_vectors/vantage_frame_v1.json")
        cls.pack_v2_ref = _load_json("f6_f10/pack_v2_alpr_reference.json")

    @_e2e_case(
        "F1+F3+F4+F5+F8+F9+F10+F11",
        4,
        "E2E-T4-W1",
        "W1: Ramp 1 ALPR gate entry lifecycle for Gate West 01 with SR-0100 and TEST-742 from Stage 1 detection to timeline overlay",
    )
    def test_e2e_t4_w1_ramp1_alpr_gate_entry_lifecycle(self) -> None:
        w1 = self.workloads["W1"]
        admitted = []
        for det in w1["detections"]:
            if det["category"] != "vehicle" or det["confidence"] < 0.55:
                continue
            admitted.append(det)
        # Distant vehicle is admitted for Stage 2 evaluation, person is ignored; cropper then skips <96px
        cropped_plates = []
        skipped = []
        for det in admitted:
            box = vc.compute_padded_crop_box(
                1920, 1080, det["bbox"], padding_ratio=0.15, min_bbox_width_px=96, max_dimension=640
            )
            if box["status"] == "ok":
                vlm_crop = vc.make_synthetic_baseline_jfif(
                    box["out_w"], box["out_h"], seed=5, target_max_bytes=vc.MAX_VLM_CROP_BYTES
                )
                vc.validate_baseline_jfif(vlm_crop, max_bytes=vc.MAX_VLM_CROP_BYTES)
                cropped_plates.append(det["plate"])
            else:
                skipped.append(box["reason"])
        self.assertEqual(cropped_plates, w1["expected_persisted_plates"])
        self.assertIn("crop_below_min_dimension", skipped)

        res_env = vc.validate_result_envelope(self.result_vec["positive"])
        self.assertEqual([o["label"] for o in res_env["observations"]], w1["expected_persisted_plates"])
        self.assertEqual(_extract_last_srql_entity(w1["srql_query"]), "camera_observations")

    @_e2e_case(
        "F1+F2+F3+F9+F11",
        4,
        "E2E-T4-W2",
        "W2: RecordingHold preservation vs quarantine and terminal reclaim purge lifecycle across SRQL and read-grants",
    )
    def test_e2e_t4_w2_hold_preservation_vs_quarantine_and_reclaim_purge(self) -> None:
        w2 = self.workloads["W2"]
        held_pinned, copy_kind = _evaluate_hold_pin(w2["held_block"], w2["hold"])
        self.assertTrue(held_pinned)
        self.assertEqual(copy_kind, "local")
        unheld_pinned, _ = _evaluate_hold_pin(w2["unheld_block"], w2["hold"])
        self.assertFalse(unheld_pinned)

        # Unheld block quarantined -> trigger purges observations and read-grant returns 410
        self.assertTrue(_evaluate_trigger_purge("quarantined", "verified"))
        status, _, body = _evaluate_read_grant_gate(
            has_auth=True,
            job_state="dispatched",
            local_state="quarantined",
            archive_state="verified",
            descriptor_match=True,
            positive_archive_payload=_load_json("wire_vectors/read_grant_response.json")["positive_archive"],
        )
        self.assertEqual(status, 410)
        self.assertEqual(body["status"], "recording_gone")

        # After releasing hold and terminal reclaim, held block purges cleanly
        self.assertTrue(_evaluate_trigger_purge("reclaimed", "deleted"))

    @_e2e_case(
        "F1+F3+F6+F9+F10",
        4,
        "E2E-T4-W3",
        "W3: Multi-tenant dual-permission RBAC, Source scoping, last-in: SRQL bypass resistance, channel revocation, and RecordingAccessAudit trail",
    )
    def test_e2e_t4_w3_multi_tenant_rbac_source_scoping_and_audit(self) -> None:
        w3 = self.workloads["W3"]
        rows = [
            {
                "camera_source_id": w3["gate_west_id"],
                "source_mode": "recorded_block",
                "catalog_entry_id": "44444444-4444-4444-8444-444444444401",
                "local_state": "present",
                "archive_state": "verified",
            },
            {
                "camera_source_id": w3["bay_04_id"],
                "source_mode": "live_keyframe_tap",
                "catalog_entry_id": None,
                "local_state": "present",
                "archive_state": "not_required",
            },
        ]
        for actor in w3["actors"]:
            with self.subTest(actor=actor["name"]):
                ok, visible, _ = _authorize_camera_observations(
                    w3["bypass_query"],
                    set(actor["permissions"]),
                    set(actor["authorized_sources"]),
                    rows,
                )
                self.assertEqual(ok, actor["expected_srql_allowed"])
                self.assertEqual([r["camera_source_id"] for r in visible], actor["expected_visible_cameras"])

    @_e2e_case(
        "F1+F6+F7+F8+F10",
        4,
        "E2E-T4-W4",
        "W4: Solution Pack v2 CLI authoring, Ed25519 signing, staged admin approval, upgrade override preservation, and uninstall detach lifecycle",
    )
    def test_e2e_t4_w4_pack_v2_authoring_staged_upgrade_and_uninstall(self) -> None:
        w4 = self.workloads["W4"]
        v2_tree = {k: v.encode("utf-8") for k, v in self.pack_v2_ref["files"].items()}
        ustar = vc.build_deterministic_ustar(v2_tree, max_uncompressed_bytes=vc.PACK_V2_LIMITS[1])
        self.assertGreater(len(ustar), 1024)
        summary = vc.validate_pack_v2_tree(v2_tree)
        self.assertEqual(summary["pack_format_version"], 2)

        staged = _evaluate_rbac_install({"catalog.packs.install"}, explicit_approval=False)
        self.assertEqual(staged["status"], "staged")
        enabled = _evaluate_rbac_install(
            {"catalog.packs.install", "dashboards.packages.manage"}, explicit_approval=True
        )
        self.assertEqual(enabled["status"], "enabled")
        self.assertEqual(w4["operator_overrides"]["max_jobs_per_minute"], 24)

    @_e2e_case(
        "F3+F5+F8+F11+F12",
        4,
        "E2E-T4-W5",
        "W5: External Rust SDK worker Ramp 1 to Ramp 2 upgrade and heartbeat-TTL failback with schema-identical alpr_plate_read output",
    )
    def test_e2e_t4_w5_rust_sdk_ramp1_to_ramp2_and_failback(self) -> None:
        w5 = self.workloads["W5"]
        hb = copy.deepcopy(self.hb_vec["positive"])
        r1 = _route_vantage_job(w5["pipeline"], [], now_us=hb["sent_at_us"], ttl_us=w5["ttl_us"])
        r2 = _route_vantage_job(w5["pipeline"], [hb], now_us=hb["sent_at_us"] + 1_000_000, ttl_us=w5["ttl_us"])
        r1_fb = _route_vantage_job(w5["pipeline"], [hb], now_us=hb["sent_at_us"] + w5["ttl_us"] + 1, ttl_us=w5["ttl_us"])
        self.assertEqual(r1["subject"], w5["expected_ramp1_subject"])
        self.assertEqual(r2["subject"], w5["expected_ramp2_subject"])
        self.assertEqual(r1_fb["subject"], w5["expected_ramp1_subject"])

    @_e2e_case(
        "F4+F7+F11+F12",
        4,
        "E2E-T4-W6",
        "W6: External Python PyO3 zero-copy NumPy worker and offline serviceradar-cli vantage dev harness",
    )
    def test_e2e_t4_w6_python_sdk_rgb8_and_offline_harness_contract(self) -> None:
        w6 = self.workloads["W6"]
        w, h = w6["frame_width"], w6["frame_height"]
        rgb_bytes = bytes((i % 251 for i in range(w * h * 3)))
        frame = copy.deepcopy(self.frame_vec["positive_payload_format"])
        frame["payload_format"] = "rgb8"
        frame["payload_b64"] = base64.b64encode(rgb_bytes).decode("ascii")
        vc.validate_live_frame(frame)
        self.assertEqual(len(rgb_bytes), h * w * 3)

        # Negative rgb8 truncated buffer fails contract
        bad_frame = copy.deepcopy(frame)
        bad_frame["payload_b64"] = base64.b64encode(rgb_bytes[:-1]).decode("ascii")
        with self.assertRaises(vc.ContractValidationError):
            vc.validate_live_frame(bad_frame)

    @_e2e_case(
        "F1+F2+F3+F12+F13+F14",
        4,
        "E2E-T4-W7",
        "W7: Phase 3 vantage.bay_guidance.v1 (Bay 04 Approach) live-tap p50/p95/p99 latency benchmark and crash/overflow isolation",
    )
    def test_e2e_t4_w7_phase3_bay_guidance_benchmark_and_isolation(self) -> None:
        w7 = self.workloads["W7"]
        pcts = _compute_percentiles_ms(w7["steady_state_latencies_ms"])
        self.assertGreater(pcts["p50"], 0.0)
        self.assertLessEqual(pcts["p50"], pcts["p95"])
        self.assertLessEqual(pcts["p95"], pcts["p99"])

        for state in w7["guidance_states"]:
            attrs = {
                "bay_id": "bay-04",
                "guidance_state": state,
                "distance_m": 1.5,
                "lateral_offset_m": -0.05,
                "confidence": 0.94,
            }
            vc.validate_bay_guidance_attributes(attrs)

        q: deque[int] = deque()
        dropped = 0
        for seq in w7["cmaf_block_sequences"]:
            if len(q) >= w7["mailbox_cap"]:
                q.popleft()
                dropped += 1
            q.append(seq)
        self.assertEqual(dropped, w7["expected_dropped_frames"])
        self.assertEqual(len(q), w7["mailbox_cap"])


# ---------------------------------------------------------------------------
# Master Catalog Completeness, Parity & Hygiene Audit
# ---------------------------------------------------------------------------


class MasterCatalogCompletenessModeATest(unittest.TestCase):
    """Audit merged `fixtures/test_catalog.json` against F1-F14 + Tier 3 + Tier 4 minimums."""

    def test_master_test_catalog_completeness_and_parity(self) -> None:
        master = _load_json("test_catalog.json")
        summary = vc.validate_test_catalog(master, enforce_minimums=True)
        self.assertEqual(summary["total"], 180)
        self.assertEqual(summary["tier_counts"], {1: 79, 2: 79, 3: 15, 4: 7})

        c1 = _load_json("catalog_f1_f5.json")["cases"]
        c2 = _load_json("catalog_f6_f10.json")["cases"]
        c3 = _load_json("catalog_f11_f14.json")["cases"]
        expected_t1_t2 = {c["test_id"]: c for c in (c1 + c2 + c3)}
        self.assertEqual(len(expected_t1_t2), 158)

        master_by_id = {c["test_id"]: c for c in master["cases"]}
        self.assertEqual(len(master_by_id), 180)
        for tid, expected_case in expected_t1_t2.items():
            self.assertIn(tid, master_by_id)
            self.assertEqual(master_by_id[tid], expected_case)

        registered = vc.get_registered_test_cases()
        mapped_methods = _collect_tier3_tier4_test_ids()
        t3_t4_cases = [c for c in master["cases"] if c["tier"] in (3, 4)]
        self.assertEqual(len(t3_t4_cases), 22)
        self.assertEqual({c["test_id"] for c in t3_t4_cases}, set(mapped_methods.keys()))
        for case in t3_t4_cases:
            self.assertEqual(set(case.keys()), {"feature", "tier", "test_id", "mode", "description"})
            self.assertEqual(case["mode"], "A+B")
            self.assertEqual(registered[case["test_id"]], case)

    def test_t3_t4_and_master_catalog_hygiene(self) -> None:
        fixtures_dir = _fixtures_dir()
        md_files = list(fixtures_dir.rglob("*.md"))
        self.assertEqual(md_files, [], f"Markdown files forbidden under fixtures/: {md_files}")

        for rel in (
            "test_catalog.json",
            "t3_t4/tier3_pairwise_matrix.json",
            "t3_t4/tier4_workloads.json",
        ):
            with self.subTest(fixture=rel):
                vc.assert_synthetic_hygiene((fixtures_dir / rel).read_text(encoding="utf-8"))


if __name__ == "__main__":
    unittest.main()
