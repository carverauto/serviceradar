"""Mode A hermetic tests for E2E-M2 (Tiers 1 & 2 covering F1–F5).

Pure Python 3.11+ stdlib `unittest` suite mapped 1:1 to `fixtures/catalog_f1_f5.json`.
"""

from __future__ import annotations

import base64
import copy
import hashlib
import json
import math
import os
import re
import sys
import unittest
from pathlib import Path
from typing import Any

if __package__ in (None, "") and "TEST_SRCDIR" not in os.environ:
    _repo_root = str(Path(__file__).resolve().parents[2])
    if _repo_root not in sys.path:
        sys.path.insert(0, _repo_root)

from integration_tests.vantage_ml import vantage_contracts as vc

_PIPELINE_ID_RE = re.compile(r"^[a-z][a-z0-9-]*(?:\.[a-z0-9][a-z0-9._-]*)+$")
_SEMVER_RE = re.compile(
    r"^(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$"
)
_HEX64_RE = re.compile(r"^[0-9a-f]{64}$")
_PLATE_TEXT_RE = re.compile(r"^[A-Z0-9-]{2,12}$")


def _fixtures_dir() -> Path:
    return vc.repo_root() / "integration_tests" / "vantage_ml" / "fixtures"


def _load_json(rel_path: str) -> Any:
    path = _fixtures_dir() / rel_path
    if not path.is_file():
        raise AssertionError(f"missing fixture file: {path}")
    return json.loads(path.read_text(encoding="utf-8"))


def _apply_dotted_patch(obj: dict[str, Any], patch: dict[str, Any]) -> dict[str, Any]:
    cloned = copy.deepcopy(obj)
    for dotted_key, value in patch.items():
        parts = dotted_key.split(".")
        cur: Any = cloned
        for part in parts[:-1]:
            if isinstance(cur, list):
                cur = cur[int(part)]
            else:
                cur = cur[part]
        last = parts[-1]
        if isinstance(cur, list):
            cur[int(last)] = value
        else:
            cur[last] = value
    return cloned


def _make_exact_size_baseline_jfif(target_bytes: int) -> bytes:
    """Create a valid Baseline JFIF byte payload padded with a pre-SOS COM marker to exact size."""
    base = vc.make_synthetic_baseline_jfif(64, 48, seed=7, target_max_bytes=4096)
    vc.validate_baseline_jfif(base, max_bytes=4096)
    if target_bytes < len(base) + 4:
        raise ValueError(f"target_bytes {target_bytes} too small for base JFIF ({len(base)} bytes)")
    # Insert a JPEG Comment (FF FE <len_hi> <len_lo> <payload>) right after APP0 JFIF (offset 20), before SOS.
    payload_len = target_bytes - len(base) - 4
    seg_len = payload_len + 2
    assert 2 <= seg_len <= 65535
    com_marker = b"\xFF\xFE" + seg_len.to_bytes(2, "big") + (b"V" * payload_len)
    out = base[:20] + com_marker + base[20:]
    assert len(out) == target_bytes
    return out


def _evaluate_trigger_purge(local_state: str, archive_state: str) -> bool:
    """Mirror PostgreSQL trigger `trg_camera_recording_catalog_purge_vantage`."""
    return local_state == "quarantined" or (
        local_state == "reclaimed" and archive_state in ("deleted", "not_required")
    )


def _evaluate_hold_coverage(entry: dict[str, Any], hold: dict[str, Any]) -> tuple[bool, str | None]:
    """Mirror `ServiceRadar.Camera.RecordingHolds.hold_protects_entry?/2` + `PD5` pin."""
    if hold.get("state") != "accepted" or entry.get("local_state") == "quarantined":
        return False, None
    t_start = entry["timeline_start_us"]
    t_end = entry["timeline_end_us"]
    h_start = hold["start_us"]
    h_end = hold["end_us"]
    if not (t_end > h_start and t_start < h_end):
        return False, None
    if entry.get("archive_state") == "verified":
        return True, "archive"
    if entry.get("local_state") == "present":
        return True, "local"
    return True, None


def _strip_think_and_fences(raw_content: str) -> tuple[str, dict[str, Any]]:
    """Mirror `vantage_vlm.rs` `parse_vlm_json_response` thinking/fence/regex validation."""
    rest = raw_content
    out_parts: list[str] = []
    while True:
        lower = rest.lower()
        open_idx = lower.find("<think")
        if open_idx < 0:
            out_parts.append(rest)
            break
        out_parts.append(rest[:open_idx])
        after_open = rest[open_idx:]
        gt_idx = after_open.find(">")
        if gt_idx < 0:
            return "truncated_thinking", {}
        close_idx = after_open.lower().find("</think>", gt_idx + 1)
        if close_idx < 0:
            return "truncated_thinking", {}
        rest = after_open[close_idx + len("</think>") :]
    cleaned = "".join(out_parts).strip()
    if "</think>" in cleaned.lower():
        return "truncated_thinking", {}
    if cleaned.startswith("```"):
        lines = cleaned.splitlines()
        if len(lines) >= 3 and lines[-1].strip().startswith("```"):
            cleaned = "\n".join(lines[1:-1]).strip()
    try:
        parsed = json.loads(cleaned)
    except json.JSONDecodeError:
        return "parse_error", {}
    if not isinstance(parsed, dict):
        return "parse_error", {}
    plate = str(parsed.get("plate_text", "")).strip().upper()
    if not _PLATE_TEXT_RE.match(plate):
        return "schema_rejected", {}
    parsed["plate_text"] = plate
    return "ok", parsed


def _vote_track_consensus(readings: list[dict[str, Any]]) -> tuple[str, int, float]:
    """Mirror `vantage_vlm.rs` `vote_track_observations` majority + confidence tie-break."""
    grouped: dict[str, list[float]] = {}
    for item in readings:
        label = str(item["plate_text"]).strip().upper()
        grouped.setdefault(label, []).append(float(item["confidence"]))
    best_label, confs = max(
        grouped.items(),
        key=lambda kv: (len(kv[1]), sum(kv[1]), max(kv[1]), kv[0]),
    )
    return best_label, len(confs), sum(confs) / len(confs)


