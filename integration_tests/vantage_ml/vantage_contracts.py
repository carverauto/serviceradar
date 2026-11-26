"""Pure Python 3.11+ stdlib contract validators and synthetic media/archive helpers.

Covers wire envelopes (`vantage.job.v1`, `vantage.result.v1`, `vantage.heartbeat.v1`,
`vantage.frame.v1`), `POST /v1/media/workers/read-grants` responses, signal schemas
(`alpr_plate_read`, `bay_guidance`), padded crop-box geometry (`frame.rs` /
`thumbnail.rs` parity), deterministic Baseline Sequential JFIF 1.01 encoding & strict
validation, deterministic POSIX.1-1988 USTAR & RFC 1952 gzip packaging, Solution Pack
v1/v2 validation (`dashboard-browser-module-v1` + SHA-256 parity), secret-free scanning,
synthetic-data hygiene scanning, and E2E test catalog registration.
"""

from __future__ import annotations

import base64
import gzip
import hashlib
import ipaddress
import json
import math
import os
import re
from pathlib import Path
from typing import Any, Mapping, Sequence

# ---------------------------------------------------------------------------
# Canonical Constants
# ---------------------------------------------------------------------------

SYNTHETIC_PLATES: tuple[str, ...] = ("SR-0100", "TEST-742")
SYNTHETIC_CAMERAS: tuple[str, ...] = ("Gate West 01", "Bay 04 Approach")
SYNTHETIC_DOMAINS: tuple[str, ...] = ("example.com", "example.org", "example.net")

RFC5737_NETS: tuple[ipaddress.IPv4Network, ...] = (
    ipaddress.IPv4Network("192.0.2.0/24"),
    ipaddress.IPv4Network("198.51.100.0/24"),
    ipaddress.IPv4Network("203.0.113.0/24"),
)

MAX_JOB_ENVELOPE_BYTES: int = 4096
MAX_RESULT_ENVELOPE_BYTES: int = 983040
MAX_VLM_CROP_BYTES: int = 98304
MAX_PERSISTED_CROP_BYTES: int = 32768
MAX_CROP_DIMENSION_PX: int = 640
MAX_FRAME_DIMENSION: int = 8192

PACK_V1_LIMITS: tuple[int, int, int] = (25 * 1024 * 1024, 64 * 1024 * 1024, 256)
PACK_V2_LIMITS: tuple[int, int, int] = (32 * 1024 * 1024, 96 * 1024 * 1024, 256)
MAX_RENDERER_BYTES: int = 8 * 1024 * 1024
MAX_USTAR_PATH_BYTES: int = 240
MAX_DASHBOARD_MANIFEST_BYTES: int = 262144

LIVE_TAP_MAILBOX_CAP: int = 8
LIVE_TAP_MAX_TRACKS: int = 128

MAX_READ_GRANT_REQUEST_BYTES: int = 8192
MAX_READ_GRANT_RESPONSE_BYTES: int = 524288
READ_GRANT_MAX_CHUNK_BYTES: int = 4_194_304
READ_GRANT_MAX_COALESCE_GAP_BYTES: int = 262_144
READ_GRANT_MAX_INIT_BYTES: int = 1_048_576
READ_GRANT_MAX_TTL_SECONDS: int = 900

ALLOWED_DASHBOARD_CAPABILITIES: frozenset[str] = frozenset(
    {
        "srql.execute",
        "saved_queries.read",
        "dashboard.preferences.read",
        "dashboard.preferences.write",
        "navigation.open",
        "popup.open",
        "details.open",
        "map.basemap.read",
        "map.deck.render",
        "camera.stream.view",
        "actions.invoke",
        "events.subscribe",
    }
)

_DASHBOARD_MANIFEST_ROOT_KEYS: frozenset[str] = frozenset(
    {
        "schema_version",
        "id",
        "name",
        "version",
        "description",
        "vendor",
        "renderer",
        "data_frames",
        "capabilities",
        "settings_schema",
        "source",
    }
)

_DASHBOARD_RENDERER_KEYS: frozenset[str] = frozenset(
    {
        "kind",
        "interface_version",
        "artifact",
        "sha256",
        "entrypoint",
        "exports",
        "trust",
    }
)

_DASHBOARD_DATA_FRAME_KEYS: frozenset[str] = frozenset(
    {
        "id",
        "query",
        "encoding",
        "required",
        "limit",
        "refresh_interval_ms",
        "fields",
        "coordinates",
    }
)

_UUID_RE = re.compile(
    r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"
)
_HEX64_RE = re.compile(r"^[0-9a-f]{64}$")
_HEX64_CASE_RE = re.compile(r"^[0-9a-fA-F]{64}$")
_SEMVER_RE = re.compile(
    r"^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$"
)
_REVERSE_DNS_RE = re.compile(r"^[a-z][a-z0-9-]*(?:\.[a-z0-9][a-z0-9-]*)+$")
_SLUG_RE = re.compile(r"^[a-z0-9][a-z0-9-]{0,126}$")
_DASHBOARD_ID_RE = re.compile(r"^[a-z0-9][a-z0-9._-]{1,127}$")
_CAPABILITY_RE = re.compile(r"^[a-z0-9][a-z0-9._-]*$")
_PLATE_TEXT_RE = re.compile(r"^[A-Z0-9-]{2,12}$")
_FEATURE_RE = re.compile(r"^(?:F(?:[1-9]|1[0-4])(?:\+F(?:[1-9]|1[0-4]))*|E2E-INFRA|T3|T4)$")

_REGISTERED_TEST_CASES: dict[str, dict[str, Any]] = {}


class ContractValidationError(ValueError):
    """Raised when a Vantage wire envelope, media artifact, pack, or schema violates contract."""


def repo_root() -> Path:
    """Resolve repository root, prioritizing Bazel runfiles over workspace traversal."""
    marker = Path("integration_tests/vantage_ml/fixtures/wire_vectors/vantage_job_v1.json")
    for env_var in ("TEST_SRCDIR", "RUNFILES_DIR"):
        srcdir = os.environ.get(env_var)
        if not srcdir:
            continue
        for workspace in (os.environ.get("TEST_WORKSPACE", ""), "_main", "serviceradar"):
            candidate = Path(srcdir) / workspace if workspace else Path(srcdir)
            if (candidate / marker).is_file():
                return candidate
    return Path(__file__).resolve().parents[2]


# ---------------------------------------------------------------------------
# Internal Scalar / Structural Validators
# ---------------------------------------------------------------------------


def _compact_json_bytes(payload: Any) -> bytes:
    try:
        encoded = json.dumps(payload, separators=(",", ":"), ensure_ascii=False)
    except (TypeError, ValueError) as exc:
        raise ContractValidationError(f"payload is not JSON-serializable: {exc}") from exc
    return encoded.encode("utf-8")


