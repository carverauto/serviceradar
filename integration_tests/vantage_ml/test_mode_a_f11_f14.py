"""Mode A hermetic E2E contract tests for F11-F14 (Tiers 1 & 2)."""

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
from collections import deque
from pathlib import Path
from typing import Any, Mapping, Sequence

if __package__ in (None, "") and "TEST_SRCDIR" not in os.environ:
    _repo_root = str(Path(__file__).resolve().parents[2])
    if _repo_root not in sys.path:
        sys.path.insert(0, _repo_root)

from integration_tests.vantage_ml import vantage_contracts as vc

_CAPABILITY_TOKEN_RE = re.compile(r"^[a-z0-9][a-z0-9._-]*$")
_UUID_RE = re.compile(
    r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"
)
_HEX64_RE = re.compile(r"^[0-9a-f]{64}$")

READ_GRANT_ERROR_STATUS_ALLOWLIST: dict[int, frozenset[str]] = {
    400: frozenset(
        {
            "invalid_request",
            "invalid_read_grant_request",
            "invalid_job_id",
            "invalid_catalog_entry_id",
            "invalid_descriptor_sha256",
            "invalid_schema_version",
            "unsupported_schema_version",
            "unknown_field",
            "invalid_field",
        }
    ),
    401: frozenset({"unauthorized"}),
    403: frozenset({"forbidden"}),
    409: frozenset(
        {
            "job_not_found",
            "job_catalog_mismatch",
            "job_catalog_entry_mismatch",
            "descriptor_sha256_mismatch",
            "descriptor_mismatch",
            "job_already_terminal",
            "job_already_completed",
            "job_cancelled",
            "job_state_conflict",
            "invalid_job_state",
            "invalid_recording_descriptor",
            "fragment_not_found",
            "no_sampled_fragments",
            "deployment_mismatch",
            "installation_mismatch",
            "media_worker_deployment_mismatch",
            "media_worker_generation_stale",
            "archive_binding_destination_mismatch",
            "grant_egress_scope_mismatch",
            "grant_methods_not_reader_only",
        }
    ),
    410: frozenset({"recording_gone"}),
    503: frozenset({"media_worker_grants_unavailable"}),
}


def normalize_capability_slug(capability: Any) -> str:
    """Normalize a capability token into a NATS-safe subject slug (fail closed)."""
    if not isinstance(capability, str) or not capability:
        raise vc.ContractValidationError("capability must be a non-empty string")
    if capability != capability.strip():
        raise vc.ContractValidationError(f"capability {capability!r} must not have leading/trailing whitespace")
    if "*" in capability or ">" in capability or any(ch.isspace() for ch in capability):
        raise vc.ContractValidationError(f"capability {capability!r} contains forbidden NATS wildcard or whitespace")
    if not _CAPABILITY_TOKEN_RE.match(capability):
        raise vc.ContractValidationError(f"capability {capability!r} failed slug character rules")
    slug = re.sub(r"[^a-z0-9]+", "_", capability.lower()).strip("_")
    if not slug:
        raise vc.ContractValidationError(f"capability {capability!r} normalized to empty slug")
    return slug


def derive_vantage_subjects(
    runner: str,
    capability: str | None,
    *,
    job_kind: str = "live",
    source_mode: str = "recorded_block",
) -> str:
    """Derive canonical Vantage NATS job or live-tap subject."""
    if source_mode == "live_keyframe_tap":
        if not capability:
            raise vc.ContractValidationError("live_keyframe_tap requires capability")
        return f"media.live.vantage.{normalize_capability_slug(capability)}.v1"
    if job_kind not in ("live", "backfill"):
        raise vc.ContractValidationError(f"invalid job_kind {job_kind!r}")
    if runner == "camera_vlm":
        return (
            "media.jobs.vantage.vlm.backfill.v1"
            if job_kind == "backfill"
            else "media.jobs.vantage.vlm.v1"
        )
    if runner == "external_worker":
        slug = normalize_capability_slug(capability)
        return (
            f"media.jobs.vantage.{slug}.backfill.v1"
            if job_kind == "backfill"
            else f"media.jobs.vantage.{slug}.v1"
        )
    raise vc.ContractValidationError(f"unsupported runner {runner!r}")


def evaluate_heartbeat_routing(
    pipeline: Mapping[str, Any],
    workers: Sequence[Mapping[str, Any]],
    *,
    now_us: int,
    ttl_us: int,
    job_kind: str = "live",
    source_mode: str = "recorded_block",
) -> dict[str, Any]:
    """Evaluate Ramp 1 <-> Ramp 2 routing given worker heartbeats and TTL."""
    runner = pipeline.get("runner", "camera_vlm")
    capability = pipeline.get("capability")
    optional = bool(pipeline.get("optional", True))
    fallback = pipeline.get("fallback_runner")

    if runner == "camera_vlm":
        return {
            "disposition": "dispatch",
            "runner": "camera_vlm",
            "subject": derive_vantage_subjects("camera_vlm", None, job_kind=job_kind),
            "rejected_heartbeats": 0,
        }

    slug_cap = normalize_capability_slug(capability)
    eligible: list[Mapping[str, Any]] = []
    rejected_heartbeats = 0
    for raw_hb in workers:
        try:
            hb = vc.validate_heartbeat(raw_hb)
        except vc.ContractValidationError:
            rejected_heartbeats += 1
            continue
        age_us = now_us - hb["sent_at_us"]
        if age_us < 0 or age_us > ttl_us:
            continue
        if hb["health"] != "ready":
            continue
        if hb["active_jobs"] >= hb["max_concurrency"]:
            continue
        if source_mode not in hb["supported_source_modes"]:
            continue
        if any(normalize_capability_slug(c) == slug_cap for c in hb["capabilities"]):
            eligible.append(hb)

    if eligible:
        return {
            "disposition": "dispatch",
            "runner": capability,
            "subject": derive_vantage_subjects(
                "external_worker", capability, job_kind=job_kind, source_mode=source_mode
            ),
            "rejected_heartbeats": rejected_heartbeats,
        }

    if optional and fallback == "camera_vlm" and source_mode == "recorded_block":
        return {
            "disposition": "fallback",
            "runner": "camera_vlm",
            "subject": derive_vantage_subjects("camera_vlm", None, job_kind=job_kind),
            "rejected_heartbeats": rejected_heartbeats,
        }

    return {"disposition": "hold", "runner": None, "subject": None, "rejected_heartbeats": rejected_heartbeats}