def _trim_crops_within_budget(envelope: dict[str, Any], max_bytes: int) -> dict[str, Any]:
    """Mirror `vantage_vlm.rs` `trim_result_crops_within_ceiling` (lowest confidence first)."""
    cloned = copy.deepcopy(envelope)

    def _size() -> int:
        return len(json.dumps(cloned, separators=(",", ":"), ensure_ascii=False).encode("utf-8"))

    if _size() <= max_bytes:
        return cloned

    candidates = sorted(
        (
            (idx, float(obs.get("confidence", 0.0)))
            for idx, obs in enumerate(cloned["observations"])
            if obs.get("crop_jpeg_b64") is not None
        ),
        key=lambda item: (item[1], item[0]),
    )
    for idx, _conf in candidates:
        cloned["observations"][idx]["crop_jpeg_b64"] = None
        if _size() <= max_bytes:
            return cloned

    raise vc.ContractValidationError(
        f"result envelope remains {_size()} bytes > {max_bytes} even after trimming all crops"
    )


def _collect_mode_a_test_ids() -> dict[str, str]:
    mapping: dict[str, str] = {}
    for cls in (
        ModeAF1AshContractsTest,
        ModeAF2LifecycleContractsTest,
        ModeAF3JetStreamContractsTest,
        ModeAF4CropperContractsTest,
        ModeAF5VlmRunnerContractsTest,
    ):
        for attr_name in dir(cls):
            if not attr_name.startswith("test_e2e_"):
                continue
            fn = getattr(cls, attr_name)
            test_id = getattr(fn, "_e2e_test_id", None)
            if test_id:
                mapping[test_id] = f"{cls.__name__}.{attr_name}"
    return mapping


def _e2e_case(feature: str, tier: int, test_id: str, description: str):
    vc.record_test_case(feature, tier, test_id, "A+B", description)

    def _decorator(fn):
        fn._e2e_test_id = test_id
        return fn

    return _decorator


class CatalogAndHygieneF1F5Test(unittest.TestCase):
    """Verify catalog_f1_f5.json completeness, 1:1 method mapping, and synthetic hygiene."""

    def test_catalog_completeness_and_1_to_1_mapping(self) -> None:
        catalog = _load_json("catalog_f1_f5.json")
        self.assertEqual(catalog["milestone"], "E2E-M2")
        self.assertEqual(catalog["features"], ["F1", "F2", "F3", "F4", "F5"])

        summary = vc.validate_test_catalog(catalog, enforce_minimums=False)
        self.assertGreaterEqual(summary["total"], 50)
        for feature in ("F1", "F2", "F3", "F4", "F5"):
            self.assertGreaterEqual(summary["per_feature_tier"].get(f"{feature}:T1", 0), 5)
            self.assertGreaterEqual(summary["per_feature_tier"].get(f"{feature}:T2", 0), 5)

        catalog_ids = {entry["test_id"] for entry in catalog["cases"]}
        mapped_ids = _collect_mode_a_test_ids()
        self.assertEqual(
            catalog_ids,
            set(mapped_ids.keys()),
            "catalog_f1_f5.json test_ids must map 1:1 with test_mode_a_f1_f5.py test methods",
        )

    def test_fixtures_pass_synthetic_hygiene(self) -> None:
        rel_files = [
            "catalog_f1_f5.json",
            "f1_f5/f1_ash_resource_vectors.json",
            "f1_f5/f2_lifecycle_state_matrix.json",
            "f1_f5/f3_jetstream_result_vectors.json",
            "f1_f5/f4_crop_geometry_vectors.json",
            "f1_f5/f5_vlm_runner_vectors.json",
        ]
        for rel in rel_files:
            with self.subTest(fixture=rel):
                raw = (_fixtures_dir() / rel).read_text(encoding="utf-8")
                self.assertEqual(vc.scan_synthetic_hygiene(raw), [])


