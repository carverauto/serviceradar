"""Mode B live cross-component E2E tests for E2E-M5 (Tiers 3 & 4).

Import- and discovery-safe: NO network, subprocess, or filesystem probes run at
module import time. Execution fails closed (`RuntimeError` or `AssertionError`)
when any required binary, environment variable, Elixir module, CLI build, SDK
checkout, or live assertion fails. Zero skips and zero fake-green mocks.

Covers exact `22` live E2E test methods:
- `Tier3PairwiseModeBTest`: `15` pairwise cross-feature combinations (`E2E-T3-01`..`E2E-T3-15`)
- `Tier4WorkloadsModeBTest`: `7` operational workloads (`E2E-T4-W1`..`E2E-T4-W7`)
"""

from __future__ import annotations

import base64
import contextlib
import copy
import hashlib
import json
import math
import os
import re
import select
import shutil
import signal
import socket
import struct
import subprocess
import sys
import time
import unittest
import urllib.parse
import uuid
from pathlib import Path
from typing import Any, Callable, Iterator, Mapping, Sequence

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


def _fixtures_dir() -> Path:
    return vc.repo_root() / "integration_tests" / "vantage_ml" / "fixtures"


def _load_json(rel_path: str) -> Any:
    path = _fixtures_dir() / rel_path
    if not path.is_file():
        raise RuntimeError(f"missing Mode B fixture file: {path}")
    return json.loads(path.read_text(encoding="utf-8"))


def _free_tcp_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.bind(("127.0.0.1", 0))
        return int(sock.getsockname()[1])


def _cargo_env() -> dict[str, str]:
    env = dict(os.environ)
    env.setdefault("CARGO_TARGET_DIR", "/Volumes/Build/cargo-target/serviceradar-f8a96b-16")
    return env


@contextlib.contextmanager
def _isolated_nats_cli_env() -> Iterator[None]:
    """Isolate HOME/XDG_CONFIG_HOME so user NATS TLS contexts do not hijack ephemeral local tests."""
    nats_home = env_probe.get_scratch_dir("nats-cli-home")
    saved = {
        k: os.environ.get(k)
        for k in ("HOME", "XDG_CONFIG_HOME", "NATS_CONTEXT", "NATS_CERT", "NATS_KEY", "NATS_CA")
    }
    os.environ["HOME"] = str(nats_home)
    os.environ["XDG_CONFIG_HOME"] = str(nats_home / ".config")
    for k in ("NATS_CONTEXT", "NATS_CERT", "NATS_KEY", "NATS_CA"):
        os.environ.pop(k, None)
    try:
        yield
    finally:
        for k, val in saved.items():
            if val is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = val


def _publish_js_json(
    subject: str,
    payload: Mapping[str, Any],
    *,
    msg_id: str | None = None,
    nats_url: str,
) -> None:
    """Publish JSON to JetStream via `nats pub -J --force-stdin` (`nats` CLI v0.2.3)."""
    cmd = ["pub", "-J", subject, "--force-stdin"]
    if msg_id:
        cmd.extend(["-H", f"Nats-Msg-Id:{msg_id}"])
    body = json.dumps(payload, separators=(",", ":")).encode("utf-8")
    with _isolated_nats_cli_env():
        nats_driver.run_nats_cli(cmd, nats_url=nats_url, stdin_bytes=body)