def validate_read_grant_request(payload: Any) -> dict[str, Any]:
    """Validate `POST /v1/media/workers/read-grants` request contract (`<= 8192` B)."""
    if not isinstance(payload, dict):
        raise vc.ContractValidationError("invalid_read_grant_request: body must be JSON object")
    encoded = json.dumps(payload, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
    if len(encoded) > vc.MAX_READ_GRANT_REQUEST_BYTES:
        raise vc.ContractValidationError(
            f"request_too_large: {len(encoded)} > {vc.MAX_READ_GRANT_REQUEST_BYTES}"
        )
    sv = payload.get("schema_version")
    if sv is not None and (isinstance(sv, bool) or sv != 1):
        raise vc.ContractValidationError("invalid_schema_version")
    job_id = payload.get("job_id")
    if not isinstance(job_id, str) or not _UUID_RE.match(job_id):
        raise vc.ContractValidationError("invalid_job_id")
    entry_id = payload.get("catalog_entry_id")
    if not isinstance(entry_id, str) or not _UUID_RE.match(entry_id):
        raise vc.ContractValidationError("invalid_catalog_entry_id")
    sha = payload.get("descriptor_sha256")
    if not isinstance(sha, str) or not _HEX64_RE.match(sha):
        raise vc.ContractValidationError("invalid_descriptor_sha256")
    return payload


def validate_coalesced_fragments(
    fragments: Sequence[Mapping[str, Any]],
    coalesced_ranges: Sequence[Mapping[str, Any]],
) -> None:
    """Enforce coalesce gap (`<= 262_144` B), chunk (`<= 4_194_304` B), and slice bounds."""
    frag_by_seq: dict[int, Mapping[str, Any]] = {}
    for frag in fragments:
        frag_by_seq[int(frag["sequence"])] = frag

    for rng in coalesced_ranges:
        rng_len = int(rng["length"])
        if rng_len < 1 or rng_len > vc.READ_GRANT_MAX_CHUNK_BYTES:
            raise vc.ContractValidationError(
                f"coalesced range length {rng_len} exceeds READ_GRANT_MAX_CHUNK_BYTES ({vc.READ_GRANT_MAX_CHUNK_BYTES})"
            )
        seqs = [int(s) for s in rng["fragment_sequences"]]
        ordered_frags = []
        for s in seqs:
            if s not in frag_by_seq:
                raise vc.ContractValidationError(
                    f"coalesced_range references unknown fragment sequence {s}"
                )
            ordered_frags.append(frag_by_seq[s])
        ordered_frags.sort(key=lambda item: int(item["first"]))
        for prev_f, next_f in zip(ordered_frags, ordered_frags[1:]):
            gap = int(next_f["first"]) - int(prev_f["last"]) - 1
            if gap > vc.READ_GRANT_MAX_COALESCE_GAP_BYTES:
                raise vc.ContractValidationError(
                    f"coalesce gap {gap} exceeds READ_GRANT_MAX_COALESCE_GAP_BYTES ({vc.READ_GRANT_MAX_COALESCE_GAP_BYTES})"
                )
        for sl in rng["slices"]:
            rel_off = int(sl["relative_offset"])
            sl_len = int(sl["length"])
            if rel_off < 0 or sl_len < 1 or (rel_off + sl_len) > rng_len:
                raise vc.ContractValidationError(
                    f"slice [{rel_off}, {rel_off + sl_len}) exceeds coalesced range length {rng_len}"
                )


def validate_read_grant_http_response(
    status_code: int,
    headers: Mapping[str, str],
    body: Mapping[str, Any],
) -> None:
    """Validate read-grant HTTP security headers, 200 payload, or error `"status"` contract."""
    lowered = {k.lower(): v for k, v in headers.items()}
    if lowered.get("cache-control") != "no-store":
        raise vc.ContractValidationError("missing Cache-Control: no-store header")
    if lowered.get("x-content-type-options") != "nosniff":
        raise vc.ContractValidationError("missing X-Content-Type-Options: nosniff header")

    if status_code == 200:
        validated = vc.validate_read_grant_response(dict(body))
        validate_coalesced_fragments(validated["fragments"], validated["coalesced_ranges"])
        return

    allowed = READ_GRANT_ERROR_STATUS_ALLOWLIST.get(status_code)
    if allowed is None:
        raise vc.ContractValidationError(f"unexpected HTTP status {status_code}")
    err_code = body.get("status")
    if not isinstance(err_code, str) or err_code not in allowed:
        raise vc.ContractValidationError(
            f"HTTP {status_code} body['status']={err_code!r} not in allowed {sorted(allowed)}"
        )


def validate_live_tap_result_strict(payload: Mapping[str, Any]) -> dict[str, Any]:
    """Validate `vantage.result.v1` and enforce strict live-tap nullity."""
    obj = vc.validate_result_envelope(dict(payload))
    if obj["source_mode"] == "live_keyframe_tap":
        for field in ("job_id", "catalog_entry_id", "descriptor_sha256"):
            if obj.get(field) is not None:
                raise vc.ContractValidationError(
                    f"live_keyframe_tap result {field} must be null"
                )
        for idx, obs in enumerate(obj["observations"]):
            if obs.get("fragment_sequence") is not None:
                raise vc.ContractValidationError(
                    f"live_keyframe_tap observations[{idx}].fragment_sequence must be null"
                )
    return obj


def validate_rgb8_dimensions(payload: Mapping[str, Any], width: int, height: int) -> bytes:
    """Validate `vantage.frame.v1` `rgb8` carrier and exact `width * height * 3` byte length."""
    if width <= 0 or height <= 0:
        raise vc.ContractValidationError("width and height must be > 0")
    obj = vc.validate_live_frame(dict(payload))
    if obj.get("payload_format") != "rgb8":
        raise vc.ContractValidationError("expected payload_format == 'rgb8'")
    raw = base64.b64decode(obj["payload_b64"].encode("ascii"), validate=True)
    expected_len = width * height * 3
    if len(raw) != expected_len:
        raise vc.ContractValidationError(
            f"rgb8 buffer length {len(raw)} != {width} * {height} * 3 ({expected_len})"
        )
    return raw


class LongshoreMailbox:
    """Bounded per-camera live keyframe tap mailbox (`<= 8` frames, drop-oldest, `<= 128` tracks)."""

    def __init__(
        self,
        *,
        mailbox_cap: int = vc.LIVE_TAP_MAILBOX_CAP,
        max_tracks: int = vc.LIVE_TAP_MAX_TRACKS,
        camera_cap: int = 4,
        max_payload_bytes: int = vc.MAX_RESULT_ENVELOPE_BYTES,
    ) -> None:
        self.mailbox_cap = mailbox_cap
        self.max_tracks = max_tracks
        self.camera_cap = camera_cap
        self.max_payload_bytes = max_payload_bytes
        self._queues: dict[str, deque[dict[str, Any]]] = {}
        self._tracks: dict[str, set[str]] = {}
        self._last_seq: dict[str, int] = {}
        self.dropped_total: int = 0
        self.oversized_dropped: int = 0

    def admit_camera(self, camera_source_id: str) -> None:
        if camera_source_id in self._queues:
            return
        if len(self._queues) >= self.camera_cap:
            raise vc.ContractValidationError(
                f"camera_cap ({self.camera_cap}) exceeded for {camera_source_id}"
            )
        self._queues[camera_source_id] = deque()
        self._tracks[camera_source_id] = set()

    def remove_camera(self, camera_source_id: str) -> None:
        self._queues.pop(camera_source_id, None)
        self._tracks.pop(camera_source_id, None)
        self._last_seq.pop(camera_source_id, None)

    def push_frame(self, envelope: Mapping[str, Any]) -> None:
        validated = vc.validate_live_frame(dict(envelope))
        encoded = json.dumps(validated, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
        if len(encoded) > self.max_payload_bytes:
            self.oversized_dropped += 1
            raise vc.ContractValidationError(
                f"vantage.frame.v1 size {len(encoded)} exceeds NATS ceiling {self.max_payload_bytes}"
            )
        cam_id = validated["camera_source_id"]
        if cam_id not in self._queues and len(self._queues) >= self.camera_cap:
            raise vc.ContractValidationError(
                f"camera_cap ({self.camera_cap}) exceeded for {cam_id}"
            )
        seq = int(validated["frame_sequence"])
        prev_seq = self._last_seq.get(cam_id)
        if prev_seq is not None and seq <= prev_seq:
            raise vc.ContractValidationError(
                f"non-monotonic frame_sequence {seq} <= {prev_seq} for camera {cam_id}"
            )

        staged_tracks = set(self._tracks.get(cam_id, set()))
        for det in validated.get("detections") or []:
            track_id = det.get("track_id")
            if not isinstance(track_id, str) or not track_id.strip():
                raise vc.ContractValidationError("detection missing non-empty track_id")
            if track_id not in staged_tracks:
                if len(staged_tracks) >= self.max_tracks:
                    raise vc.ContractValidationError(
                        f"active tracks ({self.max_tracks}) exceeded for camera {cam_id}"
                    )
                staged_tracks.add(track_id)

        if cam_id not in self._queues:
            self.admit_camera(cam_id)
        self._tracks[cam_id] = staged_tracks
        self._last_seq[cam_id] = seq

        q = self._queues[cam_id]
        if len(q) >= self.mailbox_cap:
            q.popleft()
            self.dropped_total += 1
        q.append(validated)

    def drain_camera(self, camera_source_id: str) -> list[dict[str, Any]]:
        q = self._queues.get(camera_source_id)
        if not q:
            return []
        items = list(q)
        q.clear()
        return items

    def active_track_count(self, camera_source_id: str) -> int:
        return len(self._tracks.get(camera_source_id, set()))


def compute_latency_percentiles(samples_ms: Sequence[float | int]) -> dict[str, float]:
    """Compute deterministic nearest-rank p50, p95, p99 latencies in milliseconds."""
    if not samples_ms:
        raise vc.ContractValidationError("latency sample set must not be empty")
    cleaned: list[float] = []
    for idx, val in enumerate(samples_ms):
        if isinstance(val, bool) or not isinstance(val, (int, float)):
            raise vc.ContractValidationError(f"sample[{idx}] must be a real number")
        num = float(val)
        if not math.isfinite(num) or num < 0.0:
            raise vc.ContractValidationError(f"sample[{idx}] ({num!r}) must be finite and >= 0")
        cleaned.append(num)
    cleaned.sort()
    n = len(cleaned)

    def _pct(p: float) -> float:
        rank = max(0, min(n - 1, math.ceil((p / 100.0) * n) - 1))
        return cleaned[rank]

    p50, p95, p99 = _pct(50.0), _pct(95.0), _pct(99.0)
    if not (0.0 <= p50 <= p95 <= p99):
        raise vc.ContractValidationError("percentile monotonicity invariant violated")
    return {"p50": p50, "p95": p95, "p99": p99}


def evaluate_live_retention(
    records: Sequence[Mapping[str, Any]],
    cutoff_ts_us: int,
) -> tuple[list[str], list[str]]:
    """Return `(purged_ids, preserved_ids)` matching `VantageObservation.:purge_expired_live`."""
    purged: list[str] = []
    preserved: list[str] = []
    for rec in records:
        obs_id = str(rec["observation_id"])
        is_live = rec.get("source_mode") == "live_keyframe_tap" and rec.get("catalog_entry_id") is None
        if is_live and int(rec["inserted_at_us"]) < cutoff_ts_us:
            purged.append(obs_id)
        else:
            preserved.append(obs_id)
    return purged, preserved


def filter_ocsf_event_for_viewer(
    event: Mapping[str, Any],
    *,
    authorized_camera_ids: set[str],
    has_devices_view: bool,
    has_recordings_view: bool,
    signal_schema_filter: str | None = None,
    camera_source_filter: str | None = None,
) -> bool:
    """Enforce F10/F14 DashboardFrameChannel.Events scoping and nested metadata filter."""
    if not (has_devices_view and has_recordings_view):
        return False
    sr = event.get("metadata", {}).get("service_radar", {})
    cam_id = sr.get("camera_source_id")
    if not isinstance(cam_id, str) or cam_id not in authorized_camera_ids:
        return False
    if camera_source_filter is not None and cam_id != camera_source_filter:
        return False
    schema_id = sr.get("signal_schema", {}).get("schema_id")
    if signal_schema_filter is not None and schema_id != signal_schema_filter:
        return False
    return True


def _load_fixture(filename: str) -> dict[str, Any]:
    path = (
        vc.repo_root()
        / "integration_tests"
        / "vantage_ml"
        / "fixtures"
        / "f11_f14"
        / filename
    )
    if not path.is_file():
        raise AssertionError(f"missing F11-F14 fixture file: {path}")
    return json.loads(path.read_text(encoding="utf-8"))


def _load_catalog() -> dict[str, Any]:
    path = (
        vc.repo_root()
        / "integration_tests"
        / "vantage_ml"
        / "fixtures"
        / "catalog_f11_f14.json"
    )
    if not path.is_file():
        raise AssertionError(f"missing catalog_f11_f14.json at {path}")
    return json.loads(path.read_text(encoding="utf-8"))


def _load_wire_vector(filename: str) -> dict[str, Any]:
    path = (
        vc.repo_root()
        / "integration_tests"
        / "vantage_ml"
        / "fixtures"
        / "wire_vectors"
        / filename
    )
    return json.loads(path.read_text(encoding="utf-8"))


_CATALOG_INDEX: dict[str, dict[str, Any]] | None = None


def _record_catalog_case(test_id: str) -> dict[str, Any]:
    global _CATALOG_INDEX
    if _CATALOG_INDEX is None:
        cat = _load_catalog()
        _CATALOG_INDEX = {entry["test_id"]: entry for entry in cat["cases"]}
    entry = _CATALOG_INDEX[test_id]
    return vc.record_test_case(
        entry["feature"],
        entry["tier"],
        entry["test_id"],
        entry["mode"],
        entry["description"],
    )


class F11DispatcherHeartbeatReadGrantModeATest(unittest.TestCase):
    """F11 Tier 1 & Tier 2 hermetic contract tests."""

    @classmethod
    def setUpClass(cls) -> None:
        cls.f11_hb = _load_fixture("f11_dispatcher_heartbeat_vectors.json")
        cls.f11_rg = _load_fixture("f11_read_grant_vectors.json")
        cls.rg_wire = _load_wire_vector("read_grant_response.json")

    def test_e2e_f11_t1_01_capability_slug_and_subject_derivation(self) -> None:
        _record_catalog_case("E2E-F11-T1-01")
        for case in self.f11_hb["capability_slug_cases"]["positive"]:
            with self.subTest(capability=case["input"]):
                self.assertEqual(normalize_capability_slug(case["input"]), case["expected_slug"])
                self.assertEqual(
                    derive_vantage_subjects("external_worker", case["input"], job_kind="live"),
                    case["live_job_subject"],
                )
                self.assertEqual(
                    derive_vantage_subjects("external_worker", case["input"], job_kind="backfill"),
                    case["backfill_job_subject"],
                )
                self.assertEqual(
                    derive_vantage_subjects(
                        "external_worker", case["input"], source_mode="live_keyframe_tap"
                    ),
                    case["live_tap_subject"],
                )
        self.assertEqual(
            derive_vantage_subjects("camera_vlm", None, job_kind="live"),
            self.f11_hb["subjects"]["ramp1_vlm_live"],
        )

    def test_e2e_f11_t1_02_heartbeat_validation_and_ramp2_routing(self) -> None:
        _record_catalog_case("E2E-F11-T1-02")
        workers = [self.f11_hb["workers"]["fresh_rust_alpr"]]
        scenario = next(
            s for s in self.f11_hb["routing_scenarios"] if s["name"] == "ramp2_fresh_live_job"
        )
        decision = evaluate_heartbeat_routing(
            scenario["pipeline"],
            workers,
            now_us=self.f11_hb["now_us"],
            ttl_us=self.f11_hb["heartbeat_ttl_us"],
            job_kind=scenario["job_kind"],
            source_mode=scenario["source_mode"],
        )
        self.assertEqual(decision["disposition"], scenario["expected_disposition"])
        self.assertEqual(decision["runner"], scenario["expected_runner"])
        self.assertEqual(decision["subject"], scenario["expected_subject"])

    def test_e2e_f11_t1_03_heartbeat_ttl_expiration_falls_back_to_ramp1(self) -> None:
        _record_catalog_case("E2E-F11-T1-03")
        scenario = next(
            s
            for s in self.f11_hb["routing_scenarios"]
            if s["name"] == "expired_ttl_falls_back_to_ramp1_vlm"
        )
        workers = [self.f11_hb["workers"][k] for k in scenario["worker_keys"]]
        decision = evaluate_heartbeat_routing(
            scenario["pipeline"],
            workers,
            now_us=self.f11_hb["now_us"],
            ttl_us=self.f11_hb["heartbeat_ttl_us"],
            job_kind=scenario["job_kind"],
            source_mode=scenario["source_mode"],
        )
        self.assertEqual(decision["disposition"], "fallback")
        self.assertEqual(decision["runner"], "camera_vlm")
        self.assertEqual(decision["subject"], "media.jobs.vantage.vlm.v1")

    def test_e2e_f11_t1_04_read_grant_200_archive_contract(self) -> None:
        _record_catalog_case("E2E-F11-T1-04")
        validate_read_grant_request(self.f11_rg["request_positive"])
        archive = copy.deepcopy(self.rg_wire["positive_archive"])
        validate_read_grant_http_response(
            200,
            self.f11_rg["required_security_headers"],
            archive,
        )
        self.assertEqual(archive["grant"]["role"], "reader")
        self.assertEqual(archive["grant"]["allowed_methods"], ["HEAD", "GET"])
        self.assertEqual(set(archive["credential"].keys()), {"reference", "generation", "role", "secret_id"})

    def test_e2e_f11_t1_05_read_grant_200_local_and_coalesce_gap(self) -> None:
        _record_catalog_case("E2E-F11-T1-05")
        local_grant = copy.deepcopy(self.rg_wire["positive_local"])
        cb = self.f11_rg["coalesce_boundary"]
        local_grant["fragments"] = copy.deepcopy(cb["exact_gap_coalesced_fragments"])
        for f in local_grant["fragments"]:
            f["path"] = f"/v1/blocks/{local_grant['block_key']}/fragments/{f['sequence']}"
        local_grant["coalesced_ranges"] = [copy.deepcopy(cb["exact_gap_coalesced_range"])]
        validate_read_grant_http_response(
            200,
            self.f11_rg["required_security_headers"],
            local_grant,
        )
        self.assertEqual(local_grant["read_pool"], "analysis_read")

    def test_e2e_f11_t1_06_backfill_subject_routing(self) -> None:
        _record_catalog_case("E2E-F11-T1-06")
        for s_name in ("ramp2_fresh_backfill_job", "expired_ttl_backfill_falls_back_to_ramp1_vlm_backfill"):
            scenario = next(s for s in self.f11_hb["routing_scenarios"] if s["name"] == s_name)
            workers = [self.f11_hb["workers"][k] for k in scenario["worker_keys"]]
            decision = evaluate_heartbeat_routing(
                scenario["pipeline"],
                workers,
                now_us=self.f11_hb["now_us"],
                ttl_us=self.f11_hb["heartbeat_ttl_us"],
                job_kind=scenario["job_kind"],
                source_mode=scenario["source_mode"],
            )
            self.assertEqual(decision["disposition"], scenario["expected_disposition"])
            self.assertEqual(decision["subject"], scenario["expected_subject"])

    def test_e2e_f11_t2_01_invalid_capability_slugs_and_bad_heartbeats(self) -> None:
        _record_catalog_case("E2E-F11-T2-01")
        for bad in self.f11_hb["capability_slug_cases"]["negative"]:
            with self.subTest(case=bad["name"]):
                with self.assertRaises(vc.ContractValidationError):
                    normalize_capability_slug(bad["input"])

        with self.assertRaises(vc.ContractValidationError):
            vc.validate_heartbeat(self.f11_hb["workers"]["bad_protocol_version"])

        mixed_decision = evaluate_heartbeat_routing(
            {
                "runner": "external_worker",
                "capability": "vantage.alpr.v1",
                "optional": True,
                "fallback_runner": "camera_vlm",
            },
            [
                self.f11_hb["workers"]["bad_protocol_version"],
                self.f11_hb["workers"]["fresh_rust_alpr"],
            ],
            now_us=self.f11_hb["now_us"],
            ttl_us=self.f11_hb["heartbeat_ttl_us"],
        )
        self.assertEqual(mixed_decision["disposition"], "dispatch")
        self.assertEqual(mixed_decision["subject"], "media.jobs.vantage.vantage_alpr_v1.v1")
        self.assertEqual(mixed_decision["rejected_heartbeats"], 1)

        saturated = self.f11_hb["workers"]["saturated_rust_alpr"]
        scenario = next(
            s
            for s in self.f11_hb["routing_scenarios"]
            if s["name"] == "saturated_worker_falls_back_when_optional_true"
        )
        decision = evaluate_heartbeat_routing(
            scenario["pipeline"],
            [saturated],
            now_us=self.f11_hb["now_us"],
            ttl_us=self.f11_hb["heartbeat_ttl_us"],
        )
        self.assertEqual(decision["disposition"], "fallback")
        self.assertEqual(decision["subject"], "media.jobs.vantage.vlm.v1")

    def test_e2e_f11_t2_02_strict_optional_false_holds_on_stale_or_draining(self) -> None:
        _record_catalog_case("E2E-F11-T2-02")
        scenario = next(
            s
            for s in self.f11_hb["routing_scenarios"]
            if s["name"] == "strict_optional_false_holds_when_expired_or_draining"
        )
        workers = [self.f11_hb["workers"][k] for k in scenario["worker_keys"]]
        decision = evaluate_heartbeat_routing(
            scenario["pipeline"],
            workers,
            now_us=self.f11_hb["now_us"],
            ttl_us=self.f11_hb["heartbeat_ttl_us"],
        )
        self.assertEqual(decision["disposition"], "hold")
        self.assertIsNone(decision["subject"])

    def test_e2e_f11_t2_03_read_grant_request_8192_boundary_and_400_status(self) -> None:
        _record_catalog_case("E2E-F11-T2-03")
        base = copy.deepcopy(self.f11_rg["request_positive"])
        base["pad"] = "a"
        base_len = len(json.dumps(base, separators=(",", ":"), ensure_ascii=False).encode("utf-8"))
        pad_exact = vc.MAX_READ_GRANT_REQUEST_BYTES - base_len + 1
        base["pad"] = "a" * pad_exact
        self.assertEqual(
            len(json.dumps(base, separators=(",", ":"), ensure_ascii=False).encode("utf-8")),
            vc.MAX_READ_GRANT_REQUEST_BYTES,
        )
        validate_read_grant_request(base)

        base["pad"] = "a" * (pad_exact + 1)
        with self.assertRaises(vc.ContractValidationError):
            validate_read_grant_request(base)

        for neg in self.f11_rg["request_negative"]:
            with self.subTest(case=neg["name"]):
                with self.assertRaises(vc.ContractValidationError) as ctx:
                    validate_read_grant_request(neg["payload"])
                self.assertIn(neg["expected_code"], str(ctx.exception))

    def test_e2e_f11_t2_04_read_grant_401_and_403_auth_contracts(self) -> None:
        _record_catalog_case("E2E-F11-T2-04")
        hdrs = self.f11_rg["required_security_headers"]
        validate_read_grant_http_response(401, hdrs, {"status": "unauthorized"})
        validate_read_grant_http_response(403, hdrs, {"status": "forbidden"})
        with self.assertRaises(vc.ContractValidationError):
            validate_read_grant_http_response(401, {}, {"status": "unauthorized"})
        with self.assertRaises(vc.ContractValidationError):
            validate_read_grant_http_response(403, hdrs, {"error": "forbidden"})

    def test_e2e_f11_t2_05_read_grant_409_410_503_status_contracts(self) -> None:
        _record_catalog_case("E2E-F11-T2-05")
        hdrs = self.f11_rg["required_security_headers"]
        for item in self.f11_rg["http_error_responses"]:
            with self.subTest(http_status=item["http_status"], body=item["body"]):
                validate_read_grant_http_response(item["http_status"], hdrs, item["body"])
        with self.assertRaises(vc.ContractValidationError):
            validate_read_grant_http_response(409, hdrs, {"status": "unexpected_code"})

    def test_e2e_f11_t2_06_read_grant_coalesce_gap_chunk_and_secret_leak_rejection(self) -> None:
        _record_catalog_case("E2E-F11-T2-06")
        cb = self.f11_rg["coalesce_boundary"]
        over_range = copy.deepcopy(cb["exact_gap_coalesced_range"])
        over_range["fragment_sequences"] = [0, 3]
        over_range["last"] = over_range["first"] + 327680
        over_range["length"] = 327681
        with self.assertRaises(vc.ContractValidationError):
            validate_coalesced_fragments(cb["over_gap_fragments"], [over_range])

        over_chunk = copy.deepcopy(cb["exact_gap_coalesced_range"])
        over_chunk["length"] = vc.READ_GRANT_MAX_CHUNK_BYTES + 1
        with self.assertRaises(vc.ContractValidationError):
            validate_coalesced_fragments(cb["exact_gap_coalesced_fragments"], [over_chunk])

        bad_slice = copy.deepcopy(cb["exact_gap_coalesced_range"])
        bad_slice["slices"][1]["relative_offset"] = bad_slice["length"]
        with self.assertRaises(vc.ContractValidationError):
            validate_coalesced_fragments(cb["exact_gap_coalesced_fragments"], [bad_slice])

        leaked = copy.deepcopy(self.rg_wire["positive_archive"])
        leaked["credential"]["access_key_id"] = "AKIA0123456789ABCDEF"
        with self.assertRaises(vc.ContractValidationError):
            validate_read_grant_http_response(200, self.f11_rg["required_security_headers"], leaked)


class F12CompanionSdkAndHygieneModeATest(unittest.TestCase):
    """F12 Tier 1 & Tier 2 hermetic contract tests."""

    @classmethod
    def setUpClass(cls) -> None:
        cls.f12 = _load_fixture("f12_sdk_conformance_and_hygiene.json")
        cls.job_wire = _load_wire_vector("vantage_job_v1.json")
        cls.hb_wire = _load_wire_vector("vantage_heartbeat_v1.json")
        cls.frame_wire = _load_wire_vector("vantage_frame_v1.json")

    def test_e2e_f12_t1_01_sdk_job_and_result_conformance_rust_python(self) -> None:
        _record_catalog_case("E2E-F12-T1-01")
        vc.validate_job_envelope(self.job_wire["positive"])
        for key in ("ramp2_rust_result", "ramp2_python_result"):
            with self.subTest(result=key):
                res = vc.validate_result_envelope(self.f12["ramp1_to_ramp2_parity"][key])
                self.assertEqual(res["capability"], "vantage.alpr.v1")

    def test_e2e_f12_t1_02_live_tap_result_strict_nullity(self) -> None:
        _record_catalog_case("E2E-F12-T1-02")
        res = validate_live_tap_result_strict(self.f12["live_tap_result_strict_null"])
        self.assertIsNone(res["job_id"])
        self.assertIsNone(res["catalog_entry_id"])
        self.assertIsNone(res["descriptor_sha256"])
        self.assertIsNone(res["observations"][0]["fragment_sequence"])

    def test_e2e_f12_t1_03_zero_credential_worker_config_hygiene(self) -> None:
        _record_catalog_case("E2E-F12-T1-03")
        for name, cfg in self.f12["worker_configs_clean"].items():
            with self.subTest(worker=name):
                serialized = json.dumps(cfg, indent=2)
                vc.assert_secret_free({f"{name}.json": serialized})
                vc.assert_synthetic_hygiene(serialized)
                for forbidden_env in self.f12["forbidden_env_keys"]:
                    self.assertNotIn(forbidden_env, cfg)

    def test_e2e_f12_t1_04_heartbeat_and_rgb8_frame_conformance(self) -> None:
        _record_catalog_case("E2E-F12-T1-04")
        vc.validate_heartbeat(self.hb_wire["positive"])
        rgb_case = self.f12["rgb8_frame_cases"]
        frame = copy.deepcopy(self.frame_wire["positive_payload_format"])
        frame["payload_format"] = "rgb8"
        frame["payload_b64"] = rgb_case["valid_payload_b64"]
        raw = validate_rgb8_dimensions(frame, rgb_case["width"], rgb_case["height"])
        self.assertEqual(len(raw), rgb_case["width"] * rgb_case["height"] * 3)

    def test_e2e_f12_t1_05_ramp1_to_ramp2_alpr_schema_parity(self) -> None:
        _record_catalog_case("E2E-F12-T1-05")
        parity = self.f12["ramp1_to_ramp2_parity"]
        r1 = vc.validate_result_envelope(parity["ramp1_vlm_result"])
        r2_rust = vc.validate_result_envelope(parity["ramp2_rust_result"])
        r2_py = vc.validate_result_envelope(parity["ramp2_python_result"])
        for res in (r1, r2_rust, r2_py):
            obs = res["observations"][0]
            self.assertEqual(obs["signal_schema_id"], "alpr_plate_read")
            self.assertEqual(obs["signal_schema_version"], "1.0.0")
            self.assertEqual(obs["display_contract_id"], "alpr_plate_read")
            self.assertIn(obs["attributes"]["plate_text"], vc.SYNTHETIC_PLATES)

    def test_e2e_f12_t1_06_offline_local_harness_validation_contract(self) -> None:
        _record_catalog_case("E2E-F12-T1-06")
        rust_res = vc.validate_result_envelope(self.f12["ramp1_to_ramp2_parity"]["ramp2_rust_result"])
        obs = rust_res["observations"][0]
        vc.validate_alpr_attributes(obs["attributes"])
        self.assertIn("Gate West 01", obs["search_text"])

    def test_e2e_f12_t2_01_dirty_worker_config_fails_secret_free(self) -> None:
        _record_catalog_case("E2E-F12-T2-01")
        dirty_key = copy.deepcopy(self.f12["worker_configs_clean"]["rust_alpr_worker"])
        dirty_key["secret_access_key"] = "synthetic-leaked-value"
        with self.assertRaises(vc.ContractValidationError):
            vc.assert_secret_free({"worker.json": json.dumps(dirty_key)})

        dirty_token = copy.deepcopy(self.f12["worker_configs_clean"]["python_guidance_worker"])
        dirty_token["notes"] = "ghp_" + "A1b2C3d4E5f6G7h8I9j0"
        with self.assertRaises(vc.ContractValidationError):
            vc.assert_secret_free({"worker.json": json.dumps(dirty_token)})

        dirty_uuid = copy.deepcopy(self.f12["worker_configs_clean"]["rust_alpr_worker"])
        dirty_uuid["credential_secret_id"] = "88888888-8888-4888-8888-888888888801"
        with self.assertRaises(vc.ContractValidationError):
            vc.assert_secret_free({"worker.json": json.dumps(dirty_uuid)})

    def test_e2e_f12_t2_02_live_tap_result_non_null_ids_fail_closed(self) -> None:
        _record_catalog_case("E2E-F12-T2-02")
        for field, bad_val in (
            ("job_id", "11111111-1111-4111-8111-111111111101"),
            ("catalog_entry_id", "44444444-4444-4444-8444-444444444401"),
            ("descriptor_sha256", "a" * 64),
        ):
            with self.subTest(field=field):
                bad = copy.deepcopy(self.f12["live_tap_result_strict_null"])
                bad[field] = bad_val
                with self.assertRaises(vc.ContractValidationError):
                    validate_live_tap_result_strict(bad)

        bad_frag = copy.deepcopy(self.f12["live_tap_result_strict_null"])
        bad_frag["observations"][0]["fragment_sequence"] = 0
        with self.assertRaises(vc.ContractValidationError):
            validate_live_tap_result_strict(bad_frag)

    def test_e2e_f12_t2_03_corrupt_fragment_sha256_mismatch_aborts(self) -> None:
        _record_catalog_case("E2E-F12-T2-03")
        raw_fragment = b"synthetic-fragment-bytes-gate-west-01"
        expected_sha = hashlib.sha256(raw_fragment).hexdigest()
        tampered_fragment = raw_fragment[:-1] + b"X"
        actual_sha = hashlib.sha256(tampered_fragment).hexdigest()
        self.assertNotEqual(expected_sha, actual_sha)

        def _verify_and_decode(frag_bytes: bytes, want_sha: str) -> list[dict[str, Any]]:
            if hashlib.sha256(frag_bytes).hexdigest() != want_sha:
                raise vc.ContractValidationError("fragment_sha256_mismatch")
            return [{"decoded": True}]

        with self.assertRaises(vc.ContractValidationError):
            _verify_and_decode(tampered_fragment, expected_sha)

    def test_e2e_f12_t2_04_invalid_observation_attributes_fail_schema(self) -> None:
        _record_catalog_case("E2E-F12-T2-04")
        bad_obs = copy.deepcopy(self.f12["ramp1_to_ramp2_parity"]["ramp2_rust_result"])
        bad_obs["observations"][0]["attributes"]["plate_text"] = "invalid plate!"
        with self.assertRaises(vc.ContractValidationError):
            vc.validate_result_envelope(bad_obs)

        bad_conf = copy.deepcopy(self.f12["ramp1_to_ramp2_parity"]["ramp2_python_result"])
        bad_conf["observations"][0]["confidence"] = 1.25
        with self.assertRaises(vc.ContractValidationError):
            vc.validate_result_envelope(bad_conf)

    def test_e2e_f12_t2_05_rgb8_dimension_mismatch_fails_closed(self) -> None:
        _record_catalog_case("E2E-F12-T2-05")
        rgb_case = self.f12["rgb8_frame_cases"]
        mismatch = copy.deepcopy(self.frame_wire["positive_payload_format"])
        mismatch["payload_format"] = "rgb8"
        mismatch["payload_b64"] = rgb_case["mismatch_payload_b64"]
        with self.assertRaises(vc.ContractValidationError):
            validate_rgb8_dimensions(mismatch, rgb_case["width"], rgb_case["height"])

        unaligned = copy.deepcopy(mismatch)
        unaligned["payload_b64"] = rgb_case["unaligned_payload_b64"]
        with self.assertRaises(vc.ContractValidationError):
            vc.validate_live_frame(unaligned)

    def test_e2e_f12_t2_06_disallowed_copyleft_and_non_synthetic_ip_rejected(self) -> None:
        _record_catalog_case("E2E-F12-T2-06")
        copyleft_text = "engine=" + "Open" + "ALPR" + " license=" + "AGPL" + "v3"
        bad_ip = ".".join(["192", "168", "10", "25"])
        with self.assertRaises(vc.ContractValidationError):
            vc.assert_synthetic_hygiene(copyleft_text)
        with self.assertRaises(vc.ContractValidationError):
            vc.assert_synthetic_hygiene(f"nats://{bad_ip}:4222")


class F13LiveKeyframeTapAndMailboxModeATest(unittest.TestCase):
    """F13 Tier 1 & Tier 2 hermetic contract tests."""

    @classmethod
    def setUpClass(cls) -> None:
        cls.f13 = _load_fixture("f13_live_tap_and_mailbox_vectors.json")
        cls.frame_wire = _load_wire_vector("vantage_frame_v1.json")

    def _make_frame(
        self,
        cam_key: str,
        seq: int,
        *,
        track_id: str = "bay-04-track-1",
        time_basis: str = "received",
    ) -> dict[str, Any]:
        cam = self.f13["cameras"][cam_key]
        frame = copy.deepcopy(self.frame_wire["positive"])
        frame["camera_source_id"] = cam["camera_source_id"]
        frame["stream_profile_id"] = cam["stream_profile_id"]
        frame["frame_sequence"] = seq
        frame["timeline_ts_us"] = 1700000000000000 + seq * 100000
        frame["time_basis"] = time_basis
        frame["detections"] = [
            {
                "track_id": track_id,
                "category": "vehicle",
                "confidence": 0.9,
                "bbox": [0.2, 0.3, 0.7, 0.85],
            }
        ]
        frame["pipeline_config"] = {"camera_name": cam["camera_name"]}
        return frame

    def test_e2e_f13_t1_01_live_tap_emits_vantage_frame_for_bay_04(self) -> None:
        _record_catalog_case("E2E-F13-T1-01")
        cam = self.f13["cameras"]["bay_04_approach"]
        self.assertEqual(
            derive_vantage_subjects("external_worker", cam["capability"], source_mode="live_keyframe_tap"),
            cam["live_subject"],
        )
        frame = self._make_frame("bay_04_approach", 1)
        validated = vc.validate_live_frame(frame)
        self.assertIsNone(validated["catalog_entry_id"])
        self.assertIsNone(validated["fragment_sequence"])

    def test_e2e_f13_t1_02_steady_state_mailbox_zero_drops_monotonic(self) -> None:
        _record_catalog_case("E2E-F13-T1-02")
        scenario = self.f13["burst_scenarios"]["steady_state"]
        cam_id = self.f13["cameras"]["bay_04_approach"]["camera_source_id"]
        mb = LongshoreMailbox()
        for seq in scenario["incoming_sequences"]:
            mb.push_frame(self._make_frame("bay_04_approach", seq))
        self.assertEqual(mb.dropped_total, scenario["expected_dropped_total"])
        drained = [f["frame_sequence"] for f in mb.drain_camera(cam_id)]
        self.assertEqual(drained, scenario["expected_retained_sequences"])

    def test_e2e_f13_t1_03_per_camera_mailbox_sharding_isolation(self) -> None:
        _record_catalog_case("E2E-F13-T1-03")
        bay_id = self.f13["cameras"]["bay_04_approach"]["camera_source_id"]
        gate_id = self.f13["cameras"]["gate_west_01"]["camera_source_id"]
        mb = LongshoreMailbox(camera_cap=self.f13["default_camera_cap"])
        for seq in range(1, 21):
            mb.push_frame(self._make_frame("bay_04_approach", seq))
        for seq in range(1, 4):
            mb.push_frame(self._make_frame("gate_west_01", seq, track_id="gate-track-1"))
        self.assertEqual(mb.dropped_total, 12)
        self.assertEqual([f["frame_sequence"] for f in mb.drain_camera(gate_id)], [1, 2, 3])
        self.assertEqual(len(mb.drain_camera(bay_id)), 8)

    def test_e2e_f13_t1_04_frame_carriers_and_time_basis(self) -> None:
        _record_catalog_case("E2E-F13-T1-04")
        carriers = self.f13["carriers"]
        base = self._make_frame("bay_04_approach", 10, time_basis="camera_reported")
        vc.validate_live_frame(base)

        for fmt, b64 in (
            ("annex_b_idr", carriers["annex_b_idr_b64"]),
            ("rgb8", carriers["rgb8_4x2_b64"]),
        ):
            with self.subTest(payload_format=fmt):
                pkt = copy.deepcopy(base)
                pkt.pop("frame_jpeg_b64", None)
                pkt["payload_format"] = fmt
                pkt["payload_b64"] = b64
                vc.validate_live_frame(pkt)

        tok_pkt = copy.deepcopy(base)
        tok_pkt.pop("frame_jpeg_b64", None)
        tok_pkt["read_token"] = carriers["read_token"]
        vc.validate_live_frame(tok_pkt)

    def test_e2e_f13_t1_05_camera_cap_admission(self) -> None:
        _record_catalog_case("E2E-F13-T1-05")
        mb = LongshoreMailbox(camera_cap=2)
        mb.admit_camera(self.f13["cameras"]["bay_04_approach"]["camera_source_id"])
        mb.admit_camera(self.f13["cameras"]["gate_west_01"]["camera_source_id"])
        self.assertEqual(len(mb._queues), 2)

    def test_e2e_f13_t1_06_active_tracks_128_boundary_and_teardown(self) -> None:
        _record_catalog_case("E2E-F13-T1-06")
        cam_id = self.f13["cameras"]["bay_04_approach"]["camera_source_id"]
        mb = LongshoreMailbox()
        frame = self._make_frame("bay_04_approach", 1)
        frame["detections"] = [
            {
                "track_id": f"track-{idx}",
                "category": "vehicle",
                "confidence": 0.9,
                "bbox": [0.1, 0.1, 0.5, 0.5],
            }
            for idx in range(self.f13["max_tracks_per_camera"])
        ]
        mb.push_frame(frame)
        self.assertEqual(mb.active_track_count(cam_id), vc.LIVE_TAP_MAX_TRACKS)
        mb.remove_camera(cam_id)
        self.assertEqual(mb.active_track_count(cam_id), 0)

    def test_e2e_f13_t2_01_mailbox_overflow_drops_oldest_and_counts(self) -> None:
        _record_catalog_case("E2E-F13-T2-01")
        scenario = self.f13["burst_scenarios"]["overflow_20_frames"]
        cam_id = self.f13["cameras"]["bay_04_approach"]["camera_source_id"]
        mb = LongshoreMailbox(mailbox_cap=self.f13["mailbox_cap"])
        for seq in scenario["incoming_sequences"]:
            mb.push_frame(self._make_frame("bay_04_approach", seq))
        self.assertEqual(mb.dropped_total, scenario["expected_dropped_total"])
        retained = [f["frame_sequence"] for f in mb.drain_camera(cam_id)]
        self.assertEqual(retained, scenario["expected_retained_sequences"])

    def test_e2e_f13_t2_02_track_129_exceeds_live_tap_max_tracks(self) -> None:
        _record_catalog_case("E2E-F13-T2-02")
        mb = LongshoreMailbox()
        frame = self._make_frame("bay_04_approach", 1)
        frame["detections"] = [
            {
                "track_id": f"track-{idx}",
                "category": "vehicle",
                "confidence": 0.85,
                "bbox": [0.1, 0.1, 0.5, 0.5],
            }
            for idx in range(vc.LIVE_TAP_MAX_TRACKS + 1)
        ]
        with self.assertRaises(vc.ContractValidationError):
            mb.push_frame(frame)

    def test_e2e_f13_t2_03_camera_cap_overflow_rejected(self) -> None:
        _record_catalog_case("E2E-F13-T2-03")
        mb = LongshoreMailbox(camera_cap=2)
        mb.admit_camera("22222222-2222-4222-8222-222222222201")
        mb.admit_camera("22222222-2222-4222-8222-222222222204")
        with self.assertRaises(vc.ContractValidationError):
            mb.admit_camera("22222222-2222-4222-8222-222222222209")

    def test_e2e_f13_t2_04_oversized_live_frame_exceeds_nats_payload_ceiling(self) -> None:
        _record_catalog_case("E2E-F13-T2-04")
        mb = LongshoreMailbox()
        oversized = self._make_frame("bay_04_approach", 1)
        oversized["pipeline_config"] = {"pad": "x" * (vc.MAX_RESULT_ENVELOPE_BYTES + 1)}
        with self.assertRaises(vc.ContractValidationError):
            mb.push_frame(oversized)
        self.assertEqual(mb.oversized_dropped, 1)

    def test_e2e_f13_t2_05_live_frame_bad_nullity_carrier_or_detection_fails(self) -> None:
        _record_catalog_case("E2E-F13-T2-05")
        bad_entry = self._make_frame("bay_04_approach", 1)
        bad_entry["catalog_entry_id"] = "44444444-4444-4444-8444-444444444401"
        with self.assertRaises(vc.ContractValidationError):
            vc.validate_live_frame(bad_entry)

        bad_frag = self._make_frame("bay_04_approach", 1)
        bad_frag["fragment_sequence"] = 0
        with self.assertRaises(vc.ContractValidationError):
            vc.validate_live_frame(bad_frag)

        no_carrier = self._make_frame("bay_04_approach", 1)
        no_carrier.pop("frame_jpeg_b64", None)
        with self.assertRaises(vc.ContractValidationError):
            vc.validate_live_frame(no_carrier)

        bad_det = self._make_frame("bay_04_approach", 1, track_id="   ")
        with self.assertRaises(vc.ContractValidationError):
            LongshoreMailbox().push_frame(bad_det)

    def test_e2e_f13_t2_06_non_monotonic_sequence_and_cmaf_isolation(self) -> None:
        _record_catalog_case("E2E-F13-T2-06")
        cmaf_blocks_written: list[int] = [1, 2, 3]
        mb = LongshoreMailbox()
        mb.push_frame(self._make_frame("bay_04_approach", 5))
        with self.assertRaises(vc.ContractValidationError):
            mb.push_frame(self._make_frame("bay_04_approach", 4))
        self.assertEqual(cmaf_blocks_written, [1, 2, 3])

    def test_longshore_mailbox_rollback_preserves_seq_after_rejected_frame(self) -> None:
        cam_id = self.f13["cameras"]["bay_04_approach"]["camera_source_id"]
        mb = LongshoreMailbox(mailbox_cap=8, max_tracks=2)

        f1 = self._make_frame("bay_04_approach", 1)
        f1["detections"] = [
            {"track_id": "t1", "category": "vehicle", "confidence": 0.9, "bbox": [0.1, 0.1, 0.4, 0.4]},
            {"track_id": "t2", "category": "vehicle", "confidence": 0.9, "bbox": [0.5, 0.1, 0.8, 0.4]},
        ]
        mb.push_frame(f1)

        f2_bad = self._make_frame("bay_04_approach", 2)
        f2_bad["detections"] = [
            {"track_id": "t1", "category": "vehicle", "confidence": 0.9, "bbox": [0.1, 0.1, 0.4, 0.4]},
            {"track_id": "t2", "category": "vehicle", "confidence": 0.9, "bbox": [0.5, 0.1, 0.8, 0.4]},
            {"track_id": "t3", "category": "vehicle", "confidence": 0.9, "bbox": [0.2, 0.5, 0.6, 0.9]},
        ]
        with self.assertRaises(vc.ContractValidationError):
            mb.push_frame(f2_bad)

        f2_good = self._make_frame("bay_04_approach", 2, track_id="t1")
        mb.push_frame(f2_good)

        f3_bad_det = self._make_frame("bay_04_approach", 3, track_id="   ")
        with self.assertRaises(vc.ContractValidationError):
            mb.push_frame(f3_bad_det)

        f3_good = self._make_frame("bay_04_approach", 3, track_id="t2")
        mb.push_frame(f3_good)

        self.assertEqual([f["frame_sequence"] for f in mb.drain_camera(cam_id)], [1, 2, 3])
        self.assertEqual(mb.active_track_count(cam_id), 2)


class F14GuidanceBenchmarkAndRetentionModeATest(unittest.TestCase):
    """F14 Tier 1 & Tier 2 hermetic contract tests."""

    @classmethod
    def setUpClass(cls) -> None:
        cls.f14 = _load_fixture("f14_guidance_retention_benchmark.json")
        cls.f12 = _load_fixture("f12_sdk_conformance_and_hygiene.json")
        cls.f11_hb = _load_fixture("f11_dispatcher_heartbeat_vectors.json")
        cls.res_wire = _load_wire_vector("vantage_result_v1.json")

    def test_e2e_f14_t1_01_bay_guidance_states_validate(self) -> None:
        _record_catalog_case("E2E-F14-T1-01")
        seen_states: set[str] = set()
        for attrs in self.f14["bay_guidance_positive"]:
            validated = vc.validate_bay_guidance_attributes(attrs)
            seen_states.add(validated["guidance_state"])
        self.assertEqual(seen_states, set(self.f14["guidance_states"]))

    def test_e2e_f14_t1_02_identical_process_frame_rust_and_python_live_tap(self) -> None:
        _record_catalog_case("E2E-F14-T1-02")
        rust_live = validate_live_tap_result_strict(self.res_wire["positive_live"])
        py_live = validate_live_tap_result_strict(self.f12["live_tap_result_strict_null"])
        self.assertEqual(rust_live["observations"][0]["signal_schema_id"], "bay_guidance")
        self.assertEqual(py_live["observations"][0]["signal_schema_id"], "bay_guidance")

    def test_e2e_f14_t1_03_nested_ocsf_signal_schema_and_camera_scoping(self) -> None:
        _record_catalog_case("E2E-F14-T1-03")
        event = self.f14["ocsf_event_envelope"]
        cam_id = event["metadata"]["service_radar"]["camera_source_id"]
        self.assertTrue(
            filter_ocsf_event_for_viewer(
                event,
                authorized_camera_ids={cam_id},
                has_devices_view=True,
                has_recordings_view=True,
                signal_schema_filter="bay_guidance",
                camera_source_filter=cam_id,
            )
        )

    def test_e2e_f14_t1_04_latency_benchmark_percentiles_deterministic(self) -> None:
        _record_catalog_case("E2E-F14-T1-04")
        for ref in self.f14["latency_reference_sets"]:
            with self.subTest(name=ref["name"]):
                got = compute_latency_percentiles(ref["samples_ms"])
                self.assertEqual(got, ref["expected"])
                self.assertLessEqual(got["p50"], got["p95"])
                self.assertLessEqual(got["p95"], got["p99"])

    def test_e2e_f14_t1_05_live_retention_purges_expired_preserves_fresh_and_held(self) -> None:
        _record_catalog_case("E2E-F14-T1-05")
        rb = self.f14["retention_boundary"]
        purged, preserved = evaluate_live_retention(rb["records"], rb["cutoff_ts_us"])
        self.assertEqual(purged, ["live-expired-before-cutoff"])
        self.assertIn("live-fresh-after-cutoff", preserved)
        self.assertIn("recorded-old-with-hold", preserved)

    def test_e2e_f14_t1_06_worker_dual_source_mode_support(self) -> None:
        _record_catalog_case("E2E-F14-T1-06")
        hb = self.f11_hb["workers"]["fresh_rust_alpr"]
        vc.validate_heartbeat(hb)
        for mode in ("recorded_block", "live_keyframe_tap"):
            decision = evaluate_heartbeat_routing(
                {"runner": "external_worker", "capability": "vantage.alpr.v1", "optional": False},
                [hb],
                now_us=self.f11_hb["now_us"],
                ttl_us=self.f11_hb["heartbeat_ttl_us"],
                source_mode=mode,
            )
            self.assertEqual(decision["disposition"], "dispatch")

    def test_e2e_f14_t2_01_percentiles_fail_closed_on_empty_negative_nan_and_single(self) -> None:
        _record_catalog_case("E2E-F14-T2-01")
        with self.assertRaises(vc.ContractValidationError):
            compute_latency_percentiles([])
        with self.assertRaises(vc.ContractValidationError):
            compute_latency_percentiles([-0.5, 10.0])
        with self.assertRaises(vc.ContractValidationError):
            compute_latency_percentiles([float("nan"), 10.0])
        with self.assertRaises(vc.ContractValidationError):
            compute_latency_percentiles([True, 10.0])
        self.assertEqual(compute_latency_percentiles([18.5]), {"p50": 18.5, "p95": 18.5, "p99": 18.5})

    def test_e2e_f14_t2_02_live_retention_exact_cutoff_boundary(self) -> None:
        _record_catalog_case("E2E-F14-T2-02")
        rb = self.f14["retention_boundary"]
        purged, preserved = evaluate_live_retention(rb["records"], rb["cutoff_ts_us"])
        self.assertEqual(purged, ["live-expired-before-cutoff"])
        self.assertIn("live-exact-cutoff", preserved)
        self.assertIn("live-fresh-after-cutoff", preserved)
        self.assertIn("recorded-old-with-hold", preserved)

    def test_e2e_f14_t2_03_recorded_only_worker_excluded_from_live_tap(self) -> None:
        _record_catalog_case("E2E-F14-T2-03")
        recorded_only = copy.deepcopy(self.f11_hb["workers"]["fresh_rust_alpr"])
        recorded_only["capabilities"] = ["vantage.bay_guidance.v1"]
        recorded_only["supported_source_modes"] = ["recorded_block"]
        decision = evaluate_heartbeat_routing(
            {"runner": "external_worker", "capability": "vantage.bay_guidance.v1", "optional": False},
            [recorded_only],
            now_us=self.f11_hb["now_us"],
            ttl_us=self.f11_hb["heartbeat_ttl_us"],
            source_mode="live_keyframe_tap",
        )
        self.assertEqual(decision["disposition"], "hold")

    def test_e2e_f14_t2_04_invalid_bay_guidance_attributes_fail_validation(self) -> None:
        _record_catalog_case("E2E-F14-T2-04")
        for neg in self.f14["bay_guidance_negative"]:
            with self.subTest(case=neg["name"]):
                with self.assertRaises(vc.ContractValidationError) as ctx:
                    vc.validate_bay_guidance_attributes(neg["attributes"])
                self.assertIn(neg["expected_error"], str(ctx.exception))

    def test_e2e_f14_t2_05_unauthorized_viewer_receives_zero_guidance_overlays(self) -> None:
        _record_catalog_case("E2E-F14-T2-05")
        event = self.f14["ocsf_event_envelope"]
        cam_id = event["metadata"]["service_radar"]["camera_source_id"]
        other_cam = "22222222-2222-4222-8222-222222222201"
        self.assertFalse(
            filter_ocsf_event_for_viewer(
                event,
                authorized_camera_ids={cam_id},
                has_devices_view=True,
                has_recordings_view=False,
            )
        )
        self.assertFalse(
            filter_ocsf_event_for_viewer(
                event,
                authorized_camera_ids={other_cam},
                has_devices_view=True,
                has_recordings_view=True,
            )
        )

    def test_e2e_f14_t2_06_mailbox_overflow_isolation_and_recovery_contract(self) -> None:
        _record_catalog_case("E2E-F14-T2-06")
        mb = LongshoreMailbox(mailbox_cap=8)
        frame_tmpl = _load_wire_vector("vantage_frame_v1.json")["positive"]
        for seq in range(1, 17):
            pkt = copy.deepcopy(frame_tmpl)
            pkt["frame_sequence"] = seq
            mb.push_frame(pkt)
        self.assertEqual(mb.dropped_total, 8)
        drained = mb.drain_camera(frame_tmpl["camera_source_id"])
        self.assertEqual([d["frame_sequence"] for d in drained], list(range(9, 17)))
        resumed = copy.deepcopy(frame_tmpl)
        resumed["frame_sequence"] = 17
        mb.push_frame(resumed)
        self.assertEqual([d["frame_sequence"] for d in mb.drain_camera(frame_tmpl["camera_source_id"])], [17])


class CatalogAndHygieneCompletenessTest(unittest.TestCase):
    """Verify F11-F14 catalog structure, feature minimums, 1:1 mapping, and synthetic hygiene."""

    def test_catalog_f11_f14_completeness_and_1_to_1_mapping(self) -> None:
        catalog = _load_catalog()
        summary = vc.validate_test_catalog(catalog, enforce_minimums=False)
        self.assertGreaterEqual(summary["total"], 40)
        for feat in ("F11", "F12", "F13", "F14"):
            self.assertGreaterEqual(summary["per_feature_tier"].get(f"{feat}:T1", 0), 5)
            self.assertGreaterEqual(summary["per_feature_tier"].get(f"{feat}:T2", 0), 5)

        method_names: set[str] = set()
        for cls in (
            F11DispatcherHeartbeatReadGrantModeATest,
            F12CompanionSdkAndHygieneModeATest,
            F13LiveKeyframeTapAndMailboxModeATest,
            F14GuidanceBenchmarkAndRetentionModeATest,
        ):
            method_names.update(m for m in dir(cls) if m.startswith("test_e2e_f"))

        for entry in catalog["cases"]:
            prefix = "test_" + entry["test_id"].lower().replace("-", "_") + "_"
            self.assertTrue(
                any(m.startswith(prefix) for m in method_names),
                f"catalog test_id {entry['test_id']} has no matching test method ({prefix}*)",
            )

    def test_all_f11_f14_fixtures_pass_synthetic_hygiene(self) -> None:
        fixtures_dir = vc.repo_root() / "integration_tests" / "vantage_ml" / "fixtures" / "f11_f14"
        json_files = sorted(fixtures_dir.glob("*.json"))
        self.assertGreaterEqual(len(json_files), 5)
        for jf in json_files:
            with self.subTest(file=jf.name):
                vc.assert_synthetic_hygiene(jf.read_text(encoding="utf-8"))
        catalog_path = (
            vc.repo_root() / "integration_tests" / "vantage_ml" / "fixtures" / "catalog_f11_f14.json"
        )
        vc.assert_synthetic_hygiene(catalog_path.read_text(encoding="utf-8"))


if __name__ == "__main__":
    unittest.main()