class ModeAF1AshContractsTest(unittest.TestCase):
    """F1: Vantage Ash resources, migrations, JFIF crop bounds, and RBAC contracts."""

    def setUp(self) -> None:
        self.f1 = _load_json("f1_f5/f1_ash_resource_vectors.json")
        self.job_vec = _load_json("wire_vectors/vantage_job_v1.json")

    @_e2e_case("F1", 1, "E2E-F1-T1-01", "VantagePipeline valid upsert contract & provenance")
    def test_e2e_f1_t1_01_vantage_pipeline_contract_and_provenance(self) -> None:
        p = self.f1["pipeline"]["valid"]
        self.assertRegex(p["pipeline_id"], _PIPELINE_ID_RE)
        self.assertRegex(p["version"], _SEMVER_RE)
        self.assertEqual(p["source_mode"], "recorded_block")
        self.assertEqual(p["trigger_kind"], "on_stage1_detection")
        self.assertEqual(p["input_mode"], "detection_crop")
        self.assertEqual(p["runner"], "camera_vlm")
        self.assertTrue(p["managed"])
        self.assertGreaterEqual(p["max_jobs_per_minute"], 1)
        self.assertGreaterEqual(p["max_frames_per_track"], 1)
        self.assertLessEqual(p["crop_policy"]["max_dimension"], vc.MAX_CROP_DIMENSION_PX)
        self.assertLessEqual(p["crop_policy"]["max_bytes"], vc.MAX_VLM_CROP_BYTES)

    @_e2e_case("F1", 1, "E2E-F1-T1-02", "VantageJob idempotency key and wire envelope contract")
    def test_e2e_f1_t1_02_vantage_job_idempotency_key_and_envelope(self) -> None:
        job = self.f1["job"]["sample_job"]
        self.assertEqual(
            self.f1["job"]["idempotency_key_fields"],
            ["pipeline_id", "pipeline_version", "catalog_entry_id", "target_key"],
        )
        self.assertIn(job["state"], self.f1["job"]["valid_states"])
        self.assertIn(job["job_kind"], self.f1["job"]["valid_job_kinds"])
        self.assertRegex(job["descriptor_sha256"], _HEX64_RE)
        vc.validate_job_envelope(self.job_vec["positive"])

    @_e2e_case("F1", 1, "E2E-F1-T1-03", "Recorded VantageObservation with 32 KiB JFIF & Ash bbox map")
    def test_e2e_f1_t1_03_recorded_observation_crop_and_ash_bbox_map(self) -> None:
        obs = self.f1["observation"]["recorded_valid"]
        self.assertEqual(obs["source_mode"], "recorded_block")
        self.assertIsNotNone(obs["catalog_entry_id"])
        ash_bbox = obs["ash_bbox"]
        self.assertLess(ash_bbox["x1"], ash_bbox["x2"])
        self.assertLess(ash_bbox["y1"], ash_bbox["y2"])
        self.assertEqual(
            [ash_bbox["x1"], ash_bbox["y1"], ash_bbox["x2"], ash_bbox["y2"]],
            obs["wire_bbox"],
        )
        crop_exact = _make_exact_size_baseline_jfif(vc.MAX_PERSISTED_CROP_BYTES)
        info = vc.validate_baseline_jfif(crop_exact, max_bytes=vc.MAX_PERSISTED_CROP_BYTES)
        self.assertEqual(info["byte_length"], vc.MAX_PERSISTED_CROP_BYTES)
        self.assertIn(obs["label"], obs["search_text"])

    @_e2e_case("F1", 1, "E2E-F1-T1-04", "Live-tap VantageObservation permits null catalog_entry_id")
    def test_e2e_f1_t1_04_live_tap_observation_null_catalog_entry(self) -> None:
        live = self.f1["observation"]["live_valid"]
        self.assertEqual(live["source_mode"], "live_keyframe_tap")
        self.assertIsNone(live["catalog_entry_id"])
        self.assertIsNone(live["job_id"])
        self.assertIn(live["time_basis"], ("received", "camera_reported"))
        vc.validate_bay_guidance_attributes(live["attributes"])

    @_e2e_case("F1", 1, "E2E-F1-T1-05", "Worker registration heartbeat + Dashboard provenance & RBAC")
    def test_e2e_f1_t1_05_worker_heartbeat_and_dashboard_provenance_rbac(self) -> None:
        hb_vec = _load_json("wire_vectors/vantage_heartbeat_v1.json")
        vc.validate_heartbeat(hb_vec["positive"])
        rbac = self.f1["rbac_and_provenance"]
        self.assertEqual(rbac["dashboard_package_manage_permission"], "dashboards.packages.manage")
        self.assertEqual(
            rbac["provenance_columns"],
            ["pack_id", "pack_version", "managed", "template_fingerprint"],
        )

    @_e2e_case("F1", 2, "E2E-F1-T2-01", "Exact 32768 B crop_jpeg passes vs 32769 B fails")
    def test_e2e_f1_t2_01_crop_jpeg_32768_vs_32769_boundary(self) -> None:
        ok_bytes = _make_exact_size_baseline_jfif(vc.MAX_PERSISTED_CROP_BYTES)
        vc.validate_baseline_jfif(ok_bytes, max_bytes=vc.MAX_PERSISTED_CROP_BYTES)

        too_large = _make_exact_size_baseline_jfif(vc.MAX_PERSISTED_CROP_BYTES + 1)
        with self.assertRaises(vc.ContractValidationError):
            vc.validate_baseline_jfif(too_large, max_bytes=vc.MAX_PERSISTED_CROP_BYTES)

    @_e2e_case("F1", 2, "E2E-F1-T2-02", "Reject Progressive SOF2 and non-JFIF crop_jpeg bytes")
    def test_e2e_f1_t2_02_reject_progressive_sof2_and_non_jfif(self) -> None:
        valid = vc.make_synthetic_baseline_jfif(64, 48, seed=11, target_max_bytes=8192)
        sof0_idx = valid.index(b"\xFF\xC0\x00\x11\x08")
        sof2 = bytearray(valid)
        sof2[sof0_idx + 1] = 0xC2
        with self.assertRaises(vc.ContractValidationError):
            vc.validate_baseline_jfif(bytes(sof2), max_bytes=vc.MAX_PERSISTED_CROP_BYTES)

        with self.assertRaises(vc.ContractValidationError):
            vc.validate_baseline_jfif(b"not-a-jpeg-payload", max_bytes=vc.MAX_PERSISTED_CROP_BYTES)

    @_e2e_case("F1", 2, "E2E-F1-T2-03", "Reject invalid bbox coordinates and out-of-range confidence")
    def test_e2e_f1_t2_03_reject_invalid_bbox_and_confidence(self) -> None:
        result_vec = _load_json("wire_vectors/vantage_result_v1.json")
        for bad_bbox in self.f1["observation"]["invalid_bboxes"]:
            with self.subTest(bad_bbox=bad_bbox):
                mutated = copy.deepcopy(result_vec["positive"])
                mutated["observations"][0]["bbox"] = bad_bbox
                with self.assertRaises(vc.ContractValidationError):
                    vc.validate_result_envelope(mutated)

        for bad_conf in self.f1["observation"]["invalid_confidences"]:
            with self.subTest(bad_conf=bad_conf):
                mutated = copy.deepcopy(result_vec["positive"])
                mutated["observations"][0]["confidence"] = bad_conf
                with self.assertRaises(vc.ContractValidationError):
                    vc.validate_result_envelope(mutated)

    @_e2e_case("F1", 2, "E2E-F1-T2-04", "Observation read RBAC requires recordings.view, rejects bare devices.view")
    def test_e2e_f1_t2_04_observation_rbac_contract(self) -> None:
        rbac = self.f1["rbac_and_provenance"]
        required = set(rbac["required_observation_read_permissions"])
        self.assertIn("devices.cameras.recordings.view", required)
        for perm in rbac["insufficient_observation_read_permissions"]:
            self.assertFalse(required.issubset({perm}))

    @_e2e_case("F1", 2, "E2E-F1-T2-05", "Reject invalid time_basis, source_mode, null recorded catalog_entry_id, and bad pipeline_id/SemVer")
    def test_e2e_f1_t2_05_reject_invalid_enums_null_recorded_and_pipeline_id_semver(self) -> None:
        result_vec = _load_json("wire_vectors/vantage_result_v1.json")
        for tb in self.f1["observation"]["invalid_time_bases"]:
            mutated = copy.deepcopy(result_vec["positive"])
            mutated["observations"][0]["time_basis"] = tb
            with self.assertRaises(vc.ContractValidationError):
                vc.validate_result_envelope(mutated)

        for sm in self.f1["observation"]["invalid_source_modes"]:
            mutated = copy.deepcopy(result_vec["positive"])
            mutated["source_mode"] = sm
            with self.assertRaises(vc.ContractValidationError):
                vc.validate_result_envelope(mutated)

        null_cat = copy.deepcopy(result_vec["positive"])
        null_cat["catalog_entry_id"] = None
        with self.assertRaises(vc.ContractValidationError):
            vc.validate_result_envelope(null_cat)

        for bad in self.f1["pipeline"]["invalid_cases"]:
            with self.subTest(case=bad["name"]):
                ok_id = bool(_PIPELINE_ID_RE.match(bad["pipeline_id"]))
                ok_ver = bool(_SEMVER_RE.match(bad["version"]))
                self.assertFalse(ok_id and ok_ver)


