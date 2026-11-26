"""Mode B live cross-component E2E tests for E2E-M2 (Tiers 1 & 2 covering F1–F5).

Import- and discovery-safe: NO live probes run at module import time. When any
test executes without required live services/binaries/env vars, it fails closed
with RuntimeError/AssertionError (never skipTest or fake-green mocks).
"""

from __future__ import annotations

import base64
import contextlib
import copy
import hashlib
import http.server
import json
import os
import re
import shutil
import socket
import socketserver
import subprocess
import sys
import threading
import time
import unittest
import uuid
from pathlib import Path
from typing import Any, Iterator
from urllib.parse import urlparse

if __package__ in (None, "") and "TEST_SRCDIR" not in os.environ:
    _repo_root = str(Path(__file__).resolve().parents[2])
    if _repo_root not in sys.path:
        sys.path.insert(0, _repo_root)

from integration_tests.vantage_ml import vantage_contracts as vc
from integration_tests.vantage_ml.drivers import (
    cnpg_driver,
    env_probe,
    http_ws_driver,
    media_gen,
    nats_driver,
)

_E2E_JSON_PREFIX = "__VANTAGE_E2E_JSON__:"


def _fixtures_dir() -> Path:
    return vc.repo_root() / "integration_tests" / "vantage_ml" / "fixtures"


def _load_json(rel_path: str) -> Any:
    path = _fixtures_dir() / rel_path
    if not path.is_file():
        raise AssertionError(f"missing fixture file: {path}")
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
    payload: dict[str, Any],
    *,
    msg_id: str | None = None,
    nats_url: str,
) -> None:
    """Publish JSON to JetStream via `nats pub -J --force-stdin` (`nats` CLI v0.2.3 requires `--force-stdin`)."""
    cmd = ["pub", "-J", subject, "--force-stdin"]
    if msg_id:
        cmd.extend(["-H", f"Nats-Msg-Id:{msg_id}"])
    body = json.dumps(payload, separators=(",", ":")).encode("utf-8")
    with _isolated_nats_cli_env():
        nats_driver.run_nats_cli(cmd, nats_url=nats_url, stdin_bytes=body)


def _e2e_case(feature: str, tier: int, test_id: str, description: str):
    def _decorator(fn):
        fn._e2e_test_id = test_id
        fn._e2e_feature = feature
        fn._e2e_tier = tier
        fn._e2e_description = description
        return fn

    return _decorator


def _collect_mode_b_test_ids() -> dict[str, str]:
    mapping: dict[str, str] = {}
    for cls in (
        ModeBF1AshAndSchemaTest,
        ModeBF2LifecycleCouplingTest,
        ModeBF3JetStreamAndOcsfTest,
        ModeBF4MediaCoreCropperTest,
        ModeBF5VantageVlmRunnerTest,
    ):
        for attr_name in dir(cls):
            if not attr_name.startswith("test_e2e_"):
                continue
            fn = getattr(cls, attr_name)
            test_id = getattr(fn, "_e2e_test_id", None)
            if test_id:
                mapping[test_id] = f"{cls.__name__}.{attr_name}"
    return mapping


def _eval_core_json(elixir_body: str, *, timeout: float = 120.0) -> dict[str, Any]:
    """Execute Elixir inside `elixir/serviceradar_core` against live CNPG and parse JSON output."""
    db_url = cnpg_driver.require_database_url()
    env_probe.probe_binary("psql")
    wrapped = (
        f"{elixir_body}\n"
        f'IO.puts("{_E2E_JSON_PREFIX}" <> Jason.encode!(result))\n'
    )
    proc = cnpg_driver.run_mix_eval(
        "elixir/serviceradar_core",
        wrapped,
        extra_env={
            "DATABASE_URL": db_url,
            "SERVICERADAR_VANTAGE_PIPELINES_ENABLED": "true",
        },
        timeout=timeout,
    )
    for line in reversed(proc.stdout.splitlines()):
        if line.startswith(_E2E_JSON_PREFIX):
            return json.loads(line[len(_E2E_JSON_PREFIX) :])
    raise RuntimeError(
        f"mix run did not emit {_E2E_JSON_PREFIX}; stdout={proc.stdout!r}, stderr={proc.stderr!r}"
    )


def _cleanup_synthetic_camera_records(
    *,
    source_ids: list[str] | None = None,
    pipeline_ids: list[str] | None = None,
    worker_ids: list[str] | None = None,
    dashboard_pkg_ids: list[str] | None = None,
) -> None:
    """Best-effort deterministic cleanup of Mode B CNPG test rows."""
    db_url = cnpg_driver.require_database_url()
    for src_id in source_ids or []:
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
    for pid in pipeline_ids or []:
        safe_pid = pid.replace("'", "''")
        cnpg_driver.run_psql(
            f"DELETE FROM platform.camera_vantage_pipelines WHERE pipeline_id = '{safe_pid}';",
            database_url=db_url,
        )
    for wid in worker_ids or []:
        safe_wid = wid.replace("'", "''")
        cnpg_driver.run_psql(
            f"DELETE FROM platform.vantage_worker_registrations WHERE worker_id = '{safe_wid}';",
            database_url=db_url,
        )
    for pkg_id in dashboard_pkg_ids or []:
        u = str(uuid.UUID(pkg_id))
        cnpg_driver.run_psql(
            f"""
            DELETE FROM platform.dashboard_instance_versions WHERE version_source_id IN (
              SELECT id FROM platform.dashboard_instances WHERE dashboard_package_id = '{u}'
            );
            DELETE FROM platform.dashboard_instances WHERE dashboard_package_id = '{u}';
            DELETE FROM platform.dashboard_packages WHERE id = '{u}';
            """,
            database_url=db_url,
        )


def _elixir_provision_block_snippet(
    var_prefix: str,
    *,
    tag: str,
    timeline_start_us: int,
    timeline_end_us: int,
) -> str:
    """Build Elixir snippet provisioning Source, StreamProfile, parent ownership/relay rows, RecordingBlock, and RecordingCatalogEntry."""
    uid = uuid.uuid4().hex[:12]
    desc_sha = hashlib.sha256(f"desc-{tag}-{uid}".encode("utf-8")).hexdigest()
    init_sha = hashlib.sha256(f"init-{tag}-{uid}".encode("utf-8")).hexdigest()
    block_key = hashlib.sha256(f"block-{tag}-{uid}".encode("utf-8")).hexdigest()
    storage_id = str(uuid.uuid4())
    return f"""
        {var_prefix}_uid = "{uid}"
        {{:ok, {var_prefix}_cam}} = ServiceRadar.Camera.Source.create_source(%{{
          device_uid: "sr:synthetic-e2e-" <> {var_prefix}_uid,
          vendor: "synthetic",
          vendor_camera_id: {var_prefix}_uid,
          display_name: "Gate West 01",
          assigned_agent_id: "agent-synthetic",
          assigned_gateway_id: "gateway-synthetic"
        }}, actor: actor)
        {{:ok, {var_prefix}_prof}} = ServiceRadar.Camera.StreamProfile.create_profile(%{{
          camera_source_id: {var_prefix}_cam.id,
          profile_name: "main",
          relay_eligible: true
        }}, actor: actor)
        {var_prefix}_relay_id = Ecto.UUID.generate()
        {var_prefix}_owner_id = Ecto.UUID.generate()
        {var_prefix}_claim_id = Ecto.UUID.generate()
        {var_prefix}_block_id = Ecto.UUID.generate()
        {var_prefix}_ingest_id = "ingest-" <> {var_prefix}_uid
        {var_prefix}_now = DateTime.utc_now()
        Ecto.Adapters.SQL.query!(ServiceRadar.Repo, \"\"\"
          INSERT INTO platform.camera_relay_sessions
            (id, camera_source_id, stream_profile_id, agent_id, gateway_id, status,
             media_ingest_id, viewer_count, inserted_at, updated_at)
          VALUES
            ($1, $2, $3, 'agent-synthetic', 'gateway-synthetic', 'active', $4, 0, $5, $5)
        \"\"\", [
          Ecto.UUID.dump!({var_prefix}_relay_id), Ecto.UUID.dump!({var_prefix}_cam.id),
          Ecto.UUID.dump!({var_prefix}_prof.id), {var_prefix}_ingest_id, {var_prefix}_now
        ])
        Ecto.Adapters.SQL.query!(ServiceRadar.Repo, \"\"\"
          INSERT INTO platform.camera_ingest_owners
            (id, camera_source_id, stream_profile_id, epoch, state, relay_session_id,
             inserted_at, updated_at)
          VALUES
            ($1, $2, $3, 1, 'released', $4, $5, $5)
        \"\"\", [
          Ecto.UUID.dump!({var_prefix}_owner_id), Ecto.UUID.dump!({var_prefix}_cam.id),
          Ecto.UUID.dump!({var_prefix}_prof.id), Ecto.UUID.dump!({var_prefix}_relay_id),
          {var_prefix}_now
        ])
        Ecto.Adapters.SQL.query!(ServiceRadar.Repo, \"\"\"
          INSERT INTO platform.camera_recorder_claims
            (id, ingest_owner_id, ingest_epoch, recorder_epoch, next_block_sequence,
             relay_session_id, media_ingest_id, storage_id, state, inserted_at, updated_at)
          VALUES
            ($1, $2, 1, 1, 1, $3, $4, $5, 'released', $6, $6)
        \"\"\", [
          Ecto.UUID.dump!({var_prefix}_claim_id), Ecto.UUID.dump!({var_prefix}_owner_id),
          Ecto.UUID.dump!({var_prefix}_relay_id), {var_prefix}_ingest_id,
          Ecto.UUID.dump!("{storage_id}"), {var_prefix}_now
        ])
        {var_prefix}_desc_map = %{{
          "version" => 1,
          "format" => %{{ "codec" => "avc1.42c00a", "timescale" => 90000 }},
          "init" => %{{ "length" => 256, "sha256" => "{init_sha}" }},
          "media" => %{{ "length" => 1024, "sha256" => "{init_sha}" }},
          "fragments" => []
        }}
        Ecto.Adapters.SQL.query!(ServiceRadar.Repo, \"\"\"
          INSERT INTO platform.camera_recording_blocks
            (id, block_key, camera_source_id, stream_profile_id, ingest_owner_id, ingest_epoch,
             recorder_claim_id, recorder_epoch, block_sequence, relay_session_id, media_ingest_id,
             storage_id, state, descriptor, descriptor_sha256, reconciliation_state, clock,
             inserted_at, updated_at)
          VALUES
            ($1, $2, $3, $4, $5, 1, $6, 1, 0, $7, $8, $9, 'sealed', $10, $11, 'unresolved', '{{}}'::jsonb, $12, $12)
        \"\"\", [
          Ecto.UUID.dump!({var_prefix}_block_id), "{block_key}", Ecto.UUID.dump!({var_prefix}_cam.id),
          Ecto.UUID.dump!({var_prefix}_prof.id), Ecto.UUID.dump!({var_prefix}_owner_id),
          Ecto.UUID.dump!({var_prefix}_claim_id), Ecto.UUID.dump!({var_prefix}_relay_id),
          {var_prefix}_ingest_id, Ecto.UUID.dump!("{storage_id}"), {var_prefix}_desc_map,
          "{desc_sha}", {var_prefix}_now
        ])
        {{:ok, {var_prefix}_entry}} = ServiceRadar.Camera.RecordingCatalogEntry
          |> Ash.Changeset.for_create(:register_sealed, %{{
            recording_block_id: {var_prefix}_block_id,
            camera_source_id: {var_prefix}_cam.id,
            stream_profile_id: {var_prefix}_prof.id,
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
            local_state_at: {var_prefix}_now,
            archive_state: :not_required,
            archive_state_at: {var_prefix}_now,
            sealed_at: {var_prefix}_now
          }}, actor: actor)
          |> Ash.create(actor: actor)
    """


def _provision_camera_block_sql_and_ash(tag: str, *, timeline_start_us: int, timeline_end_us: int) -> dict[str, str]:
    """Create isolated Source, StreamProfile, parent relay/ownership rows, RecordingBlock, and RecordingCatalogEntry."""
    snippet = _elixir_provision_block_snippet(
        "p", tag=tag, timeline_start_us=timeline_start_us, timeline_end_us=timeline_end_us
    )
    res = _eval_core_json(
        f"""
        alias ServiceRadar.Actors.SystemActor
        actor = SystemActor.system(:mode_b_e2e)
        {snippet}
        result = %{{
          camera_source_id: p_cam.id,
          stream_profile_id: p_prof.id,
          recording_block_id: p_block_id,
          catalog_entry_id: p_entry.id,
          descriptor_sha256: p_entry.descriptor_sha256
        }}
        """
    )
    return res


class ModeBCatalogParityTest(unittest.TestCase):
    """Verify Mode B test methods cover every test_id in catalog_f1_f5.json 1:1."""

    def test_mode_b_catalog_parity(self) -> None:
        catalog = _load_json("catalog_f1_f5.json")
        catalog_ids = {entry["test_id"] for entry in catalog["cases"]}
        mapped_ids = _collect_mode_b_test_ids()
        self.assertEqual(catalog_ids, set(mapped_ids.keys()))


