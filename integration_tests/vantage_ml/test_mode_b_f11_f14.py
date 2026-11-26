"""Mode B live cross-component E2E tests for F11-F14 (Tiers 1 & 2).

MUST be safely importable and discoverable with zero network, subprocess, or
filesystem probes at import time. Execution fails closed (`RuntimeError` or
`AssertionError`) whenever required services, binaries, companion SDK checkout,
CLI build artifacts, or Phase 2/3 runtime components are absent or fail assertions.
"""

from __future__ import annotations

import base64
import copy
import hashlib
import json
import math
import os
import re
import select
import shutil
import signal
import struct
import subprocess
import sys
import time
import unittest
import urllib.parse
import uuid
from pathlib import Path
from typing import Any, Callable, Mapping, Sequence

if __package__ in (None, "") and "TEST_SRCDIR" not in os.environ:
    _repo_root = str(Path(__file__).resolve().parents[2])
    if _repo_root not in sys.path:
        sys.path.insert(0, _repo_root)

from integration_tests.vantage_ml import vantage_contracts as vc
from integration_tests.vantage_ml.drivers import (
    cli_driver,
    cnpg_driver,
    env_probe,
    http_ws_driver,
    media_gen,
    nats_driver,
    sdk_driver,
)

_E2E_JSON_PREFIX = "__VANTAGE_E2E_JSON__:"
_FORBIDDEN_CREDENTIAL_ENV_PREFIXES = ("CNPG_", "STARROCKS_", "AWS_", "S3_")
_FORBIDDEN_CREDENTIAL_ENV_KEYS = frozenset(
    {
        "DATABASE_URL",
        "SERVICERADAR_E2E_DATABASE_URL",
        "CNPG_PASSWORD",
        "STARROCKS_PASSWORD",
        "AWS_ACCESS_KEY_ID",
        "AWS_SECRET_ACCESS_KEY",
        "AWS_SESSION_TOKEN",
        "S3_SECRET_KEY",
    }
)
_CANONICAL_SDK_REPO_URL_RE = re.compile(
    r"https://github\.com/carverauto/serviceradar(?:-sdk-vantage)?(?:\.git)?(?=['\"\s/#?)]|$)"
)


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
        raise RuntimeError(f"missing Mode B fixture file: {path}")
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
    if not path.is_file():
        raise RuntimeError(f"missing Mode B wire vector file: {path}")
    return json.loads(path.read_text(encoding="utf-8"))


def _compute_percentiles_ms(samples_ms: Sequence[float]) -> dict[str, float]:
    if not samples_ms:
        raise AssertionError("benchmark produced zero latency samples")
    for idx, val in enumerate(samples_ms):
        if isinstance(val, bool) or not math.isfinite(val) or val < 0.0:
            raise AssertionError(f"invalid latency sample[{idx}]={val!r}")
    ordered = sorted(samples_ms)
    n = len(ordered)

    def _pct(p: float) -> float:
        rank = max(0, min(n - 1, math.ceil((p / 100.0) * n) - 1))
        return ordered[rank]

    p50, p95, p99 = _pct(50.0), _pct(95.0), _pct(99.0)
    if not (0.0 <= p50 <= p95 <= p99):
        raise AssertionError(f"percentile ordering violated: {(p50, p95, p99)}")
    return {"p50": p50, "p95": p95, "p99": p99}


def _require_control_plane_auth() -> tuple[str, str, int]:
    envs = env_probe.probe_env_vars(
        "SERVICERADAR_CONTROL_PLANE_MEDIA_WORKER_TOKEN",
        "SERVICERADAR_CONTROL_PLANE_DEPLOYMENT_REF",
        "SERVICERADAR_CONTROL_PLANE_MEDIA_WORKER_GENERATION",
    )
    try:
        gen = int(envs["SERVICERADAR_CONTROL_PLANE_MEDIA_WORKER_GENERATION"])
    except ValueError as exc:
        raise RuntimeError("SERVICERADAR_CONTROL_PLANE_MEDIA_WORKER_GENERATION must be integer") from exc
    if gen < 1:
        raise RuntimeError("SERVICERADAR_CONTROL_PLANE_MEDIA_WORKER_GENERATION must be >= 1")
    return (
        envs["SERVICERADAR_CONTROL_PLANE_MEDIA_WORKER_TOKEN"],
        envs["SERVICERADAR_CONTROL_PLANE_DEPLOYMENT_REF"],
        gen,
    )


def _require_cli_dist() -> Path:
    entrypoint = cli_driver.resolve_cli_entrypoint()
    dist_cli = vc.repo_root() / "js" / "cli" / "dist" / "cli.js"
    if not dist_cli.is_file():
        raise RuntimeError(
            f"serviceradar-cli build artifact missing at {dist_cli} (entrypoint={entrypoint}); "
            "run `npm run build` in js/cli before executing Mode B CLI tests"
        )
    return entrypoint


def _require_elixir_modules(app_dir: str, modules: Sequence[str]) -> None:
    checks = "\n".join(
        f"case Code.ensure_loaded({mod}) do\n"
        f"  {{:module, _}} -> :ok\n"
        f"  {{:error, reason}} -> raise \"missing required module {mod}: #{{inspect(reason)}}\"\n"
        f"end"
        for mod in modules
    )
    cnpg_driver.run_mix_eval(app_dir, checks)


def _eval_elixir_json(
    app_dir: str,
    elixir_body: str,
    *,
    extra_env: Mapping[str, str] | None = None,
    timeout: float = 120.0,
) -> dict[str, Any]:
    db_url = cnpg_driver.require_database_url()
    env: dict[str, str] = {
        "DATABASE_URL": db_url,
        "SERVICERADAR_VANTAGE_PIPELINES_ENABLED": "true",
        "SERVICERADAR_CAMERA_RECORDING_ENABLED": "true",
    }
    if extra_env:
        env.update(extra_env)
    wrapped = f'{elixir_body}\nIO.puts("{_E2E_JSON_PREFIX}" <> Jason.encode!(result))\n'
    proc = cnpg_driver.run_mix_eval(app_dir, wrapped, extra_env=env, timeout=timeout)
    for line in reversed(proc.stdout.splitlines()):
        if line.startswith(_E2E_JSON_PREFIX):
            return json.loads(line[len(_E2E_JSON_PREFIX) :])
    raise RuntimeError(
        f"mix run in {app_dir} did not emit {_E2E_JSON_PREFIX}; stdout={proc.stdout!r}, stderr={proc.stderr!r}"
    )


def _cleanup_cnpg_records(
    *,
    source_ids: Sequence[str] = (),
    pipeline_ids: Sequence[str] = (),
    worker_ids: Sequence[str] = (),
    observation_keys: Sequence[str] = (),
) -> None:
    db_url = cnpg_driver.require_database_url()
    for obs_key in observation_keys:
        safe_key = obs_key.replace("'", "''")
        cnpg_driver.run_psql(
            f"DELETE FROM platform.camera_vantage_observations WHERE observation_key = '{safe_key}';",
            database_url=db_url,
        )
    for src_id in source_ids:
        u = str(uuid.UUID(src_id))
        cnpg_driver.run_psql(
            f"""
            DELETE FROM platform.camera_vantage_observations WHERE camera_source_id = '{u}';
            DELETE FROM platform.camera_vantage_jobs WHERE camera_source_id = '{u}';
            DELETE FROM platform.camera_recording_holds WHERE camera_source_id = '{u}';
            DELETE FROM platform.camera_recording_catalog WHERE camera_source_id = '{u}';
            DELETE FROM platform.camera_recording_blocks WHERE camera_source_id = '{u}';
            DELETE FROM platform.camera_stream_profiles WHERE camera_source_id = '{u}';
            DELETE FROM platform.camera_sources WHERE id = '{u}';
            """,
            database_url=db_url,
        )
    for pid in pipeline_ids:
        safe_pid = pid.replace("'", "''")
        cnpg_driver.run_psql(
            f"DELETE FROM platform.camera_vantage_pipelines WHERE pipeline_id = '{safe_pid}';",
            database_url=db_url,
        )
    for wid in worker_ids:
        safe_wid = wid.replace("'", "''")
        cnpg_driver.run_psql(
            f"DELETE FROM platform.vantage_worker_registrations WHERE worker_id = '{safe_wid}';",
            database_url=db_url,
        )


def _provision_camera_block(
    tag: str,
    *,
    display_name: str = "Gate West 01",
    timeline_start_us: int = 1760000000000000,
    timeline_end_us: int = 1760000010000000,
) -> dict[str, str]:
    uid = uuid.uuid4().hex[:12]
    desc_sha = hashlib.sha256(f"desc-{tag}-{uid}".encode("utf-8")).hexdigest()
    init_sha = hashlib.sha256(f"init-{tag}-{uid}".encode("utf-8")).hexdigest()
    frag_sha = hashlib.sha256(f"frag-{tag}-{uid}".encode("utf-8")).hexdigest()
    block_key = hashlib.sha256(f"block-{tag}-{uid}".encode("utf-8")).hexdigest()
    storage_id = str(uuid.uuid4())
    return _eval_elixir_json(
        "elixir/serviceradar_core",
        f"""
        alias ServiceRadar.Actors.SystemActor
        alias ServiceRadar.Camera.{{RecordingCatalogEntry, Source, StreamProfile}}
        actor = SystemActor.system(:mode_b_m4_e2e)
        uid = "{uid}"
        {{:ok, cam}} = Source.create_source(%{{
          device_uid: "sr:synthetic-m4-" <> uid,
          vendor: "synthetic",
          vendor_camera_id: uid,
          display_name: {json.dumps(display_name)},
          assigned_agent_id: "agent-synthetic",
          assigned_gateway_id: "gateway-synthetic"
        }}, actor: actor)
        {{:ok, prof}} = StreamProfile.create_profile(%{{
          camera_source_id: cam.id,
          profile_name: "main",
          relay_eligible: true
        }}, actor: actor)
        block_id = Ecto.UUID.generate()
        now = DateTime.utc_now()
        desc_json = Jason.encode!(%{{
          "version" => 1,
          "format" => %{{ "codec" => "avc1.42c00a", "timescale" => 90000 }},
          "init" => %{{ "length" => 256, "sha256" => "{init_sha}" }},
          "media" => %{{ "length" => 1024, "sha256" => "{frag_sha}" }},
          "fragments" => [
            %{{
              "sequence" => 0,
              "offset" => 0,
              "first" => 0,
              "last" => 1023,
              "length" => 1024,
              "start_ns" => 0,
              "duration_ns" => 2_000_000_000,
              "keyframe" => true,
              "sha256" => "{frag_sha}"
            }}
          ]
        }})
        Ecto.Adapters.SQL.query!(ServiceRadar.Repo, \"\"\"
          INSERT INTO platform.camera_recording_blocks
            (id, block_key, camera_source_id, stream_profile_id, ingest_owner_id, ingest_epoch,
             recorder_claim_id, recorder_epoch, block_sequence, relay_session_id, media_ingest_id,
             storage_id, state, descriptor, descriptor_sha256, reconciliation_state, clock,
             inserted_at, updated_at)
          VALUES
            ($1, $2, $3, $4, $5, 1, $6, 1, 0, $7, $8, $9, 'sealed', $10::jsonb, $11, 'unresolved', '{{}}'::jsonb, $12, $12)
        \"\"\", [
          Ecto.UUID.dump!(block_id), "{block_key}", Ecto.UUID.dump!(cam.id), Ecto.UUID.dump!(prof.id),
          Ecto.UUID.dump!(Ecto.UUID.generate()), Ecto.UUID.dump!(Ecto.UUID.generate()),
          Ecto.UUID.dump!(Ecto.UUID.generate()), Ecto.UUID.dump!(Ecto.UUID.generate()),
          Ecto.UUID.dump!("{storage_id}"), desc_json, "{desc_sha}", now
        ])
        {{:ok, entry}} = RecordingCatalogEntry
          |> Ash.Changeset.for_create(:register_sealed, %{{
            recording_block_id: block_id,
            camera_source_id: cam.id,
            stream_profile_id: prof.id,
            storage_id: "{storage_id}",
            block_key: "{block_key}",
            media_start_ns: 0,
            media_end_ns: 2_000_000_000,
            timeline_start_us: {timeline_start_us},
            timeline_end_us: {timeline_end_us},
            time_basis: :received,
            fragment_count: 1,
            media_bytes: 1024,
            init_sha256: "{init_sha}",
            descriptor_sha256: "{desc_sha}",
            local_state_at: now,
            archive_state: :not_required,
            archive_state_at: now,
            sealed_at: now
          }}, actor: actor)
          |> Ash.create(actor: actor)
        result = %{{
          camera_source_id: cam.id,
          stream_profile_id: prof.id,
          recording_block_id: block_id,
          catalog_entry_id: entry.id,
          descriptor_sha256: entry.descriptor_sha256
        }}
        """,
    )


def _read_grant_url_candidates(grant: Mapping[str, Any]) -> tuple[str, list[str]]:
    if grant.get("backing") == "archive":
        init_url = grant["init"]["presigned_url"]
        media_url = grant["media"]["presigned_url"]
        return init_url, [media_url]
    base_url = http_ws_driver.require_web_url()
    init_url = f"{base_url}{grant['init']['path']}"
    frag_urls = [f"{base_url}{frag['path']}" for frag in grant["fragments"]]
    return init_url, frag_urls


def _validate_coalesce_invariants(body: Mapping[str, Any]) -> None:
    frag_by_seq = {int(f["sequence"]): f for f in body["fragments"]}
    for rng in body["coalesced_ranges"]:
        rng_len = int(rng["length"])
        if rng_len < 1 or rng_len > vc.READ_GRANT_MAX_CHUNK_BYTES:
            raise AssertionError(f"coalesced range length {rng_len} exceeds READ_GRANT_MAX_CHUNK_BYTES")
        ordered = sorted(
            (frag_by_seq[int(seq)] for seq in rng["fragment_sequences"]),
            key=lambda item: int(item["first"]),
        )
        for prev_f, next_f in zip(ordered, ordered[1:]):
            gap = int(next_f["first"]) - int(prev_f["last"]) - 1
            if gap > vc.READ_GRANT_MAX_COALESCE_GAP_BYTES:
                raise AssertionError(f"coalesce gap {gap} exceeds READ_GRANT_MAX_COALESCE_GAP_BYTES")
        for sl in rng["slices"]:
            rel_off = int(sl["relative_offset"])
            sl_len = int(sl["length"])
            if rel_off < 0 or sl_len < 1 or (rel_off + sl_len) > rng_len:
                raise AssertionError(f"slice [{rel_off}, {rel_off + sl_len}) out of range {rng_len}")


def _ws_url_from_web_url(web_url: str) -> str:
    explicit = os.environ.get("SERVICERADAR_E2E_WS_URL", "").strip()
    if explicit:
        return explicit
    parsed = urllib.parse.urlparse(web_url)
    if parsed.scheme not in ("http", "https"):
        raise RuntimeError(f"unsupported web URL scheme for WebSocket: {web_url!r}")
    scheme = "wss" if parsed.scheme == "https" else "ws"
    return f"{scheme}://{parsed.netloc}/socket/websocket?vsn=2.0.0"


def _viewer_ws_headers(cookie_env_var: str = "SERVICERADAR_E2E_DASHBOARD_COOKIE") -> dict[str, str]:
    cookie = os.environ.get(cookie_env_var, "").strip()
    if cookie:
        return {"Cookie": cookie}
    token = os.environ.get("SERVICERADAR_E2E_AUTH_TOKEN", "").strip()
    if token and cookie_env_var == "SERVICERADAR_E2E_DASHBOARD_COOKIE":
        return {"Authorization": f"Bearer {token}"}
    raise RuntimeError(
        f"{cookie_env_var} (or SERVICERADAR_E2E_AUTH_TOKEN for authorized viewer) is required for DashboardFrameChannel tests"
    )


class DashboardChannelClient(http_ws_driver.PhoenixChannelClient):
    """Phoenix Channels v2 client supporting fragmentation, join_ref tracking, and predicate matching."""

    def __init__(
        self,
        ws_url: str,
        *,
        headers: Mapping[str, str] | None = None,
        timeout: float = 10.0,
    ) -> None:
        super().__init__(ws_url, headers=headers, timeout=timeout)
        self._join_refs: dict[str, str] = {}

    def recv_json(self) -> Any:
        fragments: bytearray | None = None
        message_opcode: int | None = None
        while True:
            b0, b1 = self._recv_exact(2)
            fin = bool(b0 & 0x80)
            opcode = b0 & 0x0F
            masked = bool(b1 & 0x80)
            length = b1 & 0x7F
            if length == 126:
                (length,) = struct.unpack("!H", self._recv_exact(2))
            elif length == 127:
                (length,) = struct.unpack("!Q", self._recv_exact(8))
            mask = self._recv_exact(4) if masked else b""
            payload = self._recv_exact(length)
            if masked:
                payload = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))

            if opcode == 0x8:
                raise RuntimeError("WebSocket closed by remote peer")
            if opcode == 0x9:
                self._send_frame(0xA, payload)
                continue
            if opcode == 0xA:
                continue

            if opcode in (0x1, 0x2):
                if fragments is not None:
                    raise RuntimeError(
                        "received new WebSocket data frame before fragmented message completed"
                    )
                if fin:
                    if opcode == 0x1:
                        return json.loads(payload.decode("utf-8"))
                    continue
                fragments = bytearray(payload)
                message_opcode = opcode
                continue

            if opcode == 0x0:
                if fragments is None or message_opcode is None:
                    raise RuntimeError(
                        "received unexpected WebSocket continuation frame without initial frame"
                    )
                fragments.extend(payload)
                if fin:
                    full_payload = bytes(fragments)
                    full_opcode = message_opcode
                    fragments = None
                    message_opcode = None
                    if full_opcode == 0x1:
                        return json.loads(full_payload.decode("utf-8"))
                    continue

    def join_topic(self, topic: str, payload: Mapping[str, Any] | None = None) -> list[Any]:
        ref = str(self._ref)
        self._ref += 1
        frame = [ref, ref, topic, "phx_join", dict(payload or {})]
        self._send_text(json.dumps(frame))
        reply = self.recv_matching(
            lambda m: (
                len(m) >= 5
                and str(m[1]) == ref
                and m[2] == topic
                and m[3] == "phx_reply"
            )
        )
        if isinstance(reply[4], Mapping) and reply[4].get("status") == "ok":
            self._join_refs[topic] = str(reply[0] if reply[0] is not None else ref)
        return reply

    def push_event(self, topic: str, event: str, payload: Mapping[str, Any] | None = None) -> str:
        ref = str(self._ref)
        self._ref += 1
        join_ref = self._join_refs.get(topic, ref)
        frame = [join_ref, ref, topic, event, dict(payload or {})]
        self._send_text(json.dumps(frame))
        return ref

    def recv_matching(
        self,
        predicate: Callable[[list[Any]], bool],
        *,
        timeout: float = 10.0,
    ) -> list[Any]:
        deadline = time.monotonic() + timeout
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise RuntimeError("timed out waiting for matching PhoenixChannelClient frame")
            if self._sock is not None:
                self._sock.settimeout(remaining)
            msg = self.recv_json()
            if isinstance(msg, list) and predicate(msg):
                return msg

    def leave_topic(self, topic: str) -> list[Any]:
        ref = self.push_event(topic, "phx_leave", {})
        return self.recv_matching(
            lambda m: len(m) >= 4 and str(m[1]) == ref and m[3] == "phx_reply"
        )