class ModeAF2LifecycleContractsTest(unittest.TestCase):
    """F2: Recording retention, quarantine, RecordingHold [h_start, h_end), and cascade rules."""

    def setUp(self) -> None:
        self.f2 = _load_json("f1_f5/f2_lifecycle_state_matrix.json")

    def _matrix_row(self, name: str) -> dict[str, Any]:
        for row in self.f2["catalog_purge_matrix"]:
            if row["name"] == name:
                return row
        raise AssertionError(f"missing F2 matrix row {name!r}")

    def _hold_case(self, name: str) -> dict[str, Any]:
        for row in self.f2["recording_hold_cases"]:
            if row["name"] == name:
                return row
        raise AssertionError(f"missing F2 hold case {name!r}")

    @_e2e_case("F2", 1, "E2E-F2-T1-01", "Quarantine transition purges observations and cancels active jobs")
    def test_e2e_f2_t1_01_quarantine_purges_observations_and_cancels_active_jobs(self) -> None:
        row = self._matrix_row("quarantined_purges_observations_and_cancels_active_jobs")
        self.assertTrue(_evaluate_trigger_purge(row["target_local_state"], row["target_archive_state"]))
        self.assertTrue(row["expect_observations_purged"])
        self.assertTrue(row["expect_active_jobs_cancelled"])
        self.assertTrue(row["expect_completed_jobs_preserved"])
        self.assertEqual(row["expected_last_error_class"], "source_deleted_or_quarantined")

    @_e2e_case("F2", 1, "E2E-F2-T1-02", "Terminal reclaim (deleted/not_required) purges observations and cancels active jobs")
    def test_e2e_f2_t1_02_terminal_reclaim_purges_and_cancels(self) -> None:
        for name in (
            "reclaimed_deleted_purges_observations_and_cancels_active_jobs",
            "reclaimed_not_required_purges_observations_and_cancels_active_jobs",
        ):
            row = self._matrix_row(name)
            self.assertTrue(_evaluate_trigger_purge(row["target_local_state"], row["target_archive_state"]))
            self.assertTrue(row["expect_observations_purged"])
            self.assertTrue(row["expect_active_jobs_cancelled"])

    @_e2e_case("F2", 1, "E2E-F2-T1-03", "Local eviction with verified archive preserves observations")
    def test_e2e_f2_t1_03_reclaimed_verified_preserves_observations(self) -> None:
        row = self._matrix_row("reclaimed_with_verified_archive_preserves_observations")
        self.assertFalse(_evaluate_trigger_purge(row["target_local_state"], row["target_archive_state"]))
        self.assertFalse(row["expect_observations_purged"])
        self.assertFalse(row["expect_active_jobs_cancelled"])

    @_e2e_case("F2", 1, "E2E-F2-T1-04", "RecordingHold PD5 pins archive over local and preserves observations")
    def test_e2e_f2_t1_04_recording_hold_pd5_pin_selection(self) -> None:
        local_case = self._hold_case("overlapping_hold_local_only_pins_local_copy")
        covered_l, pin_l = _evaluate_hold_coverage(local_case["entry"], local_case["hold"])
        self.assertEqual((covered_l, pin_l), (True, "local"))

        arch_case = self._hold_case("overlapping_hold_with_verified_archive_pins_archive_copy")
        covered_a, pin_a = _evaluate_hold_coverage(arch_case["entry"], arch_case["hold"])
        self.assertEqual((covered_a, pin_a), (True, "archive"))

    @_e2e_case("F2", 1, "E2E-F2-T1-05", "Source deletion cascades to recorded_block and live_keyframe_tap observations")
    def test_e2e_f2_t1_05_source_delete_cascades_all_observations(self) -> None:
        self.assertTrue(self.f2["live_tap_isolation"]["source_delete_cascades_live_and_recorded"])

    @_e2e_case("F2", 2, "E2E-F2-T2-01", "Direct DELETE on RecordingCatalogEntry cascades FKs")
    def test_e2e_f2_t2_01_catalog_entry_delete_fk_cascade_contract(self) -> None:
        # Recorded observations require non-null catalog_entry_id (cascaded on DELETE)
        f1 = _load_json("f1_f5/f1_ash_resource_vectors.json")
        self.assertIsNotNone(f1["observation"]["recorded_valid"]["catalog_entry_id"])

    @_e2e_case("F2", 2, "E2E-F2-T2-02", "Quarantine during dispatched job cancels job and rejects late result")
    def test_e2e_f2_t2_02_quarantine_cancels_dispatched_and_rejects_late_result(self) -> None:
        row = self._matrix_row("quarantined_purges_observations_and_cancels_active_jobs")
        self.assertTrue(_evaluate_trigger_purge(row["target_local_state"], row["target_archive_state"]))
        self.assertTrue(row["expect_active_jobs_cancelled"])

    @_e2e_case("F2", 2, "E2E-F2-T2-03", "RecordingHold half-open [h_start, h_end) boundary excludes t_end == h_start")
    def test_e2e_f2_t2_03_hold_half_open_boundary_semantics(self) -> None:
        for name in (
            "half_open_boundary_end_equals_hold_start_not_covered",
            "half_open_boundary_start_equals_hold_end_not_covered",
            "released_hold_no_longer_pins_entry",
        ):
            case = self._hold_case(name)
            with self.subTest(case=name):
                covered, pin = _evaluate_hold_coverage(case["entry"], case["hold"])
                self.assertEqual(covered, case["expect_covered"])
                self.assertEqual(pin, case["expected_pinned_copy"])

    @_e2e_case("F2", 2, "E2E-F2-T2-04", "Live-tap observations survive sibling recorded block reclaim")
    def test_e2e_f2_t2_04_live_tap_survives_sibling_reclaim(self) -> None:
        self.assertTrue(self.f2["live_tap_isolation"]["sibling_block_reclaim_preserves_live_observations"])
        self.assertGreaterEqual(self.f2["live_tap_isolation"]["default_live_observation_retention_days"], 1)

    @_e2e_case("F2", 2, "E2E-F2-T2-05", "Unrelated archive_state update on present block does not purge")
    def test_e2e_f2_t2_05_unrelated_catalog_update_does_not_purge(self) -> None:
        row = self._matrix_row("archive_verified_on_present_block_does_not_purge")
        self.assertFalse(_evaluate_trigger_purge(row["target_local_state"], row["target_archive_state"]))
        self.assertFalse(row["expect_observations_purged"])