class ModeBF1AshAndSchemaTest(unittest.TestCase):
    """F1 Mode B: Live CNPG Ash resources, SQL CHECK constraints, GIN search_tsv, and RBAC."""

    @classmethod
    def setUpClass(cls) -> None:
        cnpg_driver.require_database_url()
        env_probe.probe_binary("psql")
        env_probe.probe_binary("mix")

    @_e2e_case("F1", 1, "E2E-F1-T1-01", "Upsert VantagePipeline in CNPG with managed provenance")
    def test_e2e_f1_t1_01_live_upsert_vantage_pipeline(self) -> None:
        pid = f"io.serviceradar.e2e.f1-{uuid.uuid4().hex[:8]}"
        self.addCleanup(_cleanup_synthetic_camera_records, pipeline_ids=[pid])
        res = _eval_core_json(
            f"""
            alias ServiceRadar.Actors.SystemActor
            alias ServiceRadar.Camera.VantagePipeline
            actor = SystemActor.system(:mode_b_f1)
            {{:ok, p}} = VantagePipeline
              |> Ash.Changeset.for_create(:upsert, %{{
                pipeline_id: "{pid}",
                version: "1.0.0",
                name: "Gate West 01 ALPR",
                enabled: true,
                source_mode: :recorded_block,
                trigger_kind: :on_stage1_detection,
                input_mode: :detection_crop,
                runner: :camera_vlm,
                signal_schema_id: "alpr_plate_read",
                signal_schema_version: "1.0.0",
                display_contract_id: "alpr_plate_read",
                pack_id: "io.serviceradar.vantage-alpr",
                pack_version: "1.0.0",
                managed: true
              }}, actor: actor)
              |> Ash.create(actor: actor)
            read_back = VantagePipeline.get_by_pipeline_version!("{pid}", "1.0.0", actor: actor)
            result = %{{id: read_back.id, managed: read_back.managed, pack_id: read_back.pack_id}}
            """
        )
        self.assertTrue(res["managed"])
        self.assertEqual(res["pack_id"], "io.serviceradar.vantage-alpr")

    @_e2e_case("F1", 1, "E2E-F1-T1-02", "VantageJob idempotent double enqueue yields single row")
    def test_e2e_f1_t1_02_live_vantage_job_idempotent_enqueue(self) -> None:
        cam = _provision_camera_block_sql_and_ash(
            "f1-t1-02", timeline_start_us=1760000000000000, timeline_end_us=1760000010000000
        )
        pid = f"io.serviceradar.e2e.f1-{uuid.uuid4().hex[:8]}"
        self.addCleanup(
            _cleanup_synthetic_camera_records,
            source_ids=[cam["camera_source_id"]],
            pipeline_ids=[pid],
        )
        res = _eval_core_json(
            f"""
            require Ash.Query
            alias ServiceRadar.Actors.SystemActor
            alias ServiceRadar.Camera.VantageJob
            actor = SystemActor.system(:mode_b_f1)
            attrs = %{{
              pipeline_id: "{pid}",
              pipeline_version: "1.0.0",
              catalog_entry_id: "{cam['catalog_entry_id']}",
              camera_source_id: "{cam['camera_source_id']}",
              stream_profile_id: "{cam['stream_profile_id']}",
              target_key: "track:1",
              target_runner: "camera_vlm",
              subject: "media.jobs.vantage.vlm.v1",
              descriptor_sha256: "{cam['descriptor_sha256']}"
            }}
            {{:ok, j1}} = VantageJob |> Ash.Changeset.for_create(:enqueue, attrs, actor: actor) |> Ash.create(actor: actor)
            {{:ok, j2}} = VantageJob |> Ash.Changeset.for_create(:enqueue, attrs, actor: actor) |> Ash.create(actor: actor)
            rows = VantageJob |> Ash.Query.filter(catalog_entry_id == ^"{cam['catalog_entry_id']}" and pipeline_id == ^"{pid}") |> Ash.read!(actor: actor)
            result = %{{j1_id: j1.id, j2_id: j2.id, count: length(rows)}}
            """
        )
        self.assertEqual(res["count"], 1)
        self.assertEqual(res["j1_id"], res["j2_id"])

    @_e2e_case("F1", 1, "E2E-F1-T1-03", "Recorded VantageObservation crop_jpeg & search_tsv GIN match")
    def test_e2e_f1_t1_03_live_observation_crop_and_search_tsv(self) -> None:
        cam = _provision_camera_block_sql_and_ash(
            "f1-t1-03", timeline_start_us=1760000000000000, timeline_end_us=1760000010000000
        )
        self.addCleanup(_cleanup_synthetic_camera_records, source_ids=[cam["camera_source_id"]])
        crop_b64 = base64.b64encode(
            vc.make_synthetic_baseline_jfif(64, 48, seed=3, target_max_bytes=16384)
        ).decode("ascii")
        obs_key = f"obs-f1-t1-03-{uuid.uuid4().hex[:8]}"
        res = _eval_core_json(
            f"""
            alias ServiceRadar.Actors.SystemActor
            alias ServiceRadar.Camera.VantageObservation
            actor = SystemActor.system(:mode_b_f1)
            crop = Base.decode64!("{crop_b64}")
            {{:ok, obs}} = VantageObservation
              |> Ash.Changeset.for_create(:upsert_observation, %{{
                observation_key: "{obs_key}",
                pipeline_id: "io.serviceradar.vantage-alpr.vehicle-plate",
                pipeline_version: "1.0.0",
                worker_kind: "camera_vlm",
                model_id: "qwen3.5-4b",
                model_version: "1.0.0",
                catalog_entry_id: "{cam['catalog_entry_id']}",
                camera_source_id: "{cam['camera_source_id']}",
                stream_profile_id: "{cam['stream_profile_id']}",
                source_mode: :recorded_block,
                fragment_sequence: 0,
                media_pts_ns: 0,
                timeline_ts_us: 1760000000000000,
                time_basis: :received,
                category: "license_plate",
                label: "SR-0100",
                confidence: 0.94,
                bbox: %{{ "x1" => 0.32, "y1" => 0.58, "x2" => 0.48, "y2" => 0.66 }},
                crop_jpeg: crop,
                attributes: %{{ "plate_text" => "SR-0100", "region" => "US-CO" }},
                signal_schema_id: "alpr_plate_read",
                signal_schema_version: "1.0.0",
                display_contract_id: "alpr_plate_read",
                search_text: "SR-0100 Gate West 01 US-CO"
              }}, actor: actor)
              |> Ash.create(actor: actor)
            %{{rows: [[cnt]]}} = Ecto.Adapters.SQL.query!(
              ServiceRadar.Repo,
              "SELECT count(*) FROM platform.camera_vantage_observations WHERE id = $1 AND search_tsv @@ plainto_tsquery('english', 'SR-0100')",
              [Ecto.UUID.dump!(obs.id)]
            )
            result = %{{id: obs.id, tsv_matches: cnt}}
            """
        )
        self.assertEqual(res["tsv_matches"], 1)

    @_e2e_case("F1", 1, "E2E-F1-T1-04", "Live-tap VantageObservation persists with null catalog_entry_id")
    def test_e2e_f1_t1_04_live_tap_observation_null_catalog(self) -> None:
        cam = _provision_camera_block_sql_and_ash(
            "f1-t1-04", timeline_start_us=1760000000000000, timeline_end_us=1760000010000000
        )
        self.addCleanup(_cleanup_synthetic_camera_records, source_ids=[cam["camera_source_id"]])
        obs_key = f"obs-f1-t1-04-{uuid.uuid4().hex[:8]}"
        res = _eval_core_json(
            f"""
            alias ServiceRadar.Actors.SystemActor
            alias ServiceRadar.Camera.VantageObservation
            actor = SystemActor.system(:mode_b_f1)
            {{:ok, obs}} = VantageObservation
              |> Ash.Changeset.for_create(:upsert_observation, %{{
                observation_key: "{obs_key}",
                pipeline_id: "io.serviceradar.vantage-bay-guidance.dock",
                pipeline_version: "1.0.0",
                worker_kind: "external_rust",
                model_id: "bay-guidance-onnx",
                model_version: "1.0.0",
                catalog_entry_id: nil,
                camera_source_id: "{cam['camera_source_id']}",
                stream_profile_id: "{cam['stream_profile_id']}",
                source_mode: :live_keyframe_tap,
                frame_sequence: 4,
                timeline_ts_us: 1760000001000000,
                time_basis: :camera_reported,
                category: "vehicle",
                label: "Bay 04 Approach",
                confidence: 0.91,
                bbox: %{{ "x1" => 0.25, "y1" => 0.30, "x2" => 0.75, "y2" => 0.85 }},
                attributes: %{{ "bay_id" => "bay-04", "guidance_state" => "approach", "distance_m" => 2.1, "lateral_offset_m" => 0.0 }},
                signal_schema_id: "bay_guidance",
                signal_schema_version: "1.0.0",
                display_contract_id: "bay_guidance",
                search_text: "Bay 04 Approach"
              }}, actor: actor)
              |> Ash.create(actor: actor)
            result = %{{id: obs.id, catalog_entry_id: obs.catalog_entry_id, source_mode: to_string(obs.source_mode)}}
            """
        )
        self.assertIsNone(res["catalog_entry_id"])
        self.assertEqual(res["source_mode"], "live_keyframe_tap")

    @_e2e_case("F1", 1, "E2E-F1-T1-05", "WorkerRegistration active_for_capability + Dashboard provenance & RBAC")
    def test_e2e_f1_t1_05_worker_reg_and_dashboard_provenance(self) -> None:
        wid = f"e2e-worker-{uuid.uuid4().hex[:8]}"
        dash_id = f"io.serviceradar.e2e.console.{uuid.uuid4().hex[:8]}"
        res = _eval_core_json(
            f"""
            alias ServiceRadar.Actors.SystemActor
            alias ServiceRadar.Camera.VantageWorkerRegistration
            alias ServiceRadar.Dashboards.{{DashboardInstance, DashboardPackage}}
            alias ServiceRadar.Identity.RBAC.Catalog
            actor = SystemActor.system(:mode_b_f1)
            now = DateTime.utc_now()
            {{:ok, reg}} = VantageWorkerRegistration
              |> Ash.Changeset.for_create(:upsert_heartbeat, %{{
                worker_id: "{wid}",
                worker_kind: :external_rust,
                protocol_version: "vantage.worker.v1",
                capabilities: ["vantage.alpr.v1"],
                supported_source_modes: ["recorded_block", "live_keyframe_tap"],
                execution_backend: "onnx",
                architecture: "arm64",
                model_id: "fast-alpr-onnx",
                model_version: "1.0.0",
                max_concurrency: 4,
                active_jobs: 0,
                health: :ready,
                last_heartbeat_at: now,
                expires_at: DateTime.shift(now, second: 60)
              }}, actor: actor)
              |> Ash.create(actor: actor)
            {{:ok, active}} = VantageWorkerRegistration.active_for_capability("vantage.alpr.v1", now, actor: actor)
            dash_sha = String.duplicate("a", 64)
            manifest_map = %{{
              "schema_version" => 1,
              "id" => "{dash_id}",
              "name" => "ALPR Console E2E",
              "version" => "1.0.0",
              "renderer" => %{{
                "kind" => "browser_module",
                "interface_version" => "dashboard-browser-module-v1",
                "artifact" => "renderer.js",
                "sha256" => dash_sha,
                "trust" => "trusted"
              }},
              "data_frames" => [
                %{{
                  "id" => "observations",
                  "query" => "in:camera_observations limit:20",
                  "encoding" => "json_rows",
                  "required" => true
                }}
              ],
              "capabilities" => ["srql.execute", "events.subscribe"],
              "settings_schema" => %{{}}
            }}
            {{:ok, pkg}} = DashboardPackage
              |> Ash.Changeset.for_create(:create, %{{
                dashboard_id: "{dash_id}",
                name: "ALPR Console E2E",
                version: "1.0.0",
                manifest: manifest_map,
                renderer: manifest_map["renderer"],
                data_frames: manifest_map["data_frames"],
                capabilities: manifest_map["capabilities"],
                settings_schema: %{{}},
                content_hash: dash_sha,
                pack_id: "io.serviceradar.vantage-alpr",
                pack_version: "1.0.0",
                managed: true,
                template_fingerprint: String.duplicate("b", 64)
              }}, actor: actor)
              |> Ash.create(actor: actor)
            mgr = %{{id: "mgr", role: :operator, permissions: MapSet.new(["dashboards.packages.manage", "dashboards.packages.view_all"])}}
            {{:ok, inst}} = DashboardInstance
              |> Ash.Changeset.for_create(:create, %{{
                dashboard_package_id: pkg.id,
                name: "ALPR Console Instance",
                route_slug: "e2e-alpr-" <> String.slice("{wid}", -6, 6),
                enabled: true,
                pack_id: "io.serviceradar.vantage-alpr",
                pack_version: "1.0.0",
                managed: true,
                template_fingerprint: String.duplicate("b", 64)
              }}, actor: mgr)
              |> Ash.create(actor: mgr)
            has_perm = "dashboards.packages.manage" in Catalog.permission_keys()
            result = %{{
              worker_found: Enum.any?(active, &(&1.id == reg.id)),
              pkg_id: pkg.id,
              inst_managed: inst.managed,
              has_dash_manage_perm: has_perm
            }}
            """
        )
        self.addCleanup(
            _cleanup_synthetic_camera_records,
            worker_ids=[wid],
            dashboard_pkg_ids=[res["pkg_id"]],
        )
        self.assertTrue(res["worker_found"])
        self.assertTrue(res["inst_managed"])
        self.assertTrue(res["has_dash_manage_perm"])

    @_e2e_case("F1", 2, "E2E-F1-T2-01", "CNPG CHECK & Ash reject 32769 B crop_jpeg while 32768 B passes")
    def test_e2e_f1_t2_01_live_crop_jpeg_32768_vs_32769_check(self) -> None:
        cam = _provision_camera_block_sql_and_ash(
            "f1-t2-01", timeline_start_us=1760000000000000, timeline_end_us=1760000010000000
        )
        self.addCleanup(_cleanup_synthetic_camera_records, source_ids=[cam["camera_source_id"]])
        base = vc.make_synthetic_baseline_jfif(64, 48, seed=7, target_max_bytes=4096)
        pad_32k = 32768 - len(base) - 4
        ok_32k = base[:20] + b"\xFF\xFE" + (pad_32k + 2).to_bytes(2, "big") + (b"V" * pad_32k) + base[20:]
        bad_32k1 = base[:20] + b"\xFF\xFE" + (pad_32k + 3).to_bytes(2, "big") + (b"V" * (pad_32k + 1)) + base[20:]
        res = _eval_core_json(
            f"""
            alias ServiceRadar.Actors.SystemActor
            alias ServiceRadar.Camera.VantageObservation
            actor = SystemActor.system(:mode_b_f1)
            ok_bytes = Base.decode64!("{base64.b64encode(ok_32k).decode('ascii')}")
            bad_bytes = Base.decode64!("{base64.b64encode(bad_32k1).decode('ascii')}")
            base_attrs = %{{
              pipeline_id: "io.serviceradar.vantage-alpr.vehicle-plate",
              pipeline_version: "1.0.0",
              worker_kind: "camera_vlm",
              model_id: "qwen3.5-4b",
              model_version: "1.0.0",
              catalog_entry_id: "{cam['catalog_entry_id']}",
              camera_source_id: "{cam['camera_source_id']}",
              stream_profile_id: "{cam['stream_profile_id']}",
              source_mode: :recorded_block,
              fragment_sequence: 0,
              media_pts_ns: 0,
              timeline_ts_us: 1760000000000000,
              time_basis: :received,
              category: "license_plate",
              label: "SR-0100",
              confidence: 0.9,
              signal_schema_id: "alpr_plate_read",
              signal_schema_version: "1.0.0",
              display_contract_id: "alpr_plate_read"
            }}
            {{:ok, _}} = VantageObservation |> Ash.Changeset.for_create(:upsert_observation, Map.merge(base_attrs, %{{observation_key: "ok-32k-#{uuid.uuid4().hex[:6]}", crop_jpeg: ok_bytes}}), actor: actor) |> Ash.create(actor: actor)
            bad_ash = match?({{:error, _}}, VantageObservation |> Ash.Changeset.for_create(:upsert_observation, Map.merge(base_attrs, %{{observation_key: "bad-32k-#{uuid.uuid4().hex[:6]}", crop_jpeg: bad_bytes}}), actor: actor) |> Ash.create(actor: actor))
            bad_sql = try do
              Ecto.Adapters.SQL.query!(ServiceRadar.Repo, \"\"\"
                INSERT INTO platform.camera_vantage_observations
                  (id, observation_key, pipeline_id, pipeline_version, worker_kind, model_id, model_version,
                   catalog_entry_id, camera_source_id, stream_profile_id, source_mode, timeline_ts_us, time_basis,
                   category, label, confidence, attributes, signal_schema_id, signal_schema_version, display_contract_id,
                   search_text, crop_jpeg, inserted_at, updated_at)
                VALUES
                  ($1, $2, 'io.serviceradar.vantage-alpr.vehicle-plate', '1.0.0', 'camera_vlm', 'm', '1',
                   $3, $4, $5, 'recorded_block', 1760000000000000, 'received',
                   'license_plate', 'SR-0100', 0.9, '{{}}'::jsonb, 'alpr_plate_read', '1.0.0', 'alpr_plate_read',
                   '', $6, now(), now())
              \"\"\", [Ecto.UUID.dump!(Ecto.UUID.generate()), "sql-bad-#{uuid.uuid4().hex[:6]}", Ecto.UUID.dump!("{cam['catalog_entry_id']}"), Ecto.UUID.dump!("{cam['camera_source_id']}"), Ecto.UUID.dump!("{cam['stream_profile_id']}"), bad_bytes])
              false
            rescue
              Postgrex.Error -> true
            end
            result = %{{bad_ash: bad_ash, bad_sql: bad_sql}}
            """
        )
        self.assertTrue(res["bad_ash"])
        self.assertTrue(res["bad_sql"])

    @_e2e_case("F1", 2, "E2E-F1-T2-02", "VantageCropJpeg rejects Progressive SOF2 and non-JPEG payloads")
    def test_e2e_f1_t2_02_live_reject_sof2_and_non_jfif(self) -> None:
        cam = _provision_camera_block_sql_and_ash(
            "f1-t2-02", timeline_start_us=1760000000000000, timeline_end_us=1760000010000000
        )
        self.addCleanup(_cleanup_synthetic_camera_records, source_ids=[cam["camera_source_id"]])
        valid = vc.make_synthetic_baseline_jfif(64, 48, seed=11, target_max_bytes=8192)
        sof0_idx = valid.index(b"\xFF\xC0\x00\x11\x08")
        sof2 = bytearray(valid)
        sof2[sof0_idx + 1] = 0xC2
        res = _eval_core_json(
            f"""
            alias ServiceRadar.Actors.SystemActor
            alias ServiceRadar.Camera.VantageObservation
            actor = SystemActor.system(:mode_b_f1)
            sof2_bytes = Base.decode64!("{base64.b64encode(bytes(sof2)).decode('ascii')}")
            base_attrs = %{{
              pipeline_id: "io.serviceradar.vantage-alpr.vehicle-plate",
              pipeline_version: "1.0.0",
              worker_kind: "camera_vlm",
              model_id: "qwen3.5-4b",
              model_version: "1.0.0",
              catalog_entry_id: "{cam['catalog_entry_id']}",
              camera_source_id: "{cam['camera_source_id']}",
              stream_profile_id: "{cam['stream_profile_id']}",
              source_mode: :recorded_block,
              timeline_ts_us: 1760000000000000,
              time_basis: :received,
              category: "license_plate",
              label: "SR-0100",
              confidence: 0.9,
              signal_schema_id: "alpr_plate_read",
              signal_schema_version: "1.0.0",
              display_contract_id: "alpr_plate_read"
            }}
            sof2_err = match?({{:error, _}}, VantageObservation |> Ash.Changeset.for_create(:upsert_observation, Map.merge(base_attrs, %{{observation_key: "sof2-#{uuid.uuid4().hex[:6]}", crop_jpeg: sof2_bytes}}), actor: actor) |> Ash.create(actor: actor))
            raw_err = match?({{:error, _}}, VantageObservation |> Ash.Changeset.for_create(:upsert_observation, Map.merge(base_attrs, %{{observation_key: "raw-#{uuid.uuid4().hex[:6]}", crop_jpeg: "not-a-jpeg"}}), actor: actor) |> Ash.create(actor: actor))
            result = %{{sof2_rejected: sof2_err, non_jpeg_rejected: raw_err}}
            """
        )
        self.assertTrue(res["sof2_rejected"])
        self.assertTrue(res["non_jpeg_rejected"])

    @_e2e_case("F1", 2, "E2E-F1-T2-03", "ValidateVantageObservation rejects inverted bbox & confidence > 1.0")
    def test_e2e_f1_t2_03_live_reject_bad_bbox_and_confidence(self) -> None:
        cam = _provision_camera_block_sql_and_ash(
            "f1-t2-03", timeline_start_us=1760000000000000, timeline_end_us=1760000010000000
        )
        self.addCleanup(_cleanup_synthetic_camera_records, source_ids=[cam["camera_source_id"]])
        res = _eval_core_json(
            f"""
            alias ServiceRadar.Actors.SystemActor
            alias ServiceRadar.Camera.VantageObservation
            actor = SystemActor.system(:mode_b_f1)
            base_attrs = %{{
              pipeline_id: "io.serviceradar.vantage-alpr.vehicle-plate",
              pipeline_version: "1.0.0",
              worker_kind: "camera_vlm",
              model_id: "qwen3.5-4b",
              model_version: "1.0.0",
              catalog_entry_id: "{cam['catalog_entry_id']}",
              camera_source_id: "{cam['camera_source_id']}",
              stream_profile_id: "{cam['stream_profile_id']}",
              source_mode: :recorded_block,
              timeline_ts_us: 1760000000000000,
              time_basis: :received,
              category: "license_plate",
              label: "SR-0100",
              confidence: 0.9,
              signal_schema_id: "alpr_plate_read",
              signal_schema_version: "1.0.0",
              display_contract_id: "alpr_plate_read"
            }}
            bad_bbox = match?({{:error, _}}, VantageObservation |> Ash.Changeset.for_create(:upsert_observation, Map.merge(base_attrs, %{{observation_key: "bb-#{uuid.uuid4().hex[:6]}", bbox: %{{"x1" => 0.6, "y1" => 0.2, "x2" => 0.4, "y2" => 0.8}}}}), actor: actor) |> Ash.create(actor: actor))
            bad_conf = match?({{:error, _}}, VantageObservation |> Ash.Changeset.for_create(:upsert_observation, Map.merge(base_attrs, %{{observation_key: "cf-#{uuid.uuid4().hex[:6]}", confidence: 1.05}}), actor: actor) |> Ash.create(actor: actor))
            result = %{{bad_bbox: bad_bbox, bad_conf: bad_conf}}
            """
        )
        self.assertTrue(res["bad_bbox"])
        self.assertTrue(res["bad_conf"])

    @_e2e_case("F1", 2, "E2E-F1-T2-04", "Ash RBAC forbids non-system write and bare devices.view read")
    def test_e2e_f1_t2_04_live_ash_rbac_forbidden(self) -> None:
        cam = _provision_camera_block_sql_and_ash(
            "f1-t2-04", timeline_start_us=1760000000000000, timeline_end_us=1760000010000000
        )
        self.addCleanup(_cleanup_synthetic_camera_records, source_ids=[cam["camera_source_id"]])
        res = _eval_core_json(
            f"""
            alias ServiceRadar.Camera.VantageObservation
            viewer_bare = %{{id: "viewer-1", role: :viewer, permissions: MapSet.new(["devices.view"])}}
            viewer_rec = %{{id: "viewer-2", role: :admin, permissions: MapSet.new(["devices.view", "devices.cameras.recordings.view"])}}
            write_denied = match?({{:error, %Ash.Error.Forbidden{{}}}}, VantageObservation |> Ash.Changeset.for_create(:upsert_observation, %{{
              observation_key: "rbac-denied-#{uuid.uuid4().hex[:6]}",
              pipeline_id: "io.serviceradar.vantage-alpr.vehicle-plate",
              pipeline_version: "1.0.0",
              worker_kind: "camera_vlm",
              model_id: "m",
              model_version: "1",
              catalog_entry_id: "{cam['catalog_entry_id']}",
              camera_source_id: "{cam['camera_source_id']}",
              stream_profile_id: "{cam['stream_profile_id']}",
              source_mode: :recorded_block,
              timeline_ts_us: 1760000000000000,
              time_basis: :received,
              category: "license_plate",
              label: "SR-0100",
              confidence: 0.9,
              signal_schema_id: "alpr_plate_read",
              signal_schema_version: "1.0.0",
              display_contract_id: "alpr_plate_read"
            }}, actor: viewer_rec) |> Ash.create(actor: viewer_rec))
            bare_read_denied = match?({{:error, %Ash.Error.Forbidden{{}}}}, Ash.read(VantageObservation, actor: viewer_bare))
            rec_read_ok = match?({{:ok, _}}, Ash.read(VantageObservation, actor: viewer_rec))
            result = %{{write_denied: write_denied, bare_read_denied: bare_read_denied, rec_read_ok: rec_read_ok}}
            """
        )
        self.assertTrue(res["write_denied"])
        self.assertTrue(res["bare_read_denied"])
        self.assertTrue(res["rec_read_ok"])

    @_e2e_case("F1", 2, "E2E-F1-T2-05", "Reject invalid time_basis, null recorded catalog_entry_id, and bad pipeline_id")
    def test_e2e_f1_t2_05_live_reject_invalid_enums_and_pipeline_id(self) -> None:
        cam = _provision_camera_block_sql_and_ash(
            "f1-t2-05", timeline_start_us=1760000000000000, timeline_end_us=1760000010000000
        )
        self.addCleanup(_cleanup_synthetic_camera_records, source_ids=[cam["camera_source_id"]])
        res = _eval_core_json(
            f"""
            alias ServiceRadar.Actors.SystemActor
            alias ServiceRadar.Camera.{{VantageObservation, VantagePipeline}}
            actor = SystemActor.system(:mode_b_f1)
            null_cat = match?({{:error, _}}, VantageObservation |> Ash.Changeset.for_create(:upsert_observation, %{{
              observation_key: "nullcat-#{uuid.uuid4().hex[:6]}",
              pipeline_id: "io.serviceradar.vantage-alpr.vehicle-plate",
              pipeline_version: "1.0.0",
              worker_kind: "camera_vlm",
              model_id: "m",
              model_version: "1",
              catalog_entry_id: nil,
              camera_source_id: "{cam['camera_source_id']}",
              stream_profile_id: "{cam['stream_profile_id']}",
              source_mode: :recorded_block,
              timeline_ts_us: 1760000000000000,
              time_basis: :received,
              category: "license_plate",
              label: "SR-0100",
              confidence: 0.9,
              signal_schema_id: "alpr_plate_read",
              signal_schema_version: "1.0.0",
              display_contract_id: "alpr_plate_read"
            }}, actor: actor) |> Ash.create(actor: actor))
            bad_tb = match?({{:error, _}}, VantageObservation |> Ash.Changeset.for_create(:upsert_observation, %{{
              observation_key: "badtb-#{uuid.uuid4().hex[:6]}",
              pipeline_id: "io.serviceradar.vantage-alpr.vehicle-plate",
              pipeline_version: "1.0.0",
              worker_kind: "camera_vlm",
              model_id: "m",
              model_version: "1",
              catalog_entry_id: "{cam['catalog_entry_id']}",
              camera_source_id: "{cam['camera_source_id']}",
              stream_profile_id: "{cam['stream_profile_id']}",
              source_mode: :recorded_block,
              timeline_ts_us: 1760000000000000,
              time_basis: :wall_clock,
              category: "license_plate",
              label: "SR-0100",
              confidence: 0.9,
              signal_schema_id: "alpr_plate_read",
              signal_schema_version: "1.0.0",
              display_contract_id: "alpr_plate_read"
            }}, actor: actor) |> Ash.create(actor: actor))
            bad_pid = match?({{:error, _}}, VantagePipeline |> Ash.Changeset.for_create(:upsert, %{{
              pipeline_id: "single",
              version: "",
              name: "Invalid",
              signal_schema_id: "alpr_plate_read",
              signal_schema_version: "1.0.0",
              display_contract_id: "alpr_plate_read"
            }}, actor: actor) |> Ash.create(actor: actor))
            result = %{{null_cat: null_cat, bad_tb: bad_tb, bad_pid: bad_pid}}
            """
        )
        self.assertTrue(res["null_cat"])
        self.assertTrue(res["bad_tb"])
        self.assertTrue(res["bad_pid"])