def _require_dict(value: Any, name: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise ContractValidationError(f"{name} must be a JSON object")
    return value


def _require_list(value: Any, name: str) -> list[Any]:
    if not isinstance(value, list):
        raise ContractValidationError(f"{name} must be a list")
    return value


def _require_str(value: Any, name: str, *, non_empty: bool = True) -> str:
    if not isinstance(value, str):
        raise ContractValidationError(f"{name} must be a string")
    if non_empty and not value.strip():
        raise ContractValidationError(f"{name} must be non-empty")
    return value


def _require_bool(value: Any, name: str) -> bool:
    if not isinstance(value, bool):
        raise ContractValidationError(f"{name} must be a boolean")
    return value


def _require_int(
    value: Any,
    name: str,
    *,
    min_value: int | None = None,
    max_value: int | None = None,
) -> int:
    if isinstance(value, bool) or not isinstance(value, int):
        raise ContractValidationError(f"{name} must be an integer")
    if min_value is not None and value < min_value:
        raise ContractValidationError(f"{name} ({value}) must be >= {min_value}")
    if max_value is not None and value > max_value:
        raise ContractValidationError(f"{name} ({value}) must be <= {max_value}")
    return value


def _require_float(
    value: Any,
    name: str,
    *,
    min_value: float | None = None,
    max_value: float | None = None,
) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise ContractValidationError(f"{name} must be a finite number")
    num = float(value)
    if not math.isfinite(num):
        raise ContractValidationError(f"{name} must be finite")
    if min_value is not None and num < min_value:
        raise ContractValidationError(f"{name} ({num}) must be >= {min_value}")
    if max_value is not None and num > max_value:
        raise ContractValidationError(f"{name} ({num}) must be <= {max_value}")
    return num


def _require_uuid(value: Any, name: str) -> str:
    s = _require_str(value, name)
    if not _UUID_RE.match(s):
        raise ContractValidationError(f"{name} ({s!r}) must be a valid UUID")
    return s


def _require_hex64(value: Any, name: str, *, allow_upper: bool = False) -> str:
    s = _require_str(value, name)
    pattern = _HEX64_CASE_RE if allow_upper else _HEX64_RE
    if not pattern.match(s):
        case_desc = "64-char hex" if allow_upper else "64-char lowercase hex"
        raise ContractValidationError(f"{name} ({s!r}) must be {case_desc}")
    return s


def _require_semver(value: Any, name: str) -> str:
    s = _require_str(value, name)
    if not _SEMVER_RE.match(s):
        raise ContractValidationError(f"{name} ({s!r}) must be a valid SemVer string")
    return s


def _require_reverse_dns(value: Any, name: str) -> str:
    s = _require_str(value, name)
    if not _REVERSE_DNS_RE.match(s):
        raise ContractValidationError(f"{name} ({s!r}) must be reverse-DNS")
    return s


def _require_enum(value: Any, name: str, allowed: Sequence[str]) -> str:
    s = _require_str(value, name)
    if s not in allowed:
        raise ContractValidationError(
            f"{name} ({s!r}) must be one of {tuple(allowed)}"
        )
    return s


def _require_bbox(value: Any, name: str) -> list[float]:
    arr = _require_list(value, name)
    if len(arr) != 4:
        raise ContractValidationError(f"{name} must contain exactly 4 coordinates")
    coords = [_require_float(v, f"{name}[{i}]", min_value=0.0, max_value=1.0) for i, v in enumerate(arr)]
    if not (coords[0] < coords[2] and coords[1] < coords[3]):
        raise ContractValidationError(f"{name} must satisfy x1 < x2 and y1 < y2")
    return coords


def _decode_b64_strict(value: Any, name: str) -> bytes:
    s = _require_str(value, name)
    try:
        return base64.b64decode(s.encode("ascii"), validate=True)
    except Exception as exc:
        raise ContractValidationError(f"{name} is not valid base64: {exc}") from exc


# ---------------------------------------------------------------------------
# Signal Schema Attribute Validators
# ---------------------------------------------------------------------------


def validate_alpr_attributes(attrs: Any) -> dict[str, Any]:
    """Validate `alpr_plate_read` observation attributes."""
    obj = _require_dict(attrs, "attributes")
    plate = _require_str(obj.get("plate_text"), "attributes.plate_text")
    if not _PLATE_TEXT_RE.match(plate):
        raise ContractValidationError(
            f"attributes.plate_text ({plate!r}) must match ^[A-Z0-9-]{{2,12}}$"
        )
    for opt_key in ("region", "vehicle_color", "vehicle_type"):
        if opt_key in obj and obj[opt_key] is not None:
            _require_str(obj[opt_key], f"attributes.{opt_key}")
    if "confidence" in obj and obj["confidence"] is not None:
        _require_float(obj["confidence"], "attributes.confidence", min_value=0.0, max_value=1.0)
    return obj


def validate_bay_guidance_attributes(attrs: Any) -> dict[str, Any]:
    """Validate `bay_guidance` observation attributes."""
    obj = _require_dict(attrs, "attributes")
    _require_str(obj.get("bay_id"), "attributes.bay_id")
    _require_enum(
        obj.get("guidance_state"),
        "attributes.guidance_state",
        ("approach", "aligning", "stop", "docked", "clear"),
    )
    _require_float(obj.get("distance_m"), "attributes.distance_m", min_value=0.0)
    _require_float(obj.get("lateral_offset_m"), "attributes.lateral_offset_m")
    if "confidence" in obj and obj["confidence"] is not None:
        _require_float(obj["confidence"], "attributes.confidence", min_value=0.0, max_value=1.0)
    return obj


# ---------------------------------------------------------------------------
# Wire Envelope & Read-Grant Validators
# ---------------------------------------------------------------------------


def validate_job_envelope(payload: Any) -> dict[str, Any]:
    """Validate a `vantage.job.v1` envelope (`<= 4096` bytes)."""
    obj = _require_dict(payload, "job_envelope")
    raw = _compact_json_bytes(obj)
    if len(raw) > MAX_JOB_ENVELOPE_BYTES:
        raise ContractValidationError(
            f"job envelope size {len(raw)} exceeds MAX_JOB_ENVELOPE_BYTES ({MAX_JOB_ENVELOPE_BYTES})"
        )

    schema_version = _require_str(obj.get("schema_version"), "schema_version")
    if schema_version != "vantage.job.v1":
        raise ContractValidationError(f"schema_version must be 'vantage.job.v1', got {schema_version!r}")

    _require_uuid(obj.get("job_id"), "job_id")
    _require_reverse_dns(obj.get("pipeline_id"), "pipeline_id")
    _require_semver(obj.get("pipeline_version"), "pipeline_version")
    cap = _require_str(obj.get("capability"), "capability")
    if not _CAPABILITY_RE.match(cap):
        raise ContractValidationError(f"invalid capability slug {cap!r}")

    source_mode = _require_enum(
        obj.get("source_mode"), "source_mode", ("recorded_block", "live_keyframe_tap")
    )
    _require_uuid(obj.get("camera_source_id"), "camera_source_id")
    _require_uuid(obj.get("stream_profile_id"), "stream_profile_id")

    if source_mode == "recorded_block":
        _require_uuid(obj.get("catalog_entry_id"), "catalog_entry_id")
        _require_hex64(obj.get("descriptor_sha256"), "descriptor_sha256")
    else:
        if obj.get("catalog_entry_id") is not None:
            _require_uuid(obj.get("catalog_entry_id"), "catalog_entry_id")
        if obj.get("descriptor_sha256") is not None:
            _require_hex64(obj.get("descriptor_sha256"), "descriptor_sha256")

    _require_enum(
        obj.get("input_mode"),
        "input_mode",
        ("full_frame", "detection_crop", "multi_frame_track"),
    )

    roi_polygons = _require_list(obj.get("roi_polygons"), "roi_polygons")
    for idx, poly in enumerate(roi_polygons):
        pts = _require_list(poly, f"roi_polygons[{idx}]")
        if len(pts) < 3:
            raise ContractValidationError(f"roi_polygons[{idx}] must have at least 3 points")
        for p_idx, pt in enumerate(pts):
            coords = _require_list(pt, f"roi_polygons[{idx}][{p_idx}]")
            if len(coords) != 2:
                raise ContractValidationError(f"roi_polygons[{idx}][{p_idx}] must be [x, y]")
            _require_float(coords[0], f"roi_polygons[{idx}][{p_idx}][0]", min_value=0.0, max_value=1.0)
            _require_float(coords[1], f"roi_polygons[{idx}][{p_idx}][1]", min_value=0.0, max_value=1.0)

    crop_policy = _require_dict(obj.get("crop_policy"), "crop_policy")
    _require_float(crop_policy.get("padding_ratio"), "crop_policy.padding_ratio", min_value=0.0)
    _require_int(crop_policy.get("min_bbox_width_px"), "crop_policy.min_bbox_width_px", min_value=1)
    _require_int(
        crop_policy.get("max_dimension"),
        "crop_policy.max_dimension",
        min_value=1,
        max_value=MAX_CROP_DIMENSION_PX,
    )
    _require_int(
        crop_policy.get("max_bytes"),
        "crop_policy.max_bytes",
        min_value=512,
        max_value=MAX_VLM_CROP_BYTES,
    )

    targets = _require_list(obj.get("sampled_targets"), "sampled_targets")
    for idx, tgt in enumerate(targets):
        t = _require_dict(tgt, f"sampled_targets[{idx}]")
        _require_str(t.get("target_key"), f"sampled_targets[{idx}].target_key")
        _require_str(t.get("track_id"), f"sampled_targets[{idx}].track_id")
        _require_int(t.get("fragment_sequence"), f"sampled_targets[{idx}].fragment_sequence", min_value=0)
        _require_int(t.get("media_pts_ns"), f"sampled_targets[{idx}].media_pts_ns", min_value=0)
        _require_int(t.get("timeline_ts_us"), f"sampled_targets[{idx}].timeline_ts_us", min_value=0)
        _require_enum(
            t.get("time_basis"),
            f"sampled_targets[{idx}].time_basis",
            ("received", "camera_reported"),
        )
        _require_str(t.get("category"), f"sampled_targets[{idx}].category")
        _require_float(
            t.get("confidence"), f"sampled_targets[{idx}].confidence", min_value=0.0, max_value=1.0
        )
        _require_bbox(t.get("bbox"), f"sampled_targets[{idx}].bbox")

    _require_str(obj.get("signal_schema_id"), "signal_schema_id")
    _require_semver(obj.get("signal_schema_version"), "signal_schema_version")
    _require_str(obj.get("display_contract_id"), "display_contract_id")

    if "vlm_config" in obj and obj["vlm_config"] is not None:
        vlm = _require_dict(obj["vlm_config"], "vlm_config")
        _require_str(vlm.get("prompt"), "vlm_config.prompt")
        _require_str(vlm.get("model_profile"), "vlm_config.model_profile")
        _require_int(vlm.get("max_tokens"), "vlm_config.max_tokens", min_value=1)
        _require_float(vlm.get("temperature"), "vlm_config.temperature", min_value=0.0, max_value=2.0)

    return obj


def validate_result_envelope(payload: Any) -> dict[str, Any]:
    """Validate a `vantage.result.v1` envelope (`<= 960 KiB` / `983040` bytes)."""
    obj = _require_dict(payload, "result_envelope")
    raw = _compact_json_bytes(obj)
    if len(raw) > MAX_RESULT_ENVELOPE_BYTES:
        raise ContractValidationError(
            f"result envelope size {len(raw)} exceeds MAX_RESULT_ENVELOPE_BYTES ({MAX_RESULT_ENVELOPE_BYTES})"
        )

    schema_version = _require_str(obj.get("schema_version"), "schema_version")
    if schema_version != "vantage.result.v1":
        raise ContractValidationError(f"schema_version must be 'vantage.result.v1', got {schema_version!r}")

    source_mode = _require_enum(
        obj.get("source_mode"), "source_mode", ("recorded_block", "live_keyframe_tap")
    )
    if source_mode == "recorded_block":
        _require_uuid(obj.get("job_id"), "job_id")
        _require_uuid(obj.get("catalog_entry_id"), "catalog_entry_id")
        _require_hex64(obj.get("descriptor_sha256"), "descriptor_sha256")
    else:
        if obj.get("job_id") is not None:
            _require_uuid(obj.get("job_id"), "job_id")
        if obj.get("catalog_entry_id") is not None:
            _require_uuid(obj.get("catalog_entry_id"), "catalog_entry_id")
        if obj.get("descriptor_sha256") is not None:
            _require_hex64(obj.get("descriptor_sha256"), "descriptor_sha256")

    _require_reverse_dns(obj.get("pack_id"), "pack_id")
    _require_reverse_dns(obj.get("pipeline_id"), "pipeline_id")
    _require_semver(obj.get("pipeline_version"), "pipeline_version")
    _require_enum(
        obj.get("worker_kind"),
        "worker_kind",
        ("camera_vlm", "external_rust", "external_python"),
    )
    _require_str(obj.get("worker_id"), "worker_id")
    _require_str(obj.get("model_id"), "model_id")
    _require_str(obj.get("model_version"), "model_version")
    cap = _require_str(obj.get("capability"), "capability")
    if not _CAPABILITY_RE.match(cap):
        raise ContractValidationError(f"invalid capability slug {cap!r}")

    _require_uuid(obj.get("camera_source_id"), "camera_source_id")
    _require_uuid(obj.get("stream_profile_id"), "stream_profile_id")

    observations = _require_list(obj.get("observations"), "observations")
    for idx, item in enumerate(observations):
        obs = _require_dict(item, f"observations[{idx}]")
        _require_str(obs.get("observation_key"), f"observations[{idx}].observation_key")
        if source_mode == "recorded_block" or obs.get("fragment_sequence") is not None:
            _require_int(
                obs.get("fragment_sequence"), f"observations[{idx}].fragment_sequence", min_value=0
            )
        _require_int(obs.get("frame_sequence"), f"observations[{idx}].frame_sequence", min_value=0)
        _require_int(obs.get("media_pts_ns"), f"observations[{idx}].media_pts_ns", min_value=0)
        _require_int(obs.get("timeline_ts_us"), f"observations[{idx}].timeline_ts_us", min_value=0)
        _require_enum(
            obs.get("time_basis"),
            f"observations[{idx}].time_basis",
            ("received", "camera_reported"),
        )
        _require_str(obs.get("track_id"), f"observations[{idx}].track_id")
        _require_str(obs.get("category"), f"observations[{idx}].category")
        _require_str(obs.get("label"), f"observations[{idx}].label")
        _require_float(
            obs.get("confidence"), f"observations[{idx}].confidence", min_value=0.0, max_value=1.0
        )
        _require_bbox(obs.get("bbox"), f"observations[{idx}].bbox")

        if "crop_jpeg_b64" in obs and obs["crop_jpeg_b64"] is not None:
            crop_bytes = _decode_b64_strict(
                obs["crop_jpeg_b64"], f"observations[{idx}].crop_jpeg_b64"
            )
            validate_baseline_jfif(crop_bytes, max_bytes=MAX_PERSISTED_CROP_BYTES)

        signal_schema_id = _require_str(
            obs.get("signal_schema_id"), f"observations[{idx}].signal_schema_id"
        )
        _require_semver(
            obs.get("signal_schema_version"), f"observations[{idx}].signal_schema_version"
        )
        _require_str(obs.get("display_contract_id"), f"observations[{idx}].display_contract_id")
        _require_str(obs.get("search_text"), f"observations[{idx}].search_text", non_empty=False)

        attrs = _require_dict(obs.get("attributes"), f"observations[{idx}].attributes")
        if signal_schema_id == "alpr_plate_read":
            validate_alpr_attributes(attrs)
        elif signal_schema_id == "bay_guidance":
            validate_bay_guidance_attributes(attrs)

    return obj


def validate_heartbeat(payload: Any) -> dict[str, Any]:
    """Validate a `vantage.heartbeat.v1` worker capability heartbeat."""
    obj = _require_dict(payload, "heartbeat")
    if obj.get("schema_version") != "vantage.heartbeat.v1":
        raise ContractValidationError(
            f"schema_version must be 'vantage.heartbeat.v1', got {obj.get('schema_version')!r}"
        )
    _require_str(obj.get("worker_id"), "worker_id")
    _require_enum(
        obj.get("worker_kind"),
        "worker_kind",
        ("external_rust", "external_python", "camera_vlm"),
    )
    if obj.get("protocol_version") != "vantage.worker.v1":
        raise ContractValidationError(
            f"protocol_version must be 'vantage.worker.v1', got {obj.get('protocol_version')!r}"
        )

    caps = _require_list(obj.get("capabilities"), "capabilities")
    if not caps:
        raise ContractValidationError("capabilities must be non-empty")
    for idx, cap in enumerate(caps):
        s = _require_str(cap, f"capabilities[{idx}]")
        if not _CAPABILITY_RE.match(s):
            raise ContractValidationError(f"capabilities[{idx}] ({s!r}) is not a valid capability")

    modes = _require_list(obj.get("supported_source_modes"), "supported_source_modes")
    if not modes:
        raise ContractValidationError("supported_source_modes must be non-empty")
    for idx, mode in enumerate(modes):
        _require_enum(
            mode,
            f"supported_source_modes[{idx}]",
            ("recorded_block", "live_keyframe_tap"),
        )

    _require_str(obj.get("execution_backend"), "execution_backend")
    _require_str(obj.get("architecture"), "architecture")
    _require_str(obj.get("model_id"), "model_id")
    _require_str(obj.get("model_version"), "model_version")
    max_conc = _require_int(obj.get("max_concurrency"), "max_concurrency", min_value=1)
    _require_int(obj.get("active_jobs"), "active_jobs", min_value=0, max_value=max_conc)
    _require_enum(obj.get("health"), "health", ("ready", "degraded", "draining", "unhealthy"))
    _require_int(obj.get("sent_at_us"), "sent_at_us", min_value=0)
    return obj


def validate_live_frame(payload: Any) -> dict[str, Any]:
    """Validate a `vantage.frame.v1` live keyframe tap envelope."""
    obj = _require_dict(payload, "live_frame")
    if obj.get("schema_version") != "vantage.frame.v1":
        raise ContractValidationError(
            f"schema_version must be 'vantage.frame.v1', got {obj.get('schema_version')!r}"
        )
    if obj.get("source_mode") != "live_keyframe_tap":
        raise ContractValidationError(
            f"source_mode must be 'live_keyframe_tap', got {obj.get('source_mode')!r}"
        )
    _require_uuid(obj.get("camera_source_id"), "camera_source_id")
    _require_uuid(obj.get("stream_profile_id"), "stream_profile_id")
    _require_int(obj.get("frame_sequence"), "frame_sequence", min_value=0)
    _require_int(obj.get("timeline_ts_us"), "timeline_ts_us", min_value=0)
    _require_enum(obj.get("time_basis"), "time_basis", ("received", "camera_reported"))

    if obj.get("catalog_entry_id") is not None:
        raise ContractValidationError("live_keyframe_tap frame catalog_entry_id must be null")
    if obj.get("fragment_sequence") is not None:
        raise ContractValidationError("live_keyframe_tap frame fragment_sequence must be null")

    for det_key in ("detections", "upstream_detections"):
        if det_key in obj and obj[det_key] is not None:
            dets = _require_list(obj[det_key], det_key)
            for idx, det in enumerate(dets):
                d = _require_dict(det, f"{det_key}[{idx}]")
                if "bbox" in d and d["bbox"] is not None:
                    _require_bbox(d["bbox"], f"{det_key}[{idx}].bbox")
                if "confidence" in d and d["confidence"] is not None:
                    _require_float(
                        d["confidence"], f"{det_key}[{idx}].confidence", min_value=0.0, max_value=1.0
                    )

    if "pipeline_config" in obj and obj["pipeline_config"] is not None:
        _require_dict(obj["pipeline_config"], "pipeline_config")

    has_carrier = False
    payload_format = obj.get("payload_format")
    payload_b64 = obj.get("payload_b64")
    if payload_format is not None:
        fmt = _require_enum(
            payload_format,
            "payload_format",
            ("annex_b_idr", "jpeg", "rgb8"),
        )
        if payload_b64 is None:
            raise ContractValidationError("payload_b64 is required when payload_format is set")
        raw_payload = _decode_b64_strict(payload_b64, "payload_b64")
        if fmt == "jpeg":
            validate_baseline_jfif(raw_payload)
        elif fmt == "annex_b_idr":
            if not (
                raw_payload.startswith(b"\x00\x00\x00\x01")
                or raw_payload.startswith(b"\x00\x00\x01")
            ):
                raise ContractValidationError(
                    "payload_b64 for annex_b_idr must begin with an Annex-B start code"
                )
        elif fmt == "rgb8":
            if not raw_payload or (len(raw_payload) % 3) != 0:
                raise ContractValidationError(
                    "payload_b64 for rgb8 must be non-empty and a multiple of 3 bytes"
                )
        has_carrier = True
    elif payload_b64 is not None:
        raise ContractValidationError("payload_format is required when payload_b64 is set")

    if obj.get("frame_jpeg_b64") is not None:
        jpeg_raw = _decode_b64_strict(obj["frame_jpeg_b64"], "frame_jpeg_b64")
        validate_baseline_jfif(jpeg_raw)
        has_carrier = True
    if obj.get("idr_annex_b_b64") is not None:
        idr_raw = _decode_b64_strict(obj["idr_annex_b_b64"], "idr_annex_b_b64")
        if not (idr_raw.startswith(b"\x00\x00\x00\x01") or idr_raw.startswith(b"\x00\x00\x01")):
            raise ContractValidationError("idr_annex_b_b64 must begin with an Annex-B start code")
        has_carrier = True
    if obj.get("read_token") is not None:
        _require_str(obj["read_token"], "read_token")
        has_carrier = True

    if not has_carrier:
        raise ContractValidationError(
            "live_frame must include payload_format+payload_b64, frame_jpeg_b64, idr_annex_b_b64, or read_token"
        )
    return obj


def _contains_forbidden_credential_field(node: Any) -> str | None:
    if isinstance(node, dict):
        for k, v in node.items():
            norm = str(k).strip().lower().replace("-", "_")
            if norm in {"access_key_id", "secret_access_key", "session_token"}:
                return str(k)
            found = _contains_forbidden_credential_field(v)
            if found is not None:
                return found
    elif isinstance(node, list):
        for item in node:
            found = _contains_forbidden_credential_field(item)
            if found is not None:
                return found
    return None


def validate_read_grant_response(payload: Any) -> dict[str, Any]:
    """Validate a `POST /v1/media/workers/read-grants` 200 OK JSON response."""
    obj = _require_dict(payload, "read_grant_response")
    raw = _compact_json_bytes(obj)
    if len(raw) > MAX_READ_GRANT_RESPONSE_BYTES:
        raise ContractValidationError(
            f"read_grant_response size {len(raw)} exceeds {MAX_READ_GRANT_RESPONSE_BYTES}"
        )

    leaked = _contains_forbidden_credential_field(obj)
    if leaked is not None:
        raise ContractValidationError(
            f"read_grant_response leaked forbidden credential field {leaked!r}"
        )

    _require_int(obj.get("schema_version"), "schema_version", min_value=1, max_value=1)
    backing = _require_enum(obj.get("backing"), "backing", ("archive", "local"))
    source = _require_enum(obj.get("source"), "source", ("archive", "local"))
    if source != backing:
        raise ContractValidationError(f"source ({source!r}) must match backing ({backing!r})")

    _require_uuid(obj.get("job_id"), "job_id")
    _require_uuid(obj.get("catalog_entry_id"), "catalog_entry_id")
    _require_uuid(obj.get("camera_source_id"), "camera_source_id")
    _require_uuid(obj.get("stream_profile_id"), "stream_profile_id")
    storage_id = _require_uuid(obj.get("storage_id"), "storage_id")
    block_key = _require_hex64(obj.get("block_key"), "block_key")
    _require_hex64(obj.get("descriptor_sha256"), "descriptor_sha256")
    init_sha = _require_hex64(obj.get("init_sha256"), "init_sha256")
    _require_int(
        obj.get("ttl_seconds"),
        "ttl_seconds",
        min_value=1,
        max_value=READ_GRANT_MAX_TTL_SECONDS,
    )
    _require_str(obj.get("expires_at"), "expires_at")

    init = _require_dict(obj.get("init"), "init")
    _require_str(init.get("object_name"), "init.object_name")
    _require_int(init.get("offset"), "init.offset", min_value=0)
    init_first = _require_int(init.get("first"), "init.first", min_value=0)
    init_last = _require_int(init.get("last"), "init.last", min_value=init_first)
    init_len = _require_int(
        init.get("length"), "init.length", min_value=1, max_value=READ_GRANT_MAX_INIT_BYTES
    )
    if init_len != (init_last - init_first + 1):
        raise ContractValidationError("init.length must equal init.last - init.first + 1")
    init_obj_sha = _require_hex64(init.get("sha256"), "init.sha256")
    if init_obj_sha != init_sha:
        raise ContractValidationError("init.sha256 must match top-level init_sha256")

    frags = _require_list(obj.get("fragments"), "fragments")
    if not frags:
        raise ContractValidationError("fragments must be non-empty")
    for idx, frag in enumerate(frags):
        f = _require_dict(frag, f"fragments[{idx}]")
        seq = _require_int(f.get("sequence"), f"fragments[{idx}].sequence", min_value=0)
        _require_int(f.get("offset"), f"fragments[{idx}].offset", min_value=0)
        f_first = _require_int(f.get("first"), f"fragments[{idx}].first", min_value=0)
        f_last = _require_int(f.get("last"), f"fragments[{idx}].last", min_value=f_first)
        f_len = _require_int(f.get("length"), f"fragments[{idx}].length", min_value=1)
        if f_len != (f_last - f_first + 1):
            raise ContractValidationError(
                f"fragments[{idx}].length must equal last - first + 1"
            )
        _require_int(f.get("start_ns"), f"fragments[{idx}].start_ns", min_value=0)
        _require_int(f.get("duration_ns"), f"fragments[{idx}].duration_ns", min_value=1)
        _require_hex64(f.get("sha256"), f"fragments[{idx}].sha256")
        if backing == "local":
            fpath = _require_str(f.get("path"), f"fragments[{idx}].path")
            expected_suffix = f"/v1/blocks/{block_key}/fragments/{seq}"
            if fpath != expected_suffix:
                raise ContractValidationError(
                    f"fragments[{idx}].path ({fpath!r}) must equal {expected_suffix!r}"
                )

    ranges = _require_list(obj.get("coalesced_ranges"), "coalesced_ranges")
    for idx, rng in enumerate(ranges):
        r = _require_dict(rng, f"coalesced_ranges[{idx}]")
        r_first = _require_int(r.get("first"), f"coalesced_ranges[{idx}].first", min_value=0)
        r_last = _require_int(r.get("last"), f"coalesced_ranges[{idx}].last", min_value=r_first)
        r_len = _require_int(
            r.get("length"),
            f"coalesced_ranges[{idx}].length",
            min_value=1,
            max_value=READ_GRANT_MAX_CHUNK_BYTES,
        )
        if r_len != (r_last - r_first + 1):
            raise ContractValidationError(
                f"coalesced_ranges[{idx}].length must equal last - first + 1"
            )
        seqs = _require_list(
            r.get("fragment_sequences"), f"coalesced_ranges[{idx}].fragment_sequences"
        )
        if not seqs:
            raise ContractValidationError(
                f"coalesced_ranges[{idx}].fragment_sequences must be non-empty"
            )
        for s_idx, seq_val in enumerate(seqs):
            _require_int(
                seq_val,
                f"coalesced_ranges[{idx}].fragment_sequences[{s_idx}]",
                min_value=0,
            )
        slices = _require_list(r.get("slices"), f"coalesced_ranges[{idx}].slices")
        if not slices:
            raise ContractValidationError(f"coalesced_ranges[{idx}].slices must be non-empty")
        for sl_idx, sl in enumerate(slices):
            s = _require_dict(sl, f"coalesced_ranges[{idx}].slices[{sl_idx}]")
            _require_int(s.get("sequence"), f"slices[{sl_idx}].sequence", min_value=0)
            _require_int(s.get("offset"), f"slices[{sl_idx}].offset", min_value=0)
            _require_int(s.get("relative_offset"), f"slices[{sl_idx}].relative_offset", min_value=0)
            _require_int(s.get("length"), f"slices[{sl_idx}].length", min_value=1)
            _require_int(s.get("start_ns"), f"slices[{sl_idx}].start_ns", min_value=0)
            _require_int(s.get("duration_ns"), f"slices[{sl_idx}].duration_ns", min_value=1)
            _require_hex64(s.get("sha256"), f"slices[{sl_idx}].sha256")

    if backing == "archive":
        _require_str(init.get("key"), "init.key")
        init_url = _require_str(init.get("presigned_url"), "init.presigned_url")
        if not init_url.startswith(("https://", "http://")):
            raise ContractValidationError("init.presigned_url must be http(s)")

        media = _require_dict(obj.get("media"), "media")
        _require_str(media.get("object_name"), "media.object_name")
        _require_str(media.get("key"), "media.key")
        _require_int(media.get("length"), "media.length", min_value=1)
        _require_hex64(media.get("sha256"), "media.sha256")
        media_url = _require_str(media.get("presigned_url"), "media.presigned_url")
        if not media_url.startswith(("https://", "http://")):
            raise ContractValidationError("media.presigned_url must be http(s)")

        archive = _require_dict(obj.get("archive"), "archive")
        _require_uuid(archive.get("binding_id"), "archive.binding_id")
        _require_str(archive.get("provider"), "archive.provider")
        _require_str(archive.get("endpoint"), "archive.endpoint")
        _require_str(archive.get("region"), "archive.region")
        _require_str(archive.get("bucket"), "archive.bucket")
        _require_str(archive.get("namespace"), "archive.namespace")
        _require_hex64(archive.get("destination_sha256"), "archive.destination_sha256")
        _require_str(archive.get("init_key"), "archive.init_key")
        _require_str(archive.get("init_presigned_url"), "archive.init_presigned_url")
        _require_str(archive.get("media_key"), "archive.media_key")
        _require_str(archive.get("media_presigned_url"), "archive.media_presigned_url")

        grant = _require_dict(obj.get("grant"), "grant")
        _require_str(grant.get("grant_type"), "grant.grant_type")
        if grant.get("role") != "reader":
            raise ContractValidationError(f"grant.role must be 'reader', got {grant.get('role')!r}")
        if grant.get("purpose") != "camera_archive_read":
            raise ContractValidationError(
                f"grant.purpose must be 'camera_archive_read', got {grant.get('purpose')!r}"
            )
        _require_str(grant.get("secret_ref"), "grant.secret_ref")
        methods = _require_list(grant.get("allowed_methods"), "grant.allowed_methods")
        if not methods or any(m not in ("HEAD", "GET") for m in methods):
            raise ContractValidationError(
                f"grant.allowed_methods must be a non-empty subset of ('HEAD', 'GET'), got {methods!r}"
            )
        for list_field in ("allowed_schemes", "allowed_hosts", "allowed_ports", "allowed_paths"):
            _require_list(grant.get(list_field), f"grant.{list_field}")
        _require_str(grant.get("expires_at"), "grant.expires_at")

        cred = _require_dict(obj.get("credential"), "credential")
        allowed_cred_keys = {"reference", "generation", "role", "secret_id"}
        extra_cred = set(cred.keys()) - allowed_cred_keys
        if extra_cred:
            raise ContractValidationError(
                f"credential contains unexpected non-redacted keys: {sorted(extra_cred)}"
            )
        _require_str(cred.get("reference"), "credential.reference")
        _require_int(cred.get("generation"), "credential.generation", min_value=1)
        if cred.get("role") != "reader":
            raise ContractValidationError("credential.role must be 'reader'")
        _require_uuid(cred.get("secret_id"), "credential.secret_id")
    else:
        if obj.get("read_pool") != "analysis_read":
            raise ContractValidationError("local read grant read_pool must be 'analysis_read'")
        _require_str(obj.get("nvr_member"), "nvr_member")
        expected_init_path = f"/v1/blocks/{block_key}/init"
        if init.get("path") != expected_init_path:
            raise ContractValidationError(
                f"init.path ({init.get('path')!r}) must equal {expected_init_path!r}"
            )
        local = _require_dict(obj.get("local"), "local")
        _require_str(local.get("nvr_member"), "local.nvr_member")
        if local.get("storage_id") != storage_id:
            raise ContractValidationError("local.storage_id must match top-level storage_id")
        if local.get("block_key") != block_key:
            raise ContractValidationError("local.block_key must match top-level block_key")
        if local.get("pool") != "analysis_read" or local.get("purpose") != "analysis_read":
            raise ContractValidationError("local.pool and local.purpose must be 'analysis_read'")
        if local.get("init_path") != expected_init_path:
            raise ContractValidationError("local.init_path must match init.path")
        for forbidden_archive_key in ("media", "archive", "grant", "credential"):
            if obj.get(forbidden_archive_key) is not None:
                raise ContractValidationError(
                    f"local read grant must omit {forbidden_archive_key}"
                )

    return obj


# ---------------------------------------------------------------------------
# Crop Box Geometry (frame.rs + thumbnail.rs parity)
# ---------------------------------------------------------------------------


def compute_padded_crop_box(
    frame_w: int,
    frame_h: int,
    bbox: Sequence[float],
    padding_ratio: float = 0.15,
    min_bbox_width_px: int = 96,
    max_dimension: int = MAX_CROP_DIMENSION_PX,
) -> dict[str, Any]:
    """Compute padded native crop coordinates and bounded output dimensions.

    Matches `rust/media-core/src/frame.rs` (`floor`/`ceil` clamping) and
    `thumbnail.rs` (`round().max(1)` aspect-preserving downscale), returning an
    explicit skip descriptor with `reason == "crop_below_min_dimension"` when
    the unpadded native width is `< min_bbox_width_px`.
    """
    _require_int(frame_w, "frame_w", min_value=1, max_value=MAX_FRAME_DIMENSION)
    _require_int(frame_h, "frame_h", min_value=1, max_value=MAX_FRAME_DIMENSION)
    _require_float(padding_ratio, "padding_ratio", min_value=0.0)
    _require_int(min_bbox_width_px, "min_bbox_width_px", min_value=1)
    _require_int(max_dimension, "max_dimension", min_value=1)

    if not isinstance(bbox, (list, tuple)) or len(bbox) != 4:
        raise ContractValidationError("bbox must be a 4-element sequence [x1, y1, x2, y2]")
    raw_coords = [_require_float(v, f"bbox[{i}]") for i, v in enumerate(bbox)]
    x1 = min(max(raw_coords[0], 0.0), 1.0)
    y1 = min(max(raw_coords[1], 0.0), 1.0)
    x2 = min(max(raw_coords[2], 0.0), 1.0)
    y2 = min(max(raw_coords[3], 0.0), 1.0)
    if not (x2 > x1 and y2 > y1):
        raise ContractValidationError("clamped bbox must satisfy x2 > x1 and y2 > y1")

    raw_w = (x2 - x1) * frame_w
    rounded_w = round(raw_w)
    if rounded_w < min_bbox_width_px:
        return {
            "status": "skipped",
            "reason": "crop_below_min_dimension",
            "raw_width_px": raw_w,
            "rounded_width_px": rounded_w,
            "min_bbox_width_px": min_bbox_width_px,
        }

    bw = x2 - x1
    bh = y2 - y1
    nx1 = max(0.0, x1 - bw * padding_ratio)
    ny1 = max(0.0, y1 - bh * padding_ratio)
    nx2 = min(1.0, x2 + bw * padding_ratio)
    ny2 = min(1.0, y2 + bh * padding_ratio)

    px1 = min(int(math.floor(nx1 * frame_w)), frame_w - 1)
    py1 = min(int(math.floor(ny1 * frame_h)), frame_h - 1)
    px2 = max(px1 + 1, min(frame_w, int(math.ceil(nx2 * frame_w))))
    py2 = max(py1 + 1, min(frame_h, int(math.ceil(ny2 * frame_h))))
    crop_w = px2 - px1
    crop_h = py2 - py1

    if crop_w <= max_dimension and crop_h <= max_dimension:
        out_w, out_h = crop_w, crop_h
    else:
        scale = min(max_dimension / float(crop_w), max_dimension / float(crop_h))
        out_w = max(1, int(round(crop_w * scale)))
        out_h = max(1, int(round(crop_h * scale)))

    return {
        "status": "ok",
        "reason": None,
        "raw_width_px": raw_w,
        "px1": px1,
        "py1": py1,
        "px2": px2,
        "py2": py2,
        "crop_w": crop_w,
        "crop_h": crop_h,
        "out_w": out_w,
        "out_h": out_h,
    }


# ---------------------------------------------------------------------------
# Pure-Python Baseline Sequential JFIF 1.01 Encoder & Strict Validator
# ---------------------------------------------------------------------------

_ZIGZAG: tuple[int, ...] = (
    0, 1, 8, 16, 9, 2, 3, 10, 17, 24, 32, 25, 18, 11, 4, 5, 12, 19, 26, 33, 40, 48, 41, 34, 27, 20,
    13, 6, 7, 14, 21, 28, 35, 42, 49, 56, 57, 50, 43, 36, 29, 22, 15, 23, 30, 37, 44, 51, 58, 59,
    52, 45, 38, 31, 39, 46, 53, 60, 61, 54, 47, 55, 62, 63,
)

_STD_LUM_QUANT: tuple[int, ...] = (
    16, 11, 10, 16, 24, 40, 51, 61, 12, 12, 14, 19, 26, 58, 60, 55, 14, 13, 16, 24, 40, 57, 69, 56,
    14, 17, 22, 29, 51, 87, 80, 62, 18, 22, 37, 56, 68, 109, 103, 77, 24, 35, 55, 64, 81, 104, 113,
    92, 49, 64, 78, 87, 103, 121, 120, 101, 72, 92, 95, 98, 112, 100, 103, 99,
)

_STD_CHROM_QUANT: tuple[int, ...] = (
    17, 18, 24, 47, 99, 99, 99, 99, 18, 21, 26, 66, 99, 99, 99, 99, 24, 26, 56, 99, 99, 99, 99, 99,
    47, 66, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99,
    99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99,
)

_STD_DC_LUM_NRCODES: tuple[int, ...] = (0, 1, 5, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0)
_STD_DC_LUM_VALUES: tuple[int, ...] = (0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11)

_STD_DC_CHROM_NRCODES: tuple[int, ...] = (0, 3, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0)
_STD_DC_CHROM_VALUES: tuple[int, ...] = (0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11)

_STD_AC_LUM_NRCODES: tuple[int, ...] = (0, 2, 1, 3, 3, 2, 4, 3, 5, 5, 4, 4, 0, 0, 1, 125)
_STD_AC_LUM_VALUES: tuple[int, ...] = (
    0x01, 0x02, 0x03, 0x00, 0x04, 0x11, 0x05, 0x12, 0x21, 0x31, 0x41, 0x06, 0x13, 0x51, 0x61, 0x07,
    0x22, 0x71, 0x14, 0x32, 0x81, 0x91, 0xA1, 0x08, 0x23, 0x42, 0xB1, 0xC1, 0x15, 0x52, 0xD1, 0xF0,
    0x24, 0x33, 0x62, 0x72, 0x82, 0x09, 0x0A, 0x16, 0x17, 0x18, 0x19, 0x1A, 0x25, 0x26, 0x27, 0x28,
    0x29, 0x2A, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39, 0x3A, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48, 0x49,
    0x4A, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59, 0x5A, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68, 0x69,
    0x6A, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78, 0x79, 0x7A, 0x83, 0x84, 0x85, 0x86, 0x87, 0x88, 0x89,
    0x8A, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97, 0x98, 0x99, 0x9A, 0xA2, 0xA3, 0xA4, 0xA5, 0xA6, 0xA7,
    0xA8, 0xA9, 0xAA, 0xB2, 0xB3, 0xB4, 0xB5, 0xB6, 0xB7, 0xB8, 0xB9, 0xBA, 0xC2, 0xC3, 0xC4, 0xC5,
    0xC6, 0xC7, 0xC8, 0xC9, 0xCA, 0xD2, 0xD3, 0xD4, 0xD5, 0xD6, 0xD7, 0xD8, 0xD9, 0xDA, 0xE1, 0xE2,
    0xE3, 0xE4, 0xE5, 0xE6, 0xE7, 0xE8, 0xE9, 0xEA, 0xF1, 0xF2, 0xF3, 0xF4, 0xF5, 0xF6, 0xF7, 0xF8,
    0xF9, 0xFA,
)

_STD_AC_CHROM_NRCODES: tuple[int, ...] = (0, 2, 1, 2, 4, 4, 3, 4, 7, 5, 4, 4, 0, 1, 2, 119)
_STD_AC_CHROM_VALUES: tuple[int, ...] = (
    0x00, 0x01, 0x02, 0x03, 0x11, 0x04, 0x05, 0x21, 0x31, 0x06, 0x12, 0x41, 0x51, 0x07, 0x61, 0x71,
    0x13, 0x22, 0x32, 0x81, 0x08, 0x14, 0x42, 0x91, 0xA1, 0xB1, 0xC1, 0x09, 0x23, 0x33, 0x52, 0xF0,
    0x15, 0x62, 0x72, 0xD1, 0x0A, 0x16, 0x24, 0x34, 0xE1, 0x25, 0xF1, 0x17, 0x18, 0x19, 0x1A, 0x26,
    0x27, 0x28, 0x29, 0x2A, 0x35, 0x36, 0x37, 0x38, 0x39, 0x3A, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48,
    0x49, 0x4A, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59, 0x5A, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68,
    0x69, 0x6A, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78, 0x79, 0x7A, 0x82, 0x83, 0x84, 0x85, 0x86, 0x87,
    0x88, 0x89, 0x8A, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97, 0x98, 0x99, 0x9A, 0xA2, 0xA3, 0xA4, 0xA5,
    0xA6, 0xA7, 0xA8, 0xA9, 0xAA, 0xB2, 0xB3, 0xB4, 0xB5, 0xB6, 0xB7, 0xB8, 0xB9, 0xBA, 0xC2, 0xC3,
    0xC4, 0xC5, 0xC6, 0xC7, 0xC8, 0xC9, 0xCA, 0xD2, 0xD3, 0xD4, 0xD5, 0xD6, 0xD7, 0xD8, 0xD9, 0xDA,
    0xE2, 0xE3, 0xE4, 0xE5, 0xE6, 0xE7, 0xE8, 0xE9, 0xEA, 0xF2, 0xF3, 0xF4, 0xF5, 0xF6, 0xF7, 0xF8,
    0xF9, 0xFA,
)


def _build_huffman_table(
    nrcodes: tuple[int, ...], values: tuple[int, ...]
) -> list[tuple[int, int]]:
    table: list[tuple[int, int]] = [(0, 0)] * 256
    code = 0
    val_idx = 0
    for len_minus_1, count in enumerate(nrcodes):
        bit_len = len_minus_1 + 1
        for _ in range(count):
            sym = values[val_idx]
            table[sym] = (code, bit_len)
            code += 1
            val_idx += 1
        code <<= 1
    return table


_DC_LUM_HUFF = _build_huffman_table(_STD_DC_LUM_NRCODES, _STD_DC_LUM_VALUES)
_AC_LUM_HUFF = _build_huffman_table(_STD_AC_LUM_NRCODES, _STD_AC_LUM_VALUES)
_DC_CHROM_HUFF = _build_huffman_table(_STD_DC_CHROM_NRCODES, _STD_DC_CHROM_VALUES)
_AC_CHROM_HUFF = _build_huffman_table(_STD_AC_CHROM_NRCODES, _STD_AC_CHROM_VALUES)

_COS_T: tuple[tuple[float, ...], ...] = tuple(
    tuple(
        0.5
        * (1.0 / math.sqrt(2.0) if u == 0 else 1.0)
        * math.cos(((2 * x + 1) * u * math.pi) / 16.0)
        for x in range(8)
    )
    for u in range(8)
)

_MAGNITUDE_TABLE: tuple[tuple[int, int], ...] = tuple(
    (0, 0)
    if v == 0
    else (
        abs(v).bit_length(),
        v if v > 0 else (v + ((1 << abs(v).bit_length()) - 1)) & ((1 << abs(v).bit_length()) - 1),
    )
    for v in range(-2047, 2048)
)


def _encode_magnitude(val: int) -> tuple[int, int]:
    if -2047 <= val <= 2047:
        return _MAGNITUDE_TABLE[val + 2047]
    if val == 0:
        return (0, 0)
    cat = abs(val).bit_length()
    bits = val if val > 0 else (val + ((1 << cat) - 1)) & ((1 << cat) - 1)
    return (cat, bits)


def _scale_quant_table(base: tuple[int, ...], quality: int) -> list[int]:
    q = max(1, min(100, quality))
    scale = (5000 // q) if q < 50 else (200 - 2 * q)
    return [max(1, min(255, (b * scale + 50) // 100)) for b in base]


def _forward_dct_8x8(block: list[float]) -> list[float]:
    c0, c1, c2, c3, c4, c5, c6, c7 = _COS_T
    tmp = [0.0] * 64
    for r in range(8):
        off = r * 8
        b0, b1, b2, b3, b4, b5, b6, b7 = block[off : off + 8]
        tmp[off] = c0[0] * b0 + c0[1] * b1 + c0[2] * b2 + c0[3] * b3 + c0[4] * b4 + c0[5] * b5 + c0[6] * b6 + c0[7] * b7
        tmp[off + 1] = c1[0] * b0 + c1[1] * b1 + c1[2] * b2 + c1[3] * b3 + c1[4] * b4 + c1[5] * b5 + c1[6] * b6 + c1[7] * b7
        tmp[off + 2] = c2[0] * b0 + c2[1] * b1 + c2[2] * b2 + c2[3] * b3 + c2[4] * b4 + c2[5] * b5 + c2[6] * b6 + c2[7] * b7
        tmp[off + 3] = c3[0] * b0 + c3[1] * b1 + c3[2] * b2 + c3[3] * b3 + c3[4] * b4 + c3[5] * b5 + c3[6] * b6 + c3[7] * b7
        tmp[off + 4] = c4[0] * b0 + c4[1] * b1 + c4[2] * b2 + c4[3] * b3 + c4[4] * b4 + c4[5] * b5 + c4[6] * b6 + c4[7] * b7
        tmp[off + 5] = c5[0] * b0 + c5[1] * b1 + c5[2] * b2 + c5[3] * b3 + c5[4] * b4 + c5[5] * b5 + c5[6] * b6 + c5[7] * b7
        tmp[off + 6] = c6[0] * b0 + c6[1] * b1 + c6[2] * b2 + c6[3] * b3 + c6[4] * b4 + c6[5] * b5 + c6[6] * b6 + c6[7] * b7
        tmp[off + 7] = c7[0] * b0 + c7[1] * b1 + c7[2] * b2 + c7[3] * b3 + c7[4] * b4 + c7[5] * b5 + c7[6] * b6 + c7[7] * b7

    out = [0.0] * 64
    for col in range(8):
        t0 = tmp[col]
        t1 = tmp[8 + col]
        t2 = tmp[16 + col]
        t3 = tmp[24 + col]
        t4 = tmp[32 + col]
        t5 = tmp[40 + col]
        t6 = tmp[48 + col]
        t7 = tmp[56 + col]
        out[col] = c0[0] * t0 + c0[1] * t1 + c0[2] * t2 + c0[3] * t3 + c0[4] * t4 + c0[5] * t5 + c0[6] * t6 + c0[7] * t7
        out[8 + col] = c1[0] * t0 + c1[1] * t1 + c1[2] * t2 + c1[3] * t3 + c1[4] * t4 + c1[5] * t5 + c1[6] * t6 + c1[7] * t7
        out[16 + col] = c2[0] * t0 + c2[1] * t1 + c2[2] * t2 + c2[3] * t3 + c2[4] * t4 + c2[5] * t5 + c2[6] * t6 + c2[7] * t7
        out[24 + col] = c3[0] * t0 + c3[1] * t1 + c3[2] * t2 + c3[3] * t3 + c3[4] * t4 + c3[5] * t5 + c3[6] * t6 + c3[7] * t7
        out[32 + col] = c4[0] * t0 + c4[1] * t1 + c4[2] * t2 + c4[3] * t3 + c4[4] * t4 + c4[5] * t5 + c4[6] * t6 + c4[7] * t7
        out[40 + col] = c5[0] * t0 + c5[1] * t1 + c5[2] * t2 + c5[3] * t3 + c5[4] * t4 + c5[5] * t5 + c5[6] * t6 + c5[7] * t7
        out[48 + col] = c6[0] * t0 + c6[1] * t1 + c6[2] * t2 + c6[3] * t3 + c6[4] * t4 + c6[5] * t5 + c6[6] * t6 + c6[7] * t7
        out[56 + col] = c7[0] * t0 + c7[1] * t1 + c7[2] * t2 + c7[3] * t3 + c7[4] * t4 + c7[5] * t5 + c7[6] * t6 + c7[7] * t7
    return out


class _JpegBitWriter:
    __slots__ = ("buf", "bit_buf", "bit_count")

    def __init__(self) -> None:
        self.buf = bytearray()
        self.bit_buf = 0
        self.bit_count = 0

    def write_bits(self, value: int, length: int) -> None:
        if length == 0:
            return
        mask = (1 << length) - 1
        self.bit_buf = (self.bit_buf << length) | (value & mask)
        self.bit_count += length
        while self.bit_count >= 8:
            self.bit_count -= 8
            byte = (self.bit_buf >> self.bit_count) & 0xFF
            self.buf.append(byte)
            if byte == 0xFF:
                self.buf.append(0x00)
        self.bit_buf &= (1 << self.bit_count) - 1 if self.bit_count else 0

    def flush(self) -> None:
        if self.bit_count > 0:
            pad = 8 - self.bit_count
            ones = (1 << pad) - 1
            self.write_bits(ones, pad)

    def encode_block(
        self,
        dct: list[float],
        quant: list[int],
        prev_dc: int,
        dc_table: list[tuple[int, int]],
        ac_table: list[tuple[int, int]],
    ) -> int:
        zz = [int(round(dct[z_idx] / quant[z_idx])) for z_idx in _ZIGZAG]

        dc_diff = zz[0] - prev_dc
        prev_dc = zz[0]
        dc_cat, dc_bits = _encode_magnitude(dc_diff)
        h_code, h_len = dc_table[dc_cat]
        self.write_bits(h_code, h_len)
        self.write_bits(dc_bits, dc_cat)

        zero_run = 0
        zrl_code, zrl_len = ac_table[0xF0]
        for coeff in zz[1:]:
            if coeff == 0:
                zero_run += 1
            else:
                while zero_run >= 16:
                    self.write_bits(zrl_code, zrl_len)
                    zero_run -= 16
                cat, bits = _encode_magnitude(coeff)
                sym = (zero_run << 4) | cat
                ac_code, ac_len = ac_table[sym]
                self.write_bits(ac_code, ac_len)
                self.write_bits(bits, cat)
                zero_run = 0
        if zero_run > 0:
            eob_code, eob_len = ac_table[0x00]
            self.write_bits(eob_code, eob_len)
        return prev_dc


def _generate_synthetic_rgb(width: int, height: int, seed: int) -> bytearray:
    """Create a deterministic synthetic RGB8 image with geometric plate/bay bands."""
    rgb = bytearray(width * height * 3)
    s0 = (seed * 37 + 19) & 0xFF
    s1 = (seed * 73 + 53) & 0xFF
    s2 = (seed * 131 + 97) & 0xFF

    plate_x0 = width // 4
    plate_x1 = (width * 3) // 4
    plate_y0 = height // 3
    plate_y1 = (height * 2) // 3

    idx = 0
    for y in range(height):
        y_grad = (y * 200) // max(1, height - 1)
        in_plate_y = plate_y0 <= y < plate_y1
        for x in range(width):
            x_grad = (x * 200) // max(1, width - 1)
            if in_plate_y and plate_x0 <= x < plate_x1:
                # High-contrast synthetic plate bar pattern to exercise AC coefficients
                stripe = ((x - plate_x0) // max(2, width // 32)) % 2
                if stripe == 0:
                    r = (230 + (s0 & 0x0F)) & 0xFF
                    g = (232 + (s1 & 0x0F)) & 0xFF
                    b = (225 + (s2 & 0x0F)) & 0xFF
                else:
                    r = (28 + (s0 & 0x1F)) & 0xFF
                    g = (36 + (s1 & 0x1F)) & 0xFF
                    b = (64 + (s2 & 0x1F)) & 0xFF
            else:
                r = (40 + x_grad + s0) % 256
                g = (60 + y_grad + s1) % 256
                b = (80 + ((x_grad ^ y_grad) & 0x7F) + s2) % 256
            rgb[idx] = r
            rgb[idx + 1] = g
            rgb[idx + 2] = b
            idx += 3
    return rgb


def _downscale_rgb_box(rgb: bytearray, sw: int, sh: int, dw: int, dh: int) -> bytearray:
    out = bytearray(dw * dh * 3)
    out_idx = 0
    for dy in range(dh):
        sy0 = (dy * sh) // dh
        sy1 = min(sh, max(sy0 + 1, ((dy + 1) * sh) // dh))
        for dx in range(dw):
            sx0 = (dx * sw) // dw
            sx1 = min(sw, max(sx0 + 1, ((dx + 1) * sw) // dw))
            r_sum = 0
            g_sum = 0
            b_sum = 0
            cnt = 0
            for sy in range(sy0, sy1):
                row_base = sy * sw * 3
                for sx in range(sx0, sx1):
                    off = row_base + sx * 3
                    r_sum += rgb[off]
                    g_sum += rgb[off + 1]
                    b_sum += rgb[off + 2]
                    cnt += 1
            c = max(1, cnt)
            out[out_idx] = r_sum // c
            out[out_idx + 1] = g_sum // c
            out[out_idx + 2] = b_sum // c
            out_idx += 3
    return out


def _encode_baseline_jfif_rgb(rgb: bytearray, width: int, height: int, quality: int) -> bytes:
    q_lum = _scale_quant_table(_STD_LUM_QUANT, quality)
    q_chrom = _scale_quant_table(_STD_CHROM_QUANT, quality)

    out = bytearray()
    # SOI
    out.extend(b"\xFF\xD8")
    # APP0 (JFIF 1.01)
    out.extend(
        b"\xFF\xE0\x00\x10JFIF\x00\x01\x01\x00\x00\x01\x00\x01\x00\x00"
    )
    # DQT (Lum=0, Chrom=1) in zigzag order
    out.extend(b"\xFF\xDB\x00\x43\x00")
    out.extend(bytes(q_lum[z] for z in _ZIGZAG))
    out.extend(b"\xFF\xDB\x00\x43\x01")
    out.extend(bytes(q_chrom[z] for z in _ZIGZAG))

    # SOF0 (Baseline DCT, 8-bit, 3 components 4:4:4)
    out.extend(b"\xFF\xC0\x00\x11\x08")
    out.extend(height.to_bytes(2, "big"))
    out.extend(width.to_bytes(2, "big"))
    out.extend(b"\x03\x01\x11\x00\x02\x11\x01\x03\x11\x01")

    # DHT (DC Lum, AC Lum, DC Chrom, AC Chrom)
    for class_id, nrcodes, values in (
        (0x00, _STD_DC_LUM_NRCODES, _STD_DC_LUM_VALUES),
        (0x10, _STD_AC_LUM_NRCODES, _STD_AC_LUM_VALUES),
        (0x01, _STD_DC_CHROM_NRCODES, _STD_DC_CHROM_VALUES),
        (0x11, _STD_AC_CHROM_NRCODES, _STD_AC_CHROM_VALUES),
    ):
        seg_len = 2 + 1 + 16 + len(values)
        out.extend(b"\xFF\xC4")
        out.extend(seg_len.to_bytes(2, "big"))
        out.append(class_id)
        out.extend(bytes(nrcodes))
        out.extend(bytes(values))

    # SOS
    out.extend(b"\xFF\xDA\x00\x0C\x03\x01\x00\x02\x11\x03\x11\x00\x3F\x00")

    bw = _JpegBitWriter()
    prev_dc_y = 0
    prev_dc_cb = 0
    prev_dc_cr = 0
    y_block = [0.0] * 64
    cb_block = [0.0] * 64
    cr_block = [0.0] * 64
    max_x = width - 1
    max_y = height - 1

    for by in range(0, height, 8):
        for bx in range(0, width, 8):
            idx = 0
            for dy in range(8):
                py = by + dy
                if py > max_y:
                    py = max_y
                row_base = py * width * 3
                for dx in range(8):
                    px = bx + dx
                    if px > max_x:
                        px = max_x
                    off = row_base + px * 3
                    rf = float(rgb[off])
                    gf = float(rgb[off + 1])
                    bf = float(rgb[off + 2])
                    y_block[idx] = (0.299 * rf + 0.587 * gf + 0.114 * bf) - 128.0
                    cb_block[idx] = -0.168736 * rf - 0.331264 * gf + 0.5 * bf
                    cr_block[idx] = 0.5 * rf - 0.418688 * gf - 0.081312 * bf
                    idx += 1

            y_dct = _forward_dct_8x8(y_block)
            cb_dct = _forward_dct_8x8(cb_block)
            cr_dct = _forward_dct_8x8(cr_block)

            prev_dc_y = bw.encode_block(y_dct, q_lum, prev_dc_y, _DC_LUM_HUFF, _AC_LUM_HUFF)
            prev_dc_cb = bw.encode_block(cb_dct, q_chrom, prev_dc_cb, _DC_CHROM_HUFF, _AC_CHROM_HUFF)
            prev_dc_cr = bw.encode_block(cr_dct, q_chrom, prev_dc_cr, _DC_CHROM_HUFF, _AC_CHROM_HUFF)

    bw.flush()
    out.extend(bw.buf)
    # EOI
    out.extend(b"\xFF\xD9")
    return bytes(out)


def make_synthetic_baseline_jfif(
    width: int,
    height: int,
    seed: int = 1,
    target_max_bytes: int | None = MAX_PERSISTED_CROP_BYTES,
    quality: int = 85,
    min_quality: int = 35,
) -> bytes:
    """Deterministically generate a Baseline Sequential JFIF 1.01 JPEG (pure Python).

    Mirrors `rust/media-core/src/thumbnail.rs`: BT.601 YCbCr 4:4:4, 2D FDCT,
    Annex K tables, `0xFF -> 0xFF 0x00` byte-stuffing, and iterative quality step-down
    + 3:4 downscale when `target_max_bytes` is provided.
    """
    _require_int(width, "width", min_value=1, max_value=MAX_FRAME_DIMENSION)
    _require_int(height, "height", min_value=1, max_value=MAX_FRAME_DIMENSION)
    _require_int(seed, "seed")
    _require_int(quality, "quality", min_value=1, max_value=100)
    _require_int(min_quality, "min_quality", min_value=1, max_value=quality)
    if target_max_bytes is not None:
        _require_int(target_max_bytes, "target_max_bytes", min_value=512)

    cur_w, cur_h = width, height
    rgb = _generate_synthetic_rgb(cur_w, cur_h, seed)
    cur_q = quality

    while True:
        encoded = _encode_baseline_jfif_rgb(rgb, cur_w, cur_h, cur_q)
        if target_max_bytes is None or len(encoded) <= target_max_bytes:
            return encoded

        if cur_q > min_quality:
            cur_q = max(min_quality, cur_q - 15)
            continue

        if cur_w > 32 and cur_h > 32:
            next_w = max(32, (cur_w * 3) // 4)
            next_h = max(32, (cur_h * 3) // 4)
            rgb = _downscale_rgb_box(rgb, cur_w, cur_h, next_w, next_h)
            cur_w, cur_h = next_w, next_h
            continue

        raise ContractValidationError(
            f"synthetic JFIF ({len(encoded)} bytes at {cur_w}x{cur_h}, q={cur_q}) "
            f"exceeds target_max_bytes ({target_max_bytes})"
        )


def validate_baseline_jfif(
    jpeg_bytes: bytes | bytearray,
    *,
    max_bytes: int | None = None,
) -> dict[str, int]:
    """Strictly parse and validate a Baseline Sequential JFIF JPEG byte stream."""
    if not isinstance(jpeg_bytes, (bytes, bytearray)):
        raise ContractValidationError("jpeg_bytes must be bytes or bytearray")
    data = bytes(jpeg_bytes)
    n = len(data)
    if max_bytes is not None and n > max_bytes:
        raise ContractValidationError(f"JPEG length {n} exceeds max_bytes {max_bytes}")
    if n < 4 or data[:2] != b"\xFF\xD8":
        raise ContractValidationError("missing JPEG SOI marker (0xFF 0xD8)")
    if data[-2:] != b"\xFF\xD9":
        raise ContractValidationError("missing JPEG EOI marker (0xFF 0xD9)")

    pos = 2
    end = n - 2
    has_jfif = False
    dqt_count = 0
    dht_count = 0
    sof0_dims: tuple[int, int] | None = None
    saw_sos = False

    while pos < end:
        if data[pos] != 0xFF:
            raise ContractValidationError(
                f"expected 0xFF marker prefix at offset {pos}, got 0x{data[pos]:02X}"
            )
        if pos + 1 >= end:
            raise ContractValidationError(f"truncated marker at offset {pos}")
        marker = data[pos + 1]
        pos += 2

        if marker in (0x00, 0xFF):
            raise ContractValidationError(f"invalid marker 0xFF{marker:02X} before SOS")
        if marker == 0xD9:
            raise ContractValidationError("premature EOI marker before SOS")
        if marker == 0x01 or (0xD0 <= marker <= 0xD7):
            raise ContractValidationError(f"unexpected standalone marker 0xFF{marker:02X} before SOS")

        if pos + 2 > end:
            raise ContractValidationError(f"truncated segment length for marker 0xFF{marker:02X}")
        seg_len = int.from_bytes(data[pos : pos + 2], "big")
        if seg_len < 2 or pos + seg_len > end:
            raise ContractValidationError(
                f"invalid segment length {seg_len} for marker 0xFF{marker:02X} at offset {pos}"
            )
        seg = data[pos + 2 : pos + seg_len]
        pos += seg_len

        if marker == 0xE0:
            if len(seg) >= 14 and seg[:5] == b"JFIF\x00":
                has_jfif = True
        elif marker == 0xDB:
            # Parse one or more quantization tables inside DQT
            q_off = 0
            while q_off < len(seg):
                pq_tq = seg[q_off]
                pq = pq_tq >> 4
                tbl_size = 64 if pq == 0 else 128
                if pq not in (0, 1) or q_off + 1 + tbl_size > len(seg):
                    raise ContractValidationError("malformed DQT segment")
                dqt_count += 1
                q_off += 1 + tbl_size
        elif marker == 0xC4:
            # Parse one or more Huffman tables inside DHT
            h_off = 0
            while h_off < len(seg):
                if h_off + 17 > len(seg):
                    raise ContractValidationError("malformed DHT segment header")
                nr_sum = sum(seg[h_off + 1 : h_off + 17])
                if h_off + 17 + nr_sum > len(seg):
                    raise ContractValidationError("malformed DHT symbol table length")
                dht_count += 1
                h_off += 17 + nr_sum
        elif marker in (
            0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7, 0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF
        ):
            raise ContractValidationError(
                f"progressive or non-baseline SOF marker 0xFF{marker:02X} is forbidden"
            )
        elif marker == 0xC0:
            if sof0_dims is not None:
                raise ContractValidationError("duplicate SOF0 marker")
            if len(seg) < 6:
                raise ContractValidationError("truncated SOF0 segment")
            precision = seg[0]
            height = int.from_bytes(seg[1:3], "big")
            width = int.from_bytes(seg[3:5], "big")
            num_comp = seg[5]
            if precision != 8:
                raise ContractValidationError(f"SOF0 sample precision must be 8, got {precision}")
            if width == 0 or height == 0:
                raise ContractValidationError(f"SOF0 dimensions must be > 0, got {width}x{height}")
            if num_comp != 3 or len(seg) != 6 + 3 * num_comp:
                raise ContractValidationError(
                    f"SOF0 must specify 3 components (len={6 + 3 * 3}), got num_comp={num_comp}"
                )
            sof0_dims = (width, height)
        elif marker == 0xDA:
            if len(seg) < 6:
                raise ContractValidationError("truncated SOS segment")
            num_comp = seg[0]
            if num_comp != 3 or len(seg) != 1 + 2 * num_comp + 3:
                raise ContractValidationError("SOS must reference 3 components")
            saw_sos = True
            break

    if not saw_sos:
        raise ContractValidationError("missing SOS marker")
    if not has_jfif:
        raise ContractValidationError("missing APP0 JFIF header")
    if dqt_count < 2:
        raise ContractValidationError(f"expected >= 2 DQT tables, found {dqt_count}")
    if dht_count < 4:
        raise ContractValidationError(f"expected >= 4 DHT tables, found {dht_count}")
    if sof0_dims is None:
        raise ContractValidationError("missing SOF0 baseline marker")

    if pos >= end:
        raise ContractValidationError("empty JPEG entropy scan before EOI")

    scan_idx = pos
    while scan_idx < end:
        if data[scan_idx] == 0xFF:
            if scan_idx + 1 >= end or data[scan_idx + 1] != 0x00:
                next_b = f"0x{data[scan_idx + 1]:02X}" if scan_idx + 1 < end else "EOF"
                raise ContractValidationError(
                    f"unstuffed 0xFF ({next_b}) in entropy scan at offset {scan_idx}"
                )
            scan_idx += 2
        else:
            scan_idx += 1

    return {
        "width": sof0_dims[0],
        "height": sof0_dims[1],
        "byte_length": n,
        "dqt_count": dqt_count,
        "dht_count": dht_count,
    }


# ---------------------------------------------------------------------------
# Deterministic POSIX.1-1988 USTAR & Solution Pack v1/v2 Validator
# ---------------------------------------------------------------------------


def _normalize_archive_path(raw_path: str) -> str:
    if not isinstance(raw_path, str) or not raw_path:
        raise ContractValidationError("archive entry path must be a non-empty string")
    if "\x00" in raw_path or "\\" in raw_path:
        raise ContractValidationError(f"forbidden character in archive path {raw_path!r}")
    if raw_path.startswith("/") or raw_path.endswith("/"):
        raise ContractValidationError(f"leading/trailing slash forbidden in archive path {raw_path!r}")
    segments = raw_path.split("/")
    if any(seg in ("", ".", "..") for seg in segments):
        raise ContractValidationError(f"unsafe traversal/empty segment in archive path {raw_path!r}")
    encoded = raw_path.encode("utf-8")
    if len(encoded) > MAX_USTAR_PATH_BYTES:
        raise ContractValidationError(
            f"archive path {raw_path!r} ({len(encoded)} UTF-8 bytes) exceeds {MAX_USTAR_PATH_BYTES}"
        )
    return raw_path


def _split_ustar_path(normalized_path: str) -> tuple[bytes, bytes]:
    raw = normalized_path.encode("utf-8")
    if len(raw) <= 100:
        return (b"", raw)
    parts = normalized_path.split("/")
    for idx in range(len(parts) - 1, 0, -1):
        prefix = "/".join(parts[:idx]).encode("utf-8")
        name = "/".join(parts[idx:]).encode("utf-8")
        if len(prefix) <= 155 and len(name) <= 100:
            return (prefix, name)
    raise ContractValidationError(
        f"archive path {normalized_path!r} cannot be split into POSIX.1-1988 prefix(<=155)/name(<=100)"
    )


def _encode_ustar_header(path: str, size: int) -> bytes:
    prefix, name = _split_ustar_path(path)
    header = bytearray(512)
    header[0 : len(name)] = name
    header[100:108] = b"0000644\x00"
    header[108:116] = b"0000000\x00"
    header[116:124] = b"0000000\x00"
    size_oct = f"{size:011o}\x00".encode("ascii")
    if len(size_oct) != 12:
        raise ContractValidationError(f"entry {path!r} size {size} overflows USTAR 11-octal field")
    header[124:136] = size_oct
    header[136:148] = b"00000000000\x00"
    header[148:156] = b"        "
    header[156] = ord("0")
    header[257:263] = b"ustar\x00"
    header[263:265] = b"00"
    header[329:337] = b"0000000\x00"
    header[337:345] = b"0000000\x00"
    if prefix:
        header[345 : 345 + len(prefix)] = prefix
    checksum = sum(header)
    header[148:156] = f"{checksum:06o}\x00 ".encode("ascii")
    return bytes(header)


def build_deterministic_ustar(
    tree_files: Mapping[str, bytes | bytearray | str],
    *,
    max_uncompressed_bytes: int = PACK_V2_LIMITS[1],
    max_entries: int = PACK_V2_LIMITS[2],
) -> bytes:
    """Build a deterministic POSIX.1-1988 USTAR tar byte stream matching `archive.ts` and `pack_archive.ex`."""
    if not isinstance(tree_files, Mapping):
        raise ContractValidationError("tree_files must be a mapping")
    if len(tree_files) > max_entries:
        raise ContractValidationError(f"archive entry count {len(tree_files)} exceeds {max_entries}")

    normalized: dict[str, bytes] = {}
    for raw_path, content in tree_files.items():
        norm_path = _normalize_archive_path(raw_path)
        if norm_path in normalized:
            raise ContractValidationError(f"duplicate archive path {norm_path!r}")
        if isinstance(content, str):
            data = content.encode("utf-8")
        elif isinstance(content, (bytes, bytearray)):
            data = bytes(content)
        else:
            raise ContractValidationError(f"entry {norm_path!r} content must be bytes or str")
        normalized[norm_path] = data

    sorted_items = sorted(normalized.items(), key=lambda item: item[0].encode("utf-8"))
    chunks: list[bytes] = []
    total_bytes = 0
    for path, data in sorted_items:
        total_bytes += len(data)
        if total_bytes > max_uncompressed_bytes:
            raise ContractValidationError(
                f"uncompressed archive size {total_bytes} exceeds {max_uncompressed_bytes}"
            )
        chunks.append(_encode_ustar_header(path, len(data)))
        if data:
            chunks.append(data)
            rem = len(data) % 512
            if rem:
                chunks.append(b"\x00" * (512 - rem))

    chunks.append(b"\x00" * 1024)
    return b"".join(chunks)


def build_deterministic_targz(
    tree_files: Mapping[str, bytes | bytearray | str],
    *,
    max_compressed_bytes: int = PACK_V2_LIMITS[0],
    max_uncompressed_bytes: int = PACK_V2_LIMITS[1],
    max_entries: int = PACK_V2_LIMITS[2],
) -> bytes:
    """Build a deterministic RFC 1952 `.tar.gz` (`mtime=0`, `OS=0xFF`) matching `archive.ts` fallback."""
    tar_bytes = build_deterministic_ustar(
        tree_files,
        max_uncompressed_bytes=max_uncompressed_bytes,
        max_entries=max_entries,
    )
    gz = bytearray(gzip.compress(tar_bytes, compresslevel=9, mtime=0))
    if len(gz) >= 10:
        gz[4:8] = b"\x00\x00\x00\x00"
        gz[9] = 0xFF
    if len(gz) > max_compressed_bytes:
        raise ContractValidationError(
            f"compressed archive size {len(gz)} exceeds {max_compressed_bytes}"
        )
    return bytes(gz)


def _decode_json_entry(tree_bytes: Mapping[str, bytes], path: str) -> Any:
    if path not in tree_bytes:
        raise ContractValidationError(f"referenced pack file {path!r} is missing from archive")
    try:
        return json.loads(tree_bytes[path].decode("utf-8"))
    except Exception as exc:
        raise ContractValidationError(f"pack JSON file {path!r} is invalid: {exc}") from exc


def _validate_dashboard_module_manifest(
    manifest_obj: Any,
    renderer_bytes: bytes,
    manifest_path: str,
) -> None:
    dm = _require_dict(manifest_obj, manifest_path)
    extra_root = set(dm.keys()) - _DASHBOARD_MANIFEST_ROOT_KEYS
    if extra_root:
        raise ContractValidationError(
            f"{manifest_path} contains unknown root keys: {sorted(extra_root)}"
        )
    if "schema_version" in dm and dm["schema_version"] is not None:
        _require_int(dm["schema_version"], f"{manifest_path}.schema_version", min_value=1, max_value=1)

    dm_id = _require_str(dm.get("id"), f"{manifest_path}.id")
    if not _DASHBOARD_ID_RE.match(dm_id):
        raise ContractValidationError(f"{manifest_path}.id ({dm_id!r}) is invalid")
    _require_str(dm.get("name"), f"{manifest_path}.name")
    _require_semver(dm.get("version"), f"{manifest_path}.version")

    renderer = _require_dict(dm.get("renderer"), f"{manifest_path}.renderer")
    extra_renderer = set(renderer.keys()) - _DASHBOARD_RENDERER_KEYS
    if extra_renderer:
        raise ContractValidationError(
            f"{manifest_path}.renderer has unknown keys: {sorted(extra_renderer)}"
        )
    if renderer.get("kind") != "browser_module":
        raise ContractValidationError(f"{manifest_path}.renderer.kind must be 'browser_module'")
    if renderer.get("interface_version") != "dashboard-browser-module-v1":
        raise ContractValidationError(
            f"{manifest_path}.renderer.interface_version must be 'dashboard-browser-module-v1'"
        )
    if renderer.get("trust") != "trusted":
        raise ContractValidationError(f"{manifest_path}.renderer.trust must be 'trusted'")
    _require_str(renderer.get("artifact"), f"{manifest_path}.renderer.artifact")
    declared_sha = _require_hex64(renderer.get("sha256"), f"{manifest_path}.renderer.sha256", allow_upper=True).lower()
    actual_sha = hashlib.sha256(renderer_bytes).hexdigest()
    if declared_sha != actual_sha:
        raise ContractValidationError(
            f"{manifest_path}.renderer.sha256 ({declared_sha}) != actual renderer SHA-256 ({actual_sha})"
        )

    frames = _require_list(dm.get("data_frames"), f"{manifest_path}.data_frames")
    if not frames:
        raise ContractValidationError(f"{manifest_path}.data_frames must be non-empty")
    seen_frame_ids: set[str] = set()
    for idx, frame in enumerate(frames):
        f = _require_dict(frame, f"{manifest_path}.data_frames[{idx}]")
        extra_f = set(f.keys()) - _DASHBOARD_DATA_FRAME_KEYS
        if extra_f:
            raise ContractValidationError(
                f"{manifest_path}.data_frames[{idx}] has unknown keys: {sorted(extra_f)}"
            )
        fid = _require_str(f.get("id"), f"{manifest_path}.data_frames[{idx}].id")
        if fid in seen_frame_ids:
            raise ContractValidationError(f"{manifest_path}.data_frames duplicate id {fid!r}")
        seen_frame_ids.add(fid)
        _require_str(f.get("query"), f"{manifest_path}.data_frames[{idx}].query")
        _require_enum(
            f.get("encoding"),
            f"{manifest_path}.data_frames[{idx}].encoding",
            ("json_rows", "arrow_ipc"),
        )
        if "required" in f and f["required"] is not None:
            _require_bool(f["required"], f"{manifest_path}.data_frames[{idx}].required")
        if "limit" in f and f["limit"] is not None:
            _require_int(f["limit"], f"{manifest_path}.data_frames[{idx}].limit", min_value=1)
        if "refresh_interval_ms" in f and f["refresh_interval_ms"] is not None:
            _require_int(
                f["refresh_interval_ms"],
                f"{manifest_path}.data_frames[{idx}].refresh_interval_ms",
                min_value=1,
            )

    caps = _require_list(dm.get("capabilities"), f"{manifest_path}.capabilities")
    if not caps:
        raise ContractValidationError(f"{manifest_path}.capabilities must be non-empty")
    seen_caps: set[str] = set()
    for idx, cap in enumerate(caps):
        c = _require_str(cap, f"{manifest_path}.capabilities[{idx}]")
        if c not in ALLOWED_DASHBOARD_CAPABILITIES:
            raise ContractValidationError(
                f"{manifest_path}.capabilities[{idx}] ({c!r}) is not an allowed capability"
            )
        if c in seen_caps:
            raise ContractValidationError(f"{manifest_path}.capabilities duplicate {c!r}")
        seen_caps.add(c)


def validate_pack_v2_tree(
    tree_files: Mapping[str, bytes | bytearray | str],
    *,
    compressed_bytes: int | None = None,
) -> dict[str, Any]:
    """Validate a Solution Pack v1 or v2 file tree, including Pack v2 `dashboard_packages`."""
    if not isinstance(tree_files, Mapping):
        raise ContractValidationError("tree_files must be a mapping")

    tree_bytes: dict[str, bytes] = {}
    for raw_path, raw_content in tree_files.items():
        norm = _normalize_archive_path(raw_path)
        if norm in tree_bytes:
            raise ContractValidationError(f"duplicate pack file path {norm!r}")
        if isinstance(raw_content, str):
            tree_bytes[norm] = raw_content.encode("utf-8")
        elif isinstance(raw_content, (bytes, bytearray)):
            tree_bytes[norm] = bytes(raw_content)
        else:
            raise ContractValidationError(f"pack entry {norm!r} must be bytes or str")

    if "manifest.json" not in tree_bytes:
        raise ContractValidationError("pack tree missing root manifest.json")

    manifest = _require_dict(_decode_json_entry(tree_bytes, "manifest.json"), "manifest.json")
    pack_format_version = _require_int(
        manifest.get("pack_format_version"), "manifest.pack_format_version", min_value=1, max_value=2
    )
    pack_id = _require_reverse_dns(manifest.get("id"), "manifest.id")
    slug = _require_str(manifest.get("slug"), "manifest.slug")
    if not _SLUG_RE.match(slug):
        raise ContractValidationError(f"manifest.slug ({slug!r}) is invalid")
    _require_str(manifest.get("name"), "manifest.name")
    version = _require_semver(manifest.get("version"), "manifest.version")

    resources = _require_dict(manifest.get("resources"), "manifest.resources")
    files_map = _require_dict(manifest.get("files"), "manifest.files")
    if "manifest.json" in files_map:
        raise ContractValidationError("manifest.files must not include 'manifest.json'")

    expected_paths = set(tree_bytes.keys()) - {"manifest.json"}
    declared_paths = set(files_map.keys())
    if declared_paths != expected_paths:
        missing = sorted(expected_paths - declared_paths)
        extra = sorted(declared_paths - expected_paths)
        raise ContractValidationError(
            f"manifest.files parity mismatch (missing={missing}, extra={extra})"
        )
    for rel_path, expected_sha in files_map.items():
        digest = _require_hex64(expected_sha, f"manifest.files[{rel_path!r}]")
        actual = hashlib.sha256(tree_bytes[rel_path]).hexdigest()
        if digest != actual:
            raise ContractValidationError(
                f"SHA-256 mismatch for {rel_path!r}: manifest={digest}, actual={actual}"
            )

    v1_roots = {"manifest.json", "README.md", "checks", "rules", "dashboards", "assets"}
    v2_roots = v1_roots | {"vantage_pipelines", "signal_schemas", "dashboard_packages"}
    allowed_roots = v1_roots if pack_format_version == 1 else v2_roots
    for rel_path in tree_bytes:
        top = rel_path.split("/", 1)[0]
        if top not in allowed_roots:
            raise ContractValidationError(
                f"disallowed pack directory/file {rel_path!r} for pack_format_version={pack_format_version}"
            )

    if pack_format_version == 1:
        for v2_key in ("vantage_pipelines", "signal_schemas", "dashboard_packages"):
            if v2_key in resources:
                raise ContractValidationError(
                    f"resources.{v2_key} is forbidden in pack_format_version=1"
                )
        for v2_root_key in ("worker_dependencies", "dashboard_package_dependencies"):
            if v2_root_key in manifest:
                raise ContractValidationError(
                    f"{v2_root_key} is forbidden in pack_format_version=1"
                )

    for res_key in ("checks", "rules", "dashboards"):
        if res_key in resources and resources[res_key] is not None:
            entries = _require_list(resources[res_key], f"resources.{res_key}")
            for idx, entry in enumerate(entries):
                e = _require_dict(entry, f"resources.{res_key}[{idx}]")
                fpath = _require_str(e.get("file"), f"resources.{res_key}[{idx}].file")
                _decode_json_entry(tree_bytes, fpath)

    has_dashboard_packages = False
    if pack_format_version == 2:
        if "vantage_pipelines" in resources and resources["vantage_pipelines"] is not None:
            pipes = _require_list(resources["vantage_pipelines"], "resources.vantage_pipelines")
            for idx, pipe in enumerate(pipes):
                p = _require_dict(pipe, f"resources.vantage_pipelines[{idx}]")
                fpath = _require_str(p.get("file"), f"resources.vantage_pipelines[{idx}].file")
                if not fpath.startswith("vantage_pipelines/") or not fpath.endswith(".json"):
                    raise ContractValidationError(
                        f"resources.vantage_pipelines[{idx}].file ({fpath!r}) must be under vantage_pipelines/*.json"
                    )
                _decode_json_entry(tree_bytes, fpath)
                if not (isinstance(p.get("id"), str) and p["id"]) and not (
                    isinstance(p.get("slug"), str) and p["slug"]
                ):
                    raise ContractValidationError(
                        f"resources.vantage_pipelines[{idx}] requires 'id' or 'slug'"
                    )

        if "signal_schemas" in resources and resources["signal_schemas"] is not None:
            schemas = _require_list(resources["signal_schemas"], "resources.signal_schemas")
            for idx, sch in enumerate(schemas):
                s = _require_dict(sch, f"resources.signal_schemas[{idx}]")
                fpath = _require_str(s.get("file"), f"resources.signal_schemas[{idx}].file")
                if not fpath.startswith("signal_schemas/") or not fpath.endswith(".json"):
                    raise ContractValidationError(
                        f"resources.signal_schemas[{idx}].file ({fpath!r}) must be under signal_schemas/*.json"
                    )
                _decode_json_entry(tree_bytes, fpath)
                if s.get("display_file") is not None:
                    dpath = _require_str(
                        s["display_file"], f"resources.signal_schemas[{idx}].display_file"
                    )
                    _decode_json_entry(tree_bytes, dpath)
                _require_str(s.get("id"), f"resources.signal_schemas[{idx}].id")
                _require_semver(s.get("version"), f"resources.signal_schemas[{idx}].version")

        declared_dp_slugs: set[str] = set()
        if "dashboard_packages" in resources and resources["dashboard_packages"] is not None:
            dps = _require_list(resources["dashboard_packages"], "resources.dashboard_packages")
            if dps:
                has_dashboard_packages = True
            for idx, dp in enumerate(dps):
                d = _require_dict(dp, f"resources.dashboard_packages[{idx}]")
                dp_slug = _require_str(d.get("slug"), f"resources.dashboard_packages[{idx}].slug")
                if not _SLUG_RE.match(dp_slug):
                    raise ContractValidationError(
                        f"resources.dashboard_packages[{idx}].slug ({dp_slug!r}) is invalid"
                    )
                if dp_slug in declared_dp_slugs:
                    raise ContractValidationError(
                        f"duplicate resources.dashboard_packages slug {dp_slug!r}"
                    )
                declared_dp_slugs.add(dp_slug)
                expected_dir = f"dashboard_packages/{dp_slug}"
                if d.get("dir") is not None and d["dir"] != expected_dir:
                    raise ContractValidationError(
                        f"resources.dashboard_packages[{idx}].dir must be {expected_dir!r}"
                    )
                mfile = _require_str(
                    d.get("manifest_file") or f"{expected_dir}/manifest.json",
                    f"resources.dashboard_packages[{idx}].manifest_file",
                )
                rfile = _require_str(
                    d.get("renderer_file") or f"{expected_dir}/renderer.js",
                    f"resources.dashboard_packages[{idx}].renderer_file",
                )
                if mfile != f"{expected_dir}/manifest.json":
                    raise ContractValidationError(
                        f"resources.dashboard_packages[{idx}].manifest_file ({mfile!r}) must be {expected_dir + '/manifest.json'!r}"
                    )
                if rfile != f"{expected_dir}/renderer.js":
                    raise ContractValidationError(
                        f"resources.dashboard_packages[{idx}].renderer_file ({rfile!r}) must be {expected_dir + '/renderer.js'!r}"
                    )
                if mfile not in tree_bytes:
                    raise ContractValidationError(f"missing dashboard package manifest {mfile!r}")
                if rfile not in tree_bytes:
                    raise ContractValidationError(f"missing dashboard package renderer {rfile!r}")
                if len(tree_bytes[mfile]) > MAX_DASHBOARD_MANIFEST_BYTES:
                    raise ContractValidationError(
                        f"{mfile} size {len(tree_bytes[mfile])} exceeds {MAX_DASHBOARD_MANIFEST_BYTES}"
                    )
                renderer_bytes = tree_bytes[rfile]
                if len(renderer_bytes) > MAX_RENDERER_BYTES:
                    raise ContractValidationError(
                        f"{rfile} size {len(renderer_bytes)} exceeds MAX_RENDERER_BYTES ({MAX_RENDERER_BYTES})"
                    )
                dm_obj = _decode_json_entry(tree_bytes, mfile)
                _validate_dashboard_module_manifest(dm_obj, renderer_bytes, mfile)
                # Explicit double parity check against root manifest.files
                root_sha = files_map[rfile]
                dm_sha = dm_obj["renderer"]["sha256"].lower()
                if root_sha != dm_sha:
                    raise ContractValidationError(
                        f"dashboard renderer SHA-256 mismatch between {mfile} ({dm_sha}) and manifest.files ({root_sha})"
                    )

        for rel_path in sorted(tree_bytes.keys()):
            if rel_path.startswith("dashboard_packages/"):
                parts = rel_path.split("/")
                if len(parts) < 3 or parts[1] not in declared_dp_slugs:
                    raise ContractValidationError(
                        f"unregistered dashboard_packages file {rel_path!r} must belong to a declared resources.dashboard_packages entry"
                    )
                has_dashboard_packages = True

        if "worker_dependencies" in manifest and manifest["worker_dependencies"] is not None:
            wdeps = _require_list(manifest["worker_dependencies"], "manifest.worker_dependencies")
            for idx, wd in enumerate(wdeps):
                w = _require_dict(wd, f"manifest.worker_dependencies[{idx}]")
                _require_str(w.get("capability"), f"manifest.worker_dependencies[{idx}].capability")

        if (
            "dashboard_package_dependencies" in manifest
            and manifest["dashboard_package_dependencies"] is not None
        ):
            dpdeps = _require_list(
                manifest["dashboard_package_dependencies"],
                "manifest.dashboard_package_dependencies",
            )
            for idx, dep in enumerate(dpdeps):
                if isinstance(dep, str):
                    if "@" not in dep or not dep.split("@", 1)[0]:
                        raise ContractValidationError(
                            f"manifest.dashboard_package_dependencies[{idx}] ({dep!r}) invalid"
                        )
                elif isinstance(dep, dict):
                    _require_str(
                        dep.get("dashboard_id"),
                        f"manifest.dashboard_package_dependencies[{idx}].dashboard_id",
                    )
                else:
                    raise ContractValidationError(
                        f"manifest.dashboard_package_dependencies[{idx}] must be str or dict"
                    )

    max_comp, max_uncomp, max_entries = PACK_V2_LIMITS if has_dashboard_packages else PACK_V1_LIMITS
    if len(tree_bytes) > max_entries:
        raise ContractValidationError(f"pack entry count {len(tree_bytes)} exceeds {max_entries}")
    uncompressed_total = sum(len(v) for v in tree_bytes.values())
    if uncompressed_total > max_uncomp:
        raise ContractValidationError(
            f"uncompressed pack size {uncompressed_total} exceeds {max_uncomp}"
        )
    if compressed_bytes is not None:
        _require_int(compressed_bytes, "compressed_bytes", min_value=1)
        if compressed_bytes > max_comp:
            raise ContractValidationError(
                f"compressed pack size {compressed_bytes} exceeds {max_comp}"
            )

    return {
        "pack_format_version": pack_format_version,
        "id": pack_id,
        "slug": slug,
        "version": version,
        "file_count": len(tree_bytes),
        "uncompressed_bytes": uncompressed_total,
        "limits": (max_comp, max_uncomp, max_entries),
        "has_dashboard_packages": has_dashboard_packages,
    }


# ---------------------------------------------------------------------------
# Secret-Free Scanner (Elixir SecretFreeValidator + TS secret_free parity)
# ---------------------------------------------------------------------------

_FORBIDDEN_SECRET_KEYS: frozenset[str] = frozenset(
    {
        # Elixir SecretFreeValidator
        "password",
        "encrypted_password",
        "secret",
        "client_secret",
        "secret_key",
        "secret_payload",
        "encrypted_secret_payload",
        "private_key",
        "ssh_private_key",
        "api_key",
        "api_token",
        "access_token",
        "refresh_token",
        "bearer_token",
        "auth_token",
        "session_token",
        "access_key",
        "access_key_id",
        "secret_access_key",
        "auth_passphrase",
        "priv_passphrase",
        "community_string",
        "credential_secret_id",
        "credential_rule_id",
        "credentials_encrypted",
        "pat",
        "github_token",
        "gitlab_token",
        "gitea_token",
        # TS secret_free extras
        "passwd",
        "token",
        "x_api_key",
        "passphrase",
    }
)

_FORBIDDEN_INSTANCE_BINDING_KEYS: frozenset[str] = frozenset(
    {
        "credential_secret_id",
        "credential_rule_id",
        "owner_id",
        "actor_id",
        "created_by_id",
        "updated_by_id",
        "plugin_package_id",
        "catalog_repository_id",
        "installed_solution_pack_id",
    }
)

_FORBIDDEN_HEADER_NAMES: frozenset[str] = frozenset(
    {
        "authorization",
        "proxy-authorization",
        "x-api-key",
        "api-key",
        "x-auth-token",
        "x-gitlab-token",
    }
)

_PLACEHOLDER_ONLY_RE = re.compile(
    r"^\s*(?:\{\{\s*[a-zA-Z0-9._-]+\s*\}\}|\$\{\s*[a-zA-Z0-9._-]+\s*\})\s*$"
)

_HEADER_AUTH_SCHEME_RE = re.compile(
    r"^\s*(?:bearer|basic|token|apikey|digest|aws4-hmac-sha256)\s+(?!\{\{|\$\{)\S+",
    re.IGNORECASE,
)

_TOKEN_PATTERNS: tuple[tuple[str, re.Pattern[str], str], ...] = (
    (
        "pem_private_key",
        re.compile(r"-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----"),
        "contains PEM private key material",
    ),
    (
        "github_pat",
        re.compile(r"\b(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{16,}\b"),
        "contains a GitHub personal access token literal",
    ),
    (
        "github_fine_grained_pat",
        re.compile(r"\bgithub_pat_[A-Za-z0-9_]{16,}\b"),
        "contains a GitHub fine-grained PAT literal",
    ),
    (
        "gitlab_pat",
        re.compile(r"\bglpat-[A-Za-z0-9_-]{12,}\b"),
        "contains a GitLab personal access token literal",
    ),
    (
        "slack_token",
        re.compile(r"\bxox[baprs]-[A-Za-z0-9-]{10,}\b"),
        "contains a Slack token literal",
    ),
    (
        "aws_access_key",
        re.compile(r"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b"),
        "contains an AWS access key ID literal",
    ),
    (
        "jwt_literal",
        re.compile(r"\beyJ[A-Za-z0-9_-]{8,}\.eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b"),
        "contains a JWT token literal",
    ),
    (
        "auth_header_literal",
        re.compile(
            r"\bauthorization\s*:\s*(?:bearer|basic|token|apikey|digest|aws4-hmac-sha256)\s+(?!\{\{|\$\{)\S+",
            re.IGNORECASE,
        ),
        "contains a literal Authorization header value",
    ),
)

_RENDERER_JS_RE = re.compile(r"^dashboard_packages/[^/]+/renderer\.js$")


def _normalize_secret_key(key: str) -> str:
    return key.strip().replace("-", "_").lower()


def _is_placeholder_only(val: Any) -> bool:
    if isinstance(val, str):
        return bool(_PLACEHOLDER_ONLY_RE.match(val))
    if isinstance(val, dict) and set(val.keys()) == {"$pack_param"} and isinstance(
        val["$pack_param"], str
    ):
        return True
    return False


def _scan_string_literals(text: str, file_path: str, json_path: str) -> list[dict[str, str]]:
    violations: list[dict[str, str]] = []
    for code, regex, desc in _TOKEN_PATTERNS:
        if regex.search(text):
            violations.append(
                {
                    "file": file_path,
                    "path": json_path,
                    "code": code,
                    "message": f"secret-free violation: {desc}",
                }
            )
    return violations


def _scan_json_node(
    node: Any, file_path: str, json_path: str, in_headers: bool
) -> list[dict[str, str]]:
    violations: list[dict[str, str]] = []
    if isinstance(node, dict):
        for raw_key in sorted(node.keys(), key=str):
            val = node[raw_key]
            key = str(raw_key)
            norm = _normalize_secret_key(key)
            child_path = f"{json_path}.{key}"
            child_in_headers = in_headers or norm == "headers"

            if norm in _FORBIDDEN_SECRET_KEYS:
                violations.append(
                    {
                        "file": file_path,
                        "path": child_path,
                        "code": "forbidden_secret_key",
                        "message": f"forbidden secret key {key!r}",
                    }
                )
            elif norm in _FORBIDDEN_INSTANCE_BINDING_KEYS or (
                norm == "dashboard_id" and isinstance(val, str) and bool(_UUID_RE.match(val))
            ):
                violations.append(
                    {
                        "file": file_path,
                        "path": child_path,
                        "code": "forbidden_instance_binding_key",
                        "message": f"forbidden deployment-local binding key {key!r}",
                    }
                )
            elif (
                (norm == "id" or norm.endswith("_id"))
                and isinstance(val, str)
                and bool(_UUID_RE.match(val))
            ):
                violations.append(
                    {
                        "file": file_path,
                        "path": child_path,
                        "code": "forbidden_instance_uuid",
                        "message": f"forbidden deployment-local UUID on {key!r}",
                    }
                )
            elif (
                in_headers
                and key.lower() in _FORBIDDEN_HEADER_NAMES
                and not _is_placeholder_only(val)
            ):
                violations.append(
                    {
                        "file": file_path,
                        "path": child_path,
                        "code": "forbidden_auth_header",
                        "message": f"literal authentication header {key!r} is forbidden",
                    }
                )
            elif (
                in_headers
                and isinstance(val, str)
                and bool(_HEADER_AUTH_SCHEME_RE.match(val))
            ):
                violations.append(
                    {
                        "file": file_path,
                        "path": child_path,
                        "code": "forbidden_auth_header_value",
                        "message": "literal credential scheme in HTTP header value is forbidden",
                    }
                )

            violations.extend(_scan_json_node(val, file_path, child_path, child_in_headers))
    elif isinstance(node, list):
        for idx, item in enumerate(node):
            violations.extend(_scan_json_node(item, file_path, f"{json_path}[{idx}]", in_headers))
    elif isinstance(node, str):
        if not _is_placeholder_only(node):
            violations.extend(_scan_string_literals(node, file_path, json_path))
    return violations


def scan_secret_free(tree_files: Mapping[str, bytes | bytearray | str]) -> list[dict[str, str]]:
    """Scan a pack tree for forbidden secret keys, auth headers, and token literals.

    Returns a list of violation dicts (`[]` when clean). Note: `dashboard_packages/<slug>/renderer.js`
    and other non-JSON text files skip JSON key checks and still undergo raw token literal scanning.
    """
    violations: list[dict[str, str]] = []
    for path in sorted(tree_files.keys()):
        raw = tree_files[path]
        if isinstance(raw, (bytes, bytearray)):
            try:
                text = bytes(raw).decode("utf-8")
            except UnicodeDecodeError:
                continue
        elif isinstance(raw, str):
            text = raw
        else:
            violations.append(
                {
                    "file": path,
                    "path": "$",
                    "code": "invalid_entry_type",
                    "message": "pack file content must be UTF-8 bytes or str",
                }
            )
            continue

        if path.endswith(".json") and not _RENDERER_JS_RE.match(path):
            try:
                decoded = json.loads(text)
            except Exception as exc:
                violations.append(
                    {
                        "file": path,
                        "path": "$",
                        "code": "invalid_json",
                        "message": f"failed to parse JSON ({exc})",
                    }
                )
                continue
            violations.extend(_scan_json_node(decoded, path, "$", False))
        else:
            violations.extend(_scan_string_literals(text, path, "$"))
    return violations


def assert_secret_free(tree_files: Mapping[str, bytes | bytearray | str]) -> None:
    """Raise `ContractValidationError` if `scan_secret_free` finds any violations."""
    violations = scan_secret_free(tree_files)
    if violations:
        raise ContractValidationError(f"secret-free scan failed: {violations}")


# ---------------------------------------------------------------------------
# Synthetic Data Hygiene Scanner (Word-Boundary Anchored)
# ---------------------------------------------------------------------------

_IPV4_RE = re.compile(
    r"(?<![0-9.])\b(?:(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)\.){3}(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)\b(?![0-9.])"
)
_URL_HOST_RE = re.compile(r"\bhttps?://([A-Za-z0-9.-]+)")
_EMAIL_HOST_RE = re.compile(r"\b[A-Za-z0-9._%+-]+@([A-Za-z0-9.-]+\.[A-Za-z]{2,})\b")
_US_PHONE_RE = re.compile(
    r"(?<![A-Za-z0-9])(?:\+?1[-.\s]?)?(?:\(\d{3}\)|\d{3})[-.\s]\d{3}[-.\s]\d{4}\b"
)
_COPYLEFT_ALPR_RE = re.compile(r"\b(?:openalpr|agpl(?:v?3)?)\b", re.IGNORECASE)
_SYNTHETIC_PHONE_RE = re.compile(r"555-01\d{2}\b")


def _is_permitted_synthetic_host(host: str) -> bool:
    h = host.lower().rstrip(".")
    if h in {"localhost", "127.0.0.1", "0.0.0.0"}:
        return True
    try:
        ip = ipaddress.IPv4Address(h)
        return any(ip in net for net in RFC5737_NETS) or ip.is_loopback
    except ipaddress.AddressValueError:
        pass
    for dom in SYNTHETIC_DOMAINS:
        if h == dom or h.endswith(f".{dom}"):
            return True
    if h.endswith(".invalid") or h.endswith(".test") or h.endswith(".local"):
        return True
    return False


def scan_synthetic_hygiene(text_or_bytes: str | bytes | bytearray) -> list[dict[str, str]]:
    """Scan text or UTF-8 bytes for synthetic-data & licensing hygiene violations.

    Uses word-boundary/token-anchored rules so ordinary English words like
    `equal`, `manual`, `actual`, `virtual`, `toEqual`, and `quality` never false-positive.
    Returns a list of violation dicts (`[]` when clean).
    """
    if isinstance(text_or_bytes, (bytes, bytearray)):
        try:
            text = bytes(text_or_bytes).decode("utf-8")
        except UnicodeDecodeError as exc:
            return [{"code": "invalid_utf8", "match": "", "message": str(exc)}]
    elif isinstance(text_or_bytes, str):
        text = text_or_bytes
    else:
        raise ContractValidationError("text_or_bytes must be str, bytes, or bytearray")

    violations: list[dict[str, str]] = []

    for m in _IPV4_RE.finditer(text):
        ip_str = m.group(0)
        ip = ipaddress.IPv4Address(ip_str)
        if ip.is_loopback:
            continue
        if not any(ip in net for net in RFC5737_NETS):
            violations.append(
                {
                    "code": "non_rfc5737_ipv4",
                    "match": ip_str,
                    "message": f"IPv4 {ip_str} is outside RFC 5737 test ranges and loopback",
                }
            )

    for m in _URL_HOST_RE.finditer(text):
        host = m.group(1)
        if not _is_permitted_synthetic_host(host):
            violations.append(
                {
                    "code": "non_synthetic_url_host",
                    "match": host,
                    "message": f"URL host {host!r} is not a synthetic example/RFC5737/localhost host",
                }
            )

    for m in _EMAIL_HOST_RE.finditer(text):
        host = m.group(1)
        if not _is_permitted_synthetic_host(host):
            violations.append(
                {
                    "code": "non_synthetic_email_domain",
                    "match": host,
                    "message": f"email domain {host!r} is not a synthetic example domain",
                }
            )

    for m in _US_PHONE_RE.finditer(text):
        phone = m.group(0)
        if not _SYNTHETIC_PHONE_RE.search(phone):
            violations.append(
                {
                    "code": "non_synthetic_phone",
                    "match": phone,
                    "message": f"phone number {phone!r} must use reserved 555-0100..555-0199 range",
                }
            )

    for m in _COPYLEFT_ALPR_RE.finditer(text):
        violations.append(
            {
                "code": "disallowed_copyleft_reference",
                "match": m.group(0),
                "message": f"disallowed copyleft/proprietary engine reference {m.group(0)!r}",
            }
        )

    return violations


def assert_synthetic_hygiene(text_or_bytes: str | bytes | bytearray) -> None:
    """Raise `ContractValidationError` if `scan_synthetic_hygiene` finds any violations."""
    violations = scan_synthetic_hygiene(text_or_bytes)
    if violations:
        raise ContractValidationError(f"synthetic hygiene scan failed: {violations}")


# ---------------------------------------------------------------------------
# E2E Test Case Catalog Helpers
# ---------------------------------------------------------------------------


def record_test_case(
    feature: str,
    tier: int,
    test_id: str,
    mode: str,
    description: str,
) -> dict[str, Any]:
    """Validate and record an E2E test case entry in the in-memory catalog."""
    feat = _require_str(feature, "feature")
    if not _FEATURE_RE.match(feat):
        raise ContractValidationError(f"invalid feature identifier {feat!r}")
    t = _require_int(tier, "tier", min_value=1, max_value=4)
    tid = _require_str(test_id, "test_id")
    m = _require_enum(mode, "mode", ("A", "B", "A+B"))
    desc = _require_str(description, "description")

    entry = {
        "feature": feat,
        "tier": t,
        "test_id": tid,
        "mode": m,
        "description": desc,
    }
    _REGISTERED_TEST_CASES[tid] = entry
    return entry


def get_registered_test_cases() -> dict[str, dict[str, Any]]:
    """Return a copy of the registered in-memory test cases."""
    return dict(_REGISTERED_TEST_CASES)


def validate_test_catalog(
    catalog: Sequence[Mapping[str, Any]] | Mapping[str, Any],
    *,
    enforce_minimums: bool = False,
) -> dict[str, Any]:
    """Validate a 4-tier E2E test catalog structure and optional coverage minimums."""
    if isinstance(catalog, Mapping):
        cases = _require_list(catalog.get("cases"), "catalog.cases")
    elif isinstance(catalog, (list, tuple)):
        cases = list(catalog)
    else:
        raise ContractValidationError("catalog must be a list of entries or {'cases': [...]}")

    seen_ids: set[str] = set()
    tier_counts: dict[int, int] = {1: 0, 2: 0, 3: 0, 4: 0}
    per_feature_tier: dict[tuple[str, int], int] = {}

    for idx, raw in enumerate(cases):
        item = _require_dict(raw, f"catalog[{idx}]")
        feat = _require_str(item.get("feature"), f"catalog[{idx}].feature")
        if not _FEATURE_RE.match(feat):
            raise ContractValidationError(f"catalog[{idx}].feature ({feat!r}) is invalid")
        t = _require_int(item.get("tier"), f"catalog[{idx}].tier", min_value=1, max_value=4)
        tid = _require_str(item.get("test_id"), f"catalog[{idx}].test_id")
        if tid in seen_ids:
            raise ContractValidationError(f"duplicate test_id {tid!r} in catalog")
        seen_ids.add(tid)
        _require_enum(item.get("mode"), f"catalog[{idx}].mode", ("A", "B", "A+B"))
        _require_str(item.get("description"), f"catalog[{idx}].description")

        tier_counts[t] += 1
        key = (feat, t)
        per_feature_tier[key] = per_feature_tier.get(key, 0) + 1

    if enforce_minimums:
        for f_num in range(1, 15):
            f_key = f"F{f_num}"
            t1 = per_feature_tier.get((f_key, 1), 0)
            t2 = per_feature_tier.get((f_key, 2), 0)
            if t1 < 5:
                raise ContractValidationError(f"{f_key} Tier 1 count {t1} < 5")
            if t2 < 5:
                raise ContractValidationError(f"{f_key} Tier 2 count {t2} < 5")
        if tier_counts[3] < 15:
            raise ContractValidationError(f"Tier 3 count {tier_counts[3]} < 15")
        if tier_counts[4] < 7:
            raise ContractValidationError(f"Tier 4 count {tier_counts[4]} < 7")
        if len(cases) < 162:
            raise ContractValidationError(f"total catalog cases {len(cases)} < 162")

    return {
        "total": len(cases),
        "tier_counts": tier_counts,
        "per_feature_tier": {f"{f}:T{t}": cnt for (f, t), cnt in sorted(per_feature_tier.items())},
    }