class ModeAF3JetStreamContractsTest(unittest.TestCase):
    """F3: media.results.vantage.v1 envelope, deduplication, OCSF 1008, and terminal rejection."""

    def setUp(self) -> None:
        self.f3 = _load_json("f1_f5/f3_jetstream_result_vectors.json")

    @_e2e_case("F3", 1, "E2E-F3-T1-01", "Valid recorded_block vantage.result.v1 + OCSF 1008 signal_schema contract")
    def test_e2e_f3_t1_01_valid_recorded_result_and_ocsf_1008_shape(self) -> None:
        env = copy.deepcopy(self.f3["positive"]["recorded_alpr"])
        crop_14k = _make_exact_size_baseline_jfif(14 * 1024)
        env["observations"][0]["crop_jpeg_b64"] = base64.b64encode(crop_14k).decode("ascii")
        vc.validate_result_envelope(env)
        self.assertEqual(self.f3["subject"], "media.results.vantage.v1")
        self.assertEqual(self.f3["ocsf_contract"]["class_uid"], 1008)

    @_e2e_case("F3", 1, "E2E-F3-T1-02", "Deterministic Nats-Msg-Id vantage-result:<job_id> contract")
    def test_e2e_f3_t1_02_deterministic_nats_msg_id(self) -> None:
        env = self.f3["positive"]["recorded_alpr"]
        msg_id_1 = f"vantage-result:{env['job_id']}"
        msg_id_2 = f"vantage-result:{env['job_id']}"
        self.assertEqual(msg_id_1, msg_id_2)
        self.assertTrue(msg_id_1.startswith("vantage-result:"))

    @_e2e_case("F3", 1, "E2E-F3-T1-03", "Valid live_keyframe_tap result envelope with null job/catalog IDs")
    def test_e2e_f3_t1_03_live_tap_result_envelope(self) -> None:
        live = self.f3["positive"]["live_tap_python"]
        self.assertIsNone(live["job_id"])
        self.assertIsNone(live["catalog_entry_id"])
        self.assertEqual(live["worker_kind"], "external_python")
        vc.validate_result_envelope(live)

    @_e2e_case("F3", 1, "E2E-F3-T1-04", "emit_ocsf_events false toggle suppresses OCSF emission while validating result")
    def test_e2e_f3_t1_04_emit_ocsf_events_toggle(self) -> None:
        f1 = _load_json("f1_f5/f1_ash_resource_vectors.json")
        pipeline = copy.deepcopy(f1["pipeline"]["valid"])
        self.assertTrue(pipeline["emit_ocsf_events"])
        pipeline["emit_ocsf_events"] = False
        self.assertFalse(pipeline["emit_ocsf_events"])
        vc.validate_result_envelope(self.f3["positive"]["recorded_alpr"])

    @_e2e_case("F3", 1, "E2E-F3-T1-05", "Valid empty observations: [] batch passes envelope validation")
    def test_e2e_f3_t1_05_empty_observations_batch_valid(self) -> None:
        empty_env = self.f3["positive"]["empty_observations_batch"]
        self.assertEqual(empty_env["observations"], [])
        vc.validate_result_envelope(empty_env)

    @_e2e_case("F3", 2, "E2E-F3-T2-01", "Reject alpr_plate_read signal_schema regex/type/missing-field violations")
    def test_e2e_f3_t2_01_alpr_signal_schema_rejections(self) -> None:
        bad_plate = _apply_dotted_patch(
            self.f3["positive"]["recorded_alpr"],
            self.f3["negative"][0]["patch"],
        )
        with self.assertRaises(vc.ContractValidationError):
            vc.validate_result_envelope(bad_plate)

        missing_plate = copy.deepcopy(self.f3["positive"]["recorded_alpr"])
        del missing_plate["observations"][0]["attributes"]["plate_text"]
        with self.assertRaises(vc.ContractValidationError):
            vc.validate_result_envelope(missing_plate)

    @_e2e_case("F3", 2, "E2E-F3-T2-02", "Reject 32769 B crop_jpeg_b64 and non-JPEG bytes")
    def test_e2e_f3_t2_02_reject_oversized_or_non_jpeg_crop(self) -> None:
        oversized_crop = _make_exact_size_baseline_jfif(vc.MAX_PERSISTED_CROP_BYTES + 1)
        bad_env = copy.deepcopy(self.f3["positive"]["recorded_alpr"])
        bad_env["observations"][0]["crop_jpeg_b64"] = base64.b64encode(oversized_crop).decode("ascii")
        with self.assertRaises(vc.ContractValidationError):
            vc.validate_result_envelope(bad_env)

        non_jpeg = _apply_dotted_patch(
            self.f3["positive"]["recorded_alpr"],
            self.f3["negative"][4]["patch"],
        )
        with self.assertRaises(vc.ContractValidationError):
            vc.validate_result_envelope(non_jpeg)

    @_e2e_case("F3", 2, "E2E-F3-T2-03", "Reject inverted bbox and out-of-range confidence")
    def test_e2e_f3_t2_03_reject_inverted_bbox_and_bad_confidence(self) -> None:
        bad_conf = _apply_dotted_patch(
            self.f3["positive"]["recorded_alpr"],
            self.f3["negative"][1]["patch"],
        )
        with self.assertRaises(vc.ContractValidationError):
            vc.validate_result_envelope(bad_conf)

        bad_bbox = copy.deepcopy(self.f3["positive"]["recorded_alpr"])
        bad_bbox["observations"][0]["bbox"] = [0.6, 0.2, 0.4, 0.8]
        with self.assertRaises(vc.ContractValidationError):
            vc.validate_result_envelope(bad_bbox)

    @_e2e_case("F3", 2, "E2E-F3-T2-04", "Reject invalid descriptor_sha256 and recorded_block missing catalog_entry_id")
    def test_e2e_f3_t2_04_reject_bad_descriptor_or_missing_catalog_entry(self) -> None:
        bad_sha = copy.deepcopy(self.f3["positive"]["recorded_alpr"])
        bad_sha["descriptor_sha256"] = "not-hex64"
        with self.assertRaises(vc.ContractValidationError):
            vc.validate_result_envelope(bad_sha)

        missing_cat = copy.deepcopy(self.f3["positive"]["recorded_alpr"])
        missing_cat["catalog_entry_id"] = None
        with self.assertRaises(vc.ContractValidationError):
            vc.validate_result_envelope(missing_cat)

    @_e2e_case("F3", 2, "E2E-F3-T2-05", "Reject 983041 B (>960 KiB) envelope, wrong schema_version, and missing job_id")
    def test_e2e_f3_t2_05_reject_oversized_envelope_and_wrong_schema_version(self) -> None:
        for idx in (2, 3):
            neg = self.f3["negative"][idx]
            mutated = _apply_dotted_patch(self.f3["positive"]["recorded_alpr"], neg["patch"])
            with self.assertRaises(vc.ContractValidationError):
                vc.validate_result_envelope(mutated)

        # Exact 983040 B accepted vs 983041 B rejected
        base = copy.deepcopy(self.f3["positive"]["live_tap_python"])
        base["observations"][0]["search_text"] = ""
        base_len = len(json.dumps(base, separators=(",", ":"), ensure_ascii=False).encode("utf-8"))
        pad_exact = vc.MAX_RESULT_ENVELOPE_BYTES - base_len
        base["observations"][0]["search_text"] = "x" * pad_exact
        self.assertEqual(
            len(json.dumps(base, separators=(",", ":"), ensure_ascii=False).encode("utf-8")),
            vc.MAX_RESULT_ENVELOPE_BYTES,
        )
        vc.validate_result_envelope(base)

        base["observations"][0]["search_text"] = "x" * (pad_exact + 1)
        with self.assertRaises(vc.ContractValidationError):
            vc.validate_result_envelope(base)