class ModeBF2LifecycleCouplingTest(unittest.TestCase):
    """F2 Mode B: Live CNPG quarantine/reclaim triggers, RecordingHolds PD5, and FK cascades."""

    @classmethod
    def setUpClass(cls) -> None:
        cnpg_driver.require_database_url()
        env_probe.probe_binary("psql")
        env_probe.probe_binary("mix")

    def _seed_obs_and_jobs(
        self,
        cam: dict[str, str],
        *,
        suffix: str,
        pipeline_id: str = "io.serviceradar.vantage-alpr.vehicle-plate",
    ) -> dict[str, Any]:
        return _eval_core_json(
            f"""
            alias ServiceRadar.Actors.SystemActor
            alias ServiceRadar.Camera.{{VantageJob, VantageObservation}}
            actor = SystemActor.system(:mode_b_f2)
            now = DateTime.utc_now()
            {{:ok, pending_job}} = VantageJob |> Ash.Changeset.for_create(:enqueue, %{{
              pipeline_id: "{pipeline_id}",
              pipeline_version: "1.0.0",
              catalog_entry_id: "{cam['catalog_entry_id']}",
              camera_source_id: "{cam['camera_source_id']}",
              stream_profile_id: "{cam['stream_profile_id']}",
              target_key: "track:pending-{suffix}",
              target_runner: "camera_vlm",
              subject: "media.jobs.vantage.vlm.v1",
              descriptor_sha256: "{cam['descriptor_sha256']}"
            }}, actor: actor) |> Ash.create(actor: actor)
            {{:ok, disp_job}} = VantageJob |> Ash.Changeset.for_create(:enqueue, %{{
              pipeline_id: "{pipeline_id}",
              pipeline_version: "1.0.0",
              catalog_entry_id: "{cam['catalog_entry_id']}",
              camera_source_id: "{cam['camera_source_id']}",
              stream_profile_id: "{cam['stream_profile_id']}",
              target_key: "track:disp-{suffix}",
              target_runner: "camera_vlm",
              subject: "media.jobs.vantage.vlm.v1",
              descriptor_sha256: "{cam['descriptor_sha256']}"
            }}, actor: actor) |> Ash.create(actor: actor)
            {{:ok, disp_job}} = disp_job |> Ash.Changeset.for_update(:mark_dispatched, %{{
              dispatched_at: now, deadline_at: DateTime.shift(now, second: 60)
            }}, actor: actor) |> Ash.update(actor: actor)
            {{:ok, done_job}} = VantageJob |> Ash.Changeset.for_create(:enqueue, %{{
              pipeline_id: "{pipeline_id}",
              pipeline_version: "1.0.0",
              catalog_entry_id: "{cam['catalog_entry_id']}",
              camera_source_id: "{cam['camera_source_id']}",
              stream_profile_id: "{cam['stream_profile_id']}",
              target_key: "track:done-{suffix}",
              target_runner: "camera_vlm",
              subject: "media.jobs.vantage.vlm.v1",
              descriptor_sha256: "{cam['descriptor_sha256']}"
            }}, actor: actor) |> Ash.create(actor: actor)
            {{:ok, done_job}} = done_job |> Ash.Changeset.for_update(:mark_completed, %{{completed_at: now}}, actor: actor) |> Ash.update(actor: actor)
            {{:ok, obs}} = VantageObservation |> Ash.Changeset.for_create(:upsert_observation, %{{
              observation_key: "obs-{suffix}",
              pipeline_id: "{pipeline_id}",
              pipeline_version: "1.0.0",
              worker_kind: "camera_vlm",
              model_id: "qwen3.5-4b",
              model_version: "1.0.0",
              job_id: done_job.id,
              catalog_entry_id: "{cam['catalog_entry_id']}",
              camera_source_id: "{cam['camera_source_id']}",
              stream_profile_id: "{cam['stream_profile_id']}",
              source_mode: :recorded_block,
              fragment_sequence: 0,
              media_pts_ns: 0,
              timeline_ts_us: 1760000000000000,
              time_basis: :received,
              category: "license_plate",
              label: "TEST-742",
              confidence: 0.92,
              attributes: %{{ "plate_text" => "TEST-742" }},
              signal_schema_id: "alpr_plate_read",
              signal_schema_version: "1.0.0",
              display_contract_id: "alpr_plate_read",
              search_text: "TEST-742 Gate West 01"
            }}, actor: actor) |> Ash.create(actor: actor)
            result = %{{pending_id: pending_job.id, disp_id: disp_job.id, done_id: done_job.id, obs_id: obs.id}}
            """
        )

    @_e2e_case("F2", 1, "E2E-F2-T1-01", "Quarantine trigger purges observations and cancels active jobs")
    def test_e2e_f2_t1_01_live_quarantine_purges_and_cancels(self) -> None:
        cam = _provision_camera_block_sql_and_ash(
            "f2-t1-01", timeline_start_us=1760000000000000, timeline_end_us=1760000010000000
        )
        self.addCleanup(_cleanup_synthetic_camera_records, source_ids=[cam["camera_source_id"]])
        seeded = self._seed_obs_and_jobs(cam, suffix=uuid.uuid4().hex[:8])
        cnpg_driver.run_psql(
            f"""
            UPDATE platform.camera_recording_catalog
            SET local_state = 'quarantined',
                quarantine_reason = 'unrecoverable_journal',
                quarantine_receipt = '{{"receipt":"e2e-quarantine"}}'::jsonb,
                quarantined_bytes = 0
            WHERE id = '{cam['catalog_entry_id']}';
            """
        )
        res = _eval_core_json(
            f"""
            alias ServiceRadar.Actors.SystemActor
            alias ServiceRadar.Camera.{{VantageJob, VantageObservation}}
            actor = SystemActor.system(:mode_b_f2)
            {{:ok, obs}} = VantageObservation.get_by_id("{seeded['obs_id']}", actor: actor, not_found_error?: false)
            p = VantageJob.get_by_id!("{seeded['pending_id']}", actor: actor)
            d = VantageJob.get_by_id!("{seeded['disp_id']}", actor: actor)
            c = VantageJob.get_by_id!("{seeded['done_id']}", actor: actor)
            result = %{{obs_nil: is_nil(obs), p_state: to_string(p.state), d_state: to_string(d.state), c_state: to_string(c.state)}}
            """
        )
        self.assertTrue(res["obs_nil"])
        self.assertEqual(res["p_state"], "cancelled")
        self.assertEqual(res["d_state"], "cancelled")
        self.assertEqual(res["c_state"], "completed")

    @_e2e_case("F2", 1, "E2E-F2-T1-02", "Terminal reclaim (reclaimed + not_required/deleted) purges & cancels")
    def test_e2e_f2_t1_02_live_terminal_reclaim_purges(self) -> None:
        cam = _provision_camera_block_sql_and_ash(
            "f2-t1-02", timeline_start_us=1760000000000000, timeline_end_us=1760000010000000
        )
        self.addCleanup(_cleanup_synthetic_camera_records, source_ids=[cam["camera_source_id"]])
        seeded = self._seed_obs_and_jobs(cam, suffix=uuid.uuid4().hex[:8])
        cnpg_driver.run_psql(
            f"UPDATE platform.camera_recording_catalog SET local_state = 'reclaimed', archive_state = 'not_required' WHERE id = '{cam['catalog_entry_id']}';"
        )
        obs_cnt = cnpg_driver.run_psql(
            f"SELECT count(*) FROM platform.camera_vantage_observations WHERE id = '{seeded['obs_id']}';"
        )
        pending_state = cnpg_driver.run_psql(
            f"SELECT state FROM platform.camera_vantage_jobs WHERE id = '{seeded['pending_id']}';"
        )
        self.assertEqual(obs_cnt, "0")
        self.assertEqual(pending_state, "cancelled")

    @_e2e_case("F2", 1, "E2E-F2-T1-03", "Local eviction (reclaimed + verified) preserves observations & search_tsv")
    def test_e2e_f2_t1_03_live_reclaimed_verified_preserves(self) -> None:
        cam = _provision_camera_block_sql_and_ash(
            "f2-t1-03", timeline_start_us=1760000000000000, timeline_end_us=1760000010000000
        )
        self.addCleanup(_cleanup_synthetic_camera_records, source_ids=[cam["camera_source_id"]])
        seeded = self._seed_obs_and_jobs(cam, suffix=uuid.uuid4().hex[:8])
        cnpg_driver.run_psql(
            f"UPDATE platform.camera_recording_catalog SET local_state = 'reclaimed', archive_state = 'verified' WHERE id = '{cam['catalog_entry_id']}';"
        )
        tsv_cnt = cnpg_driver.run_psql(
            f"SELECT count(*) FROM platform.camera_vantage_observations WHERE id = '{seeded['obs_id']}' AND search_tsv @@ plainto_tsquery('english', 'TEST-742');"
        )
        self.assertEqual(tsv_cnt, "1")

    @_e2e_case("F2", 1, "E2E-F2-T1-04", "RecordingHold blocks local deletion until release_hold and reclaim")
    def test_e2e_f2_t1_04_live_recording_hold_preserves_until_release(self) -> None:
        cam = _provision_camera_block_sql_and_ash(
            "f2-t1-04", timeline_start_us=1760000000000000, timeline_end_us=1760000010000000
        )
        self.addCleanup(_cleanup_synthetic_camera_records, source_ids=[cam["camera_source_id"]])
        seeded = self._seed_obs_and_jobs(cam, suffix=uuid.uuid4().hex[:8])
        res = _eval_core_json(
            f"""
            alias ServiceRadar.Actors.SystemActor
            alias ServiceRadar.Camera.{{RecordingHolds, VantageObservation}}
            sys = SystemActor.system(:mode_b_f2)
            hold_actor = %{{id: "hold-op", role: :operator, permissions: MapSet.new(["devices.view", "devices.cameras.recordings.hold"])}}
            admin = %{{id: "admin-op", role: :admin, permissions: MapSet.new(["settings.recording.manage"])}}
            {{:ok, hold}} = RecordingHolds.place_hold(%{{
              camera_source_id: "{cam['camera_source_id']}",
              stream_profile_id: "{cam['stream_profile_id']}",
              start_us: 1760000000000000,
              end_us: 1760000010000000,
              kind: :investigation,
              reason: "Synthetic E2E hold"
            }}, actor: hold_actor)
            blocked = match?({{:error, {{:blocked_by_hold, _}}}}, RecordingHolds.begin_copy_deletion_intent("{cam['catalog_entry_id']}", :local, %{{reason: :max_local_age}}, actor: admin))
            still_there = match?({{:ok, %VantageObservation{{}}}}, VantageObservation.get_by_id("{seeded['obs_id']}", actor: sys))
            {{:ok, _released}} = RecordingHolds.release_hold(hold.id, %{{reason: "Done"}}, actor: hold_actor)
            result = %{{blocked: blocked, still_there: still_there}}
            """
        )
        self.assertTrue(res["blocked"])
        self.assertTrue(res["still_there"])
        cnpg_driver.run_psql(
            f"UPDATE platform.camera_recording_catalog SET local_state = 'reclaimed', archive_state = 'not_required' WHERE id = '{cam['catalog_entry_id']}';"
        )
        self.assertEqual(
            cnpg_driver.run_psql(
                f"SELECT count(*) FROM platform.camera_vantage_observations WHERE id = '{seeded['obs_id']}';"
            ),
            "0",
        )

    @_e2e_case("F2", 1, "E2E-F2-T1-05", "Source deletion cascades to both recorded and live_keyframe_tap observations")
    def test_e2e_f2_t1_05_live_source_delete_cascades_all(self) -> None:
        live_key = f"obs-live-{uuid.uuid4().hex[:8]}"
        rec_key = f"obs-rec-{uuid.uuid4().hex[:8]}"
        owner_snippet = _elixir_provision_block_snippet(
            "owner",
            tag="f2-t1-05-owner",
            timeline_start_us=1760000000000000,
            timeline_end_us=1760000010000000,
        )
        res = _eval_core_json(
            f"""
            alias ServiceRadar.Actors.SystemActor
            alias ServiceRadar.Camera.{{Source, StreamProfile, VantageJob, VantageObservation}}
            actor = SystemActor.system(:mode_b_f2)
            {{:error, {{:e2e_result, inner}}}} = ServiceRadar.Repo.transaction(fn ->
              uid_live = "{uuid.uuid4().hex[:12]}"
              {{:ok, cam_live}} = Source.create_source(%{{
                device_uid: "sr:synthetic-e2e-live-" <> uid_live,
                vendor: "synthetic",
                vendor_camera_id: "live-" <> uid_live,
                display_name: "Bay 04 Approach",
                assigned_agent_id: "agent-synthetic",
                assigned_gateway_id: "gateway-synthetic"
              }}, actor: actor)
              {{:ok, prof_live}} = StreamProfile.create_profile(%{{
                camera_source_id: cam_live.id,
                profile_name: "main",
                relay_eligible: true
              }}, actor: actor)
              {{:ok, _}} = VantageObservation |> Ash.Changeset.for_create(:upsert_observation, %{{
                observation_key: "{live_key}",
                pipeline_id: "io.serviceradar.vantage-bay-guidance.dock",
                pipeline_version: "1.0.0",
                worker_kind: "external_rust",
                model_id: "bay-guidance-onnx",
                model_version: "1.0.0",
                catalog_entry_id: nil,
                camera_source_id: cam_live.id,
                stream_profile_id: prof_live.id,
                source_mode: :live_keyframe_tap,
                timeline_ts_us: 1760000005000000,
                time_basis: :received,
                category: "vehicle",
                label: "Bay 04 Approach",
                confidence: 0.9,
                attributes: %{{ "bay_id" => "bay-04" }},
                signal_schema_id: "bay_guidance",
                signal_schema_version: "1.0.0",
                display_contract_id: "bay_guidance"
              }}, actor: actor) |> Ash.create(actor: actor)
              Ecto.Adapters.SQL.query!(
                ServiceRadar.Repo,
                "DELETE FROM platform.camera_sources WHERE id = $1",
                [Ecto.UUID.dump!(cam_live.id)]
              )
              %{{rows: [[live_obs_rem]]}} = Ecto.Adapters.SQL.query!(
                ServiceRadar.Repo,
                "SELECT count(*) FROM platform.camera_vantage_observations WHERE camera_source_id = $1",
                [Ecto.UUID.dump!(cam_live.id)]
              )

              {owner_snippet}
              uid_rec = "{uuid.uuid4().hex[:12]}"
              {{:ok, cam_rec}} = Source.create_source(%{{
                device_uid: "sr:synthetic-e2e-rec-" <> uid_rec,
                vendor: "synthetic",
                vendor_camera_id: "rec-" <> uid_rec,
                display_name: "Gate West 01",
                assigned_agent_id: "agent-synthetic",
                assigned_gateway_id: "gateway-synthetic"
              }}, actor: actor)
              {{:ok, prof_rec}} = StreamProfile.create_profile(%{{
                camera_source_id: cam_rec.id,
                profile_name: "main",
                relay_eligible: true
              }}, actor: actor)
              {{:ok, rec_job}} = VantageJob |> Ash.Changeset.for_create(:enqueue, %{{
                pipeline_id: "io.serviceradar.vantage-alpr.vehicle-plate",
                pipeline_version: "1.0.0",
                catalog_entry_id: owner_entry.id,
                camera_source_id: cam_rec.id,
                stream_profile_id: prof_rec.id,
                target_key: "track:cascade-{uuid.uuid4().hex[:8]}",
                target_runner: "camera_vlm",
                subject: "media.jobs.vantage.vlm.v1",
                descriptor_sha256: owner_entry.descriptor_sha256
              }}, actor: actor) |> Ash.create(actor: actor)
              {{:ok, _}} = VantageObservation |> Ash.Changeset.for_create(:upsert_observation, %{{
                observation_key: "{rec_key}",
                pipeline_id: "io.serviceradar.vantage-alpr.vehicle-plate",
                pipeline_version: "1.0.0",
                worker_kind: "camera_vlm",
                model_id: "qwen3.5-4b",
                model_version: "1.0.0",
                job_id: rec_job.id,
                catalog_entry_id: owner_entry.id,
                camera_source_id: cam_rec.id,
                stream_profile_id: prof_rec.id,
                source_mode: :recorded_block,
                fragment_sequence: 0,
                media_pts_ns: 0,
                timeline_ts_us: 1760000000000000,
                time_basis: :received,
                category: "license_plate",
                label: "SR-0100",
                confidence: 0.94,
                attributes: %{{ "plate_text" => "SR-0100" }},
                signal_schema_id: "alpr_plate_read",
                signal_schema_version: "1.0.0",
                display_contract_id: "alpr_plate_read",
                search_text: "SR-0100 Gate West 01"
              }}, actor: actor) |> Ash.create(actor: actor)
              Ecto.Adapters.SQL.query!(
                ServiceRadar.Repo,
                "DELETE FROM platform.camera_sources WHERE id = $1",
                [Ecto.UUID.dump!(cam_rec.id)]
              )
              %{{rows: [[rec_obs_rem]]}} = Ecto.Adapters.SQL.query!(
                ServiceRadar.Repo,
                "SELECT count(*) FROM platform.camera_vantage_observations WHERE camera_source_id = $1",
                [Ecto.UUID.dump!(cam_rec.id)]
              )
              %{{rows: [[rec_jobs_rem]]}} = Ecto.Adapters.SQL.query!(
                ServiceRadar.Repo,
                "SELECT count(*) FROM platform.camera_vantage_jobs WHERE camera_source_id = $1",
                [Ecto.UUID.dump!(cam_rec.id)]
              )
              ServiceRadar.Repo.rollback({{:e2e_result, %{{
                live_obs_rem: live_obs_rem,
                rec_obs_rem: rec_obs_rem,
                rec_jobs_rem: rec_jobs_rem
              }}}})
            end)
            result = inner
            """
        )
        self.assertEqual(res["live_obs_rem"], 0)
        self.assertEqual(res["rec_obs_rem"], 0)
        self.assertEqual(res["rec_jobs_rem"], 0)

    @_e2e_case("F2", 2, "E2E-F2-T2-01", "Direct DELETE on RecordingCatalogEntry cascades FK rows")
    def test_e2e_f2_t2_01_live_catalog_entry_delete_fk_cascade(self) -> None:
        cam = _provision_camera_block_sql_and_ash(
            "f2-t2-01", timeline_start_us=1760000000000000, timeline_end_us=1760000010000000
        )
        self.addCleanup(_cleanup_synthetic_camera_records, source_ids=[cam["camera_source_id"]])
        seeded = self._seed_obs_and_jobs(cam, suffix=uuid.uuid4().hex[:8])
        cnpg_driver.run_psql(
            f"DELETE FROM platform.camera_recording_catalog WHERE id = '{cam['catalog_entry_id']}';"
        )
        self.assertEqual(
            cnpg_driver.run_psql(
                f"SELECT count(*) FROM platform.camera_vantage_observations WHERE id = '{seeded['obs_id']}';"
            ),
            "0",
        )
        self.assertEqual(
            cnpg_driver.run_psql(
                f"SELECT count(*) FROM platform.camera_vantage_jobs WHERE catalog_entry_id = '{cam['catalog_entry_id']}';"
            ),
            "0",
        )

    @_e2e_case("F2", 2, "E2E-F2-T2-02", "Dispatched job cancelled on quarantine rejects late result projection")
    def test_e2e_f2_t2_02_live_quarantine_cancels_dispatched_and_rejects_late(self) -> None:
        cam = _provision_camera_block_sql_and_ash(
            "f2-t2-02", timeline_start_us=1760000000000000, timeline_end_us=1760000010000000
        )
        pid = f"io.serviceradar.e2e.f2-{uuid.uuid4().hex[:8]}"
        self.addCleanup(
            _cleanup_synthetic_camera_records,
            source_ids=[cam["camera_source_id"]],
            pipeline_ids=[pid],
        )
        seeded = self._seed_obs_and_jobs(cam, suffix=uuid.uuid4().hex[:8], pipeline_id=pid)
        cnpg_driver.run_psql(
            f"""
            UPDATE platform.camera_recording_catalog
            SET local_state = 'quarantined',
                quarantine_reason = 'unrecoverable_journal',
                quarantine_receipt = '{{"receipt":"e2e-late"}}'::jsonb,
                quarantined_bytes = 0
            WHERE id = '{cam['catalog_entry_id']}';
            """
        )
        res = _eval_core_json(
            f"""
            alias ServiceRadar.Actors.SystemActor
            alias ServiceRadar.Camera.{{VantageObservationProjector, VantagePipeline}}
            actor = SystemActor.system(:mode_b_f2)
            {{:ok, _}} = VantagePipeline |> Ash.Changeset.for_create(:upsert, %{{
              pipeline_id: "{pid}",
              version: "1.0.0",
              name: "F2 Late Result",
              enabled: true,
              signal_schema_id: "alpr_plate_read",
              signal_schema_version: "1.0.0",
              display_contract_id: "alpr_plate_read"
            }}, actor: actor) |> Ash.create(actor: actor)
            payload = %{{
              "schema_version" => "vantage.result.v1",
              "source_mode" => "recorded_block",
              "job_id" => "{seeded['disp_id']}",
              "catalog_entry_id" => "{cam['catalog_entry_id']}",
              "descriptor_sha256" => "{cam['descriptor_sha256']}",
              "camera_source_id" => "{cam['camera_source_id']}",
              "stream_profile_id" => "{cam['stream_profile_id']}",
              "pipeline_id" => "{pid}",
              "pipeline_version" => "1.0.0",
              "worker_kind" => "camera_vlm",
              "worker_id" => "worker-1",
              "model_id" => "qwen3.5-4b",
              "model_version" => "1.0.0",
              "observations" => [
                %{{
                  "observation_key" => "late-#{uuid.uuid4().hex[:8]}",
                  "fragment_sequence" => 0,
                  "media_pts_ns" => 0,
                  "timeline_ts_us" => 1760000000000000,
                  "time_basis" => "received",
                  "category" => "license_plate",
                  "label" => "SR-0100",
                  "confidence" => 0.9,
                  "bbox" => [0.3, 0.4, 0.5, 0.7],
                  "attributes" => %{{"plate_text" => "SR-0100"}},
                  "signal_schema_id" => "alpr_plate_read",
                  "signal_schema_version" => "1.0.0",
                  "display_contract_id" => "alpr_plate_read"
                }}
              ]
            }}
            res = VantageObservationProjector.ingest_result(payload)
            result = %{{err: inspect(res)}}
            """
        )
        self.assertIn("recording_gone", res["err"])

    @_e2e_case("F2", 2, "E2E-F2-T2-03", "RecordingHold half-open boundary excludes timeline_end_us == h_start")
    def test_e2e_f2_t2_03_live_hold_half_open_boundary(self) -> None:
        cam_snippet = _elixir_provision_block_snippet(
            "b",
            tag="f2-t2-03",
            timeline_start_us=1760000000000000,
            timeline_end_us=1760000010000000,
        )
        res = _eval_core_json(
            f"""
            alias ServiceRadar.Actors.SystemActor
            alias ServiceRadar.Camera.RecordingHolds
            actor = SystemActor.system(:mode_b_f2)
            hold_actor = %{{id: "hold-op", role: :operator, permissions: MapSet.new(["devices.view", "devices.cameras.recordings.hold"])}}
            admin = %{{id: "admin-op", role: :admin, permissions: MapSet.new(["settings.recording.manage"])}}
            {{:error, {{:e2e_result, inner}}}} = ServiceRadar.Repo.transaction(fn ->
              {cam_snippet}
              {{:ok, _hold}} = RecordingHolds.place_hold(%{{
                camera_source_id: b_cam.id,
                stream_profile_id: b_prof.id,
                start_us: 1760000010000000,
                end_us: 1760000020000000,
                kind: :investigation,
                reason: "Boundary hold"
              }}, actor: hold_actor)
              intent_ok = match?({{:ok, _}}, RecordingHolds.begin_copy_deletion_intent(b_entry.id, :local, %{{reason: :max_local_age}}, actor: admin))
              ServiceRadar.Repo.rollback({{:e2e_result, %{{intent_ok: intent_ok}}}})
            end)
            result = inner
            """
        )
        self.assertTrue(res["intent_ok"])

    @_e2e_case("F2", 2, "E2E-F2-T2-04", "Live-tap observation survives sibling recorded block reclaim")
    def test_e2e_f2_t2_04_live_tap_survives_sibling_reclaim(self) -> None:
        cam = _provision_camera_block_sql_and_ash(
            "f2-t2-04", timeline_start_us=1760000000000000, timeline_end_us=1760000010000000
        )
        self.addCleanup(_cleanup_synthetic_camera_records, source_ids=[cam["camera_source_id"]])
        live_key = f"obs-live-keep-{uuid.uuid4().hex[:8]}"
        _eval_core_json(
            f"""
            alias ServiceRadar.Actors.SystemActor
            alias ServiceRadar.Camera.VantageObservation
            actor = SystemActor.system(:mode_b_f2)
            {{:ok, _}} = VantageObservation |> Ash.Changeset.for_create(:upsert_observation, %{{
              observation_key: "{live_key}",
              pipeline_id: "io.serviceradar.vantage-bay-guidance.dock",
              pipeline_version: "1.0.0",
              worker_kind: "external_rust",
              model_id: "bay-guidance-onnx",
              model_version: "1.0.0",
              catalog_entry_id: nil,
              camera_source_id: "{cam['camera_source_id']}",
              stream_profile_id: "{cam['stream_profile_id']}",
              source_mode: :live_keyframe_tap,
              timeline_ts_us: 1760000005000000,
              time_basis: :received,
              category: "vehicle",
              label: "Bay 04 Approach",
              confidence: 0.9,
              attributes: %{{ "bay_id" => "bay-04" }},
              signal_schema_id: "bay_guidance",
              signal_schema_version: "1.0.0",
              display_contract_id: "bay_guidance"
            }}, actor: actor) |> Ash.create(actor: actor)
            result = %{{ok: true}}
            """
        )
        cnpg_driver.run_psql(
            f"UPDATE platform.camera_recording_catalog SET local_state = 'reclaimed', archive_state = 'not_required' WHERE id = '{cam['catalog_entry_id']}';"
        )
        self.assertEqual(
            cnpg_driver.run_psql(
                f"SELECT count(*) FROM platform.camera_vantage_observations WHERE observation_key = '{live_key}';"
            ),
            "1",
        )

    @_e2e_case("F2", 2, "E2E-F2-T2-05", "Unrelated archive_state update on present block does not purge")
    def test_e2e_f2_t2_05_live_unrelated_update_does_not_purge(self) -> None:
        cam = _provision_camera_block_sql_and_ash(
            "f2-t2-05", timeline_start_us=1760000000000000, timeline_end_us=1760000010000000
        )
        self.addCleanup(_cleanup_synthetic_camera_records, source_ids=[cam["camera_source_id"]])
        seeded = self._seed_obs_and_jobs(cam, suffix=uuid.uuid4().hex[:8])
        cnpg_driver.run_psql(
            f"UPDATE platform.camera_recording_catalog SET archive_state = 'verified' WHERE id = '{cam['catalog_entry_id']}';"
        )
        self.assertEqual(
            cnpg_driver.run_psql(
                f"SELECT count(*) FROM platform.camera_vantage_observations WHERE id = '{seeded['obs_id']}';"
            ),
            "1",
        )
        self.assertEqual(
            cnpg_driver.run_psql(
                f"SELECT state FROM platform.camera_vantage_jobs WHERE id = '{seeded['pending_id']}';"
            ),
            "pending",
        )