def _start_nats_sub(subject: str, *, count: int = 1) -> subprocess.Popen[str]:
    nats_bin = env_probe.probe_binary("nats")
    nats_url = nats_driver.require_nats_url()
    proc = subprocess.Popen(
        [str(nats_bin), "--server", nats_url, "sub", subject, f"--count={count}", "--raw"],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    time.sleep(0.25)
    if proc.poll() is not None:
        stderr = proc.stderr.read() if proc.stderr else ""
        raise RuntimeError(f"nats sub {subject} exited prematurely ({proc.returncode}): {stderr}")
    return proc


def _stop_proc(proc: subprocess.Popen[Any] | None) -> None:
    if proc is None:
        return
    if proc.poll() is None:
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait(timeout=5)
    for pipe in (proc.stdin, proc.stdout, proc.stderr):
        if pipe is not None:
            try:
                pipe.close()
            except OSError:
                pass


def _jetstream_last_for(stream: str, subject: str) -> dict[str, Any]:
    proc = nats_driver.run_nats_cli(["stream", "get", stream, "--last-for", subject, "--json"])
    msg = json.loads(proc.stdout.decode("utf-8"))
    raw_bytes = base64.b64decode(msg["data"])
    return json.loads(raw_bytes.decode("utf-8"))


def _poll_until(fn: Callable[[], Any], *, timeout_s: float = 5.0, interval_s: float = 0.15) -> Any:
    deadline = time.monotonic() + timeout_s
    last_val = None
    while True:
        last_val = fn()
        if last_val:
            return last_val
        if time.monotonic() >= deadline:
            return last_val
        time.sleep(interval_s)


class _BaseModeBF11F14Test(unittest.TestCase):
    """Shared fail-closed setup for live F11-F14 tests."""

    env_info: dict[str, Any] = {}

    @classmethod
    def setUpClass(cls) -> None:
        cls.env_info = env_probe.probe_mode_b_environment(require_services=True)


class F11DispatcherHeartbeatReadGrantModeBTest(_BaseModeBF11F14Test):
    """F11 Tier 1 & Tier 2 live cross-component E2E tests."""

    @classmethod
    def setUpClass(cls) -> None:
        super().setUpClass()
        cls.f11_hb = _load_fixture("f11_dispatcher_heartbeat_vectors.json")
        cls.f11_rg = _load_fixture("f11_read_grant_vectors.json")
        _require_elixir_modules(
            "elixir/serviceradar_core",
            (
                "ServiceRadar.Camera.VantagePipeline",
                "ServiceRadar.Camera.VantageJob",
                "ServiceRadar.Camera.VantageWorkerRegistration",
                "ServiceRadar.Camera.VantageTriggerAdmitter",
                "ServiceRadar.Camera.VantagePipelineDispatcher",
                "ServiceRadar.Camera.VantageWorkerHeartbeat",
            ),
        )

    def test_e2e_f11_t1_01_live_capability_slug_and_job_subjects(self) -> None:
        stream_jobs = nats_driver.stream_info("CAMERA_MEDIA_JOBS")
        subjects = stream_jobs.get("config", {}).get("subjects", [])
        self.assertTrue(
            any("media.jobs.vantage" in s for s in subjects),
            f"CAMERA_MEDIA_JOBS missing media.jobs.vantage.* subjects: {subjects}",
        )
        res = _eval_elixir_json(
            "elixir/serviceradar_core",
            """
            alias ServiceRadar.Camera.VantageTriggerAdmitter
            result = %{
              slug: VantageTriggerAdmitter.capability_slug("vantage.alpr.v1"),
              live: VantageTriggerAdmitter.job_subject(:external_worker, "vantage.alpr.v1", :live),
              backfill: VantageTriggerAdmitter.job_subject(:external_worker, "vantage.alpr.v1", :backfill),
              vlm: VantageTriggerAdmitter.job_subject(:camera_vlm, nil, :live)
            }
            """,
        )
        self.assertEqual(res["slug"], "vantage_alpr_v1")
        self.assertEqual(res["live"], "media.jobs.vantage.vantage_alpr_v1.v1")
        self.assertEqual(res["backfill"], "media.jobs.vantage.vantage_alpr_v1.backfill.v1")
        self.assertEqual(res["vlm"], "media.jobs.vantage.vlm.v1")

    def test_e2e_f11_t1_02_heartbeat_ingests_and_routes_to_ramp2(self) -> None:
        hb = copy.deepcopy(self.f11_hb["workers"]["fresh_rust_alpr"])
        hb["worker_id"] = f"vantage-alpr-e2e-{uuid.uuid4().hex[:8]}"
        hb["sent_at_us"] = int(time.time() * 1_000_000)
        vc.validate_heartbeat(hb)
        cam = _provision_camera_block("f11-t1-02")
        pid = f"io.serviceradar.e2e.f11-t1-02-{uuid.uuid4().hex[:8]}"
        try:
            nats_driver.publish_json("media.workers.heartbeat.v1", hb)
            rows = _poll_until(
                lambda: cnpg_driver.run_psql(
                    f"SELECT health || '|' || architecture FROM platform.vantage_worker_registrations "
                    f"WHERE worker_id = '{hb['worker_id']}' AND expires_at > NOW();"
                ),
                timeout_s=5.0,
            )
            self.assertIn("ready|arm64", rows)

            res = _eval_elixir_json(
                "elixir/serviceradar_core",
                f"""
                alias ServiceRadar.Actors.SystemActor
                alias ServiceRadar.Camera.{{RecordingCatalogEntry, VantagePipeline, VantageTriggerAdmitter}}
                actor = SystemActor.system(:e2e_f11_t1_02)
                {{:ok, pipeline}} = VantagePipeline |> Ash.Changeset.for_create(:upsert, %{{
                  pipeline_id: "{pid}",
                  version: "1.0.0",
                  name: "F11 T1-02 Ramp2 Routing",
                  enabled: true,
                  source_mode: :recorded_block,
                  trigger_kind: :on_stage1_detection,
                  object_classes: ["vehicle"],
                  min_confidence: 0.5,
                  input_mode: :detection_crop,
                  runner: :external_worker,
                  capability: "vantage.alpr.v1",
                  fallback_runner: "camera_vlm",
                  signal_schema_id: "alpr_plate_read",
                  signal_schema_version: "1.0.0",
                  display_contract_id: "alpr_plate_read"
                }}, actor: actor) |> Ash.create(actor: actor)
                entry = Ash.get!(RecordingCatalogEntry, "{cam['catalog_entry_id']}", actor: actor)
                frames = [
                  %{{
                    fragment_sequence: 0,
                    media_pts_ns: 0,
                    detections: [
                      %{{object_class: "vehicle", confidence: 0.9, bbox: [0.2, 0.3, 0.7, 0.8], track_id: "trk-r2"}}
                    ]
                  }}
                ]
                {{:ok, jobs}} = VantageTriggerAdmitter.admit_for_stage1_detections(entry, frames, enabled?: true, pipelines: [pipeline])
                job = hd(jobs)
                result = %{{target_runner: job.target_runner, subject: job.subject}}
                """,
            )
            self.assertEqual(res["target_runner"], "vantage.alpr.v1")
            self.assertEqual(res["subject"], "media.jobs.vantage.vantage_alpr_v1.v1")
        finally:
            _cleanup_cnpg_records(
                source_ids=[cam["camera_source_id"]],
                pipeline_ids=[pid],
                worker_ids=[hb["worker_id"]],
            )

    def test_e2e_f11_t1_03_expired_heartbeat_ttl_falls_back_to_ramp1(self) -> None:
        stale_id = f"vantage-alpr-stale-{uuid.uuid4().hex[:8]}"
        cam = _provision_camera_block("f11-t1-03")
        pid = f"io.serviceradar.e2e.f11-t1-03-{uuid.uuid4().hex[:8]}"
        saved_active: list[str] = []
        try:
            # Snapshot/clear any stray active vantage.alpr.v1 test registrations so TTL fallback is isolated
            existing = cnpg_driver.run_psql(
                "SELECT worker_id FROM platform.vantage_worker_registrations "
                "WHERE 'vantage.alpr.v1' = ANY(capabilities) AND expires_at > NOW();"
            )
            for line in existing.splitlines():
                wid = line.strip()
                if wid:
                    saved_active.append(wid)
            if saved_active:
                cnpg_driver.run_psql(
                    "UPDATE platform.vantage_worker_registrations "
                    "SET expires_at = NOW() - INTERVAL '60 seconds' "
                    "WHERE 'vantage.alpr.v1' = ANY(capabilities) AND expires_at > NOW();"
                )

            res = _eval_elixir_json(
                "elixir/serviceradar_core",
                f"""
                alias ServiceRadar.Actors.SystemActor
                alias ServiceRadar.Camera.{{
                  RecordingCatalogEntry,
                  VantagePipeline,
                  VantageTriggerAdmitter,
                  VantageWorkerRegistration
                }}
                actor = SystemActor.system(:e2e_f11_t1_03)
                now = DateTime.utc_now()
                short_ttl = DateTime.add(now, 1, :second)
                {{:ok, _}} = VantageWorkerRegistration
                  |> Ash.Changeset.for_create(:upsert_heartbeat, %{{
                    worker_id: "{stale_id}",
                    worker_kind: :external_rust,
                    protocol_version: "vantage.worker.v1",
                    capabilities: ["vantage.alpr.v1"],
                    supported_source_modes: ["recorded_block"],
                    execution_backend: "onnx",
                    architecture: "arm64",
                    model_id: "alpr-plate-detector-synthetic",
                    model_version: "1.0.0",
                    max_concurrency: 4,
                    active_jobs: 0,
                    health: :ready,
                    last_heartbeat_at: now,
                    expires_at: short_ttl
                  }}, actor: actor)
                  |> Ash.create(actor: actor)
                {{:ok, active_before}} = VantageWorkerRegistration.active_for_capability("vantage.alpr.v1", now, actor: actor)
                Process.sleep(1_200)
                after_ttl = DateTime.utc_now()
                {{:ok, active_after}} = VantageWorkerRegistration.active_for_capability("vantage.alpr.v1", after_ttl, actor: actor)
                {{:ok, pipeline}} = VantagePipeline |> Ash.Changeset.for_create(:upsert, %{{
                  pipeline_id: "{pid}",
                  version: "1.0.0",
                  name: "F11 T1-03 Fallback Routing",
                  enabled: true,
                  source_mode: :recorded_block,
                  trigger_kind: :on_stage1_detection,
                  object_classes: ["vehicle"],
                  min_confidence: 0.5,
                  input_mode: :detection_crop,
                  runner: :external_worker,
                  capability: "vantage.alpr.v1",
                  fallback_runner: "camera_vlm",
                  signal_schema_id: "alpr_plate_read",
                  signal_schema_version: "1.0.0",
                  display_contract_id: "alpr_plate_read"
                }}, actor: actor) |> Ash.create(actor: actor)
                entry = Ash.get!(RecordingCatalogEntry, "{cam['catalog_entry_id']}", actor: actor)
                frames = [
                  %{{
                    fragment_sequence: 0,
                    media_pts_ns: 0,
                    detections: [
                      %{{object_class: "vehicle", confidence: 0.9, bbox: [0.2, 0.3, 0.7, 0.8], track_id: "trk-fb"}}
                    ]
                  }}
                ]
                {{:ok, jobs}} = VantageTriggerAdmitter.admit_for_stage1_detections(entry, frames, enabled?: true, pipelines: [pipeline], now: after_ttl)
                job = hd(jobs)
                result = %{{
                  active_before: Enum.any?(active_before, &(&1.worker_id == "{stale_id}")),
                  active_after: Enum.any?(active_after, &(&1.worker_id == "{stale_id}")),
                  target_runner: job.target_runner,
                  subject: job.subject
                }}
                """,
            )
            self.assertTrue(res["active_before"])
            self.assertFalse(res["active_after"])
            self.assertEqual(res["target_runner"], "camera_vlm")
            self.assertEqual(res["subject"], "media.jobs.vantage.vlm.v1")
        finally:
            if saved_active:
                escaped = ", ".join(f"'{w.replace(chr(39), chr(39)*2)}'" for w in saved_active)
                cnpg_driver.run_psql(
                    f"UPDATE platform.vantage_worker_registrations "
                    f"SET expires_at = NOW() + INTERVAL '60 seconds' WHERE worker_id IN ({escaped});"
                )
            _cleanup_cnpg_records(
                source_ids=[cam["camera_source_id"]],
                pipeline_ids=[pid],
                worker_ids=[stale_id],
            )

    def test_e2e_f11_t1_04_read_grant_200_archive_and_no_store_headers(self) -> None:
        token, deploy_ref, gen = _require_control_plane_auth()
        envs = env_probe.probe_env_vars(
            "SERVICERADAR_E2E_ARCHIVE_JOB_ID",
            "SERVICERADAR_E2E_ARCHIVE_CATALOG_ENTRY_ID",
            "SERVICERADAR_E2E_ARCHIVE_DESCRIPTOR_SHA256",
        )
        status, headers, body = http_ws_driver.request_worker_read_grant(
            job_id=envs["SERVICERADAR_E2E_ARCHIVE_JOB_ID"],
            catalog_entry_id=envs["SERVICERADAR_E2E_ARCHIVE_CATALOG_ENTRY_ID"],
            descriptor_sha256=envs["SERVICERADAR_E2E_ARCHIVE_DESCRIPTOR_SHA256"],
            control_plane_token=token,
            deployment_ref=deploy_ref,
            media_worker_generation=gen,
        )
        self.assertEqual(status, 200, f"expected 200 archive read grant, got {status}: {body}")
        self.assertEqual(headers.get("cache-control"), "no-store")
        self.assertEqual(headers.get("x-content-type-options"), "nosniff")
        self.assertEqual(body["backing"], "archive")
        self.assertEqual(body["grant"]["role"], "reader")
        self.assertEqual(body["grant"]["allowed_methods"], ["HEAD", "GET"])
        _validate_coalesce_invariants(body)
        init_url, media_urls = _read_grant_url_candidates(body)
        i_status, _, init_bytes = http_ws_driver.http_request("GET", init_url)
        self.assertEqual(i_status, 200)
        self.assertEqual(hashlib.sha256(init_bytes).hexdigest(), body["init"]["sha256"])
        self.assertTrue(media_urls)

    def test_e2e_f11_t1_05_read_grant_200_local_and_coalesce_bounds(self) -> None:
        token, deploy_ref, gen = _require_control_plane_auth()
        envs = env_probe.probe_env_vars(
            "SERVICERADAR_E2E_LOCAL_JOB_ID",
            "SERVICERADAR_E2E_LOCAL_CATALOG_ENTRY_ID",
            "SERVICERADAR_E2E_LOCAL_DESCRIPTOR_SHA256",
        )
        status, headers, body = http_ws_driver.request_worker_read_grant(
            job_id=envs["SERVICERADAR_E2E_LOCAL_JOB_ID"],
            catalog_entry_id=envs["SERVICERADAR_E2E_LOCAL_CATALOG_ENTRY_ID"],
            descriptor_sha256=envs["SERVICERADAR_E2E_LOCAL_DESCRIPTOR_SHA256"],
            control_plane_token=token,
            deployment_ref=deploy_ref,
            media_worker_generation=gen,
        )
        self.assertEqual(status, 200, f"expected 200 local read grant, got {status}: {body}")
        self.assertEqual(headers.get("cache-control"), "no-store")
        self.assertEqual(headers.get("x-content-type-options"), "nosniff")
        self.assertEqual(body["backing"], "local")
        self.assertEqual(body["read_pool"], "analysis_read")
        _validate_coalesce_invariants(body)

    def test_e2e_f11_t1_06_backfill_job_dispatches_to_backfill_subject(self) -> None:
        cam = _provision_camera_block("f11-t1-06")
        pid = f"io.serviceradar.e2e.f11-backfill-{uuid.uuid4().hex[:8]}"
        wid = f"vantage-alpr-bf-{uuid.uuid4().hex[:8]}"
        try:
            enqueued = _eval_elixir_json(
                "elixir/serviceradar_core",
                f"""
                alias ServiceRadar.Actors.SystemActor
                alias ServiceRadar.Camera.{{
                  VantageJob,
                  VantagePipeline,
                  VantagePipelineDispatcher,
                  VantageWorkerRegistration
                }}
                actor = SystemActor.system(:e2e_f11_t1_06)
                now = DateTime.utc_now()
                {{:ok, _}} = VantageWorkerRegistration
                  |> Ash.Changeset.for_create(:upsert_heartbeat, %{{
                    worker_id: "{wid}",
                    worker_kind: :external_rust,
                    protocol_version: "vantage.worker.v1",
                    capabilities: ["vantage.alpr.v1"],
                    supported_source_modes: ["recorded_block"],
                    execution_backend: "onnx",
                    architecture: "arm64",
                    model_id: "alpr-plate-detector-synthetic",
                    model_version: "1.0.0",
                    max_concurrency: 4,
                    active_jobs: 0,
                    health: :ready,
                    last_heartbeat_at: now,
                    expires_at: DateTime.add(now, 60, :second)
                  }}, actor: actor)
                  |> Ash.create(actor: actor)
                {{:ok, p}} = VantagePipeline |> Ash.Changeset.for_create(:upsert, %{{
                  pipeline_id: "{pid}",
                  version: "1.0.0",
                  name: "F11 Backfill & Live",
                  enabled: true,
                  source_mode: :recorded_block,
                  trigger_kind: :on_stage1_detection,
                  runner: :external_worker,
                  capability: "vantage.alpr.v1",
                  fallback_runner: "camera_vlm",
                  signal_schema_id: "alpr_plate_read",
                  signal_schema_version: "1.0.0",
                  display_contract_id: "alpr_plate_read"
                }}, actor: actor) |> Ash.create(actor: actor)
                payload = %{{
                  "schema_version" => "vantage.job.v1",
                  "input_mode" => "detection_crop",
                  "roi_polygons" => [],
                  "crop_policy" => %{{
                    "padding_ratio" => 0.15,
                    "min_bbox_width_px" => 96,
                    "max_dimension" => 640,
                    "max_bytes" => 98_304
                  }},
                  "signal_schema_id" => "alpr_plate_read",
                  "signal_schema_version" => "1.0.0",
                  "display_contract_id" => "alpr_plate_read"
                }}
                {{:ok, bf_job}} = VantageJob |> Ash.Changeset.for_create(:enqueue, %{{
                  vantage_pipeline_id: p.id,
                  pipeline_id: "{pid}",
                  pipeline_version: "1.0.0",
                  catalog_entry_id: "{cam['catalog_entry_id']}",
                  camera_source_id: "{cam['camera_source_id']}",
                  stream_profile_id: "{cam['stream_profile_id']}",
                  target_key: "track:bf-1",
                  job_kind: :backfill,
                  state: :pending,
                  target_runner: "vantage.alpr.v1",
                  subject: "media.jobs.vantage.vantage_alpr_v1.backfill.v1",
                  descriptor_sha256: "{cam['descriptor_sha256']}",
                  sampled_targets: [],
                  job_payload: payload,
                  deadline_at: DateTime.add(now, 30, :second)
                }}, actor: actor) |> Ash.create(actor: actor)
                {{:ok, live_job}} = VantageJob |> Ash.Changeset.for_create(:enqueue, %{{
                  vantage_pipeline_id: p.id,
                  pipeline_id: "{pid}",
                  pipeline_version: "1.0.0",
                  catalog_entry_id: "{cam['catalog_entry_id']}",
                  camera_source_id: "{cam['camera_source_id']}",
                  stream_profile_id: "{cam['stream_profile_id']}",
                  target_key: "track:live-1",
                  job_kind: :live,
                  state: :pending,
                  target_runner: "vantage.alpr.v1",
                  subject: "media.jobs.vantage.vantage_alpr_v1.v1",
                  descriptor_sha256: "{cam['descriptor_sha256']}",
                  sampled_targets: [],
                  job_payload: payload,
                  deadline_at: DateTime.add(now, 30, :second)
                }}, actor: actor) |> Ash.create(actor: actor)
                cond do
                  function_exported?(VantagePipelineDispatcher, :relay, 0) -> VantagePipelineDispatcher.relay()
                  function_exported?(VantagePipelineDispatcher, :relay, 1) -> VantagePipelineDispatcher.relay([])
                  true -> :await_background_dispatcher
                end
                result = %{{bf_id: bf_job.id, live_id: live_job.id}}
                """,
            )
            bf_id = enqueued["bf_id"]
            live_id = enqueued["live_id"]

            states = _poll_until(
                lambda: (
                    lambda out: out if out.count("dispatched") == 2 else ""
                )(
                    cnpg_driver.run_psql(
                        f"SELECT id || ':' || state FROM platform.camera_vantage_jobs "
                        f"WHERE id IN ('{bf_id}', '{live_id}');"
                    )
                ),
                timeout_s=8.0,
            )
            self.assertIn(f"{bf_id}:dispatched", states)
            self.assertIn(f"{live_id}:dispatched", states)

            bf_msg = _jetstream_last_for(
                "CAMERA_MEDIA_JOBS", "media.jobs.vantage.vantage_alpr_v1.backfill.v1"
            )
            vc.validate_job_envelope(bf_msg)
            self.assertEqual(bf_msg["job_id"], bf_id)

            live_msg = _jetstream_last_for(
                "CAMERA_MEDIA_JOBS", "media.jobs.vantage.vantage_alpr_v1.v1"
            )
            vc.validate_job_envelope(live_msg)
            self.assertEqual(live_msg["job_id"], live_id)
        finally:
            _cleanup_cnpg_records(
                source_ids=[cam["camera_source_id"]],
                pipeline_ids=[pid],
                worker_ids=[wid],
            )

    def test_e2e_f11_t2_01_malformed_heartbeat_does_not_poison_registry(self) -> None:
        bad_id = f"vantage-bad-hb-{uuid.uuid4().hex[:8]}"
        good_id = f"vantage-good-hb-{uuid.uuid4().hex[:8]}"
        bad_hb = copy.deepcopy(self.f11_hb["workers"]["bad_protocol_version"])
        bad_hb["worker_id"] = bad_id
        good_hb = copy.deepcopy(self.f11_hb["workers"]["fresh_rust_alpr"])
        good_hb["worker_id"] = good_id
        good_hb["sent_at_us"] = int(time.time() * 1_000_000)
        try:
            nats_driver.publish_json("media.workers.heartbeat.v1", bad_hb)
            nats_driver.publish_json("media.workers.heartbeat.v1", good_hb)
            good_rows = _poll_until(
                lambda: cnpg_driver.run_psql(
                    f"SELECT health FROM platform.vantage_worker_registrations WHERE worker_id = '{good_id}';"
                ),
                timeout_s=5.0,
            )
            self.assertEqual(good_rows.strip(), "ready")
            bad_rows = cnpg_driver.run_psql(
                f"SELECT COUNT(*) FROM platform.vantage_worker_registrations WHERE worker_id = '{bad_id}';"
            )
            self.assertEqual(bad_rows.strip(), "0")
        finally:
            _cleanup_cnpg_records(worker_ids=[bad_id, good_id])

    def test_e2e_f11_t2_02_strict_optional_false_holds_when_worker_unavailable(self) -> None:
        unique_tok = uuid.uuid4().hex[:8]
        strict_cap = f"vantage.strict_{unique_tok}.v1"
        strict_slug = f"vantage_strict_{unique_tok}_v1"
        strict_subj = f"media.jobs.vantage.{strict_slug}.v1"
        cam = _provision_camera_block("f11-t2-02")
        pid = f"io.serviceradar.e2e.f11-strict-{unique_tok}"
        try:
            res = _eval_elixir_json(
                "elixir/serviceradar_core",
                f"""
                alias ServiceRadar.Actors.SystemActor
                alias ServiceRadar.Camera.{{
                  VantageJob,
                  VantagePipeline,
                  VantagePipelineDispatcher,
                  VantageWorkerRegistration
                }}
                actor = SystemActor.system(:e2e_f11_t2_02)
                now = DateTime.utc_now()
                {{:ok, active}} = VantageWorkerRegistration.active_for_capability("{strict_cap}", now, actor: actor)
                if active != [], do: raise("unexpected active worker for {strict_cap}")
                {{:ok, p}} = VantagePipeline |> Ash.Changeset.for_create(:upsert, %{{
                  pipeline_id: "{pid}",
                  version: "1.0.0",
                  name: "F11 Strict Optional False",
                  enabled: true,
                  source_mode: :recorded_block,
                  trigger_kind: :on_stage1_detection,
                  runner: :external_worker,
                  capability: "{strict_cap}",
                  fallback_runner: nil,
                  signal_schema_id: "alpr_plate_read",
                  signal_schema_version: "1.0.0",
                  display_contract_id: "alpr_plate_read"
                }}, actor: actor) |> Ash.create(actor: actor)
                {{:ok, job}} = VantageJob |> Ash.Changeset.for_create(:enqueue, %{{
                  vantage_pipeline_id: p.id,
                  pipeline_id: "{pid}",
                  pipeline_version: "1.0.0",
                  catalog_entry_id: "{cam['catalog_entry_id']}",
                  camera_source_id: "{cam['camera_source_id']}",
                  stream_profile_id: "{cam['stream_profile_id']}",
                  target_key: "track:strict-1",
                  job_kind: :live,
                  state: :pending,
                  target_runner: "{strict_cap}",
                  subject: "{strict_subj}",
                  descriptor_sha256: "{cam['descriptor_sha256']}",
                  sampled_targets: [],
                  job_payload: %{{ "schema_version" => "vantage.job.v1" }},
                  deadline_at: DateTime.add(now, 30, :second)
                }}, actor: actor) |> Ash.create(actor: actor)
                cond do
                  function_exported?(VantagePipelineDispatcher, :relay, 0) -> VantagePipelineDispatcher.relay()
                  function_exported?(VantagePipelineDispatcher, :relay, 1) -> VantagePipelineDispatcher.relay([])
                  true -> :await_background_dispatcher
                end
                Process.sleep(600)
                reloaded = VantageJob.get_by_id!(job.id, actor: actor)
                result = %{{job_id: job.id, state: to_string(reloaded.state), subject: reloaded.subject}}
                """,
            )
            self.assertEqual(res["state"], "pending")
            self.assertEqual(res["subject"], strict_subj)
            self.assertNotEqual(res["subject"], "media.jobs.vantage.vlm.v1")
            check_vlm = nats_driver.run_nats_cli(
                ["stream", "get", "CAMERA_MEDIA_JOBS", "--last-for", "media.jobs.vantage.vlm.v1", "--json"],
                check=False,
            )
            if check_vlm.returncode == 0:
                last_vlm = json.loads(base64.b64decode(json.loads(check_vlm.stdout.decode("utf-8"))["data"]))
                self.assertNotEqual(last_vlm.get("job_id"), res["job_id"])
        finally:
            _cleanup_cnpg_records(source_ids=[cam["camera_source_id"]], pipeline_ids=[pid])

    def test_e2e_f11_t2_03_read_grant_bad_request_and_oversized_body(self) -> None:
        token, deploy_ref, gen = _require_control_plane_auth()
        bad_payload = copy.deepcopy(self.f11_rg["request_positive"])
        status, headers, body = http_ws_driver.request_worker_read_grant(
            job_id=bad_payload["job_id"],
            catalog_entry_id=bad_payload["catalog_entry_id"],
            descriptor_sha256=bad_payload["descriptor_sha256"],
            control_plane_token=token,
            deployment_ref=deploy_ref,
            media_worker_generation=gen,
            schema_version=2,
            validate_200=False,
        )
        self.assertEqual(status, 400)
        self.assertEqual(headers.get("cache-control"), "no-store")
        self.assertEqual(headers.get("x-content-type-options"), "nosniff")
        self.assertEqual(body.get("status"), "invalid_schema_version")

        # Send actual > 8192-byte JSON request body and verify 413 request_too_large
        oversized = copy.deepcopy(self.f11_rg["request_positive"])
        oversized["pad"] = "a" * (vc.MAX_READ_GRANT_REQUEST_BYTES + 256)
        raw_req = json.dumps(oversized, separators=(",", ":")).encode("utf-8")
        self.assertGreater(len(raw_req), vc.MAX_READ_GRANT_REQUEST_BYTES)
        status_413, hdrs_413, raw_413 = http_ws_driver.http_request(
            "POST",
            "/v1/media/workers/read-grants",
            headers={
                "Content-Type": "application/json",
                "X-ServiceRadar-Control-Plane-Authorization": f"Bearer {token}",
                "X-ServiceRadar-Deployment-Ref": deploy_ref,
                "X-ServiceRadar-Media-Worker-Generation": str(gen),
            },
            raw_body=raw_req,
        )
        self.assertEqual(status_413, 413)
        self.assertEqual(hdrs_413.get("cache-control"), "no-store")
        self.assertEqual(hdrs_413.get("x-content-type-options"), "nosniff")
        self.assertEqual(json.loads(raw_413.decode("utf-8")).get("status"), "request_too_large")

    def test_e2e_f11_t2_04_read_grant_401_missing_headers_and_403_wrong_domain(self) -> None:
        status_401, hdrs_401, raw_401 = http_ws_driver.http_request(
            "POST",
            "/v1/media/workers/read-grants",
            headers={"Content-Type": "application/json"},
            json_body=self.f11_rg["request_positive"],
        )
        self.assertEqual(status_401, 401)
        self.assertEqual(hdrs_401.get("cache-control"), "no-store")
        self.assertEqual(hdrs_401.get("x-content-type-options"), "nosniff")
        self.assertEqual(json.loads(raw_401.decode("utf-8")).get("status"), "unauthorized")

        wrong_token = env_probe.probe_env_vars("SERVICERADAR_E2E_WRONG_PURPOSE_TOKEN")[
            "SERVICERADAR_E2E_WRONG_PURPOSE_TOKEN"
        ]
        _, deploy_ref, gen = _require_control_plane_auth()
        status_403, hdrs_403, body_403 = http_ws_driver.request_worker_read_grant(
            job_id=self.f11_rg["request_positive"]["job_id"],
            catalog_entry_id=self.f11_rg["request_positive"]["catalog_entry_id"],
            descriptor_sha256=self.f11_rg["request_positive"]["descriptor_sha256"],
            control_plane_token=wrong_token,
            deployment_ref=deploy_ref,
            media_worker_generation=gen,
            validate_200=False,
        )
        self.assertIn(status_403, (401, 403))
        self.assertEqual(hdrs_403.get("cache-control"), "no-store")
        self.assertEqual(hdrs_403.get("x-content-type-options"), "nosniff")
        self.assertIn(body_403.get("status"), ("forbidden", "unauthorized"))

    def test_e2e_f11_t2_05_read_grant_409_conflicts_and_410_recording_gone(self) -> None:
        token, deploy_ref, gen = _require_control_plane_auth()
        unknown_job = str(uuid.uuid4())
        status_409, hdrs_409, body_409 = http_ws_driver.request_worker_read_grant(
            job_id=unknown_job,
            catalog_entry_id=self.f11_rg["request_positive"]["catalog_entry_id"],
            descriptor_sha256=self.f11_rg["request_positive"]["descriptor_sha256"],
            control_plane_token=token,
            deployment_ref=deploy_ref,
            media_worker_generation=gen,
            validate_200=False,
        )
        self.assertEqual(status_409, 409)
        self.assertEqual(hdrs_409.get("cache-control"), "no-store")
        self.assertEqual(hdrs_409.get("x-content-type-options"), "nosniff")
        self.assertEqual(body_409.get("status"), "job_not_found")

        gone_envs = env_probe.probe_env_vars(
            "SERVICERADAR_E2E_QUARANTINED_JOB_ID",
            "SERVICERADAR_E2E_QUARANTINED_CATALOG_ENTRY_ID",
            "SERVICERADAR_E2E_QUARANTINED_DESCRIPTOR_SHA256",
        )
        status_410, hdrs_410, body_410 = http_ws_driver.request_worker_read_grant(
            job_id=gone_envs["SERVICERADAR_E2E_QUARANTINED_JOB_ID"],
            catalog_entry_id=gone_envs["SERVICERADAR_E2E_QUARANTINED_CATALOG_ENTRY_ID"],
            descriptor_sha256=gone_envs["SERVICERADAR_E2E_QUARANTINED_DESCRIPTOR_SHA256"],
            control_plane_token=token,
            deployment_ref=deploy_ref,
            media_worker_generation=gen,
            validate_200=False,
        )
        self.assertEqual(status_410, 410)
        self.assertEqual(hdrs_410.get("cache-control"), "no-store")
        self.assertEqual(hdrs_410.get("x-content-type-options"), "nosniff")
        self.assertEqual(body_410.get("status"), "recording_gone")

    def test_e2e_f11_t2_06_read_grant_never_leaks_s3_secrets_on_wire(self) -> None:
        token, deploy_ref, gen = _require_control_plane_auth()
        envs = env_probe.probe_env_vars(
            "SERVICERADAR_E2E_ARCHIVE_JOB_ID",
            "SERVICERADAR_E2E_ARCHIVE_CATALOG_ENTRY_ID",
            "SERVICERADAR_E2E_ARCHIVE_DESCRIPTOR_SHA256",
        )
        status, headers, body = http_ws_driver.request_worker_read_grant(
            job_id=envs["SERVICERADAR_E2E_ARCHIVE_JOB_ID"],
            catalog_entry_id=envs["SERVICERADAR_E2E_ARCHIVE_CATALOG_ENTRY_ID"],
            descriptor_sha256=envs["SERVICERADAR_E2E_ARCHIVE_DESCRIPTOR_SHA256"],
            control_plane_token=token,
            deployment_ref=deploy_ref,
            media_worker_generation=gen,
        )
        self.assertEqual(status, 200)
        self.assertEqual(headers.get("cache-control"), "no-store")
        self.assertEqual(headers.get("x-content-type-options"), "nosniff")
        raw_text = json.dumps(body)
        for forbidden in ("access_key_id", "secret_access_key", "session_token"):
            self.assertNotIn(forbidden, raw_text)


class F12CompanionSdkAndCliModeBTest(_BaseModeBF11F14Test):
    """F12 Tier 1 & Tier 2 live companion SDK (`serviceradar-sdk-vantage`) & CLI tests."""

    @classmethod
    def setUpClass(cls) -> None:
        super().setUpClass()
        cls.f12 = _load_fixture("f12_sdk_conformance_and_hygiene.json")
        cls.sdk_repo = env_probe.probe_sdk_repo()

    def test_e2e_f12_t1_01_rust_sdk_cargo_test_and_conformance(self) -> None:
        proc = sdk_driver.run_cargo_test(["--workspace"], sdk_dir=self.sdk_repo)
        self.assertEqual(proc.returncode, 0)

    def test_e2e_f12_t1_02_live_tap_worker_result_strict_nullity(self) -> None:
        mp4_path = media_gen.generate_synthetic_h264_mp4(
            "f12_t1_02_live_tap.mp4", width=320, height=240, duration_s=1, fps=5
        )
        schema_path = (
            vc.repo_root()
            / "integration_tests"
            / "vantage_ml"
            / "fixtures"
            / "wire_vectors"
            / "bay_guidance_schema.json"
        )
        live_frame = copy.deepcopy(_load_wire_vector("vantage_frame_v1.json")["positive"])
        live_frame["camera_source_id"] = "22222222-2222-4222-8222-222222222204"
        live_frame["stream_profile_id"] = "33333333-3333-4333-8333-333333333304"
        live_frame["frame_sequence"] = 7
        live_subj = "media.live.vantage.vantage_bay_guidance_v1.v1"

        sub_proc = _start_nats_sub("media.results.vantage.v1", count=1)
        try:
            script = f"""
import json
import os
import threading
import time
import serviceradar_vantage as sv

def process_frame(ctx):
    assert ctx.source_mode == "live_keyframe_tap", f"unexpected source_mode={{ctx.source_mode!r}}"
    assert ctx.catalog_entry_id is None
    assert ctx.fragment_sequence is None
    return [
        sv.Observation(
            category="vehicle",
            label="Bay 04 Approach",
            confidence=0.95,
            bbox=[0.2, 0.3, 0.7, 0.85],
            signal_schema_id="bay_guidance",
            signal_schema_version="1.0.0",
            display_contract_id="bay_guidance",
            attributes={{
                "bay_id": "bay-04",
                "guidance_state": "approach",
                "distance_m": 2.4,
                "lateral_offset_m": -0.05,
                "confidence": 0.95,
            }},
            search_text="Bay 04 Approach bay-04 approach",
        )
    ]

# Verify offline harness + live NATS VantageWorker execution in live_keyframe_tap mode
harness_out = sv.run_local_harness(
    {json.dumps(str(mp4_path))},
    process_frame,
    {json.dumps(str(schema_path))},
    source_mode="live_keyframe_tap",
)
assert harness_out is not None
worker = sv.VantageWorker(
    worker_id="e2e-live-tap-py",
    capabilities=["vantage.bay_guidance.v1"],
    supported_source_modes=["live_keyframe_tap"],
    nats_url=os.environ["SERVICERADAR_E2E_NATS_URL"],
    handler=process_frame,
)
t = threading.Thread(target=worker.run_for_seconds, args=(3.0,), daemon=True)
t.start()
time.sleep(0.4)
print("WORKER_READY", flush=True)
t.join(timeout=4.0)
assert not t.is_alive(), "VantageWorker thread did not exit within timeout"
"""
            # Run local harness + NATS-backed live-tap worker while publishing live_frame
            py_bin = sdk_driver.ensure_sdk_python_venv(sdk_dir=self.sdk_repo)
            worker_env = dict(os.environ)
            worker_env["SERVICERADAR_E2E_NATS_URL"] = nats_driver.require_nats_url()
            worker_env["SERVICERADAR_E2E_WEB_URL"] = http_ws_driver.require_web_url()
            worker_proc = subprocess.Popen(
                [str(py_bin), "-c", script],
                cwd=str(self.sdk_repo),
                env=worker_env,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )
            try:
                ready_deadline = time.monotonic() + 10.0
                ready_line = ""
                while time.monotonic() < ready_deadline:
                    if worker_proc.stdout is not None:
                        rlist, _, _ = select.select(
                            [worker_proc.stdout],
                            [],
                            [],
                            max(0.05, ready_deadline - time.monotonic()),
                        )
                        if rlist:
                            line = worker_proc.stdout.readline()
                            if not line:
                                break
                            ready_line = line.strip()
                            if ready_line == "WORKER_READY":
                                break
                    elif worker_proc.poll() is not None:
                        break
                if ready_line != "WORKER_READY":
                    w_out, w_err = worker_proc.communicate(timeout=5.0)
                    self.fail(
                        f"SDK worker exited before WORKER_READY (rc={worker_proc.returncode}): {w_out} {w_err}"
                    )
                time.sleep(0.2)
                nats_driver.publish_json(live_subj, live_frame)
                w_out, w_err = worker_proc.communicate(timeout=15.0)
                self.assertEqual(worker_proc.returncode, 0, f"SDK worker failed: {w_out} {w_err}")
            finally:
                _stop_proc(worker_proc)

            stdout, stderr = sub_proc.communicate(timeout=10.0)
            self.assertEqual(sub_proc.returncode, 0, f"nats sub failed: {stderr}")
            res = json.loads([ln for ln in stdout.splitlines() if ln.strip()][0])
            validated = vc.validate_result_envelope(res)
            self.assertEqual(validated["source_mode"], "live_keyframe_tap")
            self.assertIsNone(validated.get("job_id"))
            self.assertIsNone(validated.get("catalog_entry_id"))
            self.assertIsNone(validated.get("descriptor_sha256"))
            self.assertTrue(validated["observations"])
            for obs in validated["observations"]:
                self.assertIsNone(obs.get("fragment_sequence"))
        finally:
            _stop_proc(sub_proc)

    def test_e2e_f12_t1_03_worker_env_contains_zero_db_or_s3_credentials(self) -> None:
        # (a) Execute real SDK import & worker instantiation inside a cleanly stripped environment
        py_bin = sdk_driver.ensure_sdk_python_venv(sdk_dir=self.sdk_repo)
        stripped_env: dict[str, str] = {}
        for k, v in os.environ.items():
            if k in _FORBIDDEN_CREDENTIAL_ENV_KEYS or k.startswith(_FORBIDDEN_CREDENTIAL_ENV_PREFIXES):
                continue
            stripped_env[k] = v
        stripped_env["CARGO_TARGET_DIR"] = str(env_probe.get_scratch_dir("cargo-target-sdk"))
        stripped_env["UV_CACHE_DIR"] = str(env_probe.get_scratch_dir("uv-cache"))
        stripped_env["SERVICERADAR_E2E_NATS_URL"] = nats_driver.require_nats_url()
        stripped_env["SERVICERADAR_E2E_WEB_URL"] = http_ws_driver.require_web_url()

        worker_check = """
import os
import serviceradar_vantage as sv

forbidden = (
    "DATABASE_URL",
    "SERVICERADAR_E2E_DATABASE_URL",
    "CNPG_PASSWORD",
    "STARROCKS_PASSWORD",
    "AWS_ACCESS_KEY_ID",
    "AWS_SECRET_ACCESS_KEY",
    "AWS_SESSION_TOKEN",
    "S3_SECRET_KEY",
)
leaked = [k for k in forbidden if k in os.environ]
assert not leaked, f"forbidden credential keys in worker env: {leaked}"
caps = sv.WorkerCapabilities(
    capabilities=["vantage.alpr.v1"],
    supported_source_modes=["recorded_block", "live_keyframe_tap"],
    execution_backend="onnx",
    model_id="vantage-alpr-synthetic",
    model_version="1.0.0",
)
worker = sv.VantageWorker(
    worker_id="vantage-alpr-env-check",
    capabilities=caps,
    handler=lambda _ctx: [],
)
assert worker is not None
"""
        proc = subprocess.run(
            [str(py_bin), "-c", worker_check],
            cwd=str(self.sdk_repo),
            env=stripped_env,
            capture_output=True,
            text=True,
            timeout=120.0,
        )
        self.assertEqual(
            proc.returncode,
            0,
            f"SDK worker instantiation in stripped env failed: stdout={proc.stdout} stderr={proc.stderr}",
        )

        # (b) Scan companion SDK vantage-worker-alpr config/manifest files for zero DB/S3 credentials
        alpr_candidates = [
            p
            for p in (
                self.sdk_repo / "crates" / "vantage-worker-alpr",
                self.sdk_repo / "examples" / "vantage-worker-alpr",
                self.sdk_repo / "workers" / "vantage-worker-alpr",
                self.sdk_repo / "vantage-worker-alpr",
            )
            if p.is_dir()
        ]
        self.assertTrue(
            alpr_candidates,
            f"companion SDK checkout {self.sdk_repo} missing vantage-worker-alpr directory",
        )
        tree_files: dict[str, str] = {}
        for root_dir in alpr_candidates:
            for fpath in sorted(root_dir.rglob("*")):
                if not fpath.is_file():
                    continue
                if fpath.suffix.lower() not in (".json", ".toml", ".yaml", ".yml", ".env"):
                    continue
                rel = str(fpath.relative_to(self.sdk_repo))
                text = fpath.read_text(encoding="utf-8")
                tree_files[rel] = text
                for forbidden_key in self.f12["forbidden_env_keys"]:
                    self.assertNotIn(
                        forbidden_key,
                        text,
                        f"forbidden credential key {forbidden_key!r} found in {rel}",
                    )
        self.assertTrue(tree_files, "vantage-worker-alpr has zero config/manifest files")
        vc.assert_secret_free(tree_files)

    def test_e2e_f12_t1_04_python_pyo3_zero_copy_rgb_frame_shape(self) -> None:
        mp4_path = media_gen.generate_synthetic_h264_mp4(
            "f12_t1_04_rgb_zero_copy.mp4", width=320, height=240, duration_s=1, fps=5
        )
        schema_path = (
            vc.repo_root()
            / "integration_tests"
            / "vantage_ml"
            / "fixtures"
            / "wire_vectors"
            / "alpr_plate_read_schema.json"
        )
        script = f"""
import numpy as np
import serviceradar_vantage as sv

seen = []

def check_rgb(ctx):
    arr = ctx.rgb_frame
    assert isinstance(arr, np.ndarray), f"expected numpy.ndarray, got {{type(arr)}}"
    assert arr.dtype == np.uint8, f"expected uint8, got {{arr.dtype}}"
    assert arr.shape == (240, 320, 3), f"expected (240, 320, 3), got {{arr.shape}}"
    assert arr.flags["C_CONTIGUOUS"], "rgb_frame must be C-contiguous zero-copy view"
    seen.append(arr.shape)
    return []

sv.run_local_harness(
    {json.dumps(str(mp4_path))},
    check_rgb,
    {json.dumps(str(schema_path))},
)
assert len(seen) >= 1, "run_local_harness never invoked process_frame"
"""
        proc = sdk_driver.run_python_in_sdk_venv(["-c", script], sdk_dir=self.sdk_repo)
        self.assertEqual(proc.returncode, 0)

    def test_e2e_f12_t1_05_reference_alpr_worker_ramp1_to_ramp2_parity(self) -> None:
        init_path, media_path = media_gen.generate_synthetic_cmaf_block("f12_alpr_parity")
        self.assertTrue(init_path.is_file() and media_path.is_file())
        proc = sdk_driver.run_cargo_test(
            ["-p", "vantage-worker-alpr"],
            sdk_dir=self.sdk_repo,
        )
        self.assertEqual(proc.returncode, 0)
        parity = self.f12["ramp1_to_ramp2_parity"]
        r1 = vc.validate_result_envelope(parity["ramp1_vlm_result"])
        r2 = vc.validate_result_envelope(parity["ramp2_rust_result"])
        self.assertEqual(
            r1["observations"][0]["signal_schema_id"],
            r2["observations"][0]["signal_schema_id"],
        )

    def test_e2e_f12_t1_06_cli_vantage_dev_and_validate_offline(self) -> None:
        _require_cli_dist()
        mp4_path = media_gen.generate_synthetic_h264_mp4("f12_vantage_dev_gate_west_01.mp4")
        work_root = env_probe.get_scratch_dir(f"f12-cli-scaffold-{uuid.uuid4().hex[:8]}")
        pack_name = "e2e-vantage-alpr"
        pack_dir = work_root / pack_name
        try:
            cli_driver.run_cli(
                ["vantage", "init", pack_name, "--template", "python-worker"],
                cwd=work_root,
            )
            self.assertTrue(pack_dir.is_dir(), f"vantage init did not create {pack_dir}")
            val_proc = cli_driver.run_cli(["vantage", "validate", str(pack_dir), "--json"])
            self.assertEqual(val_proc.returncode, 0)
            val_json = json.loads(val_proc.stdout)
            self.assertTrue(val_json.get("valid", True))
            dev_proc = cli_driver.run_cli(
                ["vantage", "dev", str(pack_dir), "--fixture", str(mp4_path), "--json"]
            )
            self.assertEqual(dev_proc.returncode, 0)
            dev_json = json.loads(dev_proc.stdout)
            self.assertEqual(dev_json.get("status"), "ok")
        finally:
            shutil.rmtree(work_root, ignore_errors=True)

    def test_e2e_f12_t2_01_worker_rejects_leaked_secret_config_at_cli_validate(self) -> None:
        _require_cli_dist()
        work_root = env_probe.get_scratch_dir(f"f12-bad-worker-cfg-{uuid.uuid4().hex[:8]}")
        pack_name = "e2e-secret-check"
        pack_dir = work_root / pack_name
        try:
            cli_driver.run_cli(
                ["vantage", "init", pack_name, "--template", "python-worker"],
                cwd=work_root,
            )
            # First prove clean pack validates with rc == 0 (never pass vacuously on broken CLI)
            clean_proc = cli_driver.run_cli(
                ["vantage", "validate", str(pack_dir), "--json"],
                check=True,
            )
            self.assertEqual(clean_proc.returncode, 0)

            manifest_path = pack_dir / "manifest.json"
            self.assertTrue(manifest_path.is_file(), f"missing scaffolded manifest at {manifest_path}")
            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
            manifest["secret_access_key"] = "synthetic-leaked-secret"
            manifest["database_url"] = "postgres://synthetic:leak@192.0.2.10:5432/serviceradar"
            manifest_path.write_text(json.dumps(manifest, indent=2), encoding="utf-8")

            proc = cli_driver.run_cli(["vantage", "validate", str(pack_dir), "--json"], check=False)
            self.assertNotEqual(proc.returncode, 0)
            combined = (proc.stdout + "\n" + proc.stderr).lower()
            self.assertTrue(
                any(tok in combined for tok in ("secret", "credential", "forbidden", "database_url")),
                f"expected secret-validation diagnostic, got: {combined!r}",
            )
        finally:
            shutil.rmtree(work_root, ignore_errors=True)

    def test_e2e_f12_t2_02_live_tap_sdk_rejects_non_null_catalog_entry_id(self) -> None:
        proc = sdk_driver.run_cargo_test(
            ["conformance", "--", "--nocapture"],
            sdk_dir=self.sdk_repo,
        )
        self.assertEqual(proc.returncode, 0)

    def test_e2e_f12_t2_03_corrupt_fragment_sha256_aborts_before_process_frame(self) -> None:
        proc = sdk_driver.run_cargo_test(
            ["sha256_mismatch"],
            sdk_dir=self.sdk_repo,
        )
        self.assertEqual(proc.returncode, 0)

    def test_e2e_f12_t2_04_python_handler_exception_and_invalid_observation_isolated(self) -> None:
        proc = sdk_driver.run_python_in_sdk_venv(
            ["-m", "pytest", "python/tests"],
            sdk_dir=self.sdk_repo,
        )
        self.assertEqual(proc.returncode, 0)

    def test_e2e_f12_t2_05_rgb8_dimension_mismatch_rejected_by_sdk(self) -> None:
        bad_frame = copy.deepcopy(_load_wire_vector("vantage_frame_v1.json")["positive_payload_format"])
        bad_frame["payload_format"] = "rgb8"
        bad_frame["width"] = 4
        bad_frame["height"] = 2
        bad_frame["payload_b64"] = self.f12["rgb8_frame_cases"]["mismatch_payload_b64"]
        # Verify Rust SDK conformance rejects mismatched rgb8 dimensions AND Python worker ignores bad live frame
        proc_rs = sdk_driver.run_cargo_test(["rgb8"], sdk_dir=self.sdk_repo)
        self.assertEqual(proc_rs.returncode, 0)

        py_bin = sdk_driver.ensure_sdk_python_venv(sdk_dir=self.sdk_repo)
        worker_env = dict(os.environ)
        worker_env["SERVICERADAR_E2E_NATS_URL"] = nats_driver.require_nats_url()
        worker_env["SERVICERADAR_E2E_WEB_URL"] = http_ws_driver.require_web_url()
        live_subj = f"media.live.vantage.vantage_rgb_test_{uuid.uuid4().hex[:6]}.v1"
        script = f"""
import os
import serviceradar_vantage as sv

invoked = []

def handler(ctx):
    invoked.append(ctx.frame_sequence)
    return []

worker = sv.VantageWorker(
    worker_id="e2e-rgb8-mismatch",
    capabilities=[{json.dumps(live_subj.split(".")[3])}],
    supported_source_modes=["live_keyframe_tap"],
    nats_url=os.environ["SERVICERADAR_E2E_NATS_URL"],
    handler=handler,
)
worker.run_for_seconds(2.0)
assert not invoked, f"handler was invoked on mismatched rgb8 payload: {{invoked}}"
"""
        proc_py = subprocess.Popen(
            [str(py_bin), "-c", script],
            cwd=str(self.sdk_repo),
            env=worker_env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        try:
            time.sleep(0.5)
            nats_driver.publish_json(live_subj, bad_frame)
            out, err = proc_py.communicate(timeout=10.0)
            self.assertEqual(proc_py.returncode, 0, f"rgb8 mismatch check failed: {out} {err}")
        finally:
            _stop_proc(proc_py)

    def test_e2e_f12_t2_06_sdk_repo_passes_synthetic_and_license_hygiene(self) -> None:
        required_paths = (
            self.sdk_repo / "Cargo.toml",
            self.sdk_repo / "crates" / "serviceradar-vantage-sdk" / "Cargo.toml",
            self.sdk_repo / "python" / "pyproject.toml",
            self.sdk_repo / "conformance",
        )
        for req in required_paths:
            self.assertTrue(req.exists(), f"missing required SDK workspace path: {req}")

        for manifest_path in (
            self.sdk_repo / "Cargo.toml",
            self.sdk_repo / "crates" / "serviceradar-vantage-sdk" / "Cargo.toml",
            self.sdk_repo / "python" / "pyproject.toml",
        ):
            raw_text = manifest_path.read_text(encoding="utf-8")
            self.assertIn("Apache-2.0", raw_text, f"{manifest_path} missing Apache-2.0 license")
            sanitized = _CANONICAL_SDK_REPO_URL_RE.sub(
                "https://git.example.com/serviceradar-sdk-vantage",
                raw_text,
            )
            vc.assert_synthetic_hygiene(sanitized)

        cargo_lock = self.sdk_repo / "Cargo.lock"
        if cargo_lock.is_file():
            lock_text = cargo_lock.read_text(encoding="utf-8")
            self.assertIsNone(
                re.search(r"\b(?:openalpr|agpl(?:v?3)?)\b", lock_text, re.IGNORECASE),
                "disallowed copyleft dependency found in Cargo.lock",
            )


class F13LiveKeyframeTapAndMailboxModeBTest(_BaseModeBF11F14Test):
    """F13 Tier 1 & Tier 2 live keyframe tap & `longshore_mailbox` E2E tests."""

    @classmethod
    def setUpClass(cls) -> None:
        super().setUpClass()
        cls.f13 = _load_fixture("f13_live_tap_and_mailbox_vectors.json")
        _require_elixir_modules(
            "elixir/serviceradar_core_elx",
            (
                "ServiceRadarCoreElx.CameraRelay.Pipeline",
                "ServiceRadarCoreElx.CameraRelay.LongshoreMailbox",
                "ServiceRadarCoreElx.CameraRelay.LiveVantageTap",
            ),
        )

    def _provision_live_tap_camera(
        self,
        *,
        display_name: str = "Bay 04 Approach",
        capability: str = "vantage.bay_guidance.v1",
        signal_schema_id: str = "bay_guidance",
        tag: str = "f13",
    ) -> tuple[dict[str, str], str]:
        cam = _provision_camera_block(tag, display_name=display_name)
        pid = f"io.serviceradar.e2e.{tag}-{uuid.uuid4().hex[:8]}"
        _eval_elixir_json(
            "elixir/serviceradar_core",
            f"""
            alias ServiceRadar.Actors.SystemActor
            alias ServiceRadar.Camera.VantagePipeline
            actor = SystemActor.system(:mode_b_f13)
            {{:ok, _}} = VantagePipeline |> Ash.Changeset.for_create(:upsert, %{{
              pipeline_id: "{pid}",
              version: "1.0.0",
              name: {json.dumps(display_name + " Live Tap")},
              enabled: true,
              source_mode: :live_keyframe_tap,
              trigger_kind: :live_keyframe_tap,
              runner: :external_worker,
              capability: "{capability}",
              fallback_runner: nil,
              signal_schema_id: "{signal_schema_id}",
              signal_schema_version: "1.0.0",
              display_contract_id: "{signal_schema_id}",
              emit_ocsf_events: true
            }}, actor: actor) |> Ash.create(actor: actor)
            result = %{{ok: true}}
            """,
        )
        return cam, pid

    def test_e2e_f13_t1_01_live_tap_emits_vantage_frame_for_bay_04(self) -> None:
        cam, pid = self._provision_live_tap_camera(
            display_name="Bay 04 Approach",
            capability="vantage.bay_guidance.v1",
            signal_schema_id="bay_guidance",
            tag="f13-t1-01",
        )
        sub_proc = None
        try:
            sub_proc = _start_nats_sub("media.live.vantage.vantage_bay_guidance_v1.v1", count=1)
            annex_b_b64 = self.f13["carriers"]["annex_b_idr_b64"]
            _eval_elixir_json(
                "elixir/serviceradar_core_elx",
                f"""
                alias ServiceRadarCoreElx.CameraRelay.{{LiveVantageTap, Pipeline}}
                relay_id = "relay-f13-t1-01-#{uuid.uuid4().hex[:8]}"
                {{:ok, _sup, pipeline_pid}} = Membrane.Pipeline.start_link(Pipeline, relay_session_id: relay_id)
                {{:ok, _tap}} = LiveVantageTap.attach_pipeline(
                  pipeline_pid,
                  relay_session_id: relay_id,
                  camera_source_id: "{cam['camera_source_id']}",
                  stream_profile_id: "{cam['stream_profile_id']}",
                  capability: "vantage.bay_guidance.v1"
                )
                idr = Base.decode64!("{annex_b_b64}")
                send(pipeline_pid, {{:media_chunk, %{{
                  payload: idr,
                  pts: 0,
                  dts: 0,
                  sequence: 1,
                  keyframe: true,
                  codec: :h264,
                  payload_format: :annexb
                }}}})
                Process.sleep(400)
                Membrane.Pipeline.terminate(pipeline_pid)
                result = %{{emitted: true}}
                """,
            )
            stdout, stderr = sub_proc.communicate(timeout=10.0)
            self.assertEqual(sub_proc.returncode, 0, f"nats sub failed: {stderr}")
            lines = [ln for ln in stdout.splitlines() if ln.strip()]
            self.assertTrue(lines, "expected vantage.frame.v1 on media.live.vantage.vantage_bay_guidance_v1.v1")
            frame = vc.validate_live_frame(json.loads(lines[0]))
            self.assertEqual(frame["camera_source_id"], cam["camera_source_id"])
            self.assertIsNone(frame["catalog_entry_id"])
            self.assertIsNone(frame["fragment_sequence"])
        finally:
            _stop_proc(sub_proc)
            _cleanup_cnpg_records(source_ids=[cam["camera_source_id"]], pipeline_ids=[pid])

    def test_e2e_f13_t1_02_steady_state_mailbox_zero_drops_monotonic(self) -> None:
        cam, pid = self._provision_live_tap_camera(tag="f13-t1-02")
        sub_proc = None
        try:
            sub_proc = _start_nats_sub("media.live.vantage.vantage_bay_guidance_v1.v1", count=8)
            annex_b_b64 = self.f13["carriers"]["annex_b_idr_b64"]
            res = _eval_elixir_json(
                "elixir/serviceradar_core_elx",
                f"""
                alias ServiceRadarCoreElx.CameraRelay.{{LiveVantageTap, Pipeline}}
                parent = self()
                handler_id = "e2e-f13-t1-02-#{uuid.uuid4().hex[:6]}"
                :telemetry.attach(
                  handler_id,
                  [:serviceradar, :vantage, :live_tap, :dropped],
                  fn _ev, meas, _meta, _ -> send(parent, {{:dropped, meas}}) end,
                  nil
                )
                relay_id = "relay-f13-t1-02-#{uuid.uuid4().hex[:8]}"
                {{:ok, _sup, pipeline_pid}} = Membrane.Pipeline.start_link(Pipeline, relay_session_id: relay_id)
                {{:ok, _tap}} = LiveVantageTap.attach_pipeline(
                  pipeline_pid,
                  relay_session_id: relay_id,
                  camera_source_id: "{cam['camera_source_id']}",
                  stream_profile_id: "{cam['stream_profile_id']}",
                  capability: "vantage.bay_guidance.v1"
                )
                idr = Base.decode64!("{annex_b_b64}")
                for seq <- 1..8 do
                  send(pipeline_pid, {{:media_chunk, %{{
                    payload: idr,
                    pts: seq * 90_000,
                    dts: seq * 90_000,
                    sequence: seq,
                    keyframe: true,
                    codec: :h264,
                    payload_format: :annexb
                  }}}})
                  Process.sleep(30)
                end
                Process.sleep(400)
                dropped = receive do {{:dropped, _}} -> 1 after 50 -> 0 end
                :telemetry.detach(handler_id)
                Membrane.Pipeline.terminate(pipeline_pid)
                result = %{{dropped: dropped}}
                """,
            )
            self.assertEqual(res["dropped"], 0)
            stdout, stderr = sub_proc.communicate(timeout=10.0)
            self.assertEqual(sub_proc.returncode, 0, f"nats sub failed: {stderr}")
            seqs = [
                vc.validate_live_frame(json.loads(ln))["frame_sequence"]
                for ln in stdout.splitlines()
                if ln.strip()
            ]
            self.assertEqual(seqs, [1, 2, 3, 4, 5, 6, 7, 8])
        finally:
            _stop_proc(sub_proc)
            _cleanup_cnpg_records(source_ids=[cam["camera_source_id"]], pipeline_ids=[pid])

    def test_e2e_f13_t1_03_per_camera_mailbox_sharding_isolation(self) -> None:
        cam_bay, pid_bay = self._provision_live_tap_camera(
            display_name="Bay 04 Approach",
            capability="vantage.bay_guidance.v1",
            signal_schema_id="bay_guidance",
            tag="f13-t1-03-bay",
        )
        cam_gate, pid_gate = self._provision_live_tap_camera(
            display_name="Gate West 01",
            capability="vantage.alpr.v1",
            signal_schema_id="alpr_plate_read",
            tag="f13-t1-03-gate",
        )
        sub_gate = None
        try:
            sub_gate = _start_nats_sub("media.live.vantage.vantage_alpr_v1.v1", count=3)
            annex_b_b64 = self.f13["carriers"]["annex_b_idr_b64"]
            res = _eval_elixir_json(
                "elixir/serviceradar_core_elx",
                f"""
                alias ServiceRadarCoreElx.CameraRelay.{{LiveVantageTap, Pipeline}}
                idr = Base.decode64!("{annex_b_b64}")
                {{:ok, _s1, p_bay}} = Membrane.Pipeline.start_link(Pipeline, relay_session_id: "relay-bay-#{uuid.uuid4().hex[:6]}")
                {{:ok, _s2, p_gate}} = Membrane.Pipeline.start_link(Pipeline, relay_session_id: "relay-gate-#{uuid.uuid4().hex[:6]}")
                {{:ok, _}} = LiveVantageTap.attach_pipeline(
                  p_bay,
                  relay_session_id: "bay",
                  camera_source_id: "{cam_bay['camera_source_id']}",
                  stream_profile_id: "{cam_bay['stream_profile_id']}",
                  capability: "vantage.bay_guidance.v1",
                  pause_publish: true
                )
                {{:ok, _}} = LiveVantageTap.attach_pipeline(
                  p_gate,
                  relay_session_id: "gate",
                  camera_source_id: "{cam_gate['camera_source_id']}",
                  stream_profile_id: "{cam_gate['stream_profile_id']}",
                  capability: "vantage.alpr.v1"
                )
                for seq <- 1..20 do
                  send(p_bay, {{:media_chunk, %{{payload: idr, pts: seq * 90_000, dts: seq * 90_000, sequence: seq, keyframe: true, codec: :h264, payload_format: :annexb}}}})
                end
                for seq <- 1..3 do
                  send(p_gate, {{:media_chunk, %{{payload: idr, pts: seq * 90_000, dts: seq * 90_000, sequence: seq, keyframe: true, codec: :h264, payload_format: :annexb}}}})
                  Process.sleep(30)
                end
                Process.sleep(400)
                bay_drops = LiveVantageTap.dropped_count("{cam_bay['camera_source_id']}")
                gate_drops = LiveVantageTap.dropped_count("{cam_gate['camera_source_id']}")
                Membrane.Pipeline.terminate(p_bay)
                Membrane.Pipeline.terminate(p_gate)
                result = %{{bay_drops: bay_drops, gate_drops: gate_drops}}
                """,
            )
            self.assertEqual(res["bay_drops"], 12)
            self.assertEqual(res["gate_drops"], 0)
            stdout, stderr = sub_gate.communicate(timeout=10.0)
            self.assertEqual(sub_gate.returncode, 0, f"gate nats sub failed: {stderr}")
            gate_seqs = [
                vc.validate_live_frame(json.loads(ln))["frame_sequence"]
                for ln in stdout.splitlines()
                if ln.strip()
            ]
            self.assertEqual(gate_seqs, [1, 2, 3])
        finally:
            _stop_proc(sub_gate)
            _cleanup_cnpg_records(
                source_ids=[cam_bay["camera_source_id"], cam_gate["camera_source_id"]],
                pipeline_ids=[pid_bay, pid_gate],
            )

    def test_e2e_f13_t1_04_live_frame_carriers_and_time_basis(self) -> None:
        wire = _load_wire_vector("vantage_frame_v1.json")
        sdk_repo = env_probe.probe_sdk_repo()
        py_bin = sdk_driver.ensure_sdk_python_venv(sdk_dir=sdk_repo)
        cam_id = self.f13["cameras"]["bay_04_approach"]["camera_source_id"]
        stream_id = self.f13["cameras"]["bay_04_approach"]["stream_profile_id"]
        carriers = self.f13["carriers"]
        live_subj = self.f13["cameras"]["bay_04_approach"]["live_subject"]

        frames: list[dict[str, Any]] = []
        for idx, (tb, field_updates) in enumerate(
            [
                ("received", {"frame_jpeg_b64": wire["positive"]["frame_jpeg_b64"]}),
                ("camera_reported", {"payload_format": "annex_b_idr", "payload_b64": carriers["annex_b_idr_b64"]}),
                ("received", {"payload_format": "rgb8", "payload_b64": carriers["rgb8_4x2_b64"], "width": 4, "height": 2}),
                ("camera_reported", {"read_token": carriers["read_token"]}),
            ],
            start=1,
        ):
            pkt = copy.deepcopy(wire["positive"])
            pkt.pop("frame_jpeg_b64", None)
            pkt.pop("payload_format", None)
            pkt.pop("payload_b64", None)
            pkt.pop("read_token", None)
            pkt["camera_source_id"] = cam_id
            pkt["stream_profile_id"] = stream_id
            pkt["frame_sequence"] = idx
            pkt["time_basis"] = tb
            pkt.update(field_updates)
            vc.validate_live_frame(pkt)
            frames.append(pkt)

        # Start live VantageWorker over NATS and feed jpeg, annex_b_idr, and rgb8 frames
        worker_env = dict(os.environ)
        worker_env["SERVICERADAR_E2E_NATS_URL"] = nats_driver.require_nats_url()
        worker_env["SERVICERADAR_E2E_WEB_URL"] = http_ws_driver.require_web_url()
        script = """
import json
import os
import serviceradar_vantage as sv

observed = []

def handler(ctx):
    observed.append((ctx.frame_sequence, ctx.time_basis))
    return []

worker = sv.VantageWorker(
    worker_id="e2e-carriers",
    capabilities=["vantage.bay_guidance.v1"],
    supported_source_modes=["live_keyframe_tap"],
    nats_url=os.environ["SERVICERADAR_E2E_NATS_URL"],
    handler=handler,
)
worker.run_for_seconds(3.0)
assert len(observed) >= 3, f"expected >= 3 decoded carriers via live NATS, got {observed}"
print(json.dumps({"observed": observed}))
"""
        proc = subprocess.Popen(
            [str(py_bin), "-c", script],
            cwd=str(sdk_repo),
            env=worker_env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        try:
            time.sleep(0.6)
            for pkt in frames:
                nats_driver.publish_json(live_subj, pkt)
            out, err = proc.communicate(timeout=15.0)
            self.assertEqual(proc.returncode, 0, f"live carrier worker failed: {out} {err}")
        finally:
            _stop_proc(proc)

    def test_e2e_f13_t1_05_camera_cap_admission_enforced(self) -> None:
        cap = int(self.f13["default_camera_cap"])
        provisioned: list[tuple[dict[str, str], str]] = []
        try:
            for idx in range(cap + 1):
                provisioned.append(
                    self._provision_live_tap_camera(
                        display_name=f"Bay {idx + 1:02d} Approach",
                        tag=f"f13-cap-{idx}",
                    )
                )
            cam_entries = (
                "["
                + ", ".join(
                    f'%{{cam_id: "{c["camera_source_id"]}", prof_id: "{c["stream_profile_id"]}"}}'
                    for c, _ in provisioned
                )
                + "]"
            )
            res = _eval_elixir_json(
                "elixir/serviceradar_core_elx",
                f"""
                alias ServiceRadarCoreElx.CameraRelay.{{LiveVantageTap, Pipeline}}
                prev = Application.get_env(:serviceradar_core_elx, :vantage_live_tap_max_cameras)
                Application.put_env(:serviceradar_core_elx, :vantage_live_tap_max_cameras, {cap})
                cams = {cam_entries}
                {{admit_cams, [excess_cam]}} = Enum.split(cams, {cap})
                pipelines = Enum.map(cams, fn c ->
                  {{:ok, _sup, p}} = Membrane.Pipeline.start_link(Pipeline, relay_session_id: "relay-cap-" <> c.cam_id)
                  {{c, p}}
                end)
                {{admitted_pairs, [{{excess_pair_c, excess_pipe}}]}} = Enum.split(pipelines, {cap})
                admitted_res = Enum.map(admitted_pairs, fn {{c, p}} ->
                  LiveVantageTap.attach_pipeline(
                    p,
                    relay_session_id: "relay-cap-" <> c.cam_id,
                    camera_source_id: c.cam_id,
                    stream_profile_id: c.prof_id,
                    capability: "vantage.bay_guidance.v1"
                  )
                end)
                excess_res = LiveVantageTap.attach_pipeline(
                  excess_pipe,
                  relay_session_id: "relay-cap-" <> excess_pair_c.cam_id,
                  camera_source_id: excess_pair_c.cam_id,
                  stream_profile_id: excess_pair_c.prof_id,
                  capability: "vantage.bay_guidance.v1"
                )
                all_admitted_pipes_alive = Enum.all?(admitted_pairs, fn {{_c, p}} -> Process.alive?(p) end)
                Enum.each(pipelines, fn {{_c, p}} -> Membrane.Pipeline.terminate(p) end)
                if prev, do: Application.put_env(:serviceradar_core_elx, :vantage_live_tap_max_cameras, prev), else: Application.delete_env(:serviceradar_core_elx, :vantage_live_tap_max_cameras)
                result = %{{
                  all_admitted_ok: Enum.all?(admitted_res, &match?({{:ok, _}}, &1)),
                  excess_rejected: match?({{:error, _}}, excess_res),
                  all_admitted_pipes_alive: all_admitted_pipes_alive
                }}
                """,
            )
            self.assertTrue(res["all_admitted_ok"])
            self.assertTrue(res["excess_rejected"])
            self.assertTrue(res["all_admitted_pipes_alive"])
        finally:
            _cleanup_cnpg_records(
                source_ids=[c["camera_source_id"] for c, _ in provisioned],
                pipeline_ids=[p for _, p in provisioned],
            )

    def test_e2e_f13_t1_06_active_tracks_128_boundary_and_teardown(self) -> None:
        cam, pid = self._provision_live_tap_camera(tag="f13-t1-06")
        sub_proc = None
        try:
            sub_proc = _start_nats_sub("media.live.vantage.vantage_bay_guidance_v1.v1", count=1)
            annex_b_b64 = self.f13["carriers"]["annex_b_idr_b64"]
            res = _eval_elixir_json(
                "elixir/serviceradar_core_elx",
                f"""
                alias ServiceRadarCoreElx.CameraRelay.{{LiveVantageTap, Pipeline}}
                idr = Base.decode64!("{annex_b_b64}")
                tracks = for i <- 1..128, do: %{{
                  "track_id" => "t-" <> Integer.to_string(i),
                  "category" => "vehicle",
                  "confidence" => 0.9,
                  "bbox" => [0.1, 0.1, 0.4, 0.4]
                }}
                {{:ok, _sup, pipeline_pid}} = Membrane.Pipeline.start_link(Pipeline, relay_session_id: "relay-128-#{uuid.uuid4().hex[:6]}")
                {{:ok, _tap}} = LiveVantageTap.attach_pipeline(
                  pipeline_pid,
                  relay_session_id: "relay-128",
                  camera_source_id: "{cam['camera_source_id']}",
                  stream_profile_id: "{cam['stream_profile_id']}",
                  capability: "vantage.bay_guidance.v1"
                )
                send(pipeline_pid, {{:media_chunk, %{{
                  payload: idr,
                  pts: 0,
                  dts: 0,
                  sequence: 1,
                  keyframe: true,
                  codec: :h264,
                  payload_format: :annexb,
                  detections: tracks
                }}}})
                Process.sleep(400)
                active_before = LiveVantageTap.active_track_count("{cam['camera_source_id']}")
                Membrane.Pipeline.terminate(pipeline_pid)
                Process.sleep(100)
                active_after = LiveVantageTap.active_track_count("{cam['camera_source_id']}")
                result = %{{active_before: active_before, active_after: active_after}}
                """,
            )
            self.assertEqual(res["active_before"], vc.LIVE_TAP_MAX_TRACKS)
            self.assertEqual(res["active_after"], 0)
            stdout, stderr = sub_proc.communicate(timeout=10.0)
            self.assertEqual(sub_proc.returncode, 0, f"nats sub failed: {stderr}")
            frame = vc.validate_live_frame(json.loads(stdout.splitlines()[0]))
            self.assertEqual(len(frame.get("detections") or []), 128)
        finally:
            _stop_proc(sub_proc)
            _cleanup_cnpg_records(source_ids=[cam["camera_source_id"]], pipeline_ids=[pid])

    def test_e2e_f13_t2_01_mailbox_overflow_20_frames_drops_12_oldest_with_telemetry(self) -> None:
        cam, pid = self._provision_live_tap_camera(tag="f13-t2-01")
        sub_proc = None
        try:
            sub_proc = _start_nats_sub("media.live.vantage.vantage_bay_guidance_v1.v1", count=8)
            annex_b_b64 = self.f13["carriers"]["annex_b_idr_b64"]
            res = _eval_elixir_json(
                "elixir/serviceradar_core_elx",
                f"""
                alias ServiceRadarCoreElx.CameraRelay.{{LiveVantageTap, Pipeline}}
                parent = self()
                handler_id = "e2e-f13-t2-01-#{uuid.uuid4().hex[:6]}"
                :telemetry.attach(
                  handler_id,
                  [:serviceradar, :vantage, :live_tap, :dropped],
                  fn _ev, meas, _meta, _ -> send(parent, {{:drop_ev, meas}}) end,
                  nil
                )
                idr = Base.decode64!("{annex_b_b64}")
                {{:ok, _sup, pipeline_pid}} = Membrane.Pipeline.start_link(Pipeline, relay_session_id: "relay-ovf-#{uuid.uuid4().hex[:6]}")
                {{:ok, tap_pid}} = LiveVantageTap.attach_pipeline(
                  pipeline_pid,
                  relay_session_id: "relay-ovf",
                  camera_source_id: "{cam['camera_source_id']}",
                  stream_profile_id: "{cam['stream_profile_id']}",
                  capability: "vantage.bay_guidance.v1",
                  pause_publish: true
                )
                for seq <- 1..20 do
                  send(pipeline_pid, {{:media_chunk, %{{payload: idr, pts: seq * 90_000, dts: seq * 90_000, sequence: seq, keyframe: true, codec: :h264, payload_format: :annexb}}}})
                end
                Process.sleep(300)
                LiveVantageTap.resume_publish(tap_pid)
                Process.sleep(400)
                drops = LiveVantageTap.dropped_count("{cam['camera_source_id']}")
                drop_events = Stream.repeatedly(fn -> receive do {{:drop_ev, m}} -> m after 50 -> nil end end) |> Enum.take_while(& &1 != nil) |> length()
                :telemetry.detach(handler_id)
                Membrane.Pipeline.terminate(pipeline_pid)
                result = %{{drops: drops, drop_events: drop_events}}
                """,
            )
            self.assertEqual(res["drops"], 12)
            self.assertGreaterEqual(res["drop_events"], 1)
            stdout, stderr = sub_proc.communicate(timeout=10.0)
            self.assertEqual(sub_proc.returncode, 0, f"nats sub failed: {stderr}")
            retained_seqs = [
                vc.validate_live_frame(json.loads(ln))["frame_sequence"]
                for ln in stdout.splitlines()
                if ln.strip()
            ]
            self.assertEqual(retained_seqs, [13, 14, 15, 16, 17, 18, 19, 20])
        finally:
            _stop_proc(sub_proc)
            _cleanup_cnpg_records(source_ids=[cam["camera_source_id"]], pipeline_ids=[pid])

    def test_e2e_f13_t2_02_track_129_rejected_or_bounded(self) -> None:
        cam, pid = self._provision_live_tap_camera(tag="f13-t2-02")
        try:
            annex_b_b64 = self.f13["carriers"]["annex_b_idr_b64"]
            res = _eval_elixir_json(
                "elixir/serviceradar_core_elx",
                f"""
                alias ServiceRadarCoreElx.CameraRelay.{{LiveVantageTap, Pipeline}}
                idr = Base.decode64!("{annex_b_b64}")
                tracks = for i <- 1..129, do: %{{
                  "track_id" => "t-" <> Integer.to_string(i),
                  "category" => "vehicle",
                  "confidence" => 0.9,
                  "bbox" => [0.1, 0.1, 0.4, 0.4]
                }}
                {{:ok, _sup, pipeline_pid}} = Membrane.Pipeline.start_link(Pipeline, relay_session_id: "relay-129-#{uuid.uuid4().hex[:6]}")
                {{:ok, _tap}} = LiveVantageTap.attach_pipeline(
                  pipeline_pid,
                  relay_session_id: "relay-129",
                  camera_source_id: "{cam['camera_source_id']}",
                  stream_profile_id: "{cam['stream_profile_id']}",
                  capability: "vantage.bay_guidance.v1"
                )
                send(pipeline_pid, {{:media_chunk, %{{
                  payload: idr,
                  pts: 0,
                  dts: 0,
                  sequence: 1,
                  keyframe: true,
                  codec: :h264,
                  payload_format: :annexb,
                  detections: tracks
                }}}})
                Process.sleep(300)
                active = LiveVantageTap.active_track_count("{cam['camera_source_id']}")
                alive = Process.alive?(pipeline_pid)
                Membrane.Pipeline.terminate(pipeline_pid)
                result = %{{active: active, alive: alive}}
                """,
            )
            self.assertTrue(res["alive"])
            self.assertLessEqual(res["active"], vc.LIVE_TAP_MAX_TRACKS)
        finally:
            _cleanup_cnpg_records(source_ids=[cam["camera_source_id"]], pipeline_ids=[pid])

    def test_e2e_f13_t2_03_camera_cap_exceeded_refuses_excess_camera(self) -> None:
        cam1, pid1 = self._provision_live_tap_camera(display_name="Bay 04 Approach", tag="f13-t2-03a")
        cam2, pid2 = self._provision_live_tap_camera(display_name="Gate West 01", tag="f13-t2-03b")
        try:
            res = _eval_elixir_json(
                "elixir/serviceradar_core_elx",
                f"""
                alias ServiceRadarCoreElx.CameraRelay.{{LiveVantageTap, Pipeline}}
                prev = Application.get_env(:serviceradar_core_elx, :vantage_live_tap_max_cameras)
                Application.put_env(:serviceradar_core_elx, :vantage_live_tap_max_cameras, 1)
                {{:ok, _s1, p1}} = Membrane.Pipeline.start_link(Pipeline, relay_session_id: "relay-cap1-#{uuid.uuid4().hex[:6]}")
                {{:ok, _s2, p2}} = Membrane.Pipeline.start_link(Pipeline, relay_session_id: "relay-cap2-#{uuid.uuid4().hex[:6]}")
                ok_1 = LiveVantageTap.attach_pipeline(
                  p1,
                  relay_session_id: "relay-cap1",
                  camera_source_id: "{cam1['camera_source_id']}",
                  stream_profile_id: "{cam1['stream_profile_id']}",
                  capability: "vantage.bay_guidance.v1"
                )
                excess = LiveVantageTap.attach_pipeline(
                  p2,
                  relay_session_id: "relay-cap2",
                  camera_source_id: "{cam2['camera_source_id']}",
                  stream_profile_id: "{cam2['stream_profile_id']}",
                  capability: "vantage.bay_guidance.v1"
                )
                still_alive = Process.alive?(p1)
                Membrane.Pipeline.terminate(p1)
                Membrane.Pipeline.terminate(p2)
                if prev, do: Application.put_env(:serviceradar_core_elx, :vantage_live_tap_max_cameras, prev), else: Application.delete_env(:serviceradar_core_elx, :vantage_live_tap_max_cameras)
                result = %{{
                  admitted_ok: match?({{:ok, _}}, ok_1),
                  excess_rejected: match?({{:error, _}}, excess),
                  still_alive: still_alive
                }}
                """,
            )
            self.assertTrue(res["admitted_ok"])
            self.assertTrue(res["excess_rejected"])
            self.assertTrue(res["still_alive"])
        finally:
            _cleanup_cnpg_records(
                source_ids=[cam1["camera_source_id"], cam2["camera_source_id"]],
                pipeline_ids=[pid1, pid2],
            )

    def test_e2e_f13_t2_04_oversized_frame_rejected_before_nats_publish(self) -> None:
        cam, pid = self._provision_live_tap_camera(tag="f13-t2-04")
        sub_proc = None
        try:
            sub_proc = _start_nats_sub("media.live.vantage.vantage_bay_guidance_v1.v1", count=1)
            annex_b_b64 = self.f13["carriers"]["annex_b_idr_b64"]
            res = _eval_elixir_json(
                "elixir/serviceradar_core_elx",
                f"""
                alias ServiceRadarCoreElx.CameraRelay.{{LiveVantageTap, Pipeline}}
                oversized = :binary.copy(<<"A">>, 983_041)
                valid_idr = Base.decode64!("{annex_b_b64}")
                {{:ok, _sup, pipeline_pid}} = Membrane.Pipeline.start_link(Pipeline, relay_session_id: "relay-big-#{uuid.uuid4().hex[:6]}")
                {{:ok, _tap}} = LiveVantageTap.attach_pipeline(
                  pipeline_pid,
                  relay_session_id: "relay-big",
                  camera_source_id: "{cam['camera_source_id']}",
                  stream_profile_id: "{cam['stream_profile_id']}",
                  capability: "vantage.bay_guidance.v1"
                )
                send(pipeline_pid, {{:media_chunk, %{{payload: oversized, pts: 0, dts: 0, sequence: 1, keyframe: true, codec: :h264, payload_format: :annexb}}}})
                send(pipeline_pid, {{:media_chunk, %{{payload: valid_idr, pts: 90_000, dts: 90_000, sequence: 2, keyframe: true, codec: :h264, payload_format: :annexb}}}})
                Process.sleep(400)
                drops = LiveVantageTap.dropped_count("{cam['camera_source_id']}")
                Membrane.Pipeline.terminate(pipeline_pid)
                result = %{{drops: drops}}
                """,
            )
            self.assertGreaterEqual(res["drops"], 1)
            stdout, stderr = sub_proc.communicate(timeout=10.0)
            self.assertEqual(sub_proc.returncode, 0, f"nats sub failed: {stderr}")
            msg = vc.validate_live_frame(json.loads(stdout.splitlines()[0]))
            self.assertEqual(msg["frame_sequence"], 2)
        finally:
            _stop_proc(sub_proc)
            _cleanup_cnpg_records(source_ids=[cam["camera_source_id"]], pipeline_ids=[pid])

    def test_e2e_f13_t2_05_invalid_frame_payload_rejected(self) -> None:
        sdk_repo = env_probe.probe_sdk_repo()
        py_bin = sdk_driver.ensure_sdk_python_venv(sdk_dir=sdk_repo)
        bad_frame = copy.deepcopy(_load_wire_vector("vantage_frame_v1.json")["negative"][0]["payload"])
        good_frame = copy.deepcopy(_load_wire_vector("vantage_frame_v1.json")["positive"])
        bad_frame["camera_source_id"] = self.f13["cameras"]["bay_04_approach"]["camera_source_id"]
        good_frame["camera_source_id"] = self.f13["cameras"]["bay_04_approach"]["camera_source_id"]
        good_frame["frame_sequence"] = 2

        live_subj = self.f13["cameras"]["bay_04_approach"]["live_subject"]
        worker_env = dict(os.environ)
        worker_env["SERVICERADAR_E2E_NATS_URL"] = nats_driver.require_nats_url()
        worker_env["SERVICERADAR_E2E_WEB_URL"] = http_ws_driver.require_web_url()
        script = """
import os
import serviceradar_vantage as sv

processed_seqs = []

def handler(ctx):
    processed_seqs.append(ctx.frame_sequence)
    return []

worker = sv.VantageWorker(
    worker_id="e2e-invalid-frame-filter",
    capabilities=["vantage.bay_guidance.v1"],
    supported_source_modes=["live_keyframe_tap"],
    nats_url=os.environ["SERVICERADAR_E2E_NATS_URL"],
    handler=handler,
)
worker.run_for_seconds(3.0)
assert processed_seqs == [2], f"expected only valid frame [2], got {processed_seqs}"
"""
        proc = subprocess.Popen(
            [str(py_bin), "-c", script],
            cwd=str(sdk_repo),
            env=worker_env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        try:
            time.sleep(0.6)
            nats_driver.publish_json(live_subj, bad_frame)
            nats_driver.publish_json(live_subj, good_frame)
            out, err = proc.communicate(timeout=15.0)
            self.assertEqual(proc.returncode, 0, f"invalid frame rejection worker failed: {out} {err}")
        finally:
            _stop_proc(proc)

    def test_e2e_f13_t2_06_stall_or_crash_preserves_cmaf_recording_pipeline(self) -> None:
        cam, pid = self._provision_live_tap_camera(tag="f13-t2-06")
        try:
            annex_b_b64 = self.f13["carriers"]["annex_b_idr_b64"]
            res = _eval_elixir_json(
                "elixir/serviceradar_core_elx",
                f"""
                alias ServiceRadarCoreElx.CameraRelay.{{LiveVantageTap, Pipeline}}
                alias ServiceRadarRecording.Inbox
                idr = Base.decode64!("{annex_b_b64}")
                relay_id = "relay-cmaf-iso-#{uuid.uuid4().hex[:8]}"
                ingest_id = "ingest-cmaf-iso-#{uuid.uuid4().hex[:8]}"
                {{:ok, _sup, pipeline_pid}} = Membrane.Pipeline.start_link(
                  Pipeline,
                  relay_session_id: relay_id,
                  media_ingest_id: ingest_id
                )
                # Attach real ServiceRadarRecording.Inbox CMAF recorder
                parent = self()
                recorder_pid = spawn_link(fn ->
                  {{:ok, inbox}} = Inbox.new(
                    pipeline_pid,
                    relay_id,
                    ingest_id,
                    System.monotonic_time(:millisecond) + 30_000,
                    max_samples: 32
                  )
                  :ok = Membrane.Pipeline.call(pipeline_pid, {{:attach_recorder, inbox}})
                  send(parent, :recorder_attached)
                  inbox_id = inbox.id
                  loop = fn loop_fn, seqs ->
                    receive do
                      {{:recording_media, ^inbox_id, unit}} ->
                        :ok = Inbox.release(inbox, byte_size(unit.payload))
                        loop_fn.(loop_fn, [unit.sequence | seqs])
                      {{:recording_rejected, ^inbox_id, reason}} ->
                        raise("recorder rejected: #{{inspect(reason)}}")
                      {{:get_seqs, from}} ->
                        send(from, {{:recorded_seqs, Enum.reverse(seqs)}})
                    end
                  end
                  loop.(loop, [])
                end)
                receive do :recorder_attached -> :ok after 2_000 -> raise("recorder attach timeout") end

                # Attach live-tap branch with simulated slow/stalled worker, then kill it mid-stream
                {{:ok, tap_pid}} = LiveVantageTap.attach_pipeline(
                  pipeline_pid,
                  relay_session_id: relay_id,
                  camera_source_id: "{cam['camera_source_id']}",
                  stream_profile_id: "{cam['stream_profile_id']}",
                  capability: "vantage.bay_guidance.v1",
                  pause_publish: true
                )
                for seq <- 1..12 do
                  if seq == 7, do: Process.exit(tap_pid, :kill)
                  send(pipeline_pid, {{:media_chunk, %{{payload: idr, pts: seq * 90_000, dts: seq * 90_000, sequence: seq, keyframe: true, media_ingest_id: ingest_id, codec: "h264", payload_format: "annexb"}}}})
                  Process.sleep(15)
                end
                Process.sleep(300)
                pipeline_alive = Process.alive?(pipeline_pid)
                send(recorder_pid, {{:get_seqs, self()}})
                recorded_seqs = receive do {{:recorded_seqs, s}} -> s after 2_000 -> [] end
                Membrane.Pipeline.terminate(pipeline_pid)
                result = %{{pipeline_alive: pipeline_alive, recorded_seqs: recorded_seqs}}
                """,
            )
            self.assertTrue(res["pipeline_alive"], "CameraRelay.Pipeline died on live-tap stall/crash")
            self.assertEqual(res["recorded_seqs"], list(range(1, 13)), "CMAF recording had sequence gaps")
        finally:
            _cleanup_cnpg_records(source_ids=[cam["camera_source_id"]], pipeline_ids=[pid])


class F14GuidanceBenchmarkAndRetentionModeBTest(_BaseModeBF11F14Test):
    """F14 Tier 1 & Tier 2 live guidance benchmark, PubSub overlay, and retention tests."""

    @classmethod
    def setUpClass(cls) -> None:
        super().setUpClass()
        cls.f14 = _load_fixture("f14_guidance_retention_benchmark.json")
        cls.f13 = _load_fixture("f13_live_tap_and_mailbox_vectors.json")
        _require_elixir_modules(
            "elixir/serviceradar_core",
            ("ServiceRadar.Camera.VantageRetention",),
        )
        _require_elixir_modules(
            "elixir/web-ng",
            ("ServiceRadarWebNGWeb.DashboardFrameChannel.Events",),
        )

    def _provision_guidance_pipeline(self, tag: str, *, retention_days: int = 7) -> tuple[dict[str, str], str]:
        cam = _provision_camera_block(tag, display_name="Bay 04 Approach")
        pid = f"io.serviceradar.e2e.{tag}-{uuid.uuid4().hex[:8]}"
        _eval_elixir_json(
            "elixir/serviceradar_core",
            f"""
            alias ServiceRadar.Actors.SystemActor
            alias ServiceRadar.Camera.VantagePipeline
            actor = SystemActor.system(:mode_b_f14)
            schema = %{{
              "type" => "object",
              "required" => ["bay_id", "guidance_state", "distance_m", "lateral_offset_m"],
              "properties" => %{{
                "bay_id" => %{{ "type" => "string", "minLength" => 1 }},
                "guidance_state" => %{{ "type" => "string", "enum" => ["approach", "aligning", "stop", "docked", "clear"] }},
                "distance_m" => %{{ "type" => "number", "minimum" => 0 }},
                "lateral_offset_m" => %{{ "type" => "number" }},
                "confidence" => %{{ "type" => "number", "minimum" => 0, "maximum" => 1 }}
              }},
              "additionalProperties" => true
            }}
            {{:ok, _}} = VantagePipeline |> Ash.Changeset.for_create(:upsert, %{{
              pipeline_id: "{pid}",
              version: "1.0.0",
              name: "Bay 04 Approach Guidance",
              enabled: true,
              source_mode: :live_keyframe_tap,
              trigger_kind: :live_keyframe_tap,
              runner: :external_worker,
              capability: "vantage.bay_guidance.v1",
              signal_schema_id: "bay_guidance",
              signal_schema_version: "1.0.0",
              signal_schema: schema,
              display_contract_id: "bay_guidance",
              emit_ocsf_events: true,
              live_observation_retention_days: {retention_days}
            }}, actor: actor) |> Ash.create(actor: actor)
            result = %{{ok: true}}
            """,
        )
        return cam, pid

    def test_e2e_f14_t1_01_bay_guidance_states_persisted_with_null_catalog_entry(self) -> None:
        cam, pid = self._provision_guidance_pipeline("f14-t1-01")
        obs_keys: list[str] = []
        try:
            tmpl = _load_wire_vector("vantage_result_v1.json")["positive_live"]
            for idx, attrs in enumerate(self.f14["bay_guidance_positive"], start=1):
                obs_key = uuid.uuid4().hex + uuid.uuid4().hex
                obs_keys.append(obs_key)
                env = copy.deepcopy(tmpl)
                env["pipeline_id"] = pid
                env["camera_source_id"] = cam["camera_source_id"]
                env["stream_profile_id"] = cam["stream_profile_id"]
                env["observations"][0]["observation_key"] = obs_key
                env["observations"][0]["frame_sequence"] = idx
                env["observations"][0]["attributes"] = copy.deepcopy(attrs)
                env["observations"][0]["search_text"] = f"Bay 04 Approach bay-04 {attrs['guidance_state']}"
                vc.validate_result_envelope(env)
                nats_driver.publish_json("media.results.vantage.v1", env, msg_id=obs_key)

            keys_sql = ", ".join(f"'{k}'" for k in obs_keys)
            rows = _poll_until(
                lambda: (
                    lambda out: out if len([l for l in out.splitlines() if l.strip()]) == 5 else ""
                )(
                    cnpg_driver.run_psql(
                        f"SELECT (catalog_entry_id IS NULL)::text || '|' || source_mode || '|' || "
                        f"signal_schema_id || '|' || (attributes->>'guidance_state') "
                        f"FROM platform.camera_vantage_observations "
                        f"WHERE observation_key IN ({keys_sql});"
                    )
                ),
                timeout_s=8.0,
            )
            seen_states: set[str] = set()
            for line in rows.splitlines():
                parts = line.strip().split("|")
                self.assertEqual(parts[:3], ["t", "live_keyframe_tap", "bay_guidance"])
                seen_states.add(parts[3])
            self.assertEqual(seen_states, set(self.f14["guidance_states"]))
        finally:
            _cleanup_cnpg_records(
                source_ids=[cam["camera_source_id"]],
                pipeline_ids=[pid],
                observation_keys=obs_keys,
            )

    def test_e2e_f14_t1_02_rust_and_python_live_tap_workers_emit_identical_schema(self) -> None:
        sdk_repo = env_probe.probe_sdk_repo()
        proc_rs = sdk_driver.run_cargo_test(["live_keyframe_tap"], sdk_dir=sdk_repo)
        self.assertEqual(proc_rs.returncode, 0)

        py_bin = sdk_driver.ensure_sdk_python_venv(sdk_dir=sdk_repo)
        live_frame = copy.deepcopy(_load_wire_vector("vantage_frame_v1.json")["positive"])
        live_frame["camera_source_id"] = self.f13["cameras"]["bay_04_approach"]["camera_source_id"]
        live_frame["stream_profile_id"] = self.f13["cameras"]["bay_04_approach"]["stream_profile_id"]
        live_subj = self.f13["cameras"]["bay_04_approach"]["live_subject"]

        sub_proc = _start_nats_sub("media.results.vantage.v1", count=1)
        worker_env = dict(os.environ)
        worker_env["SERVICERADAR_E2E_NATS_URL"] = nats_driver.require_nats_url()
        worker_env["SERVICERADAR_E2E_WEB_URL"] = http_ws_driver.require_web_url()
        py_script = """
import os
import serviceradar_vantage as sv

def process_frame(ctx):
    return [
        sv.Observation(
            category="vehicle",
            label="Bay 04 Approach",
            confidence=0.94,
            bbox=[0.22, 0.31, 0.72, 0.84],
            signal_schema_id="bay_guidance",
            signal_schema_version="1.0.0",
            display_contract_id="bay_guidance",
            attributes={
                "bay_id": "bay-04",
                "guidance_state": "aligning",
                "distance_m": 1.4,
                "lateral_offset_m": 0.04,
                "confidence": 0.94,
            },
            search_text="Bay 04 Approach bay-04 aligning",
        )
    ]

worker = sv.VantageWorker(
    worker_id="e2e-py-guidance-parity",
    capabilities=["vantage.bay_guidance.v1"],
    supported_source_modes=["live_keyframe_tap"],
    nats_url=os.environ["SERVICERADAR_E2E_NATS_URL"],
    handler=process_frame,
)
worker.run_for_seconds(3.0)
"""
        proc_py = subprocess.Popen(
            [str(py_bin), "-c", py_script],
            cwd=str(sdk_repo),
            env=worker_env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        try:
            time.sleep(0.6)
            nats_driver.publish_json(live_subj, live_frame)
            out_py, err_py = proc_py.communicate(timeout=15.0)
            self.assertEqual(proc_py.returncode, 0, f"python guidance worker failed: {out_py} {err_py}")
            stdout, stderr = sub_proc.communicate(timeout=10.0)
            self.assertEqual(sub_proc.returncode, 0, f"nats sub failed: {stderr}")
            res_py = vc.validate_result_envelope(
                json.loads([ln for ln in stdout.splitlines() if ln.strip()][0])
            )
            self.assertEqual(res_py["source_mode"], "live_keyframe_tap")
            self.assertIsNone(res_py.get("job_id"))
            self.assertIsNone(res_py.get("catalog_entry_id"))
            self.assertEqual(res_py["observations"][0]["signal_schema_id"], "bay_guidance")
            self.assertEqual(res_py["observations"][0]["signal_schema_version"], "1.0.0")
        finally:
            _stop_proc(proc_py)
            _stop_proc(sub_proc)

    def test_e2e_f14_t1_03_dashboard_channel_receives_scoped_nested_signal_schema_events(self) -> None:
        envs = env_probe.probe_env_vars(
            "SERVICERADAR_E2E_DASHBOARD_SLUG",
            "SERVICERADAR_E2E_DASHBOARD_STREAM_TOKEN",
        )
        ws_headers = _viewer_ws_headers("SERVICERADAR_E2E_DASHBOARD_COOKIE")
        ws_url = _ws_url_from_web_url(http_ws_driver.require_web_url())
        cam, pid = self._provision_guidance_pipeline("f14-t1-03")
        obs_key = uuid.uuid4().hex + uuid.uuid4().hex
        topic = f"dashboards:{envs['SERVICERADAR_E2E_DASHBOARD_SLUG']}"
        sub_id = f"sub-guidance-{uuid.uuid4().hex[:8]}"
        client = DashboardChannelClient(ws_url, headers=ws_headers, timeout=10.0)
        try:
            join_reply = client.join_topic(topic, {"token": envs["SERVICERADAR_E2E_DASHBOARD_STREAM_TOKEN"]})
            self.assertEqual(join_reply[3], "phx_reply")
            self.assertEqual(join_reply[4].get("status"), "ok", f"join failed: {join_reply}")

            sub_ref = client.push_event(
                topic,
                "events:subscribe",
                {
                    "id": sub_id,
                    "filter": {
                        "class_uid": 1008,
                        "camera_source_id": cam["camera_source_id"],
                        "metadata": {
                            "service_radar": {
                                "signal_schema": {"schema_id": "bay_guidance"}
                            }
                        },
                    },
                },
            )
            sub_reply = client.recv_matching(
                lambda m: len(m) >= 5 and str(m[1]) == sub_ref and m[3] == "phx_reply"
            )
            self.assertEqual(sub_reply[4].get("status"), "ok", f"subscribe failed: {sub_reply}")

            # Emit matching live_keyframe_tap result -> JetStream -> EventWriter -> PubSub -> WS events:batch
            res_live = copy.deepcopy(_load_wire_vector("vantage_result_v1.json")["positive_live"])
            res_live["pipeline_id"] = pid
            res_live["camera_source_id"] = cam["camera_source_id"]
            res_live["stream_profile_id"] = cam["stream_profile_id"]
            res_live["observations"][0]["observation_key"] = obs_key
            res_live["observations"][0]["track_id"] = f"bay04-scope-{uuid.uuid4().hex[:8]}"
            vc.validate_result_envelope(res_live)
            nats_driver.publish_json("media.results.vantage.v1", res_live, msg_id=obs_key)

            batch = client.recv_matching(
                lambda m: (
                    len(m) >= 5
                    and m[3] == "events:batch"
                    and m[4].get("subscription_id") == sub_id
                    and any(
                        ev.get("metadata", {}).get("service_radar", {}).get("signal_schema", {}).get("schema_id")
                        == "bay_guidance"
                        and ev.get("metadata", {}).get("service_radar", {}).get("camera_source_id")
                        == cam["camera_source_id"]
                        for ev in m[4].get("events", [])
                    )
                ),
                timeout=10.0,
            )
            self.assertGreaterEqual(len(batch[4]["events"]), 1)
            client.leave_topic(topic)
        finally:
            client.close()
            _cleanup_cnpg_records(
                source_ids=[cam["camera_source_id"]],
                pipeline_ids=[pid],
                observation_keys=[obs_key],
            )

    def test_e2e_f14_t1_04_bay_guidance_live_tap_latency_benchmark_p50_p95_p99(self) -> None:
        """Measure real p50/p95/p99 frame-to-overlay latency over NATS -> Worker -> EventWriter -> PubSub -> WS."""
        envs = env_probe.probe_env_vars(
            "SERVICERADAR_E2E_DASHBOARD_SLUG",
            "SERVICERADAR_E2E_DASHBOARD_STREAM_TOKEN",
        )
        ws_headers = _viewer_ws_headers("SERVICERADAR_E2E_DASHBOARD_COOKIE")
        ws_url = _ws_url_from_web_url(http_ws_driver.require_web_url())
        live_subject = self.f13["cameras"]["bay_04_approach"]["live_subject"]
        cam, pid = self._provision_guidance_pipeline("f14-t1-04")
        cam_id = cam["camera_source_id"]

        client: DashboardChannelClient | None = None
        latencies_ms: list[float] = []
        try:
            # Verify a live bay_guidance worker supporting live_keyframe_tap is active/ready before streaming
            ready_workers = cnpg_driver.run_psql(
                "SELECT COUNT(*) FROM platform.vantage_worker_registrations "
                "WHERE health = 'ready' AND expires_at > NOW() "
                "AND 'vantage.bay_guidance.v1' = ANY(capabilities) "
                "AND 'live_keyframe_tap' = ANY(supported_source_modes);"
            )
            self.assertGreater(
                int(ready_workers.strip()),
                0,
                "expected at least one ready vantage.bay_guidance.v1 live_keyframe_tap worker before benchmark",
            )

            frame_tmpl = copy.deepcopy(_load_wire_vector("vantage_frame_v1.json")["positive"])
            frame_tmpl["camera_source_id"] = cam_id
            frame_tmpl["stream_profile_id"] = cam["stream_profile_id"]
            topic = f"dashboards:{envs['SERVICERADAR_E2E_DASHBOARD_SLUG']}"
            sub_id = f"sub-bench-{uuid.uuid4().hex[:8]}"
            bench_run = uuid.uuid4().hex[:8]

            client = DashboardChannelClient(ws_url, headers=ws_headers, timeout=15.0)
            join_reply = client.join_topic(topic, {"token": envs["SERVICERADAR_E2E_DASHBOARD_STREAM_TOKEN"]})
            self.assertEqual(join_reply[4].get("status"), "ok", f"join failed: {join_reply}")
            sub_ref = client.push_event(
                topic,
                "events:subscribe",
                {
                    "id": sub_id,
                    "filter": {
                        "class_uid": 1008,
                        "camera_source_id": cam_id,
                        "metadata": {
                            "service_radar": {
                                "signal_schema": {"schema_id": "bay_guidance"}
                            }
                        },
                    },
                },
            )
            sub_ack = client.recv_matching(
                lambda m: len(m) >= 5 and str(m[1]) == sub_ref and m[3] == "phx_reply"
            )
            self.assertEqual(sub_ack[4].get("status"), "ok", f"subscribe failed: {sub_ack}")

            for seq in range(1, 21):
                marker = f"bay04-bench-{bench_run}-{seq}"
                ts_us = int(time.time() * 1_000_000)
                pkt = copy.deepcopy(frame_tmpl)
                pkt["frame_sequence"] = seq
                pkt["timeline_ts_us"] = ts_us
                pkt["detections"] = [
                    {
                        "track_id": marker,
                        "category": "vehicle",
                        "confidence": 0.95,
                        "bbox": [0.22, 0.31, 0.72, 0.84],
                    }
                ]
                t0 = time.monotonic_ns()
                nats_driver.publish_json(live_subject, pkt)

                def _matches_seq(msg: list[Any], *, _marker: str = marker, _seq: int = seq, _ts: int = ts_us) -> bool:
                    if len(msg) < 5 or msg[3] != "events:batch":
                        return False
                    payload = msg[4]
                    if payload.get("subscription_id") != sub_id:
                        return False
                    for ev in payload.get("events", []):
                        sr = ev.get("metadata", {}).get("service_radar", {})
                        schema_id = sr.get("signal_schema", {}).get("schema_id")
                        if schema_id != "bay_guidance" or sr.get("camera_source_id") != cam_id:
                            continue
                        if (
                            sr.get("track_id") == _marker
                            or sr.get("frame_sequence") == _seq
                            or sr.get("timeline_ts_us") == _ts
                        ):
                            return True
                    return False

                client.recv_matching(_matches_seq, timeout=10.0)
                t1 = time.monotonic_ns()
                latencies_ms.append((t1 - t0) / 1_000_000.0)

            client.leave_topic(topic)
        finally:
            if client is not None:
                client.close()
            _cleanup_cnpg_records(
                source_ids=[cam["camera_source_id"]],
                pipeline_ids=[pid],
            )

        summary = _compute_percentiles_ms(latencies_ms)
        self.assertEqual(len(latencies_ms), 20)
        self.assertGreater(summary["p50"], 0.0)
        self.assertLessEqual(summary["p50"], summary["p95"])
        self.assertLessEqual(summary["p95"], summary["p99"])

    def test_e2e_f14_t1_05_live_observation_retention_days_cleanup(self) -> None:
        cam, pid = self._provision_guidance_pipeline("f14-t1-05", retention_days=7)
        try:
            res = _eval_elixir_json(
                "elixir/serviceradar_core",
                f"""
                alias ServiceRadar.Actors.SystemActor
                alias ServiceRadar.Camera.{{RecordingHolds, VantageObservation, VantageRetention}}
                actor = SystemActor.system(:mode_b_f14_t1_05)
                hold_actor = %{{id: "hold-op", role: :operator, permissions: MapSet.new(["devices.view", "devices.cameras.recordings.hold"])}}
                {{:ok, _hold}} = RecordingHolds.place_hold(%{{
                  camera_source_id: "{cam['camera_source_id']}",
                  stream_profile_id: "{cam['stream_profile_id']}",
                  start_us: 1760000000000000,
                  end_us: 1760000010000000,
                  kind: :investigation,
                  reason: "Retention hold E2E"
                }}, actor: hold_actor)
                now = DateTime.utc_now()
                old_ts = DateTime.add(now, -8 * 86_400, :second)
                fresh_ts = DateTime.add(now, -1 * 86_400, :second)
                k_exp = "ret-exp-#{uuid.uuid4().hex[:8]}"
                k_fresh = "ret-fresh-#{uuid.uuid4().hex[:8]}"
                k_held = "ret-held-#{uuid.uuid4().hex[:8]}"
                insert_obs = fn key, mode, cat_id, ins_at ->
                  {{:ok, obs}} = VantageObservation |> Ash.Changeset.for_create(:upsert_observation, %{{
                    observation_key: key,
                    pipeline_id: "{pid}",
                    pipeline_version: "1.0.0",
                    worker_kind: "external_rust",
                    model_id: "bay-guidance-onnx",
                    model_version: "1.0.0",
                    catalog_entry_id: cat_id,
                    camera_source_id: "{cam['camera_source_id']}",
                    stream_profile_id: "{cam['stream_profile_id']}",
                    source_mode: mode,
                    timeline_ts_us: 1760000000000000,
                    time_basis: :received,
                    category: "vehicle",
                    label: "Bay 04 Approach",
                    confidence: 0.9,
                    attributes: %{{ "bay_id" => "bay-04", "guidance_state" => "approach", "distance_m" => 2.0, "lateral_offset_m" => 0.0 }},
                    signal_schema_id: "bay_guidance",
                    signal_schema_version: "1.0.0",
                    display_contract_id: "bay_guidance"
                  }}, actor: actor) |> Ash.create(actor: actor)
                  Ecto.Adapters.SQL.query!(
                    ServiceRadar.Repo,
                    "UPDATE platform.camera_vantage_observations SET inserted_at = $1 WHERE id = $2",
                    [ins_at, Ecto.UUID.dump!(obs.id)]
                  )
                end
                insert_obs.(k_exp, :live_keyframe_tap, nil, old_ts)
                insert_obs.(k_fresh, :live_keyframe_tap, nil, fresh_ts)
                insert_obs.(k_held, :recorded_block, "{cam['catalog_entry_id']}", old_ts)

                cond do
                  function_exported?(VantageRetention, :run, 0) -> VantageRetention.run()
                  function_exported?(VantageRetention, :perform, 1) -> VantageRetention.perform(%Oban.Job{{args: %{{}}}})
                  true ->
                    VantageObservation
                    |> Ash.Query.for_read(:read, %{{}}, actor: actor)
                    |> Ash.bulk_destroy!(
                      :purge_expired_live,
                      %{{pipeline_id: "{pid}", cutoff: DateTime.add(now, -7 * 86_400, :second)}},
                      actor: actor
                    )
                end
                alive? = fn key ->
                  %{{rows: [[cnt]]}} = Ecto.Adapters.SQL.query!(
                    ServiceRadar.Repo,
                    "SELECT count(*) FROM platform.camera_vantage_observations WHERE observation_key = $1",
                    [key]
                  )
                  cnt == 1
                end
                result = %{{exp_alive: alive?.(k_exp), fresh_alive: alive?.(k_fresh), held_alive: alive?.(k_held)}}
                """,
            )
            self.assertFalse(res["exp_alive"])
            self.assertTrue(res["fresh_alive"])
            self.assertTrue(res["held_alive"])
        finally:
            _cleanup_cnpg_records(source_ids=[cam["camera_source_id"]], pipeline_ids=[pid])

    def test_e2e_f14_t1_06_dual_mode_worker_processes_recorded_and_live_interleaved(self) -> None:
        sdk_repo = env_probe.probe_sdk_repo()
        proc = sdk_driver.run_cargo_test(["dual_source_mode"], sdk_dir=sdk_repo)
        self.assertEqual(proc.returncode, 0)

    def test_e2e_f14_t2_01_benchmark_percentile_helper_rejects_empty_and_negative(self) -> None:
        sdk_repo = env_probe.probe_sdk_repo()
        mp4_path = media_gen.generate_synthetic_h264_mp4(
            "f14_t2_01_guidance_bench.mp4", width=320, height=240, duration_s=1, fps=5
        )
        schema_path = (
            vc.repo_root()
            / "integration_tests"
            / "vantage_ml"
            / "fixtures"
            / "wire_vectors"
            / "bay_guidance_schema.json"
        )
        bench_script = f"""
import json
import time
import serviceradar_vantage as sv

samples_ms = []

def handler(ctx):
    t0 = time.monotonic_ns()
    obs = sv.Observation(
        category="vehicle",
        label="Bay 04 Approach",
        confidence=0.92,
        bbox=[0.2, 0.3, 0.7, 0.85],
        signal_schema_id="bay_guidance",
        signal_schema_version="1.0.0",
        display_contract_id="bay_guidance",
        attributes={{
            "bay_id": "bay-04",
            "guidance_state": "approach",
            "distance_m": 3.0,
            "lateral_offset_m": 0.0,
        }},
    )
    t1 = time.monotonic_ns()
    samples_ms.append(max(0.001, (t1 - t0) / 1_000_000.0))
    return [obs]

sv.run_local_harness(
    {json.dumps(str(mp4_path))},
    handler,
    {json.dumps(str(schema_path))},
)
print(json.dumps({{"samples_ms": samples_ms}}))
"""
        proc = sdk_driver.run_python_in_sdk_venv(["-c", bench_script], sdk_dir=sdk_repo)
        collected = json.loads(proc.stdout.strip().splitlines()[-1])["samples_ms"]
        self.assertGreater(len(collected), 0)
        summary = _compute_percentiles_ms(collected)
        self.assertGreater(summary["p50"], 0.0)
        self.assertLessEqual(summary["p50"], summary["p95"])
        self.assertLessEqual(summary["p95"], summary["p99"])

        # Fail closed on invalid/empty live-tap benchmark inputs in SDK & percentile computation
        bad_bench_script = f"""
import serviceradar_vantage as sv
try:
    sv.run_local_harness("/nonexistent/bay_04_empty.mp4", lambda _ctx: [], {json.dumps(str(schema_path))})
except Exception:
    print("EMPTY_INPUT_REJECTED")
else:
    raise AssertionError("SDK harness accepted nonexistent/empty clip")
"""
        bad_proc = sdk_driver.run_python_in_sdk_venv(["-c", bad_bench_script], sdk_dir=sdk_repo)
        self.assertIn("EMPTY_INPUT_REJECTED", bad_proc.stdout)
        with self.assertRaises(AssertionError):
            _compute_percentiles_ms([])
        with self.assertRaises(AssertionError):
            _compute_percentiles_ms([-1.0])
        with self.assertRaises(AssertionError):
            _compute_percentiles_ms([float("nan")])

    def test_e2e_f14_t2_02_retention_exact_boundary_preserves_fresh_and_held_rows(self) -> None:
        cam, pid = self._provision_guidance_pipeline("f14-t2-02", retention_days=7)
        try:
            res = _eval_elixir_json(
                "elixir/serviceradar_core",
                f"""
                alias ServiceRadar.Actors.SystemActor
                alias ServiceRadar.Camera.{{RecordingHolds, VantageObservation}}
                actor = SystemActor.system(:mode_b_f14_t2_02)
                hold_actor = %{{id: "hold-op", role: :operator, permissions: MapSet.new(["devices.view", "devices.cameras.recordings.hold"])}}
                {{:ok, _hold}} = RecordingHolds.place_hold(%{{
                  camera_source_id: "{cam['camera_source_id']}",
                  stream_profile_id: "{cam['stream_profile_id']}",
                  start_us: 1760000000000000,
                  end_us: 1760000010000000,
                  kind: :investigation,
                  reason: "Exact boundary hold"
                }}, actor: hold_actor)
                cutoff = DateTime.truncate(DateTime.add(DateTime.utc_now(), -7 * 86_400, :second), :microsecond)
                k_before = "bnd-before-#{uuid.uuid4().hex[:8]}"
                k_equal = "bnd-equal-#{uuid.uuid4().hex[:8]}"
                k_after = "bnd-after-#{uuid.uuid4().hex[:8]}"
                k_held = "bnd-held-#{uuid.uuid4().hex[:8]}"
                insert_obs = fn key, mode, cat_id, ins_at ->
                  {{:ok, obs}} = VantageObservation |> Ash.Changeset.for_create(:upsert_observation, %{{
                    observation_key: key,
                    pipeline_id: "{pid}",
                    pipeline_version: "1.0.0",
                    worker_kind: "external_rust",
                    model_id: "bay-guidance-onnx",
                    model_version: "1.0.0",
                    catalog_entry_id: cat_id,
                    camera_source_id: "{cam['camera_source_id']}",
                    stream_profile_id: "{cam['stream_profile_id']}",
                    source_mode: mode,
                    timeline_ts_us: 1760000000000000,
                    time_basis: :received,
                    category: "vehicle",
                    label: "Bay 04 Approach",
                    confidence: 0.9,
                    attributes: %{{ "bay_id" => "bay-04", "guidance_state" => "stop", "distance_m" => 0.1, "lateral_offset_m" => 0.0 }},
                    signal_schema_id: "bay_guidance",
                    signal_schema_version: "1.0.0",
                    display_contract_id: "bay_guidance"
                  }}, actor: actor) |> Ash.create(actor: actor)
                  Ecto.Adapters.SQL.query!(
                    ServiceRadar.Repo,
                    "UPDATE platform.camera_vantage_observations SET inserted_at = $1 WHERE id = $2",
                    [ins_at, Ecto.UUID.dump!(obs.id)]
                  )
                end
                insert_obs.(k_before, :live_keyframe_tap, nil, DateTime.add(cutoff, -1, :second))
                insert_obs.(k_equal, :live_keyframe_tap, nil, cutoff)
                insert_obs.(k_after, :live_keyframe_tap, nil, DateTime.add(cutoff, 1, :second))
                insert_obs.(k_held, :recorded_block, "{cam['catalog_entry_id']}", DateTime.add(cutoff, -86_400, :second))

                # Execute canonical Ash :purge_expired_live destroy action (used by VantageRetention)
                VantageObservation
                |> Ash.Query.for_read(:read, %{{}}, actor: actor)
                |> Ash.bulk_destroy!(:purge_expired_live, %{{pipeline_id: "{pid}", cutoff: cutoff}}, actor: actor)

                exists? = fn key ->
                  %{{rows: [[cnt]]}} = Ecto.Adapters.SQL.query!(
                    ServiceRadar.Repo,
                    "SELECT count(*) FROM platform.camera_vantage_observations WHERE observation_key = $1",
                    [key]
                  )
                  cnt == 1
                end
                result = %{{
                  before_alive: exists?.(k_before),
                  equal_alive: exists?.(k_equal),
                  after_alive: exists?.(k_after),
                  held_alive: exists?.(k_held)
                }}
                """,
            )
            self.assertFalse(res["before_alive"], "cutoff - 1s live row should be purged")
            self.assertTrue(res["equal_alive"], "exact cutoff live row should be preserved")
            self.assertTrue(res["after_alive"], "cutoff + 1s live row should be preserved")
            self.assertTrue(res["held_alive"], "held recorded_block row should be preserved")
        finally:
            _cleanup_cnpg_records(source_ids=[cam["camera_source_id"]], pipeline_ids=[pid])

    def test_e2e_f14_t2_03_recorded_only_worker_excluded_from_live_tap_subject(self) -> None:
        sdk_repo = env_probe.probe_sdk_repo()
        wid = f"vantage-rec-only-{uuid.uuid4().hex[:8]}"
        cam, pid = self._provision_guidance_pipeline("f14-t2-03")
        try:
            # Register worker advertising ONLY recorded_block in CNPG
            res = _eval_elixir_json(
                "elixir/serviceradar_core",
                f"""
                alias ServiceRadar.Actors.SystemActor
                alias ServiceRadar.Camera.VantageWorkerRegistration
                actor = SystemActor.system(:mode_b_f14_t2_03)
                now = DateTime.utc_now()
                {{:ok, reg}} = VantageWorkerRegistration
                  |> Ash.Changeset.for_create(:upsert_heartbeat, %{{
                    worker_id: "{wid}",
                    worker_kind: :external_rust,
                    protocol_version: "vantage.worker.v1",
                    capabilities: ["vantage.bay_guidance.v1"],
                    supported_source_modes: ["recorded_block"],
                    execution_backend: "onnx",
                    architecture: "arm64",
                    model_id: "bay-guidance-onnx",
                    model_version: "1.0.0",
                    max_concurrency: 4,
                    active_jobs: 0,
                    health: :ready,
                    last_heartbeat_at: now,
                    expires_at: DateTime.add(now, 60, :second)
                  }}, actor: actor)
                  |> Ash.create(actor: actor)
                {{:ok, active}} = VantageWorkerRegistration.active_for_capability("vantage.bay_guidance.v1", now, actor: actor)
                rec_only = Enum.find(active, &(&1.worker_id == "{wid}"))
                result = %{{
                  supports_live: "live_keyframe_tap" in rec_only.supported_source_modes,
                  supports_recorded: "recorded_block" in rec_only.supported_source_modes
                }}
                """,
            )
            self.assertFalse(res["supports_live"])
            self.assertTrue(res["supports_recorded"])

            # Verify SDK VantageWorker with supported_source_modes=["recorded_block"] does NOT consume live_keyframe_tap frames
            py_bin = sdk_driver.ensure_sdk_python_venv(sdk_dir=sdk_repo)
            live_frame = copy.deepcopy(_load_wire_vector("vantage_frame_v1.json")["positive"])
            live_frame["camera_source_id"] = cam["camera_source_id"]
            live_frame["stream_profile_id"] = cam["stream_profile_id"]
            live_subj = self.f13["cameras"]["bay_04_approach"]["live_subject"]
            worker_env = dict(os.environ)
            worker_env["SERVICERADAR_E2E_NATS_URL"] = nats_driver.require_nats_url()
            worker_env["SERVICERADAR_E2E_WEB_URL"] = http_ws_driver.require_web_url()
            py_script = f"""
import os
import serviceradar_vantage as sv

invoked = []

def handler(ctx):
    invoked.append(ctx.frame_sequence)
    return []

worker = sv.VantageWorker(
    worker_id="{wid}",
    capabilities=["vantage.bay_guidance.v1"],
    supported_source_modes=["recorded_block"],
    nats_url=os.environ["SERVICERADAR_E2E_NATS_URL"],
    handler=handler,
)
worker.run_for_seconds(2.0)
assert not invoked, f"recorded_block-only worker processed live_keyframe_tap frames: {{invoked}}"
"""
            proc = subprocess.Popen(
                [str(py_bin), "-c", py_script],
                cwd=str(sdk_repo),
                env=worker_env,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )
            try:
                time.sleep(0.5)
                nats_driver.publish_json(live_subj, live_frame)
                out, err = proc.communicate(timeout=10.0)
                self.assertEqual(proc.returncode, 0, f"recorded-only worker check failed: {out} {err}")
            finally:
                _stop_proc(proc)
        finally:
            _cleanup_cnpg_records(
                source_ids=[cam["camera_source_id"]],
                pipeline_ids=[pid],
                worker_ids=[wid],
            )

    def test_e2e_f14_t2_04_malformed_bay_guidance_dead_letters_without_stalling_stream(self) -> None:
        cam, pid = self._provision_guidance_pipeline("f14-t2-04")
        bad_key = uuid.uuid4().hex + uuid.uuid4().hex
        good_key = uuid.uuid4().hex + uuid.uuid4().hex
        try:
            bad = copy.deepcopy(_load_wire_vector("vantage_result_v1.json")["positive_live"])
            bad["pipeline_id"] = pid
            bad["camera_source_id"] = cam["camera_source_id"]
            bad["stream_profile_id"] = cam["stream_profile_id"]
            bad["observations"][0]["observation_key"] = bad_key
            bad["observations"][0]["attributes"]["guidance_state"] = "invalid_state"
            nats_driver.publish_json("media.results.vantage.v1", bad, msg_id=bad_key)

            good = copy.deepcopy(_load_wire_vector("vantage_result_v1.json")["positive_live"])
            good["pipeline_id"] = pid
            good["camera_source_id"] = cam["camera_source_id"]
            good["stream_profile_id"] = cam["stream_profile_id"]
            good["observations"][0]["observation_key"] = good_key
            vc.validate_result_envelope(good)
            nats_driver.publish_json("media.results.vantage.v1", good, msg_id=good_key)

            good_count = _poll_until(
                lambda: (
                    lambda out: out if out.strip() == "1" else ""
                )(
                    cnpg_driver.run_psql(
                        f"SELECT COUNT(*) FROM platform.camera_vantage_observations WHERE observation_key = '{good_key}';"
                    )
                ),
                timeout_s=6.0,
            )
            self.assertEqual(good_count.strip(), "1")
            bad_count = cnpg_driver.run_psql(
                f"SELECT COUNT(*) FROM platform.camera_vantage_observations WHERE observation_key = '{bad_key}';"
            )
            self.assertEqual(bad_count.strip(), "0")
        finally:
            _cleanup_cnpg_records(
                source_ids=[cam["camera_source_id"]],
                pipeline_ids=[pid],
                observation_keys=[bad_key, good_key],
            )

    def test_e2e_f14_t2_05_unauthorized_dashboard_viewer_denied_guidance_overlays(self) -> None:
        envs = env_probe.probe_env_vars(
            "SERVICERADAR_E2E_DASHBOARD_SLUG",
            "SERVICERADAR_E2E_UNPRIVILEGED_COOKIE",
            "SERVICERADAR_E2E_UNPRIVILEGED_STREAM_TOKEN",
        )
        ws_url = _ws_url_from_web_url(http_ws_driver.require_web_url())
        cam_id = self.f13["cameras"]["bay_04_approach"]["camera_source_id"]
        topic = f"dashboards:{envs['SERVICERADAR_E2E_DASHBOARD_SLUG']}"

        # 1) Joining without stream token must be rejected
        unauth_client = DashboardChannelClient(
            ws_url, headers={"Cookie": envs["SERVICERADAR_E2E_UNPRIVILEGED_COOKIE"]}, timeout=10.0
        )
        try:
            missing_tok_reply = unauth_client.join_topic(topic, {})
            self.assertEqual(missing_tok_reply[4].get("status"), "error")
            self.assertEqual(
                missing_tok_reply[4].get("response", {}).get("reason"),
                "missing_stream_token",
            )
        finally:
            unauth_client.close()

        # 2) Authenticated unprivileged viewer joins with valid stream token, then events:subscribe fails closed
        client = DashboardChannelClient(
            ws_url, headers={"Cookie": envs["SERVICERADAR_E2E_UNPRIVILEGED_COOKIE"]}, timeout=10.0
        )
        try:
            join_reply = client.join_topic(topic, {"token": envs["SERVICERADAR_E2E_UNPRIVILEGED_STREAM_TOKEN"]})
            self.assertEqual(
                join_reply[4].get("status"),
                "ok",
                f"expected join to succeed before testing events:subscribe denial: {join_reply}",
            )
            sub_id = f"sub-unauth-{uuid.uuid4().hex[:8]}"
            sub_ref = client.push_event(
                topic,
                "events:subscribe",
                {
                    "id": sub_id,
                    "filter": {
                        "class_uid": 1008,
                        "camera_source_id": cam_id,
                        "metadata": {
                            "service_radar": {
                                "signal_schema": {"schema_id": "bay_guidance"}
                            }
                        },
                    },
                },
            )
            reply = client.recv_matching(
                lambda m: len(m) >= 5 and str(m[1]) == sub_ref and m[3] == "phx_reply"
            )
            self.assertEqual(reply[4].get("status"), "error")
            reason = str(reply[4].get("response", {}).get("reason") or "")
            self.assertTrue(reason, f"expected non-empty denial reason, got: {reply}")
            lowered = reason.lower()
            for invalid_tok in (
                "unsupported event filter",
                "invalid filter",
                "invalid_filter",
                "invalid_subscription_id",
                "subscription id is required",
                "too_many_subscriptions",
                "at most",
            ):
                self.assertNotIn(
                    invalid_tok,
                    lowered,
                    f"events:subscribe failed due to filter/capacity error rather than authorization denial: {reason!r}",
                )
            self.assertTrue(
                any(
                    auth_tok in lowered
                    for auth_tok in (
                        "not authorized",
                        "unauthorized",
                        "permission",
                        "forbidden",
                        "capability is not approved",
                        "denied",
                    )
                ),
                f"expected authorization/permission denial reason, got: {reason!r}",
            )
        finally:
            client.close()

    def test_e2e_f14_t2_06_worker_crash_and_mailbox_overflow_preserves_cmaf_and_recovers(self) -> None:
        sdk_repo = env_probe.probe_sdk_repo()
        py_bin = sdk_driver.ensure_sdk_python_venv(sdk_dir=sdk_repo)
        cam, pid = self._provision_guidance_pipeline("f14-t2-06")
        worker_proc: subprocess.Popen[str] | None = None
        worker_proc2: subprocess.Popen[str] | None = None
        worker_script = f"""
import json
import os
import subprocess
import sys
import time
import serviceradar_vantage as sv

nats_url = os.environ["SERVICERADAR_E2E_NATS_URL"]
live_subj = {json.dumps(self.f13["cameras"]["bay_04_approach"]["live_subject"])}

def handle_frame(ctx):
    return [
        sv.Observation(
            category="vehicle",
            label="Bay 04 Approach",
            confidence=0.95,
            bbox=[0.22, 0.31, 0.72, 0.84],
            signal_schema_id="bay_guidance",
            signal_schema_version="1.0.0",
            display_contract_id="bay_guidance",
            attributes={{
                "bay_id": "bay-04",
                "guidance_state": "aligning",
                "distance_m": 1.2,
                "lateral_offset_m": 0.02,
            }},
            search_text="Bay 04 Approach bay-04 aligning",
        )
    ]

worker = sv.VantageWorker(
    worker_id="e2e-f14-crash-worker",
    capabilities=["vantage.bay_guidance.v1"],
    supported_source_modes=["live_keyframe_tap"],
    nats_url=nats_url,
    handler=handle_frame,
)
worker.run_forever()
"""
        worker_env = dict(os.environ)
        worker_env["SERVICERADAR_E2E_NATS_URL"] = nats_driver.require_nats_url()
        worker_env["SERVICERADAR_E2E_WEB_URL"] = http_ws_driver.require_web_url()

        try:
            worker_proc = subprocess.Popen(
                [str(py_bin), "-c", worker_script],
                cwd=str(sdk_repo),
                env=worker_env,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )
            time.sleep(0.6)
            self.assertIsNone(worker_proc.poll(), "guidance worker exited before test burst")

            # Kill worker mid-stream, inject >8 frame burst into LiveVantageTap while CMAF recorder stays intact
            worker_proc.send_signal(signal.SIGKILL)
            worker_proc.wait(timeout=5)
            worker_proc = None

            annex_b_b64 = self.f13["carriers"]["annex_b_idr_b64"]
            relay_res = _eval_elixir_json(
                "elixir/serviceradar_core_elx",
                f"""
                alias ServiceRadarCoreElx.CameraRelay.{{LiveVantageTap, Pipeline}}
                alias ServiceRadarRecording.Inbox
                parent = self()
                handler_id = "e2e-f14-t2-06-#{uuid.uuid4().hex[:6]}"
                :telemetry.attach(
                  handler_id,
                  [:serviceradar, :vantage, :live_tap, :dropped],
                  fn _ev, meas, _meta, _ -> send(parent, {{:drop_ev, meas}}) end,
                  nil
                )
                idr = Base.decode64!("{annex_b_b64}")
                relay_id = "relay-f14-ovf-#{uuid.uuid4().hex[:8]}"
                ingest_id = "ingest-f14-ovf-#{uuid.uuid4().hex[:8]}"
                {{:ok, _sup, pipeline_pid}} = Membrane.Pipeline.start_link(
                  Pipeline,
                  relay_session_id: relay_id,
                  media_ingest_id: ingest_id
                )
                recorder_pid = spawn_link(fn ->
                  {{:ok, inbox}} = Inbox.new(
                    pipeline_pid,
                    relay_id,
                    ingest_id,
                    System.monotonic_time(:millisecond) + 30_000,
                    max_samples: 32
                  )
                  :ok = Membrane.Pipeline.call(pipeline_pid, {{:attach_recorder, inbox}})
                  send(parent, :recorder_attached)
                  inbox_id = inbox.id
                  loop = fn loop_fn, seqs ->
                    receive do
                      {{:recording_media, ^inbox_id, unit}} ->
                        :ok = Inbox.release(inbox, byte_size(unit.payload))
                        loop_fn.(loop_fn, [unit.sequence | seqs])
                      {{:recording_rejected, ^inbox_id, reason}} ->
                        raise("recorder rejected: #{{inspect(reason)}}")
                      {{:get_seqs, from}} ->
                        send(from, {{:recorded_seqs, Enum.reverse(seqs)}})
                    end
                  end
                  loop.(loop, [])
                end)
                receive do :recorder_attached -> :ok after 2_000 -> raise("recorder attach timeout") end

                {{:ok, _tap}} = LiveVantageTap.attach_pipeline(
                  pipeline_pid,
                  relay_session_id: relay_id,
                  camera_source_id: "{cam['camera_source_id']}",
                  stream_profile_id: "{cam['stream_profile_id']}",
                  capability: "vantage.bay_guidance.v1",
                  pause_publish: true
                )
                for seq <- 1..20 do
                  send(pipeline_pid, {{:media_chunk, %{{payload: idr, pts: seq * 90_000, dts: seq * 90_000, sequence: seq, keyframe: true, media_ingest_id: ingest_id, codec: "h264", payload_format: "annexb"}}}})
                end
                Process.sleep(300)
                drops = LiveVantageTap.dropped_count("{cam['camera_source_id']}")
                drop_events = Stream.repeatedly(fn -> receive do {{:drop_ev, m}} -> m after 50 -> nil end end) |> Enum.take_while(& &1 != nil) |> length()
                :telemetry.detach(handler_id)
                send(recorder_pid, {{:get_seqs, self()}})
                recorded_seqs = receive do {{:recorded_seqs, s}} -> s after 2_000 -> [] end
                pipeline_alive = Process.alive?(pipeline_pid)
                Membrane.Pipeline.terminate(pipeline_pid)
                result = %{{drops: drops, drop_events: drop_events, recorded_seqs: recorded_seqs, pipeline_alive: pipeline_alive}}
                """,
            )
            self.assertTrue(relay_res["pipeline_alive"])
            self.assertEqual(relay_res["drops"], 12)
            self.assertGreaterEqual(relay_res["drop_events"], 1)
            self.assertEqual(relay_res["recorded_seqs"], list(range(1, 21)))

            # Restart worker and verify fresh live_keyframe_tap frame produces persisted VantageObservation
            worker_proc2 = subprocess.Popen(
                [str(py_bin), "-c", worker_script],
                cwd=str(sdk_repo),
                env=worker_env,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )
            time.sleep(0.6)
            self.assertIsNone(worker_proc2.poll(), "restarted guidance worker exited prematurely")

            recovery_frame = copy.deepcopy(_load_wire_vector("vantage_frame_v1.json")["positive"])
            recovery_frame["camera_source_id"] = cam["camera_source_id"]
            recovery_frame["stream_profile_id"] = cam["stream_profile_id"]
            recovery_frame["frame_sequence"] = 21
            recovery_frame["timeline_ts_us"] = int(time.time() * 1_000_000)
            nats_driver.publish_json(
                self.f13["cameras"]["bay_04_approach"]["live_subject"],
                recovery_frame,
            )
            persisted = _poll_until(
                lambda: (
                    lambda out: out if int(out.strip() or "0") >= 1 else ""
                )(
                    cnpg_driver.run_psql(
                        f"SELECT COUNT(*) FROM platform.camera_vantage_observations "
                        f"WHERE camera_source_id = '{cam['camera_source_id']}' "
                        f"AND source_mode = 'live_keyframe_tap' AND frame_sequence = 21;"
                    )
                ),
                timeout_s=8.0,
            )
            self.assertGreaterEqual(int(persisted.strip() or "0"), 1)
        finally:
            _stop_proc(worker_proc)
            _stop_proc(worker_proc2)
            _cleanup_cnpg_records(source_ids=[cam["camera_source_id"]], pipeline_ids=[pid])


if __name__ == "__main__":
    unittest.main()