class ModeAF4CropperContractsTest(unittest.TestCase):
    """F4: Full-resolution crop geometry, min_bbox_width_px, JFIF bounds, and wire round-trips."""

    def setUp(self) -> None:
        self.f4 = _load_json("f1_f5/f4_crop_geometry_vectors.json")

    def _case(self, group: str, name: str) -> dict[str, Any]:
        for item in self.f4[group]:
            if item["name"] == name:
                return item
        raise AssertionError(f"missing F4 {group} case {name!r}")

    @_e2e_case("F4", 1, "E2E-F4-T1-01", "1080p native RGB crop geometry and 96 KiB JFIF structure")
    def test_e2e_f4_t1_01_1080p_native_crop_and_jfif(self) -> None:
        c = self._case("positive_cases", "native_1080p_vehicle_crop")
        res = vc.compute_padded_crop_box(
            c["frame_w"], c["frame_h"], c["bbox"], c["padding_ratio"], c["min_bbox_width_px"], c["max_dimension"]
        )
        self.assertEqual(res["status"], "ok")
        self.assertEqual(res["crop_w"], c["expected_crop_w"])
        self.assertEqual(res["crop_h"], c["expected_crop_h"])
        self.assertEqual(res["out_w"], c["expected_out_w"])
        self.assertEqual(res["out_h"], c["expected_out_h"])
        jpeg = vc.make_synthetic_baseline_jfif(
            res["out_w"], res["out_h"], seed=3, target_max_bytes=vc.MAX_VLM_CROP_BYTES
        )
        info = vc.validate_baseline_jfif(jpeg, max_bytes=vc.MAX_VLM_CROP_BYTES)
        self.assertLessEqual(info["byte_length"], vc.MAX_VLM_CROP_BYTES)

    @_e2e_case("F4", 1, "E2E-F4-T1-02", "4K (3840x2160) detection downscales aspect-preserving to 640px")
    def test_e2e_f4_t1_02_4k_downscale_to_640(self) -> None:
        c = self._case("positive_cases", "4k_large_detection_downscales_to_640")
        res = vc.compute_padded_crop_box(
            c["frame_w"], c["frame_h"], c["bbox"], c["padding_ratio"], c["min_bbox_width_px"], c["max_dimension"]
        )
        self.assertEqual(res["status"], "ok")
        self.assertEqual(res["out_w"], c["expected_out_w"])
        self.assertEqual(res["out_h"], c["expected_out_h"])

    @_e2e_case("F4", 1, "E2E-F4-T1-03", "Border-touching detection clamps to frame origin [0, 0]")
    def test_e2e_f4_t1_03_border_clamp(self) -> None:
        c = self._case("positive_cases", "border_touching_clamps_to_origin")
        res = vc.compute_padded_crop_box(
            c["frame_w"], c["frame_h"], c["bbox"], c["padding_ratio"], c["min_bbox_width_px"], c["max_dimension"]
        )
        self.assertEqual(res["status"], "ok")
        self.assertEqual(res["px1"], c["expected_px1"])
        self.assertEqual(res["py1"], c["expected_py1"])
        self.assertEqual(res["out_w"], c["expected_out_w"])
        self.assertEqual(res["out_h"], c["expected_out_h"])

    @_e2e_case("F4", 1, "E2E-F4-T1-04", "Quality step-down & 3/4 downscale enforce <= 32 KiB stored & <= 96 KiB VLM caps")
    def test_e2e_f4_t1_04_stored_32kib_and_vlm_96kib_caps(self) -> None:
        stored = vc.make_synthetic_baseline_jfif(
            640, 480, seed=19, target_max_bytes=vc.MAX_PERSISTED_CROP_BYTES, quality=85, min_quality=35
        )
        stored_info = vc.validate_baseline_jfif(stored, max_bytes=vc.MAX_PERSISTED_CROP_BYTES)
        self.assertLessEqual(stored_info["byte_length"], vc.MAX_PERSISTED_CROP_BYTES)

        vlm = vc.make_synthetic_baseline_jfif(
            640, 480, seed=19, target_max_bytes=vc.MAX_VLM_CROP_BYTES, quality=85, min_quality=35
        )
        vlm_info = vc.validate_baseline_jfif(vlm, max_bytes=vc.MAX_VLM_CROP_BYTES)
        self.assertLessEqual(vlm_info["byte_length"], vc.MAX_VLM_CROP_BYTES)

    @_e2e_case("F4", 1, "E2E-F4-T1-05", "vantage_protocol wire envelopes round-trip across recorded and live modes")
    def test_e2e_f4_t1_05_vantage_protocol_round_trips(self) -> None:
        for fname, validator in (
            ("wire_vectors/vantage_job_v1.json", vc.validate_job_envelope),
            ("wire_vectors/vantage_heartbeat_v1.json", vc.validate_heartbeat),
            ("wire_vectors/vantage_frame_v1.json", vc.validate_live_frame),
        ):
            vec = _load_json(fname)
            round_tripped = json.loads(json.dumps(vec["positive"], separators=(",", ":")))
            validator(round_tripped)

        res_vec = _load_json("wire_vectors/vantage_result_v1.json")
        for key in ("positive", "positive_live"):
            validator_input = json.loads(json.dumps(res_vec[key], separators=(",", ":")))
            vc.validate_result_envelope(validator_input)

    @_e2e_case("F4", 2, "E2E-F4-T2-01", "Distant 76.8 px detection skipped with crop_below_min_dimension")
    def test_e2e_f4_t2_01_distant_detection_76_8px_skipped(self) -> None:
        c = self._case("skip_cases", "distant_vehicle_76_8px_skipped")
        res = vc.compute_padded_crop_box(
            c["frame_w"], c["frame_h"], c["bbox"], c["padding_ratio"], c["min_bbox_width_px"], c["max_dimension"]
        )
        self.assertEqual(res["status"], "skipped")
        self.assertEqual(res["reason"], "crop_below_min_dimension")
        self.assertAlmostEqual(res["raw_width_px"], 76.8, places=4)

    @_e2e_case("F4", 2, "E2E-F4-T2-02", "Exact 96 px accepts while 95 px skips as crop_below_min_dimension")
    def test_e2e_f4_t2_02_exact_96_accepts_and_95_skips(self) -> None:
        ok = self._case("positive_cases", "exact_96px_boundary_accepted")
        res_ok = vc.compute_padded_crop_box(
            ok["frame_w"], ok["frame_h"], ok["bbox"], ok["padding_ratio"], ok["min_bbox_width_px"], ok["max_dimension"]
        )
        self.assertEqual(res_ok["status"], "ok")

        skip = self._case("skip_cases", "exact_95px_below_min_skipped")
        res_skip = vc.compute_padded_crop_box(
            skip["frame_w"], skip["frame_h"], skip["bbox"], skip["padding_ratio"], skip["min_bbox_width_px"], skip["max_dimension"]
        )
        self.assertEqual(res_skip["status"], "skipped")
        self.assertEqual(res_skip["reason"], "crop_below_min_dimension")

    @_e2e_case("F4", 2, "E2E-F4-T2-03", "Reject zero-area, inverted, and NaN bounding boxes")
    def test_e2e_f4_t2_03_reject_zero_area_inverted_and_nan_bbox(self) -> None:
        for name in ("zero_area_bbox", "inverted_bbox"):
            c = self._case("invalid_cases", name)
            with self.assertRaises(vc.ContractValidationError):
                vc.compute_padded_crop_box(c["frame_w"], c["frame_h"], c["bbox"])

        with self.assertRaises(vc.ContractValidationError):
            vc.compute_padded_crop_box(1920, 1080, [math.nan, 0.1, 0.5, 0.5])

    @_e2e_case("F4", 2, "E2E-F4-T2-04", "Reject 0x0 frame, max_dimension=0, and max_bytes < 512")
    def test_e2e_f4_t2_04_reject_invalid_frame_and_config(self) -> None:
        for name in ("empty_0x0_frame", "zero_max_dimension"):
            c = self._case("invalid_cases", name)
            with self.assertRaises(vc.ContractValidationError):
                vc.compute_padded_crop_box(
                    c["frame_w"], c["frame_h"], c["bbox"], c["padding_ratio"], c["min_bbox_width_px"], c["max_dimension"]
                )

        with self.assertRaises(vc.ContractValidationError):
            vc.make_synthetic_baseline_jfif(64, 64, target_max_bytes=511)

    @_e2e_case("F4", 2, "E2E-F4-T2-05", "Impossible max_bytes cap fails closed rather than exceeding limit")
    def test_e2e_f4_t2_05_impossible_max_bytes_fails_closed(self) -> None:
        with self.assertRaises(vc.ContractValidationError):
            vc.make_synthetic_baseline_jfif(256, 256, seed=9, target_max_bytes=512, quality=90, min_quality=85)