class ModeBF3JetStreamAndOcsfTest(unittest.TestCase):
    """F3 Mode B: Ephemeral JetStream delivery/dedup + EventWriter CameraVantageObservations + OCSF 1008."""

    @classmethod
    def setUpClass(cls) -> None:
        cnpg_driver.require_database_url()
        env_probe.probe_binary("psql")
        env_probe.probe_binary("mix")
        env_probe.probe_binary("nats")
        env_probe.probe_binary("nats-server")

    def _start_ephemeral_results_stream(self) -> tuple[str, str]:
        port = _free_tcp_port()
        proc, nats_url, store = nats_driver.start_ephemeral_jetstream(port=port, timeout=10.0)
        self.addCleanup(shutil.rmtree, store, True)
        self.addCleanup(self._stop_proc, proc)
        with _isolated_nats_cli_env():
            nats_driver.run_nats_cli(
                [
                    "stream",
                    "add",
                    "CAMERA_MEDIA_RESULTS",
                    "--subjects",
                    "media.results.visual_index.v1,media.results.vantage.v1",
                    "--storage",
                    "file",
                    "--retention",
                    "limits",
                    "--dupe-window",
                    "2m",
                    "--defaults",
                ],
                nats_url=nats_url,
            )
        return nats_url, "CAMERA_MEDIA_RESULTS"

    @staticmethod
    def _stop_proc(proc: subprocess.Popen[bytes]) -> None:
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

    def _fetch_stream_payload(self, nats_url: str, stream: str, seq: int) -> bytes:
        with _isolated_nats_cli_env():
            proc = nats_driver.run_nats_cli(["stream", "get", stream, str(seq), "--json"], nats_url=nats_url)
        msg = json.loads(proc.stdout.decode("utf-8"))
        return base64.b64decode(msg["data"])

    def _setup_pipeline_and_job(
        self,
        *,
        emit_ocsf: bool = True,
        source_mode: str = "recorded_block",
        signal_schema_id: str = "alpr_plate_read",
    ) -> dict[str, str]:
        cam = _provision_camera_block_sql_and_ash(
            f"f3-{uuid.uuid4().hex[:6]}",
            timeline_start_us=1760000000000000,
            timeline_end_us=1760000010000000,
        )
        pid = f"io.serviceradar.e2e.f3-{uuid.uuid4().hex[:8]}"
        self.addCleanup(
            _cleanup_synthetic_camera_records,
            source_ids=[cam["camera_source_id"]],
            pipeline_ids=[pid],
        )
        schema_map = (
            '%{ "type" => "object", "required" => ["plate_text"], "properties" => %{ "plate_text" => %{ "type" => "string", "pattern" => "^[A-Z0-9-]{2,12}$" } }, "additionalProperties" => true }'
            if signal_schema_id == "alpr_plate_read"
            else '%{ "type" => "object", "required" => ["bay_id", "guidance_state"], "properties" => %{ "bay_id" => %{ "type" => "string" }, "guidance_state" => %{ "type" => "string" } }, "additionalProperties" => true }'
        )
        trigger = "on_stage1_detection" if source_mode == "recorded_block" else "live_keyframe_tap"
        res = _eval_core_json(
            f"""
            alias ServiceRadar.Actors.SystemActor
            alias ServiceRadar.Camera.{{VantageJob, VantagePipeline}}
            actor = SystemActor.system(:mode_b_f3)
            {{:ok, p}} = VantagePipeline |> Ash.Changeset.for_create(:upsert, %{{
              pipeline_id: "{pid}",
              version: "1.0.0",
              name: "F3 E2E Pipeline",
              enabled: true,
              source_mode: :{source_mode},
              trigger_kind: :{trigger},
              signal_schema_id: "{signal_schema_id}",
              signal_schema_version: "1.0.0",
              signal_schema: {schema_map},
              display_contract_id: "{signal_schema_id}",
              emit_ocsf_events: {"true" if emit_ocsf else "false"},
              pack_id: "io.serviceradar.vantage-alpr",
              pack_version: "1.0.0"
            }}, actor: actor) |> Ash.create(actor: actor)
            job_id = if "{source_mode}" == "recorded_block" do
              {{:ok, job}} = VantageJob |> Ash.Changeset.for_create(:enqueue, %{{
                vantage_pipeline_id: p.id,
                pipeline_id: "{pid}",
                pipeline_version: "1.0.0",
                catalog_entry_id: "{cam['catalog_entry_id']}",
                camera_source_id: "{cam['camera_source_id']}",
                stream_profile_id: "{cam['stream_profile_id']}",
                target_key: "track:1",
                target_runner: "camera_vlm",
                subject: "media.jobs.vantage.vlm.v1",
                descriptor_sha256: "{cam['descriptor_sha256']}"
              }}, actor: actor) |> Ash.create(actor: actor)
              job.id
            else
              nil
            end
            result = %{{pipeline_id: "{pid}", job_id: job_id}}
            """
        )
        return {**cam, **res}

    @_e2e_case("F3", 1, "E2E-F3-T1-01", "JetStream recorded result ingests via EventWriter and emits OCSF 1008")
    def test_e2e_f3_t1_01_live_jetstream_ingest_and_ocsf_1008(self) -> None:
        nats_url, stream = self._start_ephemeral_results_stream()
        ctx = self._setup_pipeline_and_job(emit_ocsf=True)
        f3 = _load_json("f1_f5/f3_jetstream_result_vectors.json")
        env = copy.deepcopy(f3["positive"]["recorded_alpr"])
        env["job_id"] = ctx["job_id"]
        env["pipeline_id"] = ctx["pipeline_id"]
        env["camera_source_id"] = ctx["camera_source_id"]
        env["stream_profile_id"] = ctx["stream_profile_id"]
        env["catalog_entry_id"] = ctx["catalog_entry_id"]
        env["descriptor_sha256"] = ctx["descriptor_sha256"]
        env["observations"][0]["observation_key"] = f"obs-f3-01-{uuid.uuid4().hex[:8]}"

        _publish_js_json(
            "media.results.vantage.v1",
            env,
            msg_id=f"vantage-result:{ctx['job_id']}",
            nats_url=nats_url,
        )
        raw_js = self._fetch_stream_payload(nats_url, stream, 1)
        res = _eval_core_json(
            f"""
            alias ServiceRadar.Actors.SystemActor
            alias ServiceRadar.Camera.{{VantageJob, VantageObservationProjector}}
            actor = SystemActor.system(:mode_b_f3)
            raw = Base.decode64!("{base64.b64encode(raw_js).decode('ascii')}")
            parent = self()
            ocsf_opts = [
              publish: fn subject, body, _opts ->
                send(parent, {{:ocsf, subject, Jason.decode!(body)}})
                :ok
              end,
              suppress?: fn _ -> false end
            ]
            {{:ok, summary}} = VantageObservationProjector.ingest_result(raw, ocsf_opts: ocsf_opts)
            ocsf = receive do {{:ocsf, subj, ev}} -> %{{subject: subj, class_uid: ev["class_uid"], schema_id: get_in(ev, ["metadata", "service_radar", "signal_schema", "schema_id"])}} after 1000 -> nil end
            job = VantageJob.get_by_id!("{ctx['job_id']}", actor: actor)
            result = %{{count: summary.observation_count, job_state: to_string(job.state), ocsf: ocsf}}
            """
        )
        self.assertEqual(res["count"], 1)
        self.assertEqual(res["job_state"], "completed")
        self.assertEqual(res["ocsf"]["class_uid"], 1008)
        self.assertEqual(res["ocsf"]["schema_id"], "alpr_plate_read")

    @_e2e_case("F3", 1, "E2E-F3-T1-02", "Nats-Msg-Id JetStream deduplication & EventWriter replay idempotency")
    def test_e2e_f3_t1_02_live_nats_msg_id_dedup_and_replay_idempotency(self) -> None:
        nats_url, stream = self._start_ephemeral_results_stream()
        ctx = self._setup_pipeline_and_job(emit_ocsf=False)
        f3 = _load_json("f1_f5/f3_jetstream_result_vectors.json")
        env = copy.deepcopy(f3["positive"]["recorded_alpr"])
        env["job_id"] = ctx["job_id"]
        env["pipeline_id"] = ctx["pipeline_id"]
        env["camera_source_id"] = ctx["camera_source_id"]
        env["stream_profile_id"] = ctx["stream_profile_id"]
        env["catalog_entry_id"] = ctx["catalog_entry_id"]
        env["descriptor_sha256"] = ctx["descriptor_sha256"]
        obs_key = f"obs-f3-02-{uuid.uuid4().hex[:8]}"
        env["observations"][0]["observation_key"] = obs_key

        msg_id = f"vantage-result:{ctx['job_id']}"
        _publish_js_json("media.results.vantage.v1", env, msg_id=msg_id, nats_url=nats_url)
        _publish_js_json("media.results.vantage.v1", env, msg_id=msg_id, nats_url=nats_url)
        with _isolated_nats_cli_env():
            info = nats_driver.stream_info(stream, nats_url=nats_url)
        self.assertEqual(info["state"]["messages"], 1)

        raw_js = self._fetch_stream_payload(nats_url, stream, 1)
        res = _eval_core_json(
            f"""
            alias Broadway.Message
            alias ServiceRadar.EventWriter.Processors.CameraVantageObservations
            raw = Base.decode64!("{base64.b64encode(raw_js).decode('ascii')}")
            msg = %Message{{data: raw, metadata: %{{subject: "media.results.vantage.v1"}}, acknowledger: Broadway.NoopAcknowledger.init()}}
            r1 = CameraVantageObservations.process_batch([msg])
            r2 = CameraVantageObservations.process_batch([msg])
            result = %{{r1: inspect(r1), r2: inspect(r2)}}
            """
        )
        self.assertEqual(res["r1"], "{:ok, 1}")
        self.assertEqual(res["r2"], "{:ok, 0}")
        self.assertEqual(
            cnpg_driver.run_psql(
                f"SELECT count(*) FROM platform.camera_vantage_observations WHERE observation_key = '{obs_key}';"
            ),
            "1",
        )

    @_e2e_case("F3", 1, "E2E-F3-T1-03", "Live-tap JetStream result persists null catalog_entry_id & broadcasts PubSub")
    def test_e2e_f3_t1_03_live_tap_jetstream_and_pubsub(self) -> None:
        nats_url, stream = self._start_ephemeral_results_stream()
        ctx = self._setup_pipeline_and_job(
            emit_ocsf=False, source_mode="live_keyframe_tap", signal_schema_id="bay_guidance"
        )
        f3 = _load_json("f1_f5/f3_jetstream_result_vectors.json")
        env = copy.deepcopy(f3["positive"]["live_tap_python"])
        env["pipeline_id"] = ctx["pipeline_id"]
        env["camera_source_id"] = ctx["camera_source_id"]
        env["stream_profile_id"] = ctx["stream_profile_id"]
        env["observations"][0]["observation_key"] = f"obs-f3-03-{uuid.uuid4().hex[:8]}"

        _publish_js_json("media.results.vantage.v1", env, nats_url=nats_url)
        raw_js = self._fetch_stream_payload(nats_url, stream, 1)
        res = _eval_core_json(
            f"""
            alias ServiceRadar.Camera.{{VantageObservationProjector, VantagePubSub}}
            raw = Base.decode64!("{base64.b64encode(raw_js).decode('ascii')}")
            :ok = VantagePubSub.subscribe("{ctx['camera_source_id']}")
            {{:ok, summary}} = VantageObservationProjector.ingest_result(raw)
            pubsub_hit = receive do {{:camera_vantage_observations, _}} -> true after 1000 -> false end
            result = %{{count: summary.observation_count, pubsub_hit: pubsub_hit}}
            """
        )
        self.assertEqual(res["count"], 1)
        self.assertTrue(res["pubsub_hit"])

    @_e2e_case("F3", 1, "E2E-F3-T1-04", "emit_ocsf_events=false stores observation without OCSF emission")
    def test_e2e_f3_t1_04_live_emit_ocsf_false_suppresses_ocsf(self) -> None:
        ctx = self._setup_pipeline_and_job(emit_ocsf=False)
        f3 = _load_json("f1_f5/f3_jetstream_result_vectors.json")
        env = copy.deepcopy(f3["positive"]["recorded_alpr"])
        env["job_id"] = ctx["job_id"]
        env["pipeline_id"] = ctx["pipeline_id"]
        env["camera_source_id"] = ctx["camera_source_id"]
        env["stream_profile_id"] = ctx["stream_profile_id"]
        env["catalog_entry_id"] = ctx["catalog_entry_id"]
        env["descriptor_sha256"] = ctx["descriptor_sha256"]
        env["observations"][0]["observation_key"] = f"obs-f3-04-{uuid.uuid4().hex[:8]}"
        res = _eval_core_json(
            f"""
            alias ServiceRadar.Camera.VantageObservationProjector
            raw = Base.decode64!("{base64.b64encode(json.dumps(env).encode('utf-8')).decode('ascii')}")
            parent = self()
            ocsf_opts = [publish: fn s, b, _ -> send(parent, {{:ocsf, s, b}}); :ok end, suppress?: fn _ -> false end]
            {{:ok, summary}} = VantageObservationProjector.ingest_result(raw, ocsf_opts: ocsf_opts)
            emitted = receive do {{:ocsf, _, _}} -> true after 150 -> false end
            result = %{{count: summary.observation_count, emitted: emitted}}
            """
        )
        self.assertEqual(res["count"], 1)
        self.assertFalse(res["emitted"])

    @_e2e_case("F3", 1, "E2E-F3-T1-05", "Empty observations: [] completes VantageJob with 0 rows")
    def test_e2e_f3_t1_05_live_empty_observations_completes_job(self) -> None:
        ctx = self._setup_pipeline_and_job(emit_ocsf=True)
        f3 = _load_json("f1_f5/f3_jetstream_result_vectors.json")
        env = copy.deepcopy(f3["positive"]["empty_observations_batch"])
        env["job_id"] = ctx["job_id"]
        env["pipeline_id"] = ctx["pipeline_id"]
        env["camera_source_id"] = ctx["camera_source_id"]
        env["stream_profile_id"] = ctx["stream_profile_id"]
        env["catalog_entry_id"] = ctx["catalog_entry_id"]
        env["descriptor_sha256"] = ctx["descriptor_sha256"]
        res = _eval_core_json(
            f"""
            alias ServiceRadar.Actors.SystemActor
            alias ServiceRadar.Camera.{{VantageJob, VantageObservationProjector}}
            actor = SystemActor.system(:mode_b_f3)
            raw = Base.decode64!("{base64.b64encode(json.dumps(env).encode('utf-8')).decode('ascii')}")
            {{:ok, summary}} = VantageObservationProjector.ingest_result(raw)
            job = VantageJob.get_by_id!("{ctx['job_id']}", actor: actor)
            result = %{{count: summary.observation_count, job_state: to_string(job.state)}}
            """
        )
        self.assertEqual(res["count"], 0)
        self.assertEqual(res["job_state"], "completed")

    def _run_terminal_rejection(self, env: dict[str, Any], job_id: str | None) -> dict[str, Any]:
        raw_b64 = base64.b64encode(json.dumps(env).encode("utf-8")).decode("ascii")
        job_check = (
            f'job = ServiceRadar.Camera.VantageJob.get_by_id!("{job_id}", actor: ServiceRadar.Actors.SystemActor.system(:mode_b_f3)); job_state = to_string(job.state)'
            if job_id
            else 'job_state = "none"'
        )
        return _eval_core_json(
            f"""
            alias Broadway.Message
            alias ServiceRadar.EventWriter.Processors.CameraVantageObservations
            alias ServiceRadar.EventWriter.TerminalMessageError
            raw = Base.decode64!("{raw_b64}")
            msg = %Message{{data: raw, metadata: %{{subject: "media.results.vantage.v1"}}, acknowledger: Broadway.NoopAcknowledger.init()}}
            res = CameraVantageObservations.process_batch([msg])
            {{term, reason}} = case res do
              {{:incomplete, 0, [{{_, %TerminalMessageError{{reason: r}}}}]}} -> {{true, inspect(r)}}
              other -> {{false, inspect(other)}}
            end
            {job_check}
            result = %{{terminal: term, reason: reason, job_state: job_state}}
            """
        )

    @_e2e_case("F3", 2, "E2E-F3-T2-01", "Signal schema violation triggers TerminalMessageError and failed_terminal")
    def test_e2e_f3_t2_01_live_signal_schema_violation_terminal_error(self) -> None:
        ctx = self._setup_pipeline_and_job(emit_ocsf=True)
        f3 = _load_json("f1_f5/f3_jetstream_result_vectors.json")
        env = copy.deepcopy(f3["positive"]["recorded_alpr"])
        env["job_id"] = ctx["job_id"]
        env["pipeline_id"] = ctx["pipeline_id"]
        env["camera_source_id"] = ctx["camera_source_id"]
        env["stream_profile_id"] = ctx["stream_profile_id"]
        env["catalog_entry_id"] = ctx["catalog_entry_id"]
        env["descriptor_sha256"] = ctx["descriptor_sha256"]
        env["observations"][0]["attributes"]["plate_text"] = "bad plate!"
        res = self._run_terminal_rejection(env, ctx["job_id"])
        self.assertTrue(res["terminal"])
        self.assertIn("signal_schema_violation", res["reason"])
        self.assertEqual(res["job_state"], "failed_terminal")

    @_e2e_case("F3", 2, "E2E-F3-T2-02", "32769 B crop_jpeg_b64 and non-JPEG rejected as TerminalMessageError")
    def test_e2e_f3_t2_02_live_oversized_or_non_jpeg_crop_terminal_error(self) -> None:
        ctx = self._setup_pipeline_and_job(emit_ocsf=False)
        f3 = _load_json("f1_f5/f3_jetstream_result_vectors.json")
        base_jpeg = vc.make_synthetic_baseline_jfif(64, 48, seed=7, target_max_bytes=4096)
        pad = 32769 - len(base_jpeg) - 4
        bad_32k1 = base_jpeg[:20] + b"\xFF\xFE" + (pad + 2).to_bytes(2, "big") + (b"V" * pad) + base_jpeg[20:]
        env = copy.deepcopy(f3["positive"]["recorded_alpr"])
        env["job_id"] = ctx["job_id"]
        env["pipeline_id"] = ctx["pipeline_id"]
        env["camera_source_id"] = ctx["camera_source_id"]
        env["stream_profile_id"] = ctx["stream_profile_id"]
        env["catalog_entry_id"] = ctx["catalog_entry_id"]
        env["descriptor_sha256"] = ctx["descriptor_sha256"]
        env["observations"][0]["crop_jpeg_b64"] = base64.b64encode(bad_32k1).decode("ascii")
        res = self._run_terminal_rejection(env, ctx["job_id"])
        self.assertTrue(res["terminal"])
        self.assertIn("crop_too_large", res["reason"])

        ctx2 = self._setup_pipeline_and_job(emit_ocsf=False)
        env2 = copy.deepcopy(f3["positive"]["recorded_alpr"])
        env2["job_id"] = ctx2["job_id"]
        env2["pipeline_id"] = ctx2["pipeline_id"]
        env2["camera_source_id"] = ctx2["camera_source_id"]
        env2["stream_profile_id"] = ctx2["stream_profile_id"]
        env2["catalog_entry_id"] = ctx2["catalog_entry_id"]
        env2["descriptor_sha256"] = ctx2["descriptor_sha256"]
        env2["observations"][0]["observation_key"] = f"obs-f3-nonjpeg-{uuid.uuid4().hex[:8]}"
        env2["observations"][0]["crop_jpeg_b64"] = base64.b64encode(b"not-a-jpeg").decode("ascii")
        res2 = self._run_terminal_rejection(env2, ctx2["job_id"])
        self.assertTrue(res2["terminal"])
        self.assertIn("invalid_crop_jpeg", res2["reason"])

    @_e2e_case("F3", 2, "E2E-F3-T2-03", "Inverted bbox and out-of-range confidence rejected as TerminalMessageError")
    def test_e2e_f3_t2_03_live_bad_bbox_and_confidence_terminal_error(self) -> None:
        ctx = self._setup_pipeline_and_job(emit_ocsf=False)
        f3 = _load_json("f1_f5/f3_jetstream_result_vectors.json")
        env = copy.deepcopy(f3["positive"]["recorded_alpr"])
        env["job_id"] = ctx["job_id"]
        env["pipeline_id"] = ctx["pipeline_id"]
        env["camera_source_id"] = ctx["camera_source_id"]
        env["stream_profile_id"] = ctx["stream_profile_id"]
        env["catalog_entry_id"] = ctx["catalog_entry_id"]
        env["descriptor_sha256"] = ctx["descriptor_sha256"]
        env["observations"][0]["bbox"] = [0.6, 0.2, 0.4, 0.8]
        res = self._run_terminal_rejection(env, ctx["job_id"])
        self.assertTrue(res["terminal"])
        self.assertIn("invalid_bbox", res["reason"])

        ctx2 = self._setup_pipeline_and_job(emit_ocsf=False)
        env2 = copy.deepcopy(f3["positive"]["recorded_alpr"])
        env2["job_id"] = ctx2["job_id"]
        env2["pipeline_id"] = ctx2["pipeline_id"]
        env2["camera_source_id"] = ctx2["camera_source_id"]
        env2["stream_profile_id"] = ctx2["stream_profile_id"]
        env2["catalog_entry_id"] = ctx2["catalog_entry_id"]
        env2["descriptor_sha256"] = ctx2["descriptor_sha256"]
        env2["observations"][0]["observation_key"] = f"obs-f3-badconf-{uuid.uuid4().hex[:8]}"
        env2["observations"][0]["confidence"] = 1.05
        res2 = self._run_terminal_rejection(env2, ctx2["job_id"])
        self.assertTrue(res2["terminal"])
        self.assertIn("invalid_result_envelope", res2["reason"])

    @_e2e_case("F3", 2, "E2E-F3-T2-04", "Descriptor SHA-256 mismatch and quarantined block drop cleanly")
    def test_e2e_f3_t2_04_live_sha_mismatch_and_quarantined_drop(self) -> None:
        ctx = self._setup_pipeline_and_job(emit_ocsf=False)
        f3 = _load_json("f1_f5/f3_jetstream_result_vectors.json")
        env = copy.deepcopy(f3["positive"]["recorded_alpr"])
        env["job_id"] = ctx["job_id"]
        env["pipeline_id"] = ctx["pipeline_id"]
        env["camera_source_id"] = ctx["camera_source_id"]
        env["stream_profile_id"] = ctx["stream_profile_id"]
        env["catalog_entry_id"] = ctx["catalog_entry_id"]
        env["descriptor_sha256"] = "0" * 64
        env["observations"][0]["observation_key"] = f"obs-f3-sha-{uuid.uuid4().hex[:8]}"
        res = self._run_terminal_rejection(env, ctx["job_id"])
        self.assertTrue(res["terminal"])
        self.assertEqual(
            cnpg_driver.run_psql(
                f"SELECT count(*) FROM platform.camera_vantage_observations WHERE catalog_entry_id = '{ctx['catalog_entry_id']}';"
            ),
            "0",
        )

        ctx_q = self._setup_pipeline_and_job(emit_ocsf=False)
        cnpg_driver.run_psql(
            f"""
            UPDATE platform.camera_recording_catalog
            SET local_state = 'quarantined',
                quarantine_reason = 'unrecoverable_journal',
                quarantine_receipt = '{{"receipt":"e2e-f3-quarantine"}}'::jsonb,
                quarantined_bytes = 0
            WHERE id = '{ctx_q['catalog_entry_id']}';
            """
        )
        env_q = copy.deepcopy(f3["positive"]["recorded_alpr"])
        env_q["job_id"] = ctx_q["job_id"]
        env_q["pipeline_id"] = ctx_q["pipeline_id"]
        env_q["camera_source_id"] = ctx_q["camera_source_id"]
        env_q["stream_profile_id"] = ctx_q["stream_profile_id"]
        env_q["catalog_entry_id"] = ctx_q["catalog_entry_id"]
        env_q["descriptor_sha256"] = ctx_q["descriptor_sha256"]
        env_q["observations"][0]["observation_key"] = f"obs-f3-quar-{uuid.uuid4().hex[:8]}"
        raw_q_b64 = base64.b64encode(json.dumps(env_q).encode("utf-8")).decode("ascii")
        res_q = _eval_core_json(
            f"""
            alias Broadway.Message
            alias ServiceRadar.Camera.VantageObservationProjector
            alias ServiceRadar.EventWriter.Processors.CameraVantageObservations
            raw = Base.decode64!("{raw_q_b64}")
            proj_res = VantageObservationProjector.ingest_result(raw)
            msg = %Message{{data: raw, metadata: %{{subject: "media.results.vantage.v1"}}, acknowledger: Broadway.NoopAcknowledger.init()}}
            ew_res = CameraVantageObservations.process_batch([msg])
            result = %{{proj: inspect(proj_res), ew: inspect(ew_res)}}
            """
        )
        self.assertEqual(res_q["proj"], "{:error, :recording_gone}")
        self.assertEqual(res_q["ew"], "{:ok, 0}")
        self.assertEqual(
            cnpg_driver.run_psql(
                f"SELECT count(*) FROM platform.camera_vantage_observations WHERE catalog_entry_id = '{ctx_q['catalog_entry_id']}';"
            ),
            "0",
        )

    @_e2e_case("F3", 2, "E2E-F3-T2-05", ">960 KiB raw payload & wrong schema_version rejected cleanly")
    def test_e2e_f3_t2_05_live_oversized_payload_and_bad_schema_version(self) -> None:
        ctx = self._setup_pipeline_and_job(emit_ocsf=False)
        f3 = _load_json("f1_f5/f3_jetstream_result_vectors.json")
        env = copy.deepcopy(f3["positive"]["recorded_alpr"])
        env["schema_version"] = "vantage.result.v99"
        env["job_id"] = ctx["job_id"]
        env["pipeline_id"] = ctx["pipeline_id"]
        env["camera_source_id"] = ctx["camera_source_id"]
        env["stream_profile_id"] = ctx["stream_profile_id"]
        env["catalog_entry_id"] = ctx["catalog_entry_id"]
        env["descriptor_sha256"] = ctx["descriptor_sha256"]
        res = self._run_terminal_rejection(env, ctx["job_id"])
        self.assertTrue(res["terminal"])
        self.assertIn("invalid_result_envelope", res["reason"])

        oversized = b"{" + (b" " * vc.MAX_RESULT_ENVELOPE_BYTES) + b"}"
        res2 = _eval_core_json(
            f"""
            alias Broadway.Message
            alias ServiceRadar.EventWriter.Processors.CameraVantageObservations
            alias ServiceRadar.EventWriter.TerminalMessageError
            raw = Base.decode64!("{base64.b64encode(oversized).decode('ascii')}")
            msg = %Message{{data: raw, metadata: %{{subject: "media.results.vantage.v1"}}, acknowledger: Broadway.NoopAcknowledger.init()}}
            {{:incomplete, 0, [{{_, %TerminalMessageError{{reason: r}}}}]}} = CameraVantageObservations.process_batch([msg])
            result = %{{reason: to_string(r)}}
            """
        )
        self.assertEqual(res2["reason"], "envelope_too_large")