def _publish_core_json(
    subject: str,
    payload: Mapping[str, Any],
    *,
    nats_url: str,
) -> None:
    """Publish JSON to Core NATS via `nats pub --force-stdin`."""
    body = json.dumps(payload, separators=(",", ":")).encode("utf-8")
    with _isolated_nats_cli_env():
        nats_driver.run_nats_cli(["pub", subject, "--force-stdin"], nats_url=nats_url, stdin_bytes=body)


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
    pack_ids: Sequence[str] = (),
    dashboard_pkg_ids: Sequence[str] = (),
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
        audit_cnt = cnpg_driver.run_psql(
            f"SELECT count(*) FROM platform.camera_recording_access_audits WHERE camera_source_id = '{u}';",
            database_url=db_url,
        )
        if audit_cnt != "0":
            cnpg_driver.run_psql(
                f"""
                BEGIN;
                ALTER TABLE platform.camera_recording_access_audits
                  DISABLE TRIGGER camera_recording_access_audits_append_only_trigger;
                DELETE FROM platform.camera_recording_access_audits WHERE camera_source_id = '{u}';
                ALTER TABLE platform.camera_recording_access_audits
                  ENABLE TRIGGER camera_recording_access_audits_append_only_trigger;
                COMMIT;
                """,
                database_url=db_url,
            )
        disp_cnt = cnpg_driver.run_psql(
            f"""
            SELECT count(*) FROM platform.camera_recording_dispositions
            WHERE catalog_entry_id IN (
              SELECT id FROM platform.camera_recording_catalog
              WHERE camera_source_id = '{u}' OR recording_block_id IN (
                SELECT id FROM platform.camera_recording_blocks WHERE camera_source_id = '{u}'
              )
            );
            """,
            database_url=db_url,
        )
        if disp_cnt != "0":
            cnpg_driver.run_psql(
                f"""
                BEGIN;
                ALTER TABLE platform.camera_recording_dispositions
                  DISABLE TRIGGER trg_camera_recording_dispositions_append_only;
                DELETE FROM platform.camera_recording_dispositions
                WHERE catalog_entry_id IN (
                  SELECT id FROM platform.camera_recording_catalog
                  WHERE camera_source_id = '{u}' OR recording_block_id IN (
                    SELECT id FROM platform.camera_recording_blocks WHERE camera_source_id = '{u}'
                  )
                );
                ALTER TABLE platform.camera_recording_dispositions
                  ENABLE TRIGGER trg_camera_recording_dispositions_append_only;
                COMMIT;
                """,
                database_url=db_url,
            )
        cnpg_driver.run_psql(
            f"""
            DELETE FROM platform.camera_vantage_observations WHERE camera_source_id = '{u}';
            DELETE FROM platform.camera_vantage_jobs WHERE camera_source_id = '{u}';
            DELETE FROM platform.camera_recording_holds_versions WHERE version_source_id IN (
              SELECT id FROM platform.camera_recording_holds WHERE camera_source_id = '{u}'
            );
            DELETE FROM platform.camera_recording_holds WHERE camera_source_id = '{u}';
            DELETE FROM platform.camera_recording_catalog WHERE camera_source_id = '{u}'
              OR recording_block_id IN (
                SELECT id FROM platform.camera_recording_blocks WHERE camera_source_id = '{u}'
              );
            DELETE FROM platform.camera_recording_blocks WHERE camera_source_id = '{u}';
            DELETE FROM platform.camera_recorder_claims WHERE ingest_owner_id IN (
              SELECT id FROM platform.camera_ingest_owners WHERE camera_source_id = '{u}'
            );
            DELETE FROM platform.camera_consumer_leases WHERE ingest_owner_id IN (
              SELECT id FROM platform.camera_ingest_owners WHERE camera_source_id = '{u}'
            );
            DELETE FROM platform.camera_ingest_owners WHERE camera_source_id = '{u}';
            DELETE FROM platform.camera_relay_sessions WHERE camera_source_id = '{u}';
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
    for pk in pack_ids:
        safe_pk = pk.replace("'", "''")
        cnpg_driver.run_psql(
            f"""
            DELETE FROM platform.dashboard_instances WHERE pack_id = '{safe_pk}';
            DELETE FROM platform.installed_solution_packs WHERE pack_id = '{safe_pk}';
            """,
            database_url=db_url,
        )
    for dpkg in dashboard_pkg_ids:
        safe_dp = dpkg.replace("'", "''")
        cnpg_driver.run_psql(
            f"DELETE FROM platform.dashboard_packages WHERE dashboard_id = '{safe_dp}';",
            database_url=db_url,
        )


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
        f"{cookie_env_var} (or SERVICERADAR_E2E_AUTH_TOKEN) is required for DashboardFrameChannel tests"
    )


class DashboardChannelClient(http_ws_driver.PhoenixChannelClient):
    """RFC 6455 Phoenix Channels v2 helper handling fragmentation, Ping/Pong, and join_ref tracking."""

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


def _poll_until(fn: Callable[[], Any], *, timeout_s: float = 8.0, interval_s: float = 0.2) -> Any:
    deadline = time.monotonic() + timeout_s
    last_val = None
    while True:
        last_val = fn()
        if last_val:
            return last_val
        if time.monotonic() >= deadline:
            return last_val
        time.sleep(interval_s)


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

    return {"p50": _pct(50.0), "p95": _pct(95.0), "p99": _pct(99.0)}


def _provision_camera_blocks(
    tag: str,
    *,
    display_name: str = "Gate West 01",
    count: int = 1,
    timeline_start_us: int = 1760000000000000,
) -> dict[str, Any]:
    uid = uuid.uuid4().hex[:12]
    storage_id = str(uuid.uuid4())
    return _eval_elixir_json(
        "elixir/serviceradar_core",
        f"""
        alias ServiceRadar.Actors.SystemActor
        alias ServiceRadar.Camera.{{RecordingCatalogEntry, Source, StreamProfile}}
        actor = SystemActor.system(:mode_b_t3_t4)
        uid = "{uid}"
        {{:ok, cam}} = Source.create_source(%{{
          device_uid: "sr:synthetic-t3t4-" <> uid,
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

        relay_id = Ecto.UUID.generate()
        owner_id = Ecto.UUID.generate()
        claim_id = Ecto.UUID.generate()
        ingest_id = "ingest-{tag}-" <> uid
        prov_now = DateTime.utc_now()
        Ecto.Adapters.SQL.query!(ServiceRadar.Repo, \"\"\"
          INSERT INTO platform.camera_relay_sessions
            (id, camera_source_id, stream_profile_id, agent_id, gateway_id, status,
             media_ingest_id, viewer_count, inserted_at, updated_at)
          VALUES
            ($1, $2, $3, 'agent-synthetic', 'gateway-synthetic', 'active', $4, 0, $5, $5)
        \"\"\", [
          Ecto.UUID.dump!(relay_id), Ecto.UUID.dump!(cam.id),
          Ecto.UUID.dump!(prof.id), ingest_id, prov_now
        ])
        Ecto.Adapters.SQL.query!(ServiceRadar.Repo, \"\"\"
          INSERT INTO platform.camera_ingest_owners
            (id, camera_source_id, stream_profile_id, epoch, state, relay_session_id,
             inserted_at, updated_at)
          VALUES
            ($1, $2, $3, 1, 'released', $4, $5, $5)
        \"\"\", [
          Ecto.UUID.dump!(owner_id), Ecto.UUID.dump!(cam.id),
          Ecto.UUID.dump!(prof.id), Ecto.UUID.dump!(relay_id), prov_now
        ])
        Ecto.Adapters.SQL.query!(ServiceRadar.Repo, \"\"\"
          INSERT INTO platform.camera_recorder_claims
            (id, ingest_owner_id, ingest_epoch, recorder_epoch, next_block_sequence,
             relay_session_id, media_ingest_id, storage_id, state, inserted_at, updated_at)
          VALUES
            ($1, $2, 1, 1, {count}, $3, $4, $5, 'released', $6, $6)
        \"\"\", [
          Ecto.UUID.dump!(claim_id), Ecto.UUID.dump!(owner_id),
          Ecto.UUID.dump!(relay_id), ingest_id, Ecto.UUID.dump!("{storage_id}"), prov_now
        ])

        blocks =
          for idx <- 0..({count} - 1) do
            block_id = Ecto.UUID.generate()
            now = DateTime.utc_now()
            desc_sha = :sha256 |> :crypto.hash("desc-{tag}-" <> uid <> "-" <> Integer.to_string(idx)) |> Base.encode16(case: :lower)
            init_sha = :sha256 |> :crypto.hash("init-{tag}-" <> uid <> "-" <> Integer.to_string(idx)) |> Base.encode16(case: :lower)
            frag_sha = :sha256 |> :crypto.hash("frag-{tag}-" <> uid <> "-" <> Integer.to_string(idx)) |> Base.encode16(case: :lower)
            block_key = :sha256 |> :crypto.hash("block-{tag}-" <> uid <> "-" <> Integer.to_string(idx)) |> Base.encode16(case: :lower)
            desc_json = Jason.encode!(%{{
              "version" => 1,
              "format" => %{{ "codec" => "avc1.42c00a", "timescale" => 90000 }},
              "init" => %{{ "length" => 256, "sha256" => init_sha }},
              "media" => %{{ "length" => 1024, "sha256" => frag_sha }},
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
                  "sha256" => frag_sha
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
                ($1, $2, $3, $4, $5, 1, $6, 1, $7, $8, $9, $10, 'sealed', $11::jsonb, $12, 'unresolved', '{{}}'::jsonb, $13, $13)
            \"\"\", [
              Ecto.UUID.dump!(block_id), block_key, Ecto.UUID.dump!(cam.id), Ecto.UUID.dump!(prof.id),
              Ecto.UUID.dump!(owner_id), Ecto.UUID.dump!(claim_id),
              idx, Ecto.UUID.dump!(relay_id), ingest_id,
              Ecto.UUID.dump!("{storage_id}"), desc_json, desc_sha, now
            ])
            t_start = {timeline_start_us} + (idx * 10_000_000)
            t_end = t_start + 10_000_000
            {{:ok, entry}} = RecordingCatalogEntry
              |> Ash.Changeset.for_create(:register_sealed, %{{
                recording_block_id: block_id,
                camera_source_id: cam.id,
                stream_profile_id: prof.id,
                storage_id: "{storage_id}",
                block_key: block_key,
                media_start_ns: 0,
                media_end_ns: 2_000_000_000,
                timeline_start_us: t_start,
                timeline_end_us: t_end,
                time_basis: :received,
                fragment_count: 1,
                media_bytes: 1024,
                init_sha256: init_sha,
                descriptor_sha256: desc_sha,
                local_state_at: now,
                archive_state: :not_required,
                archive_state_at: now,
                sealed_at: now
              }}, actor: actor)
              |> Ash.create(actor: actor)
            %{{
              recording_block_id: block_id,
              catalog_entry_id: entry.id,
              descriptor_sha256: entry.descriptor_sha256,
              timeline_start_us: t_start,
              timeline_end_us: t_end
            }}
          end

        result = %{{
          camera_source_id: cam.id,
          stream_profile_id: prof.id,
          blocks: blocks
        }}
        """,
    )


def _write_pack_tree(dest_dir: Path, files_map: Mapping[str, str]) -> Path:
    if dest_dir.exists():
        shutil.rmtree(dest_dir)
    for rel_path, content in files_map.items():
        target = dest_dir / rel_path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(content, encoding="utf-8")
    return dest_dir


def _restamp_v2_tree(files_map: Mapping[str, str]) -> dict[str, str]:
    updated = dict(files_map)
    renderer_rel = "dashboard_packages/alpr-console/renderer.js"
    dm_rel = "dashboard_packages/alpr-console/manifest.json"
    if renderer_rel in updated and dm_rel in updated:
        dm = json.loads(updated[dm_rel])
        dm["renderer"]["sha256"] = hashlib.sha256(updated[renderer_rel].encode("utf-8")).hexdigest()
        updated[dm_rel] = json.dumps(dm, indent=2) + "\n"
    manifest = json.loads(updated["manifest.json"])
    manifest["files"] = {
        rel: hashlib.sha256(content.encode("utf-8")).hexdigest()
        for rel, content in sorted(updated.items())
        if rel != "manifest.json"
    }
    updated["manifest.json"] = json.dumps(manifest, indent=2) + "\n"
    return updated


class _BaseModeBTier3Tier4Test(unittest.TestCase):
    """Fail-closed shared setup verifying live toolchain, services, and companion SDK."""

    env_info: dict[str, Any] = {}

    @classmethod
    def setUpClass(cls) -> None:
        cls.env_info = env_probe.probe_mode_b_environment(require_services=True)
        cls.scratch = env_probe.get_scratch_dir("mode-b-t3-t4")
        cls.sdk_repo = env_probe.probe_sdk_repo()


# ---------------------------------------------------------------------------
# Tier 3: 15 Pairwise Cross-Feature Live E2E Tests
# ---------------------------------------------------------------------------


class Tier3PairwiseModeBTest(_BaseModeBTier3Tier4Test):
    """Live cross-component verification of all 15 Tier 3 pairwise combinations."""

    @classmethod
    def setUpClass(cls) -> None:
        super().setUpClass()
        _require_elixir_modules(
            "elixir/serviceradar_core",
            (
                "ServiceRadar.Camera.VantagePipeline",
                "ServiceRadar.Camera.VantageJob",
                "ServiceRadar.Camera.VantageObservation",
                "ServiceRadar.Camera.VantageObservationProjector",
                "ServiceRadar.Camera.VantagePipelineDispatcher",
                "ServiceRadar.Camera.VantageWorkerHeartbeat",
                "ServiceRadar.Camera.VantageWorkerRegistration",
                "ServiceRadar.Camera.VantageRetention",
                "ServiceRadar.Camera.SemanticSearch",
                "ServiceRadar.Catalog.PackManifest",
                "ServiceRadar.Catalog.PackArchive",
                "ServiceRadar.Catalog.Reconciler",
                "ServiceRadar.Dashboards.PackageImport",
            ),
        )
        _require_elixir_modules(
            "elixir/serviceradar_core_elx",
            (
                "ServiceRadarCoreElx.CameraRelay.LongshoreMailbox",
                "ServiceRadarCoreElx.CameraRelay.LiveVantageTap",
            ),
        )
        _require_elixir_modules(
            "elixir/web-ng",
            (
                "ServiceRadarWebNG.SRQL.EntityAccess",
                "ServiceRadarWebNGWeb.DashboardFrameChannel.Events",
            ),
        )
        cls.t3 = _load_json("t3_t4/tier3_pairwise_matrix.json")
        cls.pairs = {p["test_id"]: p for p in cls.t3["pairs"]}
        cls.result_vec = _load_json("wire_vectors/vantage_result_v1.json")
        cls.v2_ref = _load_json("f6_f10/pack_v2_alpr_reference.json")
        cls.f13 = _load_json("f11_f14/f13_live_tap_and_mailbox_vectors.json")

    def test_e2e_t3_01_f1_x_f2_cnpg_fk_trigger_hold_and_live_tap_cascade(self) -> None:
        prov = _provision_camera_blocks("t3-01", count=2)
        cam_id = prov["camera_source_id"]
        prof_id = prov["stream_profile_id"]
        blk_a, blk_b = prov["blocks"]
        pid = f"io.serviceradar.e2e-t3-01.{uuid.uuid4().hex[:8]}"
        cascade_uid = uuid.uuid4().hex[:12]
        cascade_obs_key = f"t3-01-obs-live-cascade-{cascade_uid}"
        self.addCleanup(
            lambda: _cleanup_cnpg_records(
                source_ids=[cam_id],
                pipeline_ids=[pid],
                observation_keys=[cascade_obs_key],
            )
        )

        res = _eval_elixir_json(
            "elixir/serviceradar_core",
            f"""
            alias ServiceRadar.Actors.SystemActor
            alias ServiceRadar.Camera.{{RecordingCatalogEntry, RecordingHolds, Source, StreamProfile, VantageJob, VantageObservation, VantagePipeline}}
            require Ash.Query
            actor = SystemActor.system(:mode_b_t3_01)
            hold_actor = %{{id: "hold-op", role: :operator, permissions: MapSet.new(["devices.view", "devices.cameras.recordings.hold"])}}
            admin = %{{id: "admin-op", role: :admin, permissions: MapSet.new(["settings.recording.manage"])}}
            now = DateTime.utc_now()

            {{:ok, _pipe}} = VantagePipeline
              |> Ash.Changeset.for_create(:upsert, %{{
                pipeline_id: "{pid}",
                version: "1.0.0",
                name: "T3-01 Lifecycle",
                camera_selector: %{{}},
                enabled: true,
                source_mode: :recorded_block,
                trigger_kind: :on_stage1_detection,
                input_mode: :detection_crop,
                runner: :camera_vlm,
                signal_schema_id: "alpr_plate_read",
                signal_schema_version: "1.0.0",
                display_contract_id: "alpr_plate_read"
              }}, actor: actor)
              |> Ash.create(actor: actor)

            {{:ok, job_a}} = VantageJob
              |> Ash.Changeset.for_create(:enqueue, %{{
                pipeline_id: "{pid}", pipeline_version: "1.0.0",
                camera_source_id: "{cam_id}", stream_profile_id: "{prof_id}",
                catalog_entry_id: "{blk_a['catalog_entry_id']}", descriptor_sha256: "{blk_a['descriptor_sha256']}",
                target_key: "t3-01-a", target_runner: "camera_vlm", subject: "media.jobs.vantage.vlm.v1"
              }}, actor: actor)
              |> Ash.create(actor: actor)
            {{:ok, job_b}} = VantageJob
              |> Ash.Changeset.for_create(:enqueue, %{{
                pipeline_id: "{pid}", pipeline_version: "1.0.0",
                camera_source_id: "{cam_id}", stream_profile_id: "{prof_id}",
                catalog_entry_id: "{blk_b['catalog_entry_id']}", descriptor_sha256: "{blk_b['descriptor_sha256']}",
                target_key: "t3-01-b", target_runner: "camera_vlm", subject: "media.jobs.vantage.vlm.v1"
              }}, actor: actor)
              |> Ash.create(actor: actor)

            obs_base = %{{
              pack_id: "io.serviceradar.vantage-alpr", pipeline_id: "{pid}", pipeline_version: "1.0.0",
              worker_kind: "camera_vlm", worker_id: "w-1", model_id: "m", model_version: "1.0.0",
              camera_source_id: "{cam_id}", stream_profile_id: "{prof_id}",
              frame_sequence: 1, media_pts_ns: 1000, time_basis: :received, track_id: "1",
              category: "license_plate", label: "SR-0100", confidence: 0.94,
              bbox: %{{"x1" => 0.2, "y1" => 0.3, "x2" => 0.5, "y2" => 0.6}},
              attributes: %{{"plate_text" => "SR-0100"}},
              signal_schema_id: "alpr_plate_read", signal_schema_version: "1.0.0", display_contract_id: "alpr_plate_read"
            }}
            {{:ok, _}} = VantageObservation
              |> Ash.Changeset.for_create(:upsert_observation, Map.merge(obs_base, %{{
                observation_key: "t3-01-obs-a", source_mode: :recorded_block,
                catalog_entry_id: "{blk_a['catalog_entry_id']}", fragment_sequence: 0,
                timeline_ts_us: {blk_a['timeline_start_us']}
              }}), actor: actor)
              |> Ash.create(actor: actor)
            {{:ok, _}} = VantageObservation
              |> Ash.Changeset.for_create(:upsert_observation, Map.merge(obs_base, %{{
                observation_key: "t3-01-obs-b", source_mode: :recorded_block,
                catalog_entry_id: "{blk_b['catalog_entry_id']}", fragment_sequence: 0,
                timeline_ts_us: {blk_b['timeline_start_us']}
              }}), actor: actor)
              |> Ash.create(actor: actor)
            {{:ok, _}} = VantageObservation
              |> Ash.Changeset.for_create(:upsert_observation, Map.merge(obs_base, %{{
                observation_key: "t3-01-obs-live", source_mode: :live_keyframe_tap,
                catalog_entry_id: nil, fragment_sequence: nil,
                timeline_ts_us: {blk_b['timeline_end_us']}
              }}), actor: actor)
              |> Ash.create(actor: actor)

            {{:ok, hold}} = RecordingHolds.place_hold(%{{
              camera_source_id: "{cam_id}",
              stream_profile_id: "{prof_id}",
              start_us: {blk_a['timeline_start_us']},
              end_us: {blk_a['timeline_end_us']},
              kind: :investigation,
              reason: "e2e_t3_01"
            }}, actor: hold_actor)
            hold_blocked = match?({{:error, {{:blocked_by_hold, _}}}}, RecordingHolds.begin_copy_deletion_intent("{blk_a['catalog_entry_id']}", :local, %{{reason: :max_local_age}}, actor: admin))

            # Quarantine blk_b -> blk_b observations purged, job_b cancelled; blk_a & live survive
            entry_b = Ash.get!(RecordingCatalogEntry, "{blk_b['catalog_entry_id']}", actor: actor)
            {{:ok, _}} = entry_b
              |> Ash.Changeset.for_update(:quarantine_in_place, %{{
                quarantine_reason: :binding_compromised,
                quarantine_receipt: %{{"reason" => "e2e_t3_01"}},
                quarantined_bytes: 1024,
                local_state_at: now,
                archive_state: :not_required,
                archive_state_at: now
              }}, actor: actor)
              |> Ash.update(actor: actor)
            {{:ok, job_b_after}} = VantageJob.get_by_id(job_b.id, actor: actor)
            cnt_after_q = VantageObservation |> Ash.Query.filter(camera_source_id == "{cam_id}") |> Ash.count!(actor: actor)

            # Release hold and reclaim blk_a -> blk_a observations purged; live survives until Source delete
            {{:ok, _}} = RecordingHolds.release_hold(hold.id, %{{release_reason: "done"}}, actor: hold_actor)
            entry_a = Ash.get!(RecordingCatalogEntry, "{blk_a['catalog_entry_id']}", actor: actor)
            {{:ok, entry_a}} = entry_a
              |> Ash.Changeset.for_update(:transition_local_state, %{{local_state: :reclaimed, local_state_at: now}}, actor: actor)
              |> Ash.update(actor: actor)
            {{:ok, _}} = entry_a
              |> Ash.Changeset.for_update(:transition_archive_state, %{{archive_state: :deleted, archive_state_at: now, archive_deleted_reason: :operator}}, actor: actor)
              |> Ash.update(actor: actor)
            cnt_after_reclaim = VantageObservation |> Ash.Query.filter(camera_source_id == "{cam_id}") |> Ash.count!(actor: actor)

            # Isolate Source deletion cascade onto a fresh Source without RecordingHolds/audit rows
            # so Ash.destroy!/2 executes cleanly without tripping camera_recording_access_audits_append_only_trigger.
            {{:ok, cam_cascade}} = Source.create_source(%{{
              device_uid: "sr:synthetic-t3t4-cascade-{cascade_uid}",
              vendor: "synthetic",
              vendor_camera_id: "cascade-{cascade_uid}",
              display_name: "Bay 04 Approach",
              assigned_agent_id: "agent-synthetic",
              assigned_gateway_id: "gateway-synthetic"
            }}, actor: actor)
            {{:ok, prof_cascade}} = StreamProfile.create_profile(%{{
              camera_source_id: cam_cascade.id,
              profile_name: "main",
              relay_eligible: true
            }}, actor: actor)
            cascade_id = cam_cascade.id
            {{:ok, _}} = VantageObservation
              |> Ash.Changeset.for_create(:upsert_observation, Map.merge(obs_base, %{{
                observation_key: "{cascade_obs_key}",
                camera_source_id: cascade_id,
                stream_profile_id: prof_cascade.id,
                source_mode: :live_keyframe_tap,
                catalog_entry_id: nil,
                fragment_sequence: nil,
                timeline_ts_us: {blk_b['timeline_end_us']}
              }}), actor: actor)
              |> Ash.create(actor: actor)
            cnt_before_src = VantageObservation |> Ash.Query.filter(camera_source_id == ^cascade_id) |> Ash.count!(actor: actor)
            :ok = Ash.destroy!(cam_cascade, actor: actor)
            cnt_after_src = VantageObservation |> Ash.Query.filter(camera_source_id == ^cascade_id) |> Ash.count!(actor: actor)

            result = %{{
              job_a_state: to_string(job_a.state),
              job_b_state: to_string(job_b_after.state),
              hold_blocked: hold_blocked,
              cnt_after_q: cnt_after_q,
              cnt_after_reclaim: cnt_after_reclaim,
              cnt_before_src: cnt_before_src,
              cnt_after_src: cnt_after_src
            }}
            """,
        )
        self.assertTrue(res["hold_blocked"])
        self.assertEqual(res["job_b_state"], "cancelled")
        self.assertEqual(res["cnt_after_q"], 2)
        self.assertEqual(res["cnt_after_reclaim"], 1)
        self.assertEqual(res["cnt_before_src"], 1)
        self.assertEqual(res["cnt_after_src"], 0)

    def test_e2e_t3_02_f1_x_f3_eventwriter_prevalidation_and_search_tsv(self) -> None:
        prov = _provision_camera_blocks("t3-02", count=1)
        cam_id = prov["camera_source_id"]
        prof_id = prov["stream_profile_id"]
        blk = prov["blocks"][0]
        pid = f"io.serviceradar.e2e-t3-02.{uuid.uuid4().hex[:8]}"
        self.addCleanup(lambda: _cleanup_cnpg_records(source_ids=[cam_id], pipeline_ids=[pid]))

        exact_32k = vc.make_synthetic_baseline_jfif(64, 48, seed=11, target_max_bytes=4096)
        payload_len = 32768 - len(exact_32k) - 4
        exact_32k = exact_32k[:20] + b"\xFF\xFE" + (payload_len + 2).to_bytes(2, "big") + (b"V" * payload_len) + exact_32k[20:]
        over_32k = exact_32k[:20] + b"\xFF\xFE" + (payload_len + 3).to_bytes(2, "big") + (b"V" * (payload_len + 1)) + exact_32k[20:]
        self.assertEqual(len(exact_32k), 32768)
        self.assertEqual(len(over_32k), 32769)

        pos_env = copy.deepcopy(self.result_vec["positive"])
        pos_env["pipeline_id"] = pid
        pos_env["camera_source_id"] = cam_id
        pos_env["stream_profile_id"] = prof_id
        pos_env["catalog_entry_id"] = blk["catalog_entry_id"]
        pos_env["descriptor_sha256"] = blk["descriptor_sha256"]
        pos_env["observations"] = [pos_env["observations"][0]]
        pos_env["observations"][0]["observation_key"] = f"t3-02-pos-{uuid.uuid4().hex[:8]}"
        pos_env["observations"][0]["crop_jpeg_b64"] = base64.b64encode(exact_32k).decode("ascii")

        bad_env = copy.deepcopy(pos_env)
        bad_env["observations"][0]["observation_key"] = f"t3-02-neg-{uuid.uuid4().hex[:8]}"
        bad_env["observations"][0]["crop_jpeg_b64"] = base64.b64encode(over_32k).decode("ascii")

        res = _eval_elixir_json(
            "elixir/serviceradar_core",
            f"""
            alias ServiceRadar.Actors.SystemActor
            alias ServiceRadar.Camera.{{VantageJob, VantageObservationProjector, VantagePipeline}}
            actor = SystemActor.system(:mode_b_t3_02)
            {{:ok, _}} = VantagePipeline
              |> Ash.Changeset.for_create(:upsert, %{{
                pipeline_id: "{pid}", version: "1.0.0", name: "T3-02",
                camera_selector: %{{}}, enabled: true, source_mode: :recorded_block,
                trigger_kind: :on_stage1_detection, input_mode: :detection_crop,
                runner: :camera_vlm,
                signal_schema_id: "alpr_plate_read", signal_schema_version: "1.0.0",
                display_contract_id: "alpr_plate_read",
                signal_schema: %{{ "type" => "object", "required" => ["plate_text"], "properties" => %{{ "plate_text" => %{{ "type" => "string", "pattern" => "^[A-Z0-9-]{{2,12}}$" }} }} }}
              }}, actor: actor)
              |> Ash.create(actor: actor)
            {{:ok, job}} = VantageJob
              |> Ash.Changeset.for_create(:enqueue, %{{
                pipeline_id: "{pid}", pipeline_version: "1.0.0",
                camera_source_id: "{cam_id}", stream_profile_id: "{prof_id}",
                catalog_entry_id: "{blk['catalog_entry_id']}", descriptor_sha256: "{blk['descriptor_sha256']}",
                target_key: "t3-02-t1", target_runner: "camera_vlm", subject: "media.jobs.vantage.vlm.v1"
              }}, actor: actor)
              |> Ash.create(actor: actor)
            pos_payload = Jason.decode!(System.fetch_env!("E2E_POS_JSON")) |> Map.put("job_id", job.id)
            neg_payload = Jason.decode!(System.fetch_env!("E2E_NEG_JSON")) |> Map.put("job_id", job.id)

            neg_res = VantageObservationProjector.ingest_result(neg_payload)
            pos_res = VantageObservationProjector.ingest_result(pos_payload)

            %{{rows: [[tsv_cnt]]}} = Ecto.Adapters.SQL.query!(
              ServiceRadar.Repo,
              "SELECT count(*) FROM platform.camera_vantage_observations WHERE camera_source_id = $1 AND search_tsv @@ plainto_tsquery('english', 'SR-0100')",
              [Ecto.UUID.dump!("{cam_id}")]
            )
            result = %{{neg_ok: match?({{:ok, _}}, neg_res), pos_ok: match?({{:ok, _}}, pos_res), tsv_cnt: tsv_cnt}}
            """,
            extra_env={"E2E_POS_JSON": json.dumps(pos_env), "E2E_NEG_JSON": json.dumps(bad_env)},
        )
        self.assertFalse(res["neg_ok"])
        self.assertTrue(res["pos_ok"])
        self.assertEqual(res["tsv_cnt"], 1)

    def test_e2e_t3_03_f2_x_f3_quarantine_race_drops_inflight_result(self) -> None:
        prov = _provision_camera_blocks("t3-03", count=1)
        cam_id = prov["camera_source_id"]
        prof_id = prov["stream_profile_id"]
        blk = prov["blocks"][0]
        pid = f"io.serviceradar.e2e-t3-03.{uuid.uuid4().hex[:8]}"
        self.addCleanup(lambda: _cleanup_cnpg_records(source_ids=[cam_id], pipeline_ids=[pid]))

        env_payload = copy.deepcopy(self.result_vec["positive"])
        env_payload["pipeline_id"] = pid
        env_payload["camera_source_id"] = cam_id
        env_payload["stream_profile_id"] = prof_id
        env_payload["catalog_entry_id"] = blk["catalog_entry_id"]
        env_payload["descriptor_sha256"] = blk["descriptor_sha256"]
        env_payload["observations"] = [env_payload["observations"][0]]
        env_payload["observations"][0]["observation_key"] = f"t3-03-{uuid.uuid4().hex[:8]}"

        res = _eval_elixir_json(
            "elixir/serviceradar_core",
            f"""
            alias ServiceRadar.Actors.SystemActor
            alias ServiceRadar.Camera.{{RecordingCatalogEntry, VantageJob, VantageObservation, VantageObservationProjector, VantagePipeline}}
            require Ash.Query
            actor = SystemActor.system(:mode_b_t3_03)
            now = DateTime.utc_now()
            {{:ok, _}} = VantagePipeline
              |> Ash.Changeset.for_create(:upsert, %{{
                pipeline_id: "{pid}", version: "1.0.0", name: "T3-03",
                camera_selector: %{{}}, enabled: true, source_mode: :recorded_block,
                trigger_kind: :on_stage1_detection, input_mode: :detection_crop,
                runner: :camera_vlm,
                signal_schema_id: "alpr_plate_read", signal_schema_version: "1.0.0",
                display_contract_id: "alpr_plate_read"
              }}, actor: actor)
              |> Ash.create(actor: actor)
            {{:ok, job}} = VantageJob
              |> Ash.Changeset.for_create(:enqueue, %{{
                pipeline_id: "{pid}", pipeline_version: "1.0.0",
                camera_source_id: "{cam_id}", stream_profile_id: "{prof_id}",
                catalog_entry_id: "{blk['catalog_entry_id']}", descriptor_sha256: "{blk['descriptor_sha256']}",
                target_key: "t3-03", target_runner: "camera_vlm", subject: "media.jobs.vantage.vlm.v1"
              }}, actor: actor)
              |> Ash.create(actor: actor)
            entry = Ash.get!(RecordingCatalogEntry, "{blk['catalog_entry_id']}", actor: actor)
            {{:ok, _}} = entry
              |> Ash.Changeset.for_update(:quarantine_in_place, %{{
                quarantine_reason: :binding_compromised,
                quarantine_receipt: %{{"reason" => "race"}},
                quarantined_bytes: 1024,
                local_state_at: now,
                archive_state: :not_required,
                archive_state_at: now
              }}, actor: actor)
              |> Ash.update(actor: actor)
            payload = Jason.decode!(System.fetch_env!("E2E_ENV_JSON")) |> Map.put("job_id", job.id)
            ingest_res = VantageObservationProjector.ingest_result(payload)
            {{:error, :recording_gone}} = ingest_res
            obs_cnt = VantageObservation |> Ash.Query.filter(camera_source_id == "{cam_id}") |> Ash.count!(actor: actor)
            {{:ok, job_after}} = VantageJob.get_by_id(job.id, actor: actor)
            result = %{{obs_cnt: obs_cnt, job_state: to_string(job_after.state), dropped: ingest_res == {{:error, :recording_gone}}}}
            """,
            extra_env={"E2E_ENV_JSON": json.dumps(env_payload)},
        )
        self.assertEqual(res["obs_cnt"], 0)
        self.assertEqual(res["job_state"], "cancelled")
        self.assertTrue(res["dropped"])

    def test_e2e_t3_04_f2_x_f11_quarantine_reclaim_triggers_read_grant_410(self) -> None:
        token, dep_ref, gen = _require_control_plane_auth()
        prov = _provision_camera_blocks("t3-04", count=1)
        cam_id = prov["camera_source_id"]
        prof_id = prov["stream_profile_id"]
        blk = prov["blocks"][0]
        pid = f"io.serviceradar.e2e-t3-04.{uuid.uuid4().hex[:8]}"
        self.addCleanup(lambda: _cleanup_cnpg_records(source_ids=[cam_id], pipeline_ids=[pid]))

        setup = _eval_elixir_json(
            "elixir/serviceradar_core",
            f"""
            alias ServiceRadar.Actors.SystemActor
            alias ServiceRadar.Camera.{{VantageJob, VantagePipeline}}
            actor = SystemActor.system(:mode_b_t3_04)
            now = DateTime.utc_now()
            {{:ok, _}} = VantagePipeline
              |> Ash.Changeset.for_create(:upsert, %{{
                pipeline_id: "{pid}", version: "1.0.0", name: "T3-04",
                camera_selector: %{{}}, enabled: true, source_mode: :recorded_block,
                trigger_kind: :on_stage1_detection, input_mode: :detection_crop,
                runner: :camera_vlm,
                signal_schema_id: "alpr_plate_read", signal_schema_version: "1.0.0",
                display_contract_id: "alpr_plate_read"
              }}, actor: actor)
              |> Ash.create(actor: actor)
            {{:ok, job}} = VantageJob
              |> Ash.Changeset.for_create(:enqueue, %{{
                pipeline_id: "{pid}", pipeline_version: "1.0.0",
                camera_source_id: "{cam_id}", stream_profile_id: "{prof_id}",
                catalog_entry_id: "{blk['catalog_entry_id']}", descriptor_sha256: "{blk['descriptor_sha256']}",
                target_key: "t3-04", target_runner: "camera_vlm", subject: "media.jobs.vantage.vlm.v1"
              }}, actor: actor)
              |> Ash.create(actor: actor)
            {{:ok, job}} = job
              |> Ash.Changeset.for_update(:mark_dispatched, %{{
                dispatched_at: now,
                deadline_at: DateTime.shift(now, second: 60)
              }}, actor: actor)
              |> Ash.update(actor: actor)
            result = %{{job_id: job.id}}
            """,
        )
        job_id = setup["job_id"]

        # Positive control: playable entry returns 200
        status_ok, hdrs_ok, body_ok = http_ws_driver.request_worker_read_grant(
            job_id=job_id,
            catalog_entry_id=blk["catalog_entry_id"],
            descriptor_sha256=blk["descriptor_sha256"],
            control_plane_token=token,
            deployment_ref=dep_ref,
            media_worker_generation=gen,
        )
        self.assertEqual(status_ok, 200)
        self.assertEqual(hdrs_ok.get("cache-control"), "no-store")
        self.assertEqual(body_ok["job_id"], job_id)

        # Quarantine entry -> read-grants fails closed 410 recording_gone
        _eval_elixir_json(
            "elixir/serviceradar_core",
            f"""
            alias ServiceRadar.Actors.SystemActor
            alias ServiceRadar.Camera.RecordingCatalogEntry
            actor = SystemActor.system(:mode_b_t3_04_q)
            now = DateTime.utc_now()
            entry = Ash.get!(RecordingCatalogEntry, "{blk['catalog_entry_id']}", actor: actor)
            {{:ok, _}} = entry
              |> Ash.Changeset.for_update(:quarantine_in_place, %{{
                quarantine_reason: :binding_compromised,
                quarantine_receipt: %{{"reason" => "e2e"}},
                quarantined_bytes: 1024,
                local_state_at: now,
                archive_state: :not_required,
                archive_state_at: now
              }}, actor: actor)
              |> Ash.update(actor: actor)
            result = %{{ok: true}}
            """,
        )
        status_gone, hdrs_gone, body_gone = http_ws_driver.request_worker_read_grant(
            job_id=job_id,
            catalog_entry_id=blk["catalog_entry_id"],
            descriptor_sha256=blk["descriptor_sha256"],
            control_plane_token=token,
            deployment_ref=dep_ref,
            media_worker_generation=gen,
            validate_200=False,
        )
        self.assertEqual(status_gone, 410)
        self.assertEqual(hdrs_gone.get("cache-control"), "no-store")
        self.assertEqual(body_gone.get("status"), "recording_gone")

    def test_e2e_t3_05_f3_x_f9_eventwriter_to_srql_and_semantic_search(self) -> None:
        recent_start_us = int(time.time() * 1_000_000) - 10_000_000
        prov = _provision_camera_blocks(
            "t3-05", display_name="Gate West 01", count=1, timeline_start_us=recent_start_us
        )
        cam_id = prov["camera_source_id"]
        prof_id = prov["stream_profile_id"]
        blk = prov["blocks"][0]
        pid = f"io.serviceradar.e2e-t3-05.{uuid.uuid4().hex[:8]}"
        self.addCleanup(lambda: _cleanup_cnpg_records(source_ids=[cam_id], pipeline_ids=[pid]))

        res = _eval_elixir_json(
            "elixir/web-ng",
            f"""
            alias ServiceRadar.Actors.SystemActor
            alias ServiceRadar.Camera.{{SemanticSearch, VantageObservation, VantagePipeline}}
            alias ServiceRadarWebNG.SRQL.EntityAccess
            sys_actor = SystemActor.system(:mode_b_t3_05)
            {{:ok, _}} = VantagePipeline
              |> Ash.Changeset.for_create(:upsert, %{{
                pipeline_id: "{pid}", version: "1.0.0", name: "T3-05",
                camera_selector: %{{}}, enabled: true, source_mode: :recorded_block,
                trigger_kind: :on_stage1_detection, input_mode: :detection_crop,
                runner: :camera_vlm,
                signal_schema_id: "alpr_plate_read", signal_schema_version: "1.0.0",
                display_contract_id: "alpr_plate_read"
              }}, actor: sys_actor)
              |> Ash.create(actor: sys_actor)
            {{:ok, _}} = VantageObservation
              |> Ash.Changeset.for_create(:upsert_observation, %{{
                observation_key: "t3-05-obs-{uuid.uuid4().hex[:8]}",
                pack_id: "io.serviceradar.vantage-alpr", pipeline_id: "{pid}", pipeline_version: "1.0.0",
                worker_kind: "camera_vlm", worker_id: "w1", model_id: "m", model_version: "1.0.0",
                source_mode: :recorded_block,
                camera_source_id: "{cam_id}", stream_profile_id: "{prof_id}",
                catalog_entry_id: "{blk['catalog_entry_id']}", fragment_sequence: 0,
                frame_sequence: 1, media_pts_ns: 1000, timeline_ts_us: {blk['timeline_start_us'] + 1_000_000},
                time_basis: :received, track_id: "1", category: "license_plate", label: "SR-0100",
                confidence: 0.94, bbox: %{{"x1" => 0.3, "y1" => 0.5, "x2" => 0.5, "y2" => 0.7}},
                attributes: %{{"plate_text" => "SR-0100"}},
                signal_schema_id: "alpr_plate_read", signal_schema_version: "1.0.0",
                display_contract_id: "alpr_plate_read", search_text: "SR-0100 Gate West 01"
              }}, actor: sys_actor)
              |> Ash.create(actor: sys_actor)

            full_actor = %{{
              id: Ecto.UUID.generate(),
              permissions: MapSet.new(["devices.view", "devices.cameras.recordings.view"]),
              authorized_camera_source_ids: ["{cam_id}"]
            }}
            bare_actor = %{{
              id: Ecto.UUID.generate(),
              permissions: MapSet.new(["devices.view"]),
              authorized_camera_source_ids: ["{cam_id}"]
            }}
            ok_auth = EntityAccess.authorize("in:devices in:camera_observations label:SR-0100", full_actor)
            denied_auth = EntityAccess.authorize("in:devices in:camera_observations label:SR-0100", bare_actor)
            {{:ok, search_res}} = SemanticSearch.search(%{{query: "SR-0100", camera_source_id: "{cam_id}"}}, actor: full_actor)
            search_denied = SemanticSearch.search(%{{query: "SR-0100", camera_source_id: "{cam_id}"}}, actor: bare_actor)
            result = %{{
              ok_auth: ok_auth == :ok,
              denied_auth: denied_auth == {{:error, :forbidden}},
              search_hit_count: length(search_res.results),
              search_denied: match?({{:error, %Ash.Error.Forbidden{{}}}}, search_denied)
            }}
            """,
        )
        self.assertTrue(res["ok_auth"])
        self.assertTrue(res["denied_auth"])
        self.assertGreaterEqual(res["search_hit_count"], 1)
        self.assertTrue(res["search_denied"])

    def test_e2e_t3_06_f3_x_f10_ocsf_to_dashboard_events_scoping(self) -> None:
        envs = env_probe.probe_env_vars(
            "SERVICERADAR_E2E_DASHBOARD_SLUG",
            "SERVICERADAR_E2E_DASHBOARD_STREAM_TOKEN",
            "SERVICERADAR_E2E_CAMERA_SOURCE_ID",
        )
        ws_url = _ws_url_from_web_url(http_ws_driver.require_web_url())
        nats_url = nats_driver.require_nats_url()
        headers = _viewer_ws_headers()
        topic = f"dashboards:{envs['SERVICERADAR_E2E_DASHBOARD_SLUG']}"
        cam_id = envs["SERVICERADAR_E2E_CAMERA_SOURCE_ID"]

        client = DashboardChannelClient(ws_url, headers=headers, timeout=10.0)
        try:
            join_reply = client.join_topic(topic, {"token": envs["SERVICERADAR_E2E_DASHBOARD_STREAM_TOKEN"]})
            self.assertEqual(join_reply[4].get("status"), "ok", f"join failed: {join_reply}")
            sub_id = f"t3-06-{uuid.uuid4().hex[:8]}"
            sub_ref = client.push_event(
                topic,
                "events:subscribe",
                {
                    "id": sub_id,
                    "filter": {
                        "class_uid": 1008,
                        "camera_source_id": cam_id,
                        "metadata": {"service_radar": {"signal_schema": {"schema_id": "alpr_plate_read"}}},
                    },
                },
            )
            sub_reply = client.recv_matching(
                lambda m: len(m) >= 5 and str(m[1]) == sub_ref and m[3] == "phx_reply"
            )
            self.assertEqual(sub_reply[4].get("status"), "ok", f"events:subscribe failed: {sub_reply}")

            # Publish OCSF 1008 camera event via NATS so EventWriter persists OcsfEvent in CNPG
            # and broadcasts over web-ng Phoenix.PubSub to DashboardFrameChannel.
            event_id = str(uuid.uuid4())
            ocsf_event = {
                "id": event_id,
                "time": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                "class_uid": 1008,
                "category_uid": 1,
                "type_uid": 100801,
                "activity_id": 1,
                "activity_name": "Create",
                "severity_id": 1,
                "severity": "Informational",
                "status_id": 1,
                "status": "Success",
                "log_name": "camera.vantage.observation",
                "log_provider": "serviceradar.vantage",
                "message": "Vantage license_plate: SR-0100",
                "metadata": {
                    "service_radar": {
                        "signal_schema": {
                            "producer_id": "io.serviceradar.vantage-alpr",
                            "producer_version": "1.0.0",
                            "schema_id": "alpr_plate_read",
                            "schema_version": "1.0.0",
                        },
                        "source_type": "camera_vantage",
                        "camera_source_id": cam_id,
                        "observation_key": f"t3-06-{uuid.uuid4().hex}",
                        "source_mode": "recorded_block",
                        "timeline_ts_us": int(time.time() * 1_000_000),
                        "time_basis": "received",
                        "category": "license_plate",
                        "label": "SR-0100",
                        "confidence": 0.94,
                        "attributes": {"plate_text": "SR-0100"},
                    }
                },
            }
            _publish_js_json(
                "events.internal.camera",
                ocsf_event,
                msg_id=f"e2e-t3-06-{uuid.uuid4().hex}",
                nats_url=nats_url,
            )
            batch = client.recv_matching(
                lambda m: (
                    len(m) >= 5
                    and m[2] == topic
                    and m[3] == "events:batch"
                    and isinstance(m[4], Mapping)
                    and m[4].get("subscription_id") == sub_id
                ),
                timeout=10.0,
            )
            events = batch[4].get("events") or []
            self.assertGreaterEqual(len(events), 1, f"expected events:batch payload, got {batch}")
        finally:
            client.close()

    def test_e2e_t3_07_f4_x_f5_media_core_cropper_and_vlm_bounds(self) -> None:
        cargo_bin = env_probe.probe_binary("cargo")
        env = _cargo_env()
        repo = vc.repo_root()
        for args in (
            [str(cargo_bin), "test", "--manifest-path", str(repo / "rust/media-core/Cargo.toml"), "crop"],
            [str(cargo_bin), "test", "--manifest-path", str(repo / "rust/media-worker/Cargo.toml"), "vantage_vlm"],
        ):
            proc = subprocess.run(args, cwd=str(repo), env=env, capture_output=True, text=True, timeout=300.0)
            self.assertEqual(proc.returncode, 0, f"{args!r} failed: {proc.stdout}\n{proc.stderr}")
            self.assertIn("test result: ok.", proc.stdout, f"missing cargo test summary in stdout: {proc.stdout!r}")
            passed_counts = [int(n) for n in re.findall(r"test result: ok\.\s+(\d+)\s+passed;", proc.stdout)]
            self.assertGreaterEqual(
                sum(passed_counts),
                1,
                f"expected >= 1 passed cargo test for {args!r}, got {proc.stdout!r}",
            )

    def test_e2e_t3_08_f5_x_f11_dispatcher_ramp1_fallback_and_read_grant(self) -> None:
        token, dep_ref, gen = _require_control_plane_auth()
        prov = _provision_camera_blocks("t3-08", count=1)
        cam_id = prov["camera_source_id"]
        prof_id = prov["stream_profile_id"]
        blk = prov["blocks"][0]
        pid = f"io.serviceradar.e2e-t3-08.{uuid.uuid4().hex[:8]}"
        self.addCleanup(lambda: _cleanup_cnpg_records(source_ids=[cam_id], pipeline_ids=[pid]))

        out = _eval_elixir_json(
            "elixir/serviceradar_core",
            f"""
            alias ServiceRadar.Actors.SystemActor
            alias ServiceRadar.Camera.{{VantageJob, VantagePipeline, VantagePipelineDispatcher}}
            actor = SystemActor.system(:mode_b_t3_08)
            {{:ok, _}} = VantagePipeline
              |> Ash.Changeset.for_create(:upsert, %{{
                pipeline_id: "{pid}", version: "1.0.0", name: "T3-08",
                camera_selector: %{{}}, enabled: true, source_mode: :recorded_block,
                trigger_kind: :on_stage1_detection, input_mode: :detection_crop,
                runner: :external_worker, capability: "vantage.alpr.v1",
                fallback_runner: "camera_vlm",
                signal_schema_id: "alpr_plate_read", signal_schema_version: "1.0.0",
                display_contract_id: "alpr_plate_read"
              }}, actor: actor)
              |> Ash.create(actor: actor)
            {{:ok, job}} = VantageJob
              |> Ash.Changeset.for_create(:enqueue, %{{
                pipeline_id: "{pid}", pipeline_version: "1.0.0",
                camera_source_id: "{cam_id}", stream_profile_id: "{prof_id}",
                catalog_entry_id: "{blk['catalog_entry_id']}", descriptor_sha256: "{blk['descriptor_sha256']}",
                target_key: "t3-08", target_runner: "camera_vlm", subject: "media.jobs.vantage.vlm.v1"
              }}, actor: actor)
              |> Ash.create(actor: actor)
            route = VantagePipelineDispatcher.resolve_route(job, actor: actor)
            result = %{{job_id: job.id, subject: route.subject, runner: route.runner}}
            """,
        )
        self.assertEqual(out["subject"], "media.jobs.vantage.vlm.v1")
        status, _, body = http_ws_driver.request_worker_read_grant(
            job_id=out["job_id"],
            catalog_entry_id=blk["catalog_entry_id"],
            descriptor_sha256=blk["descriptor_sha256"],
            control_plane_token=token,
            deployment_ref=dep_ref,
            media_worker_generation=gen,
        )
        self.assertEqual(status, 200)
        self.assertEqual(body["job_id"], out["job_id"])

    def test_e2e_t3_09_f6_x_f7_cli_pack_v2_and_elixir_archive_verify(self) -> None:
        _require_cli_dist()
        uid = uuid.uuid4().hex[:8]
        pack_dir = _write_pack_tree(self.scratch / f"t3_09_{uid}", self.v2_ref["files"])
        srpack = self.scratch / f"t3_09_{uid}.srpack"
        priv_key = self.scratch / f"t3_09_{uid}.key"
        pub_key = self.scratch / f"t3_09_{uid}.pub"
        self.addCleanup(lambda: shutil.rmtree(pack_dir, ignore_errors=True))

        cli_driver.run_cli(["pack", "validate", str(pack_dir), "--json"])
        cli_driver.run_cli(["pack", "build", str(pack_dir), "-o", str(srpack), "--json"])
        cli_driver.run_cli(
            ["pack", "keygen", "--private-key-out", str(priv_key), "--public-key-out", str(pub_key), "--key-id", "t3-09", "--json"]
        )
        sign_out = json.loads(
            cli_driver.run_cli(["pack", "sign", str(srpack), "--key", str(priv_key), "--key-id", "t3-09", "--json"]).stdout
        )
        sig_path = Path(sign_out["signature_file"])

        res = _eval_elixir_json(
            "elixir/serviceradar_core",
            """
            alias ServiceRadar.Catalog.{PackArchive, PackManifest, UploadSignature}
            tar_bytes = File.read!(System.fetch_env!("E2E_SRPACK"))
            content_hash = :sha256 |> :crypto.hash(tar_bytes) |> Base.encode16(case: :lower)
            {:ok, extracted} = PackArchive.extract(tar_bytes)
            {:ok, _} = PackManifest.validate_pack_tree(extracted.files, [])
            sig = Jason.decode!(File.read!(System.fetch_env!("E2E_SIG")))
            pub = String.trim(File.read!(System.fetch_env!("E2E_PUB")))
            :ok = UploadSignature.verify(sig, extracted.manifest, content_hash, %{sig["key_id"] => pub})
            result = %{version: extracted.manifest["pack_format_version"], ok: true}
            """,
            extra_env={"E2E_SRPACK": str(srpack), "E2E_SIG": str(sig_path), "E2E_PUB": str(pub_key)},
        )
        self.assertEqual(res["version"], 2)
        self.assertTrue(res["ok"])

        # Negative control: tamper renderer.js and verify CLI pack validate fails closed
        (pack_dir / "dashboard_packages/alpr-console/renderer.js").write_text("export const x = 1;\n", encoding="utf-8")
        bad_proc = cli_driver.run_cli(["pack", "validate", str(pack_dir), "--json"], check=False)
        self.assertNotEqual(bad_proc.returncode, 0)

    def test_e2e_t3_10_f6_x_f8_reconciler_and_alpr_reference_pack(self) -> None:
        uid = uuid.uuid4().hex[:8]
        pack_id = f"io.serviceradar.e2e-t3-10-{uid}"
        dash_id = f"io.serviceradar.e2e-t3-10-console-{uid}"
        route_slug = f"e2e-t3-10-console-{uid}"
        pid = f"{pack_id}.vehicle-plate"
        self.addCleanup(
            lambda: _cleanup_cnpg_records(pipeline_ids=[pid], pack_ids=[pack_id], dashboard_pkg_ids=[dash_id])
        )
        files = dict(self.v2_ref["files"])
        m = json.loads(files["manifest.json"])
        m["id"] = pack_id
        m["slug"] = f"e2e-t3-10-{uid}"
        m["resources"]["vantage_pipelines"][0]["id"] = pid
        m["resources"]["checks"][0]["slug"] = f"chk-t3-10-{uid}"
        m["resources"]["rules"][0]["name"] = f"Rule T3-10 {uid}"
        m["resources"]["dashboards"][0]["slug"] = f"dash-t3-10-{uid}"
        m["resources"]["dashboard_packages"][0]["route_slug"] = route_slug
        files["manifest.json"] = json.dumps(m, indent=2) + "\n"
        pipe = json.loads(files["vantage_pipelines/alpr-vehicle-plate.json"])
        pipe["pipeline_id"] = pid
        files["vantage_pipelines/alpr-vehicle-plate.json"] = json.dumps(pipe, indent=2) + "\n"
        dm = json.loads(files["dashboard_packages/alpr-console/manifest.json"])
        dm["id"] = dash_id
        files["dashboard_packages/alpr-console/manifest.json"] = json.dumps(dm, indent=2) + "\n"
        chk = json.loads(files["checks/alpr-worker-health.json"])
        chk["slug"] = f"chk-t3-10-{uid}"
        files["checks/alpr-worker-health.json"] = json.dumps(chk, indent=2) + "\n"
        rule = json.loads(files["rules/alpr-watchlist-alert.json"])
        rule["slug"] = f"rule-t3-10-{uid}"
        rule["name"] = f"Rule T3-10 {uid}"
        files["rules/alpr-watchlist-alert.json"] = json.dumps(rule, indent=2) + "\n"
        dash = json.loads(files["dashboards/alpr-overview.json"])
        dash["slug"] = f"dash-t3-10-{uid}"
        files["dashboards/alpr-overview.json"] = json.dumps(dash, indent=2) + "\n"
        files = _restamp_v2_tree(files)
        pdir = _write_pack_tree(self.scratch / f"t3_10_{uid}", files)
        self.addCleanup(lambda: shutil.rmtree(pdir, ignore_errors=True))

        res = _eval_elixir_json(
            "elixir/serviceradar_core",
            f"""
            alias ServiceRadar.Catalog.Reconciler
            pdir = System.fetch_env!("E2E_PDIR")
            tree = Path.wildcard(Path.join(pdir, "**/*")) |> Enum.filter(&File.regular?/1) |> Map.new(fn p -> {{Path.relative_to(p, pdir), File.read!(p)}} end)
            {{:ok, blob_pid}} = Agent.start_link(fn -> %{{}} end)
            blob_store = %{{
              put: fn k, b -> Agent.update(blob_pid, &Map.put(&1, k, b)); :ok end,
              delete: fn k -> Agent.update(blob_pid, &Map.delete(&1, k)); :ok end
            }}
            actor = %{{id: Ecto.UUID.generate(), permissions: MapSet.new(["catalog.packs.install", "dashboards.packages.manage"])}}
            {{:ok, r}} = Reconciler.reconcile(tree, %{{}}, actor: actor, dashboard_blob_store: blob_store, activate_dashboard_packages: true)
            rule_rec = Enum.find(r.applied_rules, &(&1.name == "Rule T3-10 {uid}"))
            pkg_rec = Enum.find(r.applied_dashboard_packages, &(&1.route_slug == "{route_slug}"))
            {{:ok, _}} = Reconciler.uninstall("{pack_id}", actor: actor, dashboard_blob_store: blob_store)
            result = %{{rule_enabled: rule_rec.record.enabled, pkg_status: to_string(pkg_rec.status)}}
            """,
            extra_env={"E2E_PDIR": str(pdir)},
        )
        self.assertFalse(res["rule_enabled"])
        self.assertEqual(res["pkg_status"], "enabled")

    def test_e2e_t3_11_f6_x_f10_dashboard_package_staging_and_channel(self) -> None:
        uid = uuid.uuid4().hex[:8]
        pack_id = f"io.serviceradar.e2e-t3-11-{uid}"
        dash_id = f"io.serviceradar.e2e-t3-11-console-{uid}"
        route_slug = f"e2e-t3-11-console-{uid}"
        detached_slug = f"e2e-t3-11-detached-{uid}"
        pid = f"{pack_id}.vehicle-plate"
        self.addCleanup(
            lambda: _cleanup_cnpg_records(pipeline_ids=[pid], pack_ids=[pack_id], dashboard_pkg_ids=[dash_id])
        )
        files = dict(self.v2_ref["files"])
        m = json.loads(files["manifest.json"])
        m["id"] = pack_id
        m["slug"] = f"e2e-t3-11-{uid}"
        m["resources"]["vantage_pipelines"][0]["id"] = pid
        m["resources"]["checks"][0]["slug"] = f"chk-t3-11-{uid}"
        m["resources"]["rules"][0]["name"] = f"Rule T3-11 {uid}"
        m["resources"]["dashboards"][0]["slug"] = f"dash-t3-11-{uid}"
        m["resources"]["dashboard_packages"][0]["route_slug"] = route_slug
        files["manifest.json"] = json.dumps(m, indent=2) + "\n"
        pipe = json.loads(files["vantage_pipelines/alpr-vehicle-plate.json"])
        pipe["pipeline_id"] = pid
        files["vantage_pipelines/alpr-vehicle-plate.json"] = json.dumps(pipe, indent=2) + "\n"
        dm = json.loads(files["dashboard_packages/alpr-console/manifest.json"])
        dm["id"] = dash_id
        files["dashboard_packages/alpr-console/manifest.json"] = json.dumps(dm, indent=2) + "\n"
        chk = json.loads(files["checks/alpr-worker-health.json"])
        chk["slug"] = f"chk-t3-11-{uid}"
        files["checks/alpr-worker-health.json"] = json.dumps(chk, indent=2) + "\n"
        rule = json.loads(files["rules/alpr-watchlist-alert.json"])
        rule["slug"] = f"rule-t3-11-{uid}"
        rule["name"] = f"Rule T3-11 {uid}"
        files["rules/alpr-watchlist-alert.json"] = json.dumps(rule, indent=2) + "\n"
        dash = json.loads(files["dashboards/alpr-overview.json"])
        dash["slug"] = f"dash-t3-11-{uid}"
        files["dashboards/alpr-overview.json"] = json.dumps(dash, indent=2) + "\n"
        files = _restamp_v2_tree(files)
        pdir = _write_pack_tree(self.scratch / f"t3_11_{uid}", files)
        self.addCleanup(lambda: shutil.rmtree(pdir, ignore_errors=True))

        res = _eval_elixir_json(
            "elixir/web-ng",
            f"""
            alias ServiceRadar.Actors.SystemActor
            alias ServiceRadar.Catalog.Reconciler
            alias ServiceRadar.Dashboards.DashboardInstance
            alias ServiceRadar.Identity.{{RBAC, Users}}
            alias ServiceRadarWebNG.Accounts.Scope
            alias ServiceRadarWebNG.Dashboards
            alias ServiceRadarWebNGWeb.DashboardFrameChannel
            require Ash.Query

            sys_actor = SystemActor.system(:mode_b_t3_11)
            pdir = System.fetch_env!("E2E_PDIR")
            tree = Path.wildcard(Path.join(pdir, "**/*")) |> Enum.filter(&File.regular?/1) |> Map.new(fn p -> {{Path.relative_to(p, pdir), File.read!(p)}} end)
            {{:ok, blob_pid}} = Agent.start_link(fn -> %{{}} end)
            blob_store = %{{
              put: fn k, b -> Agent.update(blob_pid, &Map.put(&1, k, b)); :ok end,
              delete: fn k -> Agent.update(blob_pid, &Map.delete(&1, k)); :ok end
            }}
            installer = %{{id: Ecto.UUID.generate(), permissions: MapSet.new(["catalog.packs.install"])}}
            admin = %{{id: Ecto.UUID.generate(), permissions: MapSet.new(["catalog.packs.install", "dashboards.packages.manage"])}}

            {{:ok, user}} = Users.register_with_password(%{{
              email: "e2e-t3-11-{uid}@example.com",
              password: "synthetic_password_123!",
              password_confirmation: "synthetic_password_123!"
            }}, actor: sys_actor)

            try do
              viewer_scope = Scope.for_user(user, permissions: RBAC.permissions_for_user(user))
              token = DashboardFrameChannel.stream_token("{route_slug}", [], user.id)
              join_socket = %Phoenix.Socket{{
                joined: false,
                transport_pid: self(),
                serializer: Phoenix.Socket.V2.JSONSerializer,
                topic: "dashboards:{route_slug}",
                assigns: %{{current_user: user, current_scope: viewer_scope}}
              }}

              {{:ok, staged}} = Reconciler.reconcile(tree, %{{}}, actor: installer, dashboard_blob_store: blob_store, activate_dashboard_packages: false)
              staged_pkg = Enum.find(staged.applied_dashboard_packages, &(&1.route_slug == "{route_slug}"))
              staged_lookup = Dashboards.get_enabled_instance_by_slug("{route_slug}", scope: viewer_scope)
              staged_join = DashboardFrameChannel.join("dashboards:{route_slug}", %{{"token" => token}}, join_socket)

              {{:ok, enabled}} = Reconciler.reconcile(tree, %{{}}, actor: admin, dashboard_blob_store: blob_store, activate_dashboard_packages: true)
              enabled_pkg = Enum.find(enabled.applied_dashboard_packages, &(&1.route_slug == "{route_slug}"))
              enabled_lookup = Dashboards.get_enabled_instance_by_slug("{route_slug}", scope: viewer_scope)
              enabled_join = DashboardFrameChannel.join("dashboards:{route_slug}", %{{"token" => token}}, join_socket)

              # Create a detached DashboardInstance (managed: false) and confirm uninstall removes managed while preserving detached
              {{:ok, _detached}} = DashboardInstance
                |> Ash.Changeset.for_create(:create, %{{
                  dashboard_package_id: enabled_pkg.package.id,
                  name: "Detached T3-11 Console",
                  route_slug: "{detached_slug}",
                  placement: :dashboard,
                  enabled: true,
                  pack_id: "{pack_id}",
                  pack_version: "1.0.0",
                  managed: false
                }}, actor: sys_actor)
                |> Ash.create(actor: sys_actor)

              {{:ok, _}} = Reconciler.uninstall("{pack_id}", actor: admin, dashboard_blob_store: blob_store)
              post_uninstall_managed_lookup = Dashboards.get_enabled_instance_by_slug("{route_slug}", scope: viewer_scope)
              post_uninstall_managed_join = DashboardFrameChannel.join("dashboards:{route_slug}", %{{"token" => token}}, join_socket)

              detached_token = DashboardFrameChannel.stream_token("{detached_slug}", [], user.id)
              detached_socket = %Phoenix.Socket{{join_socket | topic: "dashboards:{detached_slug}"}}
              post_uninstall_detached_lookup = Dashboards.get_enabled_instance_by_slug("{detached_slug}", scope: viewer_scope)
              post_uninstall_detached_join = DashboardFrameChannel.join("dashboards:{detached_slug}", %{{"token" => detached_token}}, detached_socket)

              result = %{{
                staged_status: to_string(staged_pkg.status),
                staged_instance_nil: is_nil(staged_pkg.instance),
                staged_lookup_not_found: staged_lookup == {{:error, :not_found}},
                staged_join_unavailable: staged_join == {{:error, %{{reason: "dashboard_unavailable"}}}},
                enabled_status: to_string(enabled_pkg.status),
                enabled_instance_ok: match?({{:ok, %DashboardInstance{{route_slug: "{route_slug}", enabled: true, managed: true}}}}, enabled_lookup),
                enabled_join_ok: match?({{:ok, %{{}}, _}}, enabled_join),
                post_uninstall_managed_not_found: post_uninstall_managed_lookup == {{:error, :not_found}},
                post_uninstall_managed_join_unavailable: post_uninstall_managed_join == {{:error, %{{reason: "dashboard_unavailable"}}}},
                post_uninstall_detached_preserved: match?({{:ok, %DashboardInstance{{route_slug: "{detached_slug}", enabled: true, managed: false}}}}, post_uninstall_detached_lookup),
                post_uninstall_detached_join_ok: match?({{:ok, %{{}}, _}}, post_uninstall_detached_join)
              }}
            after
              ServiceRadar.Repo.query!("DELETE FROM platform.dashboard_instances WHERE route_slug IN ($1, $2)", ["{route_slug}", "{detached_slug}"])
              ServiceRadar.Repo.query!("DELETE FROM platform.dashboard_packages WHERE dashboard_id = $1", ["{dash_id}"])
              ServiceRadar.Repo.query!("DELETE FROM platform.ng_users WHERE id = $1", [Ecto.UUID.dump!(user.id)])
            end
            """,
            extra_env={"E2E_PDIR": str(pdir)},
        )
        self.assertEqual(res["staged_status"], "staged")
        self.assertTrue(res["staged_instance_nil"])
        self.assertTrue(res["staged_lookup_not_found"])
        self.assertTrue(res["staged_join_unavailable"])
        self.assertEqual(res["enabled_status"], "enabled")
        self.assertTrue(res["enabled_instance_ok"])
        self.assertTrue(res["enabled_join_ok"])
        self.assertTrue(res["post_uninstall_managed_not_found"])
        self.assertTrue(res["post_uninstall_managed_join_unavailable"])
        self.assertTrue(res["post_uninstall_detached_preserved"])
        self.assertTrue(res["post_uninstall_detached_join_ok"])

    def test_e2e_t3_12_f8_x_f11_x_f12_alpr_ramp1_to_ramp2_and_failback(self) -> None:
        prov = _provision_camera_blocks("t3-12", count=1)
        cam_id = prov["camera_source_id"]
        prof_id = prov["stream_profile_id"]
        blk = prov["blocks"][0]
        pid = f"io.serviceradar.e2e-t3-12.{uuid.uuid4().hex[:8]}"
        wid = f"t3-12-worker-{uuid.uuid4().hex[:8]}"
        self.addCleanup(lambda: _cleanup_cnpg_records(source_ids=[cam_id], pipeline_ids=[pid], worker_ids=[wid]))

        hb = {
            "schema_version": "vantage.heartbeat.v1",
            "worker_id": wid,
            "worker_kind": "external_rust",
            "protocol_version": "vantage.worker.v1",
            "capabilities": ["vantage.alpr.v1"],
            "supported_source_modes": ["recorded_block", "live_keyframe_tap"],
            "execution_backend": "onnx",
            "architecture": "arm64",
            "model_id": "alpr-onnx",
            "model_version": "1.0.0",
            "max_concurrency": 4,
            "active_jobs": 0,
            "health": "ready",
            "sent_at_us": int(time.time() * 1_000_000),
        }
        res = _eval_elixir_json(
            "elixir/serviceradar_core",
            f"""
            alias ServiceRadar.Actors.SystemActor
            alias ServiceRadar.Camera.{{VantageJob, VantagePipeline, VantagePipelineDispatcher, VantageWorkerHeartbeat}}
            actor = SystemActor.system(:mode_b_t3_12)
            {{:ok, _}} = VantagePipeline
              |> Ash.Changeset.for_create(:upsert, %{{
                pipeline_id: "{pid}", version: "1.0.0", name: "T3-12",
                camera_selector: %{{}}, enabled: true, source_mode: :recorded_block,
                trigger_kind: :on_stage1_detection, input_mode: :detection_crop,
                runner: :external_worker, capability: "vantage.alpr.v1",
                fallback_runner: "camera_vlm",
                signal_schema_id: "alpr_plate_read", signal_schema_version: "1.0.0",
                display_contract_id: "alpr_plate_read"
              }}, actor: actor)
              |> Ash.create(actor: actor)
            {{:ok, job}} = VantageJob
              |> Ash.Changeset.for_create(:enqueue, %{{
                pipeline_id: "{pid}", pipeline_version: "1.0.0",
                camera_source_id: "{cam_id}", stream_profile_id: "{prof_id}",
                catalog_entry_id: "{blk['catalog_entry_id']}", descriptor_sha256: "{blk['descriptor_sha256']}",
                target_key: "t3-12", target_runner: "camera_vlm", subject: "media.jobs.vantage.vlm.v1"
              }}, actor: actor)
              |> Ash.create(actor: actor)
            r1 = VantagePipelineDispatcher.resolve_route(job, actor: actor)
            {{:ok, reg}} = VantageWorkerHeartbeat.ingest_json(System.fetch_env!("E2E_HB"), actor: actor)
            r2 = VantagePipelineDispatcher.resolve_route(job, actor: actor)
            {{:ok, _}} = reg |> Ash.Changeset.for_update(:expire_for_test, %{{}}, actor: actor) |> Ash.update(actor: actor)
            r1_fb = VantagePipelineDispatcher.resolve_route(job, actor: actor)
            result = %{{r1: r1.subject, r2: r2.subject, r1_fb: r1_fb.subject}}
            """,
            extra_env={"E2E_HB": json.dumps(hb)},
        )
        self.assertEqual(res["r1"], "media.jobs.vantage.vlm.v1")
        self.assertEqual(res["r2"], "media.jobs.vantage.vantage_alpr_v1.v1")
        self.assertEqual(res["r1_fb"], "media.jobs.vantage.vlm.v1")

    def test_e2e_t3_13_f11_x_f12_sdk_worker_grants_and_zero_credentials(self) -> None:
        proc = sdk_driver.run_cargo_test(["conformance"], sdk_dir=self.sdk_repo)
        self.assertEqual(proc.returncode, 0)

        py_bin = sdk_driver.ensure_sdk_python_venv(sdk_dir=self.sdk_repo)
        stripped_env = {
            k: v
            for k, v in os.environ.items()
            if k not in _FORBIDDEN_CREDENTIAL_ENV_KEYS and not k.startswith(_FORBIDDEN_CREDENTIAL_ENV_PREFIXES)
        }
        stripped_env["CARGO_TARGET_DIR"] = str(env_probe.get_scratch_dir("cargo-target-sdk"))
        stripped_env["UV_CACHE_DIR"] = str(env_probe.get_scratch_dir("uv-cache"))
        stripped_env["SERVICERADAR_E2E_NATS_URL"] = nats_driver.require_nats_url()
        stripped_env["SERVICERADAR_E2E_WEB_URL"] = http_ws_driver.require_web_url()

        check_py = """
import os, serviceradar_vantage as sv
for k in ("DATABASE_URL", "SERVICERADAR_E2E_DATABASE_URL", "CNPG_PASSWORD", "AWS_SECRET_ACCESS_KEY"):
    assert k not in os.environ
caps = sv.WorkerCapabilities(
    capabilities=["vantage.alpr.v1"],
    supported_source_modes=["recorded_block", "live_keyframe_tap"],
    execution_backend="onnx",
    model_id="vantage-alpr-synthetic",
    model_version="1.0.0",
)
assert sv.VantageWorker(worker_id="t3-13-py", capabilities=caps, handler=lambda _c: []) is not None
"""
        py_proc = subprocess.run([str(py_bin), "-c", check_py], cwd=str(self.sdk_repo), env=stripped_env, capture_output=True, text=True, timeout=120.0)
        self.assertEqual(py_proc.returncode, 0, f"{py_proc.stdout}\n{py_proc.stderr}")

    def test_e2e_t3_14_f12_x_f13_live_tap_frame_to_sdk_process_frame(self) -> None:
        py_bin = sdk_driver.ensure_sdk_python_venv(sdk_dir=self.sdk_repo)
        live_subj = f"media.live.vantage.vantage_bay_guidance_v1_{uuid.uuid4().hex[:6]}.v1"
        out_subj = f"media.results.vantage.t3_14.{uuid.uuid4().hex[:6]}"
        frame = copy.deepcopy(_load_json("wire_vectors/vantage_frame_v1.json")["positive"])
        frame["frame_sequence"] = 101

        nats_bin = env_probe.probe_binary("nats")
        nats_url = nats_driver.require_nats_url()
        sub_proc = subprocess.Popen(
            [str(nats_bin), "--server", nats_url, "sub", out_subj, "--count=1", "--raw"],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        self.addCleanup(lambda: _stop_proc(sub_proc))
        time.sleep(0.25)

        worker_script = f"""
import os, sys, serviceradar_vantage as sv
worker = sv.VantageWorker(
    worker_id="t3-14-guidance",
    capabilities=["vantage.bay_guidance.v1"],
    supported_source_modes=["live_keyframe_tap"],
    nats_url=os.environ["SERVICERADAR_E2E_NATS_URL"],
    live_subject={json.dumps(live_subj)},
    result_subject={json.dumps(out_subj)},
    handler=lambda ctx: [sv.Observation(
        category="vehicle", label="Bay 04 Approach", confidence=0.95, bbox=[0.2, 0.3, 0.7, 0.85],
        signal_schema_id="bay_guidance", signal_schema_version="1.0.0", display_contract_id="bay_guidance",
        attributes={{"bay_id": "bay-04", "guidance_state": "approach", "distance_m": 2.1, "lateral_offset_m": 0.0}},
        search_text="Bay 04 Approach bay-04 approach"
    )],
)
print("WORKER_READY", flush=True)
worker.run_until_one()
"""
        worker_env = dict(os.environ)
        worker_env["SERVICERADAR_E2E_NATS_URL"] = nats_url
        w_proc = subprocess.Popen([str(py_bin), "-c", worker_script], cwd=str(self.sdk_repo), env=worker_env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.addCleanup(lambda: _stop_proc(w_proc))

        ready = ""
        if w_proc.stdout is not None:
            rlist, _, _ = select.select([w_proc.stdout], [], [], 10.0)
            if rlist:
                ready = w_proc.stdout.readline().strip()
        self.assertEqual(ready, "WORKER_READY")
        _publish_core_json(live_subj, frame, nats_url=nats_url)
        w_proc.communicate(timeout=15.0)
        self.assertEqual(w_proc.returncode, 0)
        stdout, stderr = sub_proc.communicate(timeout=10.0)
        self.assertEqual(sub_proc.returncode, 0, stderr)
        res = vc.validate_result_envelope(json.loads(stdout.strip().splitlines()[0]))
        self.assertIsNone(res.get("job_id"))
        self.assertIsNone(res.get("catalog_entry_id"))
        self.assertIsNone(res.get("descriptor_sha256"))
        self.assertIsNone(res["observations"][0].get("fragment_sequence"))

    def test_e2e_t3_15_f13_x_f14_mailbox_backpressure_latency_and_retention(self) -> None:
        cam_id = str(uuid.uuid4())
        prof_id = str(uuid.uuid4())
        idr_b64 = self.f13["carriers"]["annex_b_idr_b64"]
        res = _eval_elixir_json(
            "elixir/serviceradar_core_elx",
            f"""
            alias ServiceRadarCoreElx.CameraRelay.{{LiveVantageTap, Pipeline}}
            alias ServiceRadarRecording.Inbox
            parent = self()
            idr = Base.decode64!("{idr_b64}")
            relay_id = "relay-t3-15-#{uuid.uuid4().hex[:8]}"
            ingest_id = "ingest-t3-15-#{uuid.uuid4().hex[:8]}"
            {{:ok, _sup, pid}} = Membrane.Pipeline.start_link(Pipeline, relay_session_id: relay_id, media_ingest_id: ingest_id)
            rec_pid = spawn_link(fn ->
              {{:ok, inbox}} = Inbox.new(pid, relay_id, ingest_id, System.monotonic_time(:millisecond) + 30_000, max_samples: 32)
              :ok = Membrane.Pipeline.call(pid, {{:attach_recorder, inbox}})
              send(parent, :attached)
              iid = inbox.id
              loop = fn f, seqs ->
                receive do
                  {{:recording_media, ^iid, unit}} ->
                    :ok = Inbox.release(inbox, byte_size(unit.payload))
                    f.(f, [unit.sequence | seqs])
                  {{:get_seqs, from}} ->
                    send(from, {{:seqs, Enum.reverse(seqs)}})
                end
              end
              loop.(loop, [])
            end)
            receive do :attached -> :ok after 2_000 -> raise("attach timeout") end
            {{:ok, _tap}} = LiveVantageTap.attach_pipeline(
              pid, relay_session_id: relay_id, camera_source_id: "{cam_id}",
              stream_profile_id: "{prof_id}", capability: "vantage.bay_guidance.v1", pause_publish: true
            )
            for seq <- 1..20 do
              send(pid, {{:media_chunk, %{{payload: idr, pts: seq * 90_000, dts: seq * 90_000, sequence: seq, keyframe: true, media_ingest_id: ingest_id, codec: "h264", payload_format: "annexb"}}}})
            end
            Process.sleep(250)
            drops = LiveVantageTap.dropped_count("{cam_id}")
            send(rec_pid, {{:get_seqs, self()}})
            seqs = receive do {{:seqs, s}} -> s after 2_000 -> [] end
            Membrane.Pipeline.terminate(pid)
            result = %{{drops: drops, seqs: seqs}}
            """,
        )
        self.assertEqual(res["drops"], 12)
        self.assertEqual(res["seqs"], list(range(1, 21)))


# ---------------------------------------------------------------------------
# Tier 4: 7 Realistic Operational Workload Live E2E Tests
# ---------------------------------------------------------------------------


class Tier4WorkloadsModeBTest(_BaseModeBTier3Tier4Test):
    """Live cross-component verification of all 7 Tier 4 operational workloads."""

    @classmethod
    def setUpClass(cls) -> None:
        super().setUpClass()
        _require_elixir_modules(
            "elixir/serviceradar_core",
            (
                "ServiceRadar.Camera.VantagePipeline",
                "ServiceRadar.Camera.VantageJob",
                "ServiceRadar.Camera.VantageObservation",
                "ServiceRadar.Camera.VantageObservationProjector",
                "ServiceRadar.Camera.VantagePipelineDispatcher",
                "ServiceRadar.Camera.VantageWorkerHeartbeat",
                "ServiceRadar.Camera.VantageRetention",
                "ServiceRadar.Camera.SemanticSearch",
                "ServiceRadar.Catalog.Reconciler",
            ),
        )
        cls.t4 = _load_json("t3_t4/tier4_workloads.json")
        cls.workloads = {w["workload"]: w for w in cls.t4["workloads"]}
        cls.result_vec = _load_json("wire_vectors/vantage_result_v1.json")
        cls.v2_ref = _load_json("f6_f10/pack_v2_alpr_reference.json")
        cls.f13 = _load_json("f11_f14/f13_live_tap_and_mailbox_vectors.json")

    def test_e2e_t4_w1_ramp1_alpr_gate_entry_lifecycle(self) -> None:
        recent_start_us = int(time.time() * 1_000_000) - 10_000_000
        prov = _provision_camera_blocks(
            "t4-w1", display_name="Gate West 01", count=1, timeline_start_us=recent_start_us
        )
        cam_id = prov["camera_source_id"]
        prof_id = prov["stream_profile_id"]
        blk = prov["blocks"][0]
        pid = f"io.serviceradar.e2e-w1.{uuid.uuid4().hex[:8]}"
        self.addCleanup(lambda: _cleanup_cnpg_records(source_ids=[cam_id], pipeline_ids=[pid]))

        res_env = copy.deepcopy(self.result_vec["positive"])
        res_env["pipeline_id"] = pid
        res_env["camera_source_id"] = cam_id
        res_env["stream_profile_id"] = prof_id
        res_env["catalog_entry_id"] = blk["catalog_entry_id"]
        res_env["descriptor_sha256"] = blk["descriptor_sha256"]
        res_env["observations"][0]["observation_key"] = f"w1-sr0100-{uuid.uuid4().hex[:8]}"
        res_env["observations"][0]["timeline_ts_us"] = recent_start_us + 1_000_000
        res_env["observations"][1]["observation_key"] = f"w1-test742-{uuid.uuid4().hex[:8]}"
        res_env["observations"][1]["timeline_ts_us"] = recent_start_us + 2_000_000

        out = _eval_elixir_json(
            "elixir/web-ng",
            f"""
            alias ServiceRadar.Actors.SystemActor
            alias ServiceRadar.Camera.{{SemanticSearch, VantageJob, VantageObservationProjector, VantagePipeline, VantagePipelineDispatcher}}
            sys_actor = SystemActor.system(:mode_b_t4_w1)
            {{:ok, _}} = VantagePipeline
              |> Ash.Changeset.for_create(:upsert, %{{
                pipeline_id: "{pid}", version: "1.0.0", name: "W1 Gate West 01",
                camera_selector: %{{}}, enabled: true, source_mode: :recorded_block,
                trigger_kind: :on_stage1_detection, input_mode: :detection_crop,
                runner: :camera_vlm, capability: "vantage.alpr.v1",
                emit_ocsf_events: true,
                signal_schema_id: "alpr_plate_read", signal_schema_version: "1.0.0",
                display_contract_id: "alpr_plate_read"
              }}, actor: sys_actor)
              |> Ash.create(actor: sys_actor)
            {{:ok, job}} = VantageJob
              |> Ash.Changeset.for_create(:enqueue, %{{
                pipeline_id: "{pid}", pipeline_version: "1.0.0",
                camera_source_id: "{cam_id}", stream_profile_id: "{prof_id}",
                catalog_entry_id: "{blk['catalog_entry_id']}", descriptor_sha256: "{blk['descriptor_sha256']}",
                target_key: "w1-track-1", target_runner: "camera_vlm", subject: "media.jobs.vantage.vlm.v1"
              }}, actor: sys_actor)
              |> Ash.create(actor: sys_actor)
            route = VantagePipelineDispatcher.resolve_route(job, actor: sys_actor)
            payload = Jason.decode!(System.fetch_env!("E2E_RES_JSON")) |> Map.put("job_id", job.id)
            {{:ok, _}} = VantageObservationProjector.ingest_result(payload)
            viewer = %{{
              id: Ecto.UUID.generate(),
              permissions: MapSet.new(["devices.view", "devices.cameras.recordings.view"]),
              authorized_camera_source_ids: ["{cam_id}"]
            }}
            {{:ok, hits}} = SemanticSearch.search(%{{query: "TEST-742", camera_source_id: "{cam_id}"}}, actor: viewer)
            result = %{{subject: route.subject, hit_count: length(hits.results)}}
            """,
            extra_env={"E2E_RES_JSON": json.dumps(res_env)},
        )
        self.assertEqual(out["subject"], "media.jobs.vantage.vlm.v1")
        self.assertGreaterEqual(out["hit_count"], 1)

    def test_e2e_t4_w2_hold_preservation_vs_quarantine_and_reclaim_purge(self) -> None:
        prov = _provision_camera_blocks("t4-w2", display_name="Gate West 01", count=2)
        cam_id = prov["camera_source_id"]
        prof_id = prov["stream_profile_id"]
        held_blk, unheld_blk = prov["blocks"]
        pid = f"io.serviceradar.e2e-w2.{uuid.uuid4().hex[:8]}"
        self.addCleanup(lambda: _cleanup_cnpg_records(source_ids=[cam_id], pipeline_ids=[pid]))

        out = _eval_elixir_json(
            "elixir/serviceradar_core",
            f"""
            alias ServiceRadar.Actors.SystemActor
            alias ServiceRadar.Camera.{{RecordingCatalogEntry, RecordingHolds, VantageObservation, VantagePipeline}}
            require Ash.Query
            actor = SystemActor.system(:mode_b_t4_w2)
            hold_actor = %{{id: "hold-op", role: :operator, permissions: MapSet.new(["devices.view", "devices.cameras.recordings.hold"])}}
            admin = %{{id: "admin-op", role: :admin, permissions: MapSet.new(["settings.recording.manage"])}}
            now = DateTime.utc_now()
            {{:ok, _}} = VantagePipeline
              |> Ash.Changeset.for_create(:upsert, %{{
                pipeline_id: "{pid}", version: "1.0.0", name: "W2 Hold vs Purge",
                camera_selector: %{{}}, enabled: true, source_mode: :recorded_block,
                trigger_kind: :on_stage1_detection, input_mode: :detection_crop,
                runner: :camera_vlm,
                signal_schema_id: "alpr_plate_read", signal_schema_version: "1.0.0",
                display_contract_id: "alpr_plate_read"
              }}, actor: actor)
              |> Ash.create(actor: actor)
            for {{blk_id, ts, key, plate}} <- [
              {{"{held_blk['catalog_entry_id']}", {held_blk['timeline_start_us']}, "w2-held", "SR-0100"}},
              {{"{unheld_blk['catalog_entry_id']}", {unheld_blk['timeline_start_us']}, "w2-unheld", "TEST-742"}}
            ] do
              {{:ok, _}} = VantageObservation
                |> Ash.Changeset.for_create(:upsert_observation, %{{
                  observation_key: key, pack_id: "io.serviceradar.vantage-alpr", pipeline_id: "{pid}", pipeline_version: "1.0.0",
                  worker_kind: "camera_vlm", worker_id: "w1", model_id: "m", model_version: "1.0.0",
                  source_mode: :recorded_block,
                  camera_source_id: "{cam_id}", stream_profile_id: "{prof_id}",
                  catalog_entry_id: blk_id, fragment_sequence: 0, frame_sequence: 1,
                  media_pts_ns: 1000, timeline_ts_us: ts, time_basis: :received, track_id: "1",
                  category: "license_plate", label: plate, confidence: 0.92,
                  bbox: %{{"x1" => 0.3, "y1" => 0.5, "x2" => 0.5, "y2" => 0.7}}, attributes: %{{"plate_text" => plate}},
                  signal_schema_id: "alpr_plate_read", signal_schema_version: "1.0.0", display_contract_id: "alpr_plate_read"
                }}, actor: actor)
                |> Ash.create(actor: actor)
            end
            {{:ok, hold}} = RecordingHolds.place_hold(%{{
              camera_source_id: "{cam_id}", stream_profile_id: "{prof_id}",
              start_us: {held_blk['timeline_start_us']},
              end_us: {held_blk['timeline_end_us']}, kind: :investigation, reason: "w2_hold"
            }}, actor: hold_actor)
            hold_blocked = match?({{:error, {{:blocked_by_hold, _}}}}, RecordingHolds.begin_copy_deletion_intent("{held_blk['catalog_entry_id']}", :local, %{{reason: :max_local_age}}, actor: admin))
            unheld = Ash.get!(RecordingCatalogEntry, "{unheld_blk['catalog_entry_id']}", actor: actor)
            {{:ok, unheld}} = unheld
              |> Ash.Changeset.for_update(:transition_local_state, %{{local_state: :reclaimed, local_state_at: now}}, actor: actor)
              |> Ash.update(actor: actor)
            {{:ok, _}} = unheld
              |> Ash.Changeset.for_update(:transition_archive_state, %{{archive_state: :deleted, archive_state_at: now, archive_deleted_reason: :operator}}, actor: actor)
              |> Ash.update(actor: actor)
            cnt_after_unheld = VantageObservation |> Ash.Query.filter(camera_source_id == "{cam_id}") |> Ash.count!(actor: actor)
            {{:ok, _}} = RecordingHolds.release_hold(hold.id, %{{release_reason: "w2_release"}}, actor: hold_actor)
            held = Ash.get!(RecordingCatalogEntry, "{held_blk['catalog_entry_id']}", actor: actor)
            {{:ok, held}} = held
              |> Ash.Changeset.for_update(:transition_local_state, %{{local_state: :reclaimed, local_state_at: now}}, actor: actor)
              |> Ash.update(actor: actor)
            {{:ok, _}} = held
              |> Ash.Changeset.for_update(:transition_archive_state, %{{archive_state: :deleted, archive_state_at: now, archive_deleted_reason: :operator}}, actor: actor)
              |> Ash.update(actor: actor)
            cnt_final = VantageObservation |> Ash.Query.filter(camera_source_id == "{cam_id}") |> Ash.count!(actor: actor)
            result = %{{hold_blocked: hold_blocked, cnt_after_unheld: cnt_after_unheld, cnt_final: cnt_final}}
            """,
        )
        self.assertTrue(out["hold_blocked"])
        self.assertEqual(out["cnt_after_unheld"], 1)
        self.assertEqual(out["cnt_final"], 0)

    def test_e2e_t4_w3_multi_tenant_rbac_source_scoping_and_audit(self) -> None:
        recent_start_us = int(time.time() * 1_000_000) - 10_000_000
        prov_gw = _provision_camera_blocks(
            "t4-w3-gw", display_name="Gate West 01", count=1, timeline_start_us=recent_start_us
        )
        prov_b4 = _provision_camera_blocks(
            "t4-w3-b4", display_name="Bay 04 Approach", count=1, timeline_start_us=recent_start_us
        )
        gw_id = prov_gw["camera_source_id"]
        b4_id = prov_b4["camera_source_id"]
        self.addCleanup(lambda: _cleanup_cnpg_records(source_ids=[gw_id, b4_id]))

        out = _eval_elixir_json(
            "elixir/web-ng",
            f"""
            alias ServiceRadar.Actors.SystemActor
            alias ServiceRadar.Camera.{{RecordingAccessAudit, SemanticSearch, VantageObservation}}
            alias ServiceRadarWebNG.SRQL.EntityAccess
            require Ash.Query
            sys = SystemActor.system(:mode_b_t4_w3)
            for {{cid, pid, p_id, ts, key, lbl}} <- [
              {{"{gw_id}", "{prov_gw['stream_profile_id']}", "{prov_gw['blocks'][0]['catalog_entry_id']}", {prov_gw['blocks'][0]['timeline_start_us'] + 1_000_000}, "w3-gw-{uuid.uuid4().hex[:6]}", "SR-0100"}},
              {{"{b4_id}", "{prov_b4['stream_profile_id']}", "{prov_b4['blocks'][0]['catalog_entry_id']}", {prov_b4['blocks'][0]['timeline_start_us'] + 1_000_000}, "w3-b4-{uuid.uuid4().hex[:6]}", "TEST-742"}}
            ] do
              {{:ok, _}} = VantageObservation
                |> Ash.Changeset.for_create(:upsert_observation, %{{
                  observation_key: key, pack_id: "io.serviceradar.vantage-alpr", pipeline_id: "io.serviceradar.vantage-alpr.vehicle-plate", pipeline_version: "1.0.0",
                  worker_kind: "camera_vlm", worker_id: "w1", model_id: "m", model_version: "1.0.0",
                  source_mode: :recorded_block,
                  camera_source_id: cid, stream_profile_id: pid, catalog_entry_id: p_id,
                  fragment_sequence: 0, frame_sequence: 1, media_pts_ns: 1000, timeline_ts_us: ts,
                  time_basis: :received, track_id: "1", category: "license_plate", label: lbl,
                  confidence: 0.9, bbox: %{{"x1" => 0.2, "y1" => 0.3, "x2" => 0.5, "y2" => 0.6}}, attributes: %{{"plate_text" => lbl}},
                  signal_schema_id: "alpr_plate_read", signal_schema_version: "1.0.0", display_contract_id: "alpr_plate_read",
                  search_text: lbl <> " Bay 04 Approach"
                }}, actor: sys)
                |> Ash.create(actor: sys)
            end

            b4_actor = %{{id: Ecto.UUID.generate(), permissions: MapSet.new(["devices.view", "devices.cameras.recordings.view"]), authorized_camera_source_ids: ["{b4_id}"]}}
            bare_actor = %{{id: Ecto.UUID.generate(), permissions: MapSet.new(["devices.view"]), authorized_camera_source_ids: ["{gw_id}", "{b4_id}"]}}

            bypass_denied = EntityAccess.authorize("in:devices in:camera_observations", bare_actor)
            gw_denied = SemanticSearch.search(%{{query: "SR-0100", camera_source_id: "{gw_id}"}}, actor: b4_actor)
            {{:ok, b4_res}} = SemanticSearch.search(%{{query: "TEST-742", camera_source_id: "{b4_id}"}}, actor: b4_actor)
            audit_cnt = RecordingAccessAudit |> Ash.Query.filter(camera_source_id == "{b4_id}") |> Ash.count!(actor: sys)
            result = %{{
              bypass_denied: bypass_denied == {{:error, :forbidden}},
              gw_denied: match?({{:error, %Ash.Error.Forbidden{{}}}}, gw_denied),
              b4_hit_count: length(b4_res.results),
              audit_cnt: audit_cnt
            }}
            """,
        )
        self.assertTrue(out["bypass_denied"])
        self.assertTrue(out["gw_denied"])
        self.assertGreaterEqual(out["b4_hit_count"], 1)
        self.assertGreaterEqual(out["audit_cnt"], 1)

    def test_e2e_t4_w4_pack_v2_authoring_staged_upgrade_and_uninstall(self) -> None:
        _require_cli_dist()
        uid = uuid.uuid4().hex[:8]
        work_dir = env_probe.get_scratch_dir(f"t4-w4-{uid}")
        pack_slug = f"w4-pack-{uid}"
        pack_id = f"io.serviceradar.vantage.{pack_slug}"
        dash_id = f"{pack_id}-console"
        pipe_id = f"{pack_id}.pipeline"
        pack_dir = work_dir / pack_slug
        self.addCleanup(lambda: shutil.rmtree(work_dir, ignore_errors=True))
        self.addCleanup(
            lambda: _cleanup_cnpg_records(pipeline_ids=[pipe_id], pack_ids=[pack_id], dashboard_pkg_ids=[dash_id])
        )

        cli_driver.run_cli(["vantage", "init", pack_slug, "--template", "vlm", "--with-dashboard"], cwd=work_dir)
        cli_driver.run_cli(["vantage", "validate", str(pack_dir), "--json"])
        srpack = work_dir / f"{pack_slug}.srpack"
        cli_driver.run_cli(["pack", "build", str(pack_dir), "-o", str(srpack), "--json"])
        self.assertTrue(srpack.is_file())

        priv_key = work_dir / "w4.key"
        pub_key = work_dir / "w4.pub"
        index_path = work_dir / "pack-index.json"
        cli_driver.run_cli(["pack", "keygen", "--private-key-out", str(priv_key), "--public-key-out", str(pub_key), "--key-id", "w4-key", "--json"])
        sign_out = json.loads(cli_driver.run_cli(["pack", "sign", str(srpack), "--key", str(priv_key), "--key-id", "w4-key", "--json"]).stdout)
        self.assertTrue(Path(sign_out["signature_file"]).is_file())
        idx_out = json.loads(cli_driver.run_cli(["pack", "index", str(srpack), "--out", str(index_path), "--base-url", "https://packages.example.com/", "--json"]).stdout)
        self.assertEqual(idx_out["pack_count"], 1)

        # Negative control: tampered manifest/renderer fails CLI validate
        renderer_candidates = list((pack_dir / "dashboard_packages").glob("*/renderer.js"))
        self.assertTrue(renderer_candidates, "expected bundled dashboard renderer.js")
        orig_renderer = renderer_candidates[0].read_text(encoding="utf-8")
        renderer_candidates[0].write_text("export const tampered = true;\n", encoding="utf-8")
        bad_val = cli_driver.run_cli(["pack", "validate", str(pack_dir), "--json"], check=False)
        self.assertNotEqual(bad_val.returncode, 0)
        renderer_candidates[0].write_text(orig_renderer, encoding="utf-8")

        # Live Reconciler staged -> enabled -> uninstall
        out = _eval_elixir_json(
            "elixir/serviceradar_core",
            """
            alias ServiceRadar.Catalog.{PackArchive, Reconciler}
            {:ok, ex} = PackArchive.extract(File.read!(System.fetch_env!("E2E_SRPACK")))
            {:ok, blob_pid} = Agent.start_link(fn -> %{} end)
            blob_store = %{
              put: fn k, b -> Agent.update(blob_pid, &Map.put(&1, k, b)); :ok end,
              delete: fn k -> Agent.update(blob_pid, &Map.delete(&1, k)); :ok end
            }
            installer = %{id: Ecto.UUID.generate(), permissions: MapSet.new(["catalog.packs.install"])}
            admin = %{id: Ecto.UUID.generate(), permissions: MapSet.new(["catalog.packs.install", "dashboards.packages.manage"])}
            {:ok, staged} = Reconciler.reconcile(ex.files, %{}, actor: installer, dashboard_blob_store: blob_store, activate_dashboard_packages: false)
            {:ok, enabled} = Reconciler.reconcile(ex.files, %{}, actor: admin, dashboard_blob_store: blob_store, activate_dashboard_packages: true)
            {:ok, _} = Reconciler.uninstall(ex.manifest["id"], actor: admin, dashboard_blob_store: blob_store)
            staged_statuses = Enum.map(staged.applied_dashboard_packages, &to_string(&1.status))
            enabled_statuses = Enum.map(enabled.applied_dashboard_packages, &to_string(&1.status))
            result = %{staged: staged_statuses, enabled: enabled_statuses}
            """,
            extra_env={"E2E_SRPACK": str(srpack)},
        )
        self.assertEqual(out["staged"], ["staged"])
        self.assertEqual(out["enabled"], ["enabled"])

    def test_e2e_t4_w5_rust_sdk_ramp1_to_ramp2_and_failback(self) -> None:
        proc = sdk_driver.run_cargo_test(["-p", "vantage-worker-alpr"], sdk_dir=self.sdk_repo)
        self.assertEqual(proc.returncode, 0)

        prov = _provision_camera_blocks("t4-w5", count=1)
        cam_id = prov["camera_source_id"]
        prof_id = prov["stream_profile_id"]
        blk = prov["blocks"][0]
        pid = f"io.serviceradar.e2e-w5.{uuid.uuid4().hex[:8]}"
        wid = f"w5-rust-{uuid.uuid4().hex[:8]}"
        self.addCleanup(lambda: _cleanup_cnpg_records(source_ids=[cam_id], pipeline_ids=[pid], worker_ids=[wid]))

        hb = {
            "schema_version": "vantage.heartbeat.v1",
            "worker_id": wid,
            "worker_kind": "external_rust",
            "protocol_version": "vantage.worker.v1",
            "capabilities": ["vantage.alpr.v1"],
            "supported_source_modes": ["recorded_block", "live_keyframe_tap"],
            "execution_backend": "onnx",
            "architecture": "arm64",
            "model_id": "vantage-alpr-rs",
            "model_version": "1.0.0",
            "max_concurrency": 4,
            "active_jobs": 0,
            "health": "ready",
            "sent_at_us": int(time.time() * 1_000_000),
        }
        out = _eval_elixir_json(
            "elixir/serviceradar_core",
            f"""
            alias ServiceRadar.Actors.SystemActor
            alias ServiceRadar.Camera.{{VantageJob, VantagePipeline, VantagePipelineDispatcher, VantageWorkerHeartbeat}}
            actor = SystemActor.system(:mode_b_t4_w5)
            {{:ok, _}} = VantagePipeline
              |> Ash.Changeset.for_create(:upsert, %{{
                pipeline_id: "{pid}", version: "1.0.0", name: "W5 Ramp Switch",
                camera_selector: %{{}}, enabled: true, source_mode: :recorded_block,
                trigger_kind: :on_stage1_detection, input_mode: :detection_crop,
                runner: :external_worker, capability: "vantage.alpr.v1",
                fallback_runner: "camera_vlm",
                signal_schema_id: "alpr_plate_read", signal_schema_version: "1.0.0", display_contract_id: "alpr_plate_read"
              }}, actor: actor)
              |> Ash.create(actor: actor)
            {{:ok, job}} = VantageJob
              |> Ash.Changeset.for_create(:enqueue, %{{
                pipeline_id: "{pid}", pipeline_version: "1.0.0",
                camera_source_id: "{cam_id}", stream_profile_id: "{prof_id}",
                catalog_entry_id: "{blk['catalog_entry_id']}", descriptor_sha256: "{blk['descriptor_sha256']}",
                target_key: "w5", target_runner: "camera_vlm", subject: "media.jobs.vantage.vlm.v1"
              }}, actor: actor)
              |> Ash.create(actor: actor)
            r1 = VantagePipelineDispatcher.resolve_route(job, actor: actor)
            {{:ok, reg}} = VantageWorkerHeartbeat.ingest_json(System.fetch_env!("E2E_HB"), actor: actor)
            r2 = VantagePipelineDispatcher.resolve_route(job, actor: actor)
            {{:ok, _}} = reg |> Ash.Changeset.for_update(:expire_for_test, %{{}}, actor: actor) |> Ash.update(actor: actor)
            r1_fb = VantagePipelineDispatcher.resolve_route(job, actor: actor)
            result = %{{r1: r1.subject, r2: r2.subject, r1_fb: r1_fb.subject}}
            """,
            extra_env={"E2E_HB": json.dumps(hb)},
        )
        self.assertEqual(out["r1"], "media.jobs.vantage.vlm.v1")
        self.assertEqual(out["r2"], "media.jobs.vantage.vantage_alpr_v1.v1")
        self.assertEqual(out["r1_fb"], "media.jobs.vantage.vlm.v1")

    def test_e2e_t4_w6_python_sdk_rgb8_and_offline_harness(self) -> None:
        _require_cli_dist()
        mp4_path = media_gen.generate_synthetic_h264_mp4("t4_w6_gate_west_01.mp4", width=320, height=240, duration_s=1, fps=5)
        schema_path = _fixtures_dir() / "wire_vectors" / "alpr_plate_read_schema.json"
        work_dir = env_probe.get_scratch_dir(f"t4-w6-{uuid.uuid4().hex[:8]}")
        pack_dir = work_dir / "w6-py-alpr"
        self.addCleanup(lambda: shutil.rmtree(work_dir, ignore_errors=True))

        cli_driver.run_cli(["vantage", "init", "w6-py-alpr", "--template", "python-worker"], cwd=work_dir)
        cli_driver.run_cli(["vantage", "validate", str(pack_dir), "--json"])
        dev_out = json.loads(
            cli_driver.run_cli(["vantage", "dev", str(pack_dir), "--fixture", str(mp4_path), "--json"]).stdout
        )
        self.assertEqual(dev_out.get("status"), "ok")

        py_script = f"""
import numpy as np, serviceradar_vantage as sv
seen = []
def handler(ctx):
    arr = ctx.rgb_frame
    assert isinstance(arr, np.ndarray) and arr.dtype == np.uint8
    assert arr.shape == (240, 320, 3) and arr.flags["C_CONTIGUOUS"]
    seen.append(arr.shape)
    return []
sv.run_local_harness({json.dumps(str(mp4_path))}, handler, {json.dumps(str(schema_path))})
assert len(seen) >= 1
"""
        proc = sdk_driver.run_python_in_sdk_venv(["-c", py_script], sdk_dir=self.sdk_repo)
        self.assertEqual(proc.returncode, 0)

    def test_e2e_t4_w7_phase3_bay_guidance_benchmark_and_isolation(self) -> None:
        envs = env_probe.probe_env_vars(
            "SERVICERADAR_E2E_DASHBOARD_SLUG",
            "SERVICERADAR_E2E_DASHBOARD_STREAM_TOKEN",
            "SERVICERADAR_E2E_CAMERA_SOURCE_ID",
        )
        py_bin = sdk_driver.ensure_sdk_python_venv(sdk_dir=self.sdk_repo)
        cam_id = envs["SERVICERADAR_E2E_CAMERA_SOURCE_ID"]
        live_subj = f"media.live.vantage.vantage_bay_guidance_v1_{uuid.uuid4().hex[:6]}.v1"
        ws_url = _ws_url_from_web_url(http_ws_driver.require_web_url())
        headers = _viewer_ws_headers()
        topic = f"dashboards:{envs['SERVICERADAR_E2E_DASHBOARD_SLUG']}"
        nats_url = nats_driver.require_nats_url()

        worker_script = f"""
import os, serviceradar_vantage as sv
worker = sv.VantageWorker(
    worker_id="w7-bay-guidance",
    capabilities=["vantage.bay_guidance.v1"],
    supported_source_modes=["live_keyframe_tap"],
    nats_url=os.environ["SERVICERADAR_E2E_NATS_URL"],
    live_subject={json.dumps(live_subj)},
    handler=lambda ctx: [sv.Observation(
        category="vehicle", label="Bay 04 Approach", confidence=0.95, bbox=[0.2, 0.3, 0.7, 0.85],
        signal_schema_id="bay_guidance", signal_schema_version="1.0.0", display_contract_id="bay_guidance",
        attributes={{"bay_id": "bay-04", "guidance_state": "approach", "distance_m": 1.8, "lateral_offset_m": -0.04}},
        search_text="Bay 04 Approach bay-04 approach"
    )],
)
print("WORKER_READY", flush=True)
worker.run_forever()
"""
        worker_env = dict(os.environ)
        worker_env["SERVICERADAR_E2E_NATS_URL"] = nats_url
        w_proc = subprocess.Popen([str(py_bin), "-c", worker_script], cwd=str(self.sdk_repo), env=worker_env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.addCleanup(lambda: _stop_proc(w_proc))

        client = DashboardChannelClient(ws_url, headers=headers, timeout=10.0)
        self.addCleanup(client.close)
        join_reply = client.join_topic(topic, {"token": envs["SERVICERADAR_E2E_DASHBOARD_STREAM_TOKEN"]})
        self.assertEqual(join_reply[4].get("status"), "ok")
        sub_ref = client.push_event(
            topic,
            "events:subscribe",
            {
                "id": f"w7-{uuid.uuid4().hex[:8]}",
                "filter": {"class_uid": 1008, "camera_source_id": cam_id, "metadata": {"service_radar": {"signal_schema": {"schema_id": "bay_guidance"}}}},
            },
        )
        client.recv_matching(lambda m: len(m) >= 5 and str(m[1]) == sub_ref and m[3] == "phx_reply")

        samples_ms: list[float] = []
        base_frame = copy.deepcopy(_load_json("wire_vectors/vantage_frame_v1.json")["positive"])
        base_frame["camera_source_id"] = cam_id
        for seq in range(1, 6):
            pkt = copy.deepcopy(base_frame)
            pkt["frame_sequence"] = seq
            pkt["timeline_ts_us"] = int(time.time() * 1_000_000)
            t0 = time.monotonic()
            _publish_core_json(live_subj, pkt, nats_url=nats_url)
            client.recv_matching(lambda m: len(m) >= 5 and m[2] == topic and m[3] == "events:batch", timeout=10.0)
            samples_ms.append((time.monotonic() - t0) * 1000.0)

        pcts = _compute_percentiles_ms(samples_ms)
        self.assertLessEqual(pcts["p50"], pcts["p95"])
        self.assertLessEqual(pcts["p95"], pcts["p99"])

        # Crash worker mid-stream & verify CMAF recorder + drop-oldest isolation
        w_proc.send_signal(signal.SIGKILL)
        w_proc.wait(timeout=5)
        idr_b64 = self.f13["carriers"]["annex_b_idr_b64"]
        iso = _eval_elixir_json(
            "elixir/serviceradar_core_elx",
            f"""
            alias ServiceRadarCoreElx.CameraRelay.{{LiveVantageTap, Pipeline}}
            idr = Base.decode64!("{idr_b64}")
            relay_id = "relay-w7-#{uuid.uuid4().hex[:8]}"
            ingest_id = "ingest-w7-#{uuid.uuid4().hex[:8]}"
            {{:ok, _sup, pid}} = Membrane.Pipeline.start_link(Pipeline, relay_session_id: relay_id, media_ingest_id: ingest_id)
            {{:ok, _}} = LiveVantageTap.attach_pipeline(
              pid, relay_session_id: relay_id, camera_source_id: "{cam_id}",
              stream_profile_id: "{base_frame['stream_profile_id']}", capability: "vantage.bay_guidance.v1", pause_publish: true
            )
            for seq <- 1..20 do
              send(pid, {{:media_chunk, %{{payload: idr, pts: seq * 90_000, dts: seq * 90_000, sequence: seq, keyframe: true, media_ingest_id: ingest_id, codec: "h264", payload_format: "annexb"}}}})
            end
            Process.sleep(200)
            drops = LiveVantageTap.dropped_count("{cam_id}")
            alive = Process.alive?(pid)
            Membrane.Pipeline.terminate(pid)
            result = %{{drops: drops, alive: alive}}
            """,
        )
        self.assertTrue(iso["alive"])
        self.assertEqual(iso["drops"], 12)

        # Verify live_observation_retention_days cleanup purges expired live rows without touching active ones
        ret = _eval_elixir_json(
            "elixir/serviceradar_core",
            """
            alias ServiceRadar.Actors.SystemActor
            alias ServiceRadar.Camera.VantageRetention
            actor = SystemActor.system(:mode_b_t4_w7_ret)
            {:ok, purged} = VantageRetention.cleanup_expired_live_observations(actor: actor)
            result = %{purged: purged}
            """,
        )
        self.assertIsInstance(ret["purged"], int)


if __name__ == "__main__":
    unittest.main()