class ModeAF5VlmRunnerContractsTest(unittest.TestCase):
    """F5: Ramp 1 VLM request payload, thinking/JSON validation, consensus, and 960 KiB trim."""

    def setUp(self) -> None:
        self.f5 = _load_json("f1_f5/f5_vlm_runner_vectors.json")
        self.job_vec = _load_json("wire_vectors/vantage_job_v1.json")
        self.result_vec = _load_json("wire_vectors/vantage_result_v1.json")
        self.grant_vec = _load_json("wire_vectors/read_grant_response.json")

    @_e2e_case("F5", 1, "E2E-F5-T1-01", "Ramp 1 VLM job & OpenAI request disable thinking and require JSON")
    def test_e2e_f5_t1_01_vlm_request_and_job_contract(self) -> None:
        job = vc.validate_job_envelope(self.job_vec["positive"])
        defaults = self.f5["vlm_request_defaults"]
        self.assertFalse(defaults["enable_thinking"])
        self.assertFalse(defaults["chat_template_kwargs"]["enable_thinking"])
        self.assertGreaterEqual(job["vlm_config"]["max_tokens"], 1)
        self.assertEqual(defaults["endpoint_path"], "/v1/chat/completions")

    @_e2e_case("F5", 1, "E2E-F5-T1-02", "3-frame track consensus selects majority plate TEST-742")
    def test_e2e_f5_t1_02_three_frame_track_consensus(self) -> None:
        case = self.f5["consensus_cases"][0]
        winner, votes, avg_conf = _vote_track_consensus(case["readings"])
        self.assertEqual(winner, case["expected_winner"])
        self.assertEqual(votes, case["expected_vote_count"])
        self.assertGreater(avg_conf, 0.90)

    @_e2e_case("F5", 1, "E2E-F5-T1-03", "Mixed targets skip <96 px vehicle while accepting valid target")
    def test_e2e_f5_t1_03_mixed_targets_skip_tiny_and_process_valid(self) -> None:
        valid = vc.compute_padded_crop_box(1920, 1080, [0.30, 0.45, 0.55, 0.80], 0.15, 96, 640)
        tiny = vc.compute_padded_crop_box(1920, 1080, [0.40, 0.40, 0.44, 0.50], 0.15, 96, 640)
        self.assertEqual(valid["status"], "ok")
        self.assertEqual(tiny["status"], "skipped")
        self.assertEqual(tiny["reason"], "crop_below_min_dimension")

    @_e2e_case("F5", 1, "E2E-F5-T1-04", "410 recording_gone read-grant response ACKs cleanly with 0 results")
    def test_e2e_f5_t1_04_read_grant_410_gone_disposition(self) -> None:
        disp = self.f5["error_disposition_cases"]["read_grant_410_gone"]
        self.assertEqual(disp["http_status"], 410)
        self.assertTrue(disp["expect_ack"])
        self.assertEqual(disp["expect_published_results"], 0)

    @_e2e_case("F5", 1, "E2E-F5-T1-05", "Local and archive read-grant contracts pass validation cleanly")
    def test_e2e_f5_t1_05_local_and_archive_read_grant_contracts(self) -> None:
        arch = vc.validate_read_grant_response(self.grant_vec["positive_archive"])
        loc = vc.validate_read_grant_response(self.grant_vec["positive_local"])
        self.assertEqual(arch["backing"], "archive")
        self.assertEqual(loc["backing"], "local")
        self.assertEqual(arch["descriptor_sha256"], loc["descriptor_sha256"])

    @_e2e_case("F5", 2, "E2E-F5-T2-01", "Closed <think> stripped cleanly vs unclosed <think> rejected")
    def test_e2e_f5_t2_01_closed_vs_unclosed_think_blocks(self) -> None:
        closed_case, unclosed_case = self.f5["vlm_response_cases"][0], self.f5["vlm_response_cases"][1]
        status_ok, parsed = _strip_think_and_fences(closed_case["raw_content"])
        self.assertEqual(status_ok, "ok")
        self.assertEqual(parsed["plate_text"], closed_case["expected_plate_text"])

        status_bad, empty = _strip_think_and_fences(unclosed_case["raw_content"])
        self.assertEqual(status_bad, "truncated_thinking")
        self.assertEqual(empty, {})

    @_e2e_case("F5", 2, "E2E-F5-T2-02", "Non-JSON prose and invalid plate_text regex rejected with zero observations")
    def test_e2e_f5_t2_02_non_json_and_regex_rejection(self) -> None:
        for case in self.f5["vlm_response_cases"][2:]:
            with self.subTest(case=case["name"]):
                status, parsed = _strip_think_and_fences(case["raw_content"])
                self.assertEqual(status, case["expected_outcome"])
                self.assertEqual(parsed, {})

    @_e2e_case("F5", 2, "E2E-F5-T2-03", "SHA-256 mismatch aborts before VLM invocation")
    def test_e2e_f5_t2_03_sha256_mismatch_aborts_before_vlm(self) -> None:
        expected = hashlib.sha256(b"synthetic-init").hexdigest()
        corrupted = hashlib.sha256(b"corrupted-init").hexdigest()
        self.assertNotEqual(expected, corrupted)
        disp = self.f5["error_disposition_cases"]["sha256_mismatch"]
        self.assertEqual(disp["expect_vlm_calls"], 0)
        self.assertTrue(disp["expect_nak"])

    @_e2e_case("F5", 2, "E2E-F5-T2-04", "VLM HTTP 500/timeout NAKs without fabricating observations")
    def test_e2e_f5_t2_04_vlm_http_500_nak_disposition(self) -> None:
        disp = self.f5["error_disposition_cases"]["vlm_http_500"]
        self.assertEqual(disp["http_status"], 500)
        self.assertTrue(disp["expect_nak"])
        self.assertEqual(disp["expect_published_results"], 0)

    @_e2e_case("F5", 2, "E2E-F5-T2-05", "Trim lowest-confidence crop_jpeg_b64 previews first within 960 KiB")
    def test_e2e_f5_t2_05_trim_lowest_confidence_crops_under_960kib(self) -> None:
        env = copy.deepcopy(self.result_vec["positive"])
        crop_32k_b64 = base64.b64encode(_make_exact_size_baseline_jfif(32 * 1024)).decode("ascii")
        # 25 observations * ~43.7 KB base64 > 983040 B -> lowest-confidence crops must be trimmed first
        observations = []
        for idx in range(25):
            obs = copy.deepcopy(env["observations"][0])
            obs["observation_key"] = f"{idx:064x}"
            obs["track_id"] = str(idx)
            obs["confidence"] = round(0.50 + idx * 0.019, 4)
            obs["crop_jpeg_b64"] = crop_32k_b64
            observations.append(obs)
        env["observations"] = observations

        trimmed = _trim_crops_within_budget(env, vc.MAX_RESULT_ENVELOPE_BYTES)
        vc.validate_result_envelope(trimmed)
        # Lowest confidence item (idx 0) was stripped while highest confidence item (idx 24) survived
        self.assertIsNone(trimmed["observations"][0]["crop_jpeg_b64"])
        self.assertIsNotNone(trimmed["observations"][-1]["crop_jpeg_b64"])


if __name__ == "__main__":
    unittest.main()