class ModeBF4MediaCoreCropperTest(unittest.TestCase):
    """F4 Mode B: Live `cargo test -p serviceradar-media-core` execution against crop.rs & vantage_protocol.rs."""

    _cargo_stdout: str = ""

    @classmethod
    def setUpClass(cls) -> None:
        cargo = env_probe.probe_binary("cargo")
        proc = subprocess.run(
            [str(cargo), "test", "-p", "serviceradar-media-core"],
            cwd=str(vc.repo_root()),
            env=_cargo_env(),
            capture_output=True,
            text=True,
            timeout=180,
        )
        if proc.returncode != 0:
            raise RuntimeError(
                f"cargo test -p serviceradar-media-core failed (rc={proc.returncode}):\n{proc.stdout}\n{proc.stderr}"
            )
        cls._cargo_stdout = proc.stdout

    def _assert_rust_test_passed(self, rust_test_substr: str) -> None:
        matching = [
            line
            for line in self._cargo_stdout.splitlines()
            if rust_test_substr in line and line.strip().endswith("... ok")
        ]
        self.assertTrue(
            matching,
            f"expected Rust media-core test matching {rust_test_substr!r} to pass in:\n{self._cargo_stdout}",
        )

    @_e2e_case("F4", 1, "E2E-F4-T1-01", "Rust media-core 1080p native RGB crop within <= 96 KiB Baseline JFIF")
    def test_e2e_f4_t1_01_rust_1080p_native_crop(self) -> None:
        self._assert_rust_test_passed(
            "crop::tests::native_1080p_detection_crop_slices_full_res_and_encodes_baseline_jfif_within_96kib"
        )

    @_e2e_case("F4", 1, "E2E-F4-T1-02", "Rust media-core 4K downscales to 640px preserving aspect ratio")
    def test_e2e_f4_t1_02_rust_4k_downscale_to_640(self) -> None:
        self._assert_rust_test_passed(
            "crop::tests::oversized_crop_downscales_to_640px_and_preview_config_caps_at_32kib"
        )

    @_e2e_case("F4", 1, "E2E-F4-T1-03", "Rust media-core border clamping and invalid input guards")
    def test_e2e_f4_t1_03_rust_border_clamping(self) -> None:
        self._assert_rust_test_passed(
            "crop::tests::border_clamping_and_invalid_inputs_behave_deterministically"
        )

    @_e2e_case("F4", 1, "E2E-F4-T1-04", "Rust media-core quality step-down & 3/4 downscale under tight max_bytes")
    def test_e2e_f4_t1_04_rust_tight_max_bytes_stepdown(self) -> None:
        self._assert_rust_test_passed(
            "crop::tests::thin_aspect_ratio_noisy_crop_fits_tight_max_bytes"
        )

    @_e2e_case("F4", 1, "E2E-F4-T1-05", "Rust media-core vantage_protocol round-trips & ROI polygon crops")
    def test_e2e_f4_t1_05_rust_vantage_protocol_and_roi_polygon(self) -> None:
        self._assert_rust_test_passed(
            "vantage_protocol::tests::vantage_job_result_heartbeat_and_live_envelopes_round_trip_and_validate"
        )
        self._assert_rust_test_passed(
            "crop::tests::roi_polygon_filtering_and_masking_enforce_gate_boundaries"
        )

    @_e2e_case("F4", 2, "E2E-F4-T2-01", "Rust media-core rejects undersized unpadded bbox even if padded > min_width")
    def test_e2e_f4_t2_01_rust_undersized_unpadded_skipped(self) -> None:
        self._assert_rust_test_passed(
            "crop::tests::rejects_undersized_unpadded_bbox_even_when_padding_would_exceed_min_width"
        )

    @_e2e_case("F4", 2, "E2E-F4-T2-02", "Rust media-core 96 vs 95 px & crop_outside_roi gate boundaries")
    def test_e2e_f4_t2_02_rust_min_width_and_roi_skip(self) -> None:
        self._assert_rust_test_passed(
            "crop::tests::rejects_undersized_unpadded_bbox_even_when_padding_would_exceed_min_width"
        )
        self._assert_rust_test_passed(
            "crop::tests::roi_polygon_filtering_and_masking_enforce_gate_boundaries"
        )

    @_e2e_case("F4", 2, "E2E-F4-T2-03", "Rust media-core rejects zero-area/inverted/NaN bounding boxes")
    def test_e2e_f4_t2_03_rust_invalid_bbox(self) -> None:
        self._assert_rust_test_passed(
            "crop::tests::border_clamping_and_invalid_inputs_behave_deterministically"
        )

    @_e2e_case("F4", 2, "E2E-F4-T2-04", "Rust media-core validates frame dimensions and CropConfig bounds")
    def test_e2e_f4_t2_04_rust_invalid_frame_and_config(self) -> None:
        self._assert_rust_test_passed(
            "crop::tests::border_clamping_and_invalid_inputs_behave_deterministically"
        )
        self._assert_rust_test_passed(
            "thumbnail::tests::validates_config_and_encodes_worst_case_quality_100_jfif_structure"
        )

    @_e2e_case("F4", 2, "E2E-F4-T2-05", "Rust media-core tight byte cap returns bounded error without exceeding cap")
    def test_e2e_f4_t2_05_rust_bounded_encoding_error(self) -> None:
        self._assert_rust_test_passed(
            "thumbnail::tests::enforces_tight_byte_cap_by_lowering_quality_or_scale"
        )


class _ReusableThreadingHTTPServer(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True


class ModeBF5VantageVlmRunnerTest(unittest.TestCase):
    """F5 Mode B: Live `serviceradar-media-worker` binary + ephemeral NATS + ffmpeg CMAF + mock HTTP VLM/grants."""

    _worker_bin: Path | None = None
    _cmaf_init: Path | None = None
    _cmaf_media: Path | None = None
    _cargo_vlm_stdout: str = ""

    @classmethod
    def setUpClass(cls) -> None:
        cargo = env_probe.probe_binary("cargo")
        env_probe.probe_binary("ffmpeg")
        env_probe.probe_binary("nats")
        env_probe.probe_binary("nats-server")

        # 1. Verify Rust unit/integration vantage_vlm suite passes
        test_proc = subprocess.run(
            [str(cargo), "test", "-p", "serviceradar-media-worker", "vantage_vlm"],
            cwd=str(vc.repo_root()),
            env=_cargo_env(),
            capture_output=True,
            text=True,
            timeout=240,
        )
        if test_proc.returncode != 0:
            raise RuntimeError(
                f"cargo test -p serviceradar-media-worker vantage_vlm failed:\n{test_proc.stdout}\n{test_proc.stderr}"
            )
        cls._cargo_vlm_stdout = test_proc.stdout

        # 2. Build real `serviceradar-media-worker` binary for live subprocess E2E runs
        build_proc = subprocess.run(
            [str(cargo), "build", "-p", "serviceradar-media-worker", "--bin", "serviceradar-media-worker"],
            cwd=str(vc.repo_root()),
            env=_cargo_env(),
            capture_output=True,
            text=True,
            timeout=300,
        )
        if build_proc.returncode != 0:
            raise RuntimeError(
                f"cargo build serviceradar-media-worker failed:\n{build_proc.stdout}\n{build_proc.stderr}"
            )
        target_dir = Path(_cargo_env()["CARGO_TARGET_DIR"])
        bin_path = target_dir / "debug" / "serviceradar-media-worker"
        if not bin_path.is_file():
            raise RuntimeError(f"built serviceradar-media-worker binary missing at {bin_path}")
        cls._worker_bin = bin_path

        # 3. Generate real synthetic 1080p H.264/fMP4 CMAF block (`init.mp4`, `media.m4s`) via ffmpeg
        init_path, media_path = media_gen.generate_synthetic_cmaf_block(
            prefix="mode_b_f5_1080p",
            width=1920,
            height=1080,
            duration_s=2,
            fps=15,
            scratch_subdir="media",
        )
        cls._cmaf_init = init_path
        cls._cmaf_media = media_path

    def _run_live_worker_scenario(
        self,
        *,
        backing: str = "local",
        grant_status: int = 200,
        corrupt_init_sha: bool = False,
        vlm_responses: list[tuple[int, str]] | None = None,
        sampled_targets: list[dict[str, Any]] | None = None,
        wait_for_result: bool = True,
        expect_failed_metric: bool = False,
        expect_gone_metric: bool = False,
    ) -> dict[str, Any]:
        assert self._worker_bin is not None
        assert self._cmaf_init is not None and self._cmaf_media is not None

        init_bytes = self._cmaf_init.read_bytes()
        media_bytes = self._cmaf_media.read_bytes()
        init_sha = hashlib.sha256(init_bytes).hexdigest()
        media_sha = hashlib.sha256(media_bytes).hexdigest()
        desc_sha = hashlib.sha256(init_bytes + media_bytes).hexdigest()
        block_key = hashlib.sha256(f"block-{uuid.uuid4().hex}".encode("utf-8")).hexdigest()
        storage_id = str(uuid.uuid4())
        job_id = str(uuid.uuid4())
        cat_id = str(uuid.uuid4())
        cam_id = str(uuid.uuid4())
        prof_id = str(uuid.uuid4())

        nats_port = _free_tcp_port()
        nats_proc, nats_url, store = nats_driver.start_ephemeral_jetstream(port=nats_port, timeout=10.0)
        self.addCleanup(shutil.rmtree, store, True)
        self.addCleanup(ModeBF3JetStreamAndOcsfTest._stop_proc, nats_proc)

        recorded_vlm_requests: list[dict[str, Any]] = []
        vlm_queue = list(vlm_responses or [(200, json.dumps({"plate_text": "SR-0100", "region": "US-CO", "confidence": 0.94}))])
        lock = threading.Lock()
        server_port_box: list[int] = [0]

        class _MockHandler(http.server.BaseHTTPRequestHandler):
            def log_message(self, format: str, *args: Any) -> None:
                return

            def do_POST(self) -> None:
                length = int(self.headers.get("Content-Length", "0"))
                body = self.rfile.read(length)
                if self.path == "/v1/media/workers/read-grants":
                    if grant_status == 410:
                        payload = json.dumps({"error": "recording_gone"}).encode("utf-8")
                        self.send_response(410)
                        self.send_header("Content-Type", "application/json")
                        self.send_header("Content-Length", str(len(payload)))
                        self.end_headers()
                        self.wfile.write(payload)
                        return

                    port = server_port_box[0]
                    expected_init_sha = ("f" * 64) if corrupt_init_sha else init_sha
                    if backing == "archive":
                        init_key = f"lab/{storage_id}/{block_key}/init.mp4"
                        media_key = f"lab/{storage_id}/{block_key}/media.m4s"
                        qs = (
                            "X-Amz-Algorithm=AWS4-HMAC-SHA256&X-Amz-Credential=synthetic"
                            "&X-Amz-Date=20261124T220000Z&X-Amz-Expires=300"
                            "&X-Amz-SignedHeaders=host&X-Amz-Signature=" + ("a" * 64)
                        )
                        grant_resp = {
                            "schema_version": 1,
                            "backing": "archive",
                            "source": "archive",
                            "job_id": job_id,
                            "catalog_entry_id": cat_id,
                            "camera_source_id": cam_id,
                            "stream_profile_id": prof_id,
                            "storage_id": storage_id,
                            "block_key": block_key,
                            "descriptor_sha256": desc_sha,
                            "init_sha256": expected_init_sha,
                            "ttl_seconds": 300,
                            "expires_at": "2026-11-24T23:59:00Z",
                            "init": {
                                "object_name": "init.mp4",
                                "offset": 0,
                                "first": 0,
                                "last": len(init_bytes) - 1,
                                "length": len(init_bytes),
                                "sha256": expected_init_sha,
                                "key": init_key,
                                "etag": '"init-etag"',
                                "version_id": None,
                                "presigned_url": f"http://127.0.0.1:{port}/vantage-archive/{init_key}?{qs}",
                            },
                            "media": {
                                "object_name": "media.m4s",
                                "key": media_key,
                                "length": len(media_bytes),
                                "sha256": media_sha,
                                "etag": '"media-etag"',
                                "version_id": None,
                                "presigned_url": f"http://127.0.0.1:{port}/vantage-archive/{media_key}?{qs}",
                            },
                            "fragments": [
                                {
                                    "sequence": 0,
                                    "offset": 0,
                                    "first": 0,
                                    "last": len(media_bytes) - 1,
                                    "length": len(media_bytes),
                                    "start_ns": 0,
                                    "duration_ns": 2000000000,
                                    "sha256": media_sha,
                                }
                            ],
                            "coalesced_ranges": [
                                {
                                    "first": 0,
                                    "last": len(media_bytes) - 1,
                                    "length": len(media_bytes),
                                    "fragment_sequences": [0],
                                    "slices": [
                                        {
                                            "sequence": 0,
                                            "offset": 0,
                                            "relative_offset": 0,
                                            "length": len(media_bytes),
                                            "start_ns": 0,
                                            "duration_ns": 2000000000,
                                            "sha256": media_sha,
                                        }
                                    ],
                                }
                            ],
                            "archive": {
                                "binding_id": str(uuid.uuid4()),
                                "provider": "s3_compatible",
                                "endpoint": f"http://127.0.0.1:{port}",
                                "region": "us-east-1",
                                "bucket": "vantage-archive",
                                "namespace": "lab",
                                "destination_sha256": hashlib.sha256(b"dest-e2e").hexdigest(),
                                "init_key": init_key,
                                "init_etag": '"init-etag"',
                                "init_presigned_url": f"http://127.0.0.1:{port}/vantage-archive/{init_key}?{qs}",
                                "media_key": media_key,
                                "media_etag": '"media-etag"',
                                "media_presigned_url": f"http://127.0.0.1:{port}/vantage-archive/{media_key}?{qs}",
                            },
                            "grant": {
                                "grant_id": str(uuid.uuid4()),
                                "grant_type": "camera_archive_credential",
                                "role": "reader",
                                "purpose": "camera_archive_read",
                                "secret_ref": "cred-ref-e2e",
                                "allowed_schemes": ["http"],
                                "allowed_hosts": ["127.0.0.1"],
                                "allowed_ports": [port],
                                "allowed_paths": ["/vantage-archive/lab/"],
                                "allowed_methods": ["HEAD", "GET"],
                                "expires_at": "2026-11-24T23:59:00Z",
                            },
                            "credential": {
                                "reference": "cred-ref-e2e",
                                "generation": 1,
                                "role": "reader",
                                "secret_id": str(uuid.uuid4()),
                            },
                        }
                    else:
                        grant_resp = {
                            "schema_version": 1,
                            "backing": "local",
                            "source": "local",
                            "read_pool": "analysis_read",
                            "nvr_member": "127.0.0.1",
                            "job_id": job_id,
                            "catalog_entry_id": cat_id,
                            "camera_source_id": cam_id,
                            "stream_profile_id": prof_id,
                            "storage_id": storage_id,
                            "block_key": block_key,
                            "descriptor_sha256": desc_sha,
                            "init_sha256": expected_init_sha,
                            "ttl_seconds": 300,
                            "expires_at": "2026-11-24T23:59:00Z",
                            "init": {
                                "object_name": "init.mp4",
                                "offset": 0,
                                "first": 0,
                                "last": len(init_bytes) - 1,
                                "length": len(init_bytes),
                                "sha256": expected_init_sha,
                                "path": f"/v1/blocks/{block_key}/init",
                            },
                            "fragments": [
                                {
                                    "sequence": 0,
                                    "offset": 0,
                                    "first": 0,
                                    "last": len(media_bytes) - 1,
                                    "length": len(media_bytes),
                                    "start_ns": 0,
                                    "duration_ns": 2000000000,
                                    "sha256": media_sha,
                                    "path": f"/v1/blocks/{block_key}/fragments/0",
                                }
                            ],
                            "coalesced_ranges": [],
                            "local": {
                                "nvr_member": "127.0.0.1",
                                "endpoint": f"http://127.0.0.1:{port}",
                                "storage_id": storage_id,
                                "block_key": block_key,
                                "pool": "analysis_read",
                                "purpose": "analysis_read",
                                "init_path": f"/v1/blocks/{block_key}/init",
                            },
                        }
                    vc.validate_read_grant_response(grant_resp)
                    payload = json.dumps(grant_resp).encode("utf-8")
                    self.send_response(200)
                    self.send_header("Content-Type", "application/json")
                    self.send_header("Content-Length", str(len(payload)))
                    self.end_headers()
                    self.wfile.write(payload)
                    return

                if self.path == "/v1/chat/completions":
                    req_obj = json.loads(body.decode("utf-8"))
                    with lock:
                        recorded_vlm_requests.append(req_obj)
                        status_code, content_str = (
                            vlm_queue.pop(0) if len(vlm_queue) > 1 else vlm_queue[0]
                        )
                    if status_code != 200:
                        err_body = json.dumps({"error": "upstream_vlm_error"}).encode("utf-8")
                        self.send_response(status_code)
                        self.send_header("Content-Type", "application/json")
                        self.send_header("Content-Length", str(len(err_body)))
                        self.end_headers()
                        self.wfile.write(err_body)
                        return
                    resp_body = json.dumps(
                        {
                            "id": "chatcmpl-e2e",
                            "object": "chat.completion",
                            "choices": [
                                {"index": 0, "message": {"role": "assistant", "content": content_str}}
                            ],
                        }
                    ).encode("utf-8")
                    self.send_response(200)
                    self.send_header("Content-Type", "application/json")
                    self.send_header("Content-Length", str(len(resp_body)))
                    self.end_headers()
                    self.wfile.write(resp_body)
                    return

                self.send_error(404)

            def do_GET(self) -> None:
                parsed = urlparse(self.path)
                p = parsed.path
                blob: bytes | None = None
                if p.endswith("/init") or p.endswith("/init.mp4"):
                    blob = init_bytes
                elif p.endswith("/fragments/0") or p.endswith("/media.m4s"):
                    blob = media_bytes
                if blob is None:
                    self.send_error(404)
                    return
                rng = self.headers.get("Range")
                if rng and rng.startswith("bytes="):
                    start_s, end_s = rng[len("bytes=") :].split("-", 1)
                    first = int(start_s)
                    last = int(end_s) if end_s else len(blob) - 1
                    slice_bytes = blob[first : last + 1]
                    self.send_response(206)
                    self.send_header("Content-Range", f"bytes {first}-{last}/{len(blob)}")
                    self.send_header("Content-Length", str(len(slice_bytes)))
                    self.end_headers()
                    self.wfile.write(slice_bytes)
                    return
                self.send_response(200)
                self.send_header("Content-Length", str(len(blob)))
                self.end_headers()
                self.wfile.write(blob)

        srv = _ReusableThreadingHTTPServer(("127.0.0.1", 0), _MockHandler)
        server_port_box[0] = srv.server_address[1]
        srv_thread = threading.Thread(target=srv.serve_forever, daemon=True)
        srv_thread.start()
        self.addCleanup(srv.shutdown)
        self.addCleanup(srv.server_close)

        http_port = _free_tcp_port()
        worker_port = _free_tcp_port()
        mock_url = f"http://127.0.0.1:{server_port_box[0]}"
        worker_env = dict(os.environ)
        worker_env.update(
            {
                "SERVICERADAR_MEDIA_WORKER_LISTEN_ADDR": f"127.0.0.1:{worker_port}",
                "MEDIA_WORKER_BACKEND": "stub",
                "SERVICERADAR_MEDIA_WORKER_EXECUTION_PROVIDER": "cpu_explicit",
                "MEDIA_WORKER_DEVICE": "cpu",
                "SERVICERADAR_MEDIA_WORKER_CONTROL_PLANE_URL": mock_url,
                "SERVICERADAR_MEDIA_WORKER_AUTH_TOKEN": "synthetic-worker-token",
                "SERVICERADAR_MEDIA_WORKER_DEPLOYMENT_REF": str(uuid.uuid4()),
                "SERVICERADAR_MEDIA_WORKER_GENERATION": "1",
                "SERVICERADAR_MEDIA_WORKER_NVR_SCHEME": "http",
                "SERVICERADAR_MEDIA_WORKER_NVR_READ_PORT": str(http_port),
                "SERVICERADAR_MEDIA_WORKER_NATS_URL": nats_url,
                "SERVICERADAR_CAMERA_VLM_ENABLED": "true",
                "SERVICERADAR_CAMERA_VLM_URL": f"{mock_url}/v1/chat/completions",
                "SERVICERADAR_CAMERA_VLM_MODEL": "qwen3.5-4b",
                "SERVICERADAR_CAMERA_VLM_TIMEOUT_MS": "5000",
                "SERVICERADAR_MEDIA_WORKER_VANTAGE_VLM_CONCURRENCY": "1",
            }
        )
        worker_proc = subprocess.Popen(
            [str(self._worker_bin)],
            env=worker_env,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
        )
        self.addCleanup(ModeBF3JetStreamAndOcsfTest._stop_proc, worker_proc)

        # Wait until /readyz returns 200 (meaning NATS streams & pull loops are connected)
        deadline = time.monotonic() + 20.0
        ready = False
        while time.monotonic() < deadline:
            if worker_proc.poll() is not None:
                err_out = worker_proc.stderr.read().decode("utf-8", errors="replace") if worker_proc.stderr else ""
                raise RuntimeError(f"serviceradar-media-worker exited early: {err_out}")
            try:
                status, _, _ = http_ws_driver.http_request("GET", f"http://127.0.0.1:{worker_port}/readyz", timeout=1.0)
                if status == 200:
                    ready = True
                    break
            except RuntimeError:
                pass
            time.sleep(0.15)
        if not ready:
            raise RuntimeError("serviceradar-media-worker did not reach /readyz 200 within 20s")

        job_envelope = {
            "schema_version": "vantage.job.v1",
            "job_id": job_id,
            "pack_id": "io.serviceradar.vantage-alpr",
            "pipeline_id": "io.serviceradar.vantage-alpr.vehicle-plate",
            "pipeline_version": "1.0.0",
            "capability": "vantage.alpr.v1",
            "source_mode": "recorded_block",
            "camera_source_id": cam_id,
            "stream_profile_id": prof_id,
            "catalog_entry_id": cat_id,
            "descriptor_sha256": desc_sha,
            "input_mode": "detection_crop",
            "roi_polygons": [],
            "crop_policy": {
                "padding_ratio": 0.15,
                "min_bbox_width_px": 96,
                "max_dimension": 640,
                "max_bytes": 98304,
            },
            "sampled_targets": sampled_targets
            or [
                {
                    "target_key": "track:1",
                    "track_id": "1",
                    "fragment_sequence": 0,
                    "media_pts_ns": 0,
                    "timeline_ts_us": 1760000000000000,
                    "time_basis": "received",
                    "category": "vehicle",
                    "confidence": 0.91,
                    "bbox": [0.30, 0.45, 0.55, 0.80],
                }
            ],
            "signal_schema_id": "alpr_plate_read",
            "signal_schema_version": "1.0.0",
            "display_contract_id": "alpr_plate_read",
            "vlm_config": {
                "prompt": "Read the license plate at Gate West 01.",
                "model_profile": "qwen3.5-4b",
                "max_tokens": 256,
                "temperature": 0.0,
                "json_schema": {
                    "type": "object",
                    "required": ["plate_text"],
                    "properties": {
                        "plate_text": {"type": "string", "pattern": "^[A-Z0-9-]{2,12}$"},
                        "region": {"type": "string"},
                        "confidence": {"type": "number"},
                    },
                    "additionalProperties": True,
                },
            },
        }
        _publish_js_json("media.jobs.vantage.vlm.v1", job_envelope, msg_id=job_id, nats_url=nats_url)

        published_result: dict[str, Any] | None = None
        metrics_text = ""
        poll_deadline = time.monotonic() + 15.0
        while time.monotonic() < poll_deadline:
            _, _, metrics_raw = http_ws_driver.http_request("GET", f"http://127.0.0.1:{worker_port}/metrics", timeout=2.0)
            metrics_text = metrics_raw.decode("utf-8", errors="replace")
            with _isolated_nats_cli_env():
                info = nats_driver.stream_info("CAMERA_MEDIA_RESULTS", nats_url=nats_url)
            msg_count = info["state"]["messages"]
            if wait_for_result and msg_count >= 1:
                with _isolated_nats_cli_env():
                    got = nats_driver.run_nats_cli(["stream", "get", "CAMERA_MEDIA_RESULTS", "1", "--json"], nats_url=nats_url)
                raw_msg = json.loads(got.stdout.decode("utf-8"))
                published_result = json.loads(base64.b64decode(raw_msg["data"]).decode("utf-8"))
                break
            if expect_gone_metric and re.search(
                r"serviceradar_media_worker_vantage_jobs_gone_total [1-9]\d*", metrics_text
            ):
                break
            if expect_failed_metric and re.search(
                r"serviceradar_media_worker_vantage_jobs_failed_total [1-9]\d*", metrics_text
            ):
                break
            time.sleep(0.15)

        return {
            "result": published_result,
            "metrics": metrics_text,
            "vlm_requests": recorded_vlm_requests,
            "job_id": job_id,
            "worker_logs": self._drain_worker_stderr(worker_proc),
        }

    @staticmethod
    def _drain_worker_stderr(worker_proc: subprocess.Popen[bytes]) -> str:
        if worker_proc.poll() is None:
            worker_proc.terminate()
            try:
                worker_proc.wait(timeout=3)
            except subprocess.TimeoutExpired:
                worker_proc.kill()
                worker_proc.wait(timeout=3)
        if worker_proc.stdout is not None:
            return worker_proc.stdout.read().decode("utf-8", errors="replace")
        return ""

    def _assert_rust_vlm_test_passed(self, test_substr: str) -> None:
        matching = [
            line
            for line in self._cargo_vlm_stdout.splitlines()
            if test_substr in line and line.strip().endswith("... ok")
        ]
        self.assertTrue(matching, f"expected {test_substr!r} in:\n{self._cargo_vlm_stdout}")

    @_e2e_case("F5", 1, "E2E-F5-T1-01", "Live media-worker executes single-frame Ramp 1 VLM job & publishes to JetStream")
    def test_e2e_f5_t1_01_live_worker_single_frame_vlm_job(self) -> None:
        out = self._run_live_worker_scenario(backing="local")
        res = out["result"]
        self.assertIsNotNone(res, f"no result published;\nworker_logs:\n{out['worker_logs']}\nmetrics:\n{out['metrics']}")
        vc.validate_result_envelope(res)
        self.assertEqual(res["observations"][0]["label"], "SR-0100")
        self.assertEqual(len(out["vlm_requests"]), 1)
        req = out["vlm_requests"][0]
        self.assertFalse(req["enable_thinking"])
        self.assertFalse(req["chat_template_kwargs"]["enable_thinking"])

    @_e2e_case("F5", 1, "E2E-F5-T1-02", "Live media-worker 3-frame track consensus selects TEST-742")
    def test_e2e_f5_t1_02_live_worker_three_frame_consensus(self) -> None:
        targets = [
            {
                "target_key": "track:1:f0",
                "track_id": "1",
                "fragment_sequence": 0,
                "media_pts_ns": pts,
                "timeline_ts_us": 1760000000000000 + idx * 100000,
                "time_basis": "received",
                "category": "vehicle",
                "confidence": 0.90,
                "bbox": [0.30, 0.45, 0.55, 0.80],
            }
            for idx, pts in enumerate((0, 1000, 2000))
        ]
        responses = [
            (200, json.dumps({"plate_text": "TEST-742", "region": "US-CA", "confidence": 0.94})),
            (200, json.dumps({"plate_text": "TEST-742", "region": "US-CA", "confidence": 0.91})),
            (200, json.dumps({"plate_text": "TEST-74Z", "region": "US-CA", "confidence": 0.62})),
        ]
        out = self._run_live_worker_scenario(backing="local", sampled_targets=targets, vlm_responses=responses)
        self.assertIsNotNone(out["result"])
        vc.validate_result_envelope(out["result"])
        self.assertEqual(out["result"]["observations"][0]["label"], "TEST-742")

    @_e2e_case("F5", 1, "E2E-F5-T1-03", "Live media-worker skips tiny <96 px detection and increments crop skip metric")
    def test_e2e_f5_t1_03_live_worker_skips_tiny_bbox(self) -> None:
        targets = [
            {
                "target_key": "track:valid",
                "track_id": "1",
                "fragment_sequence": 0,
                "media_pts_ns": 0,
                "timeline_ts_us": 1760000000000000,
                "time_basis": "received",
                "category": "vehicle",
                "confidence": 0.92,
                "bbox": [0.30, 0.45, 0.55, 0.80],
            },
            {
                "target_key": "track:tiny",
                "track_id": "2",
                "fragment_sequence": 0,
                "media_pts_ns": 0,
                "timeline_ts_us": 1760000000000000,
                "time_basis": "received",
                "category": "vehicle",
                "confidence": 0.88,
                "bbox": [0.40, 0.40, 0.44, 0.50],
            },
        ]
        out = self._run_live_worker_scenario(backing="local", sampled_targets=targets)
        self.assertIsNotNone(out["result"])
        self.assertEqual(len(out["result"]["observations"]), 1)
        self.assertIn('reason="crop_below_min_dimension"', out["metrics"])

    @_e2e_case("F5", 1, "E2E-F5-T1-04", "Live media-worker ACKs cleanly on 410 recording_gone")
    def test_e2e_f5_t1_04_live_worker_410_gone_acks_cleanly(self) -> None:
        out = self._run_live_worker_scenario(grant_status=410, wait_for_result=False, expect_gone_metric=True)
        self.assertIsNone(out["result"])
        self.assertIn("serviceradar_media_worker_vantage_jobs_gone_total 1", out["metrics"])

    @_e2e_case("F5", 1, "E2E-F5-T1-05", "Live media-worker decodes and verifies SHA-256 via archive presigned range GET")
    def test_e2e_f5_t1_05_live_worker_archive_presigned_range_read(self) -> None:
        out = self._run_live_worker_scenario(backing="archive")
        self.assertIsNotNone(out["result"], f"archive run failed; metrics:\n{out['metrics']}")
        vc.validate_result_envelope(out["result"])
        self.assertEqual(out["result"]["observations"][0]["label"], "SR-0100")

    @_e2e_case("F5", 2, "E2E-F5-T2-01", "Live media-worker rejects unclosed <think> with truncated_thinking metric")
    def test_e2e_f5_t2_01_live_worker_truncated_thinking_rejected(self) -> None:
        out = self._run_live_worker_scenario(
            vlm_responses=[(200, "<think>unterminated reasoning at max_tokens")]
        )
        self.assertIsNotNone(out["result"])
        self.assertEqual(out["result"]["observations"], [])
        self.assertIn('outcome="truncated_thinking"', out["metrics"])

    @_e2e_case("F5", 2, "E2E-F5-T2-02", "Live media-worker rejects non-JSON and regex-failing plate_text")
    def test_e2e_f5_t2_02_live_worker_bad_json_and_regex_rejected(self) -> None:
        out = self._run_live_worker_scenario(
            vlm_responses=[(200, json.dumps({"plate_text": "NOT A VALID PLATE!!!", "region": "US-CO"}))]
        )
        self.assertIsNotNone(out["result"])
        self.assertEqual(out["result"]["observations"], [])
        self.assertIn('outcome="schema_rejected"', out["metrics"])

    @_e2e_case("F5", 2, "E2E-F5-T2-03", "Live media-worker aborts before VLM on SHA-256 mismatch")
    def test_e2e_f5_t2_03_live_worker_sha256_mismatch_aborts_before_vlm(self) -> None:
        out = self._run_live_worker_scenario(
            corrupt_init_sha=True, wait_for_result=False, expect_failed_metric=True
        )
        self.assertEqual(len(out["vlm_requests"]), 0)
        self.assertRegex(
            out["metrics"], r"serviceradar_media_worker_vantage_jobs_failed_total [1-9]\d*"
        )

    @_e2e_case("F5", 2, "E2E-F5-T2-04", "Live media-worker NAKs on VLM HTTP 500 without fabricating observations")
    def test_e2e_f5_t2_04_live_worker_vlm_http_500_naks(self) -> None:
        out = self._run_live_worker_scenario(
            vlm_responses=[(500, "internal error")],
            wait_for_result=False,
            expect_failed_metric=True,
        )
        self.assertIsNone(out["result"])
        self.assertIn('outcome="http_error"', out["metrics"])
        self.assertRegex(
            out["metrics"], r"serviceradar_media_worker_vantage_jobs_failed_total [1-9]\d*"
        )

    @_e2e_case("F5", 2, "E2E-F5-T2-05", "Rust media-worker trims lowest-confidence crops under 960 KiB ceiling")
    def test_e2e_f5_t2_05_rust_trims_crops_under_960kib(self) -> None:
        self._assert_rust_vlm_test_passed(
            "vantage_vlm::tests::handles_410_gone_and_trims_crop_previews_under_960kib_ceiling"
        )


if __name__ == "__main__":
    unittest.main()
