# Implementation Plan: Vantage ML Extensibility, Solution Pack Bundling, and Vantage Worker SDK

## Phase 1: Canonical Vantage Observation Model, Solution Pack v2 (Pipelines + Dashboard Modules), Full-Res Crops, and Ramp 1 VLM + ALPR Pack

- [ ] 1.1 **Ash Resources & Migrations (`elixir/serviceradar_core`):**
  - Add `ServiceRadar.Camera.VantagePipeline` (`platform.camera_vantage_pipelines`), `ServiceRadar.Camera.VantageJob` (`platform.camera_vantage_jobs`), `ServiceRadar.Camera.VantageObservation` (`platform.camera_vantage_observations`), and `ServiceRadar.Camera.VantageWorkerRegistration` (`platform.vantage_worker_registrations`) with `Ash.Policy.Authorizer`, FK `on_delete: :delete` to `RecordingCatalogEntry` and `Source`, `crop_jpeg` `<= 32 KiB` check constraint, and generated `search_tsv` GIN index.
  - Generate migrations via `mix ash.codegen add_vantage_ml_pipelines_and_observations` (no raw `mix ecto.gen.migration`).
  - Couple `camera_vantage_observations` and pending `camera_vantage_jobs` into terminal deletion, `quarantine_in_place`, and `RecordingHold` preservation paths alongside `VisualFrame` and `VisualClipCaption`.
- [ ] 1.2 **JetStream Result Ingestion & OCSF Projection (`elixir/serviceradar_core`):**
  - Add `ServiceRadar.Camera.VantageObservationEnvelope` and `ServiceRadar.Camera.VantageObservationProjector` validating schema bounds, digest/job identity, pack `signal_schema`, and idempotent upserts.
  - Add `ServiceRadar.EventWriter.Processors.CameraVantageObservations` consuming `media.results.vantage.v1` from `CAMERA_MEDIA_RESULTS`, projecting into `platform.camera_vantage_observations` and optionally emitting OCSF Event Log Activity records carrying `metadata.service_radar.signal_schema`.
  - Wire NATS stream/user permissions in `helm/serviceradar/templates/_nats_static_users.tpl` and core `runtime.exs`.
- [ ] 1.3 **Full-Resolution Detection/ROI Cropper & Ramp 1 Declarative VLM Runner (`rust/media-core`, `rust/media-worker`):**
  - Add bounded padded bbox/ROI crop extraction (`crop_detection_jpeg`, native resolution before bounded downscale `<= 640px`, `<= 96 KiB`, minimum bbox pixel gate) to `serviceradar-media-core`.
  - Add `media.jobs.vantage.vlm.v1` pull consumer to `serviceradar-media-worker` that obtains scoped Fragment Read Grants, verifies SHA-256, extracts full-res track-best keyframe crops, calls the configured OpenAI-compatible `camera_vlm` endpoint with pack-defined structured prompt/schema, applies optional multi-frame track consensus, and publishes normalized `media.results.vantage.v1` envelopes.
- [ ] 1.4 **Solution Pack `pack_format_version: 2` (`elixir/serviceradar_core`, `elixir/web-ng`, `js/cli`):**
  - Extend `ServiceRadar.Catalog.PackManifest`, `PackArchive`, `DependencyChecker`, `Reconciler`, and `PackExporter` to support `vantage_pipelines/*.json`, `signal_schemas/*.json`, `worker_dependencies`, and bundled/referenced `dashboard_packages/` (`dashboard-browser-module-v1`).
  - Enforce explicit SHA-256 verification, `SecretFreeValidator` scanning, and explicit RBAC approval gating (`catalog.packs.install` + `dashboards.packages.manage` / `cli.dashboard.publish`) before enabling bundled browser modules or binding `DashboardInstance` routes, preserving `version_already_published` immutability.
  - Extend `@carverauto/serviceradar-cli` `pack validate|build|sign|index` to validate and package `vantage_pipelines`, `signal_schemas`, `worker_dependencies`, and `dashboard_packages` (invoking or verifying `dashboard build` artifacts).
- [ ] 1.5 **SRQL Entity, Vantage UI, and Search Integration (`rust/srql`, `elixir/web-ng`):**
  - Expose `in:camera_observations` through SRQL `AshAdapter` with `devices.view` + `devices.cameras.recordings.view` RBAC and camera scope pre-filtering.
  - Extend `ServiceRadar.Camera.SemanticSearch` with an authorized `camera_vantage_observations` FTS/attribute search leg and `RecordingAccessAudit` logging.
  - Render pack observations on Vantage's scrubber event rail, clip playback modal SVG/canvas bounding-box overlays, and crop previews using each pack's `display_contract`.
- [ ] 1.6 **Reference ALPR Solution Pack (`io.serviceradar.vantage-alpr`) & Synthetic Verification:**
  - Ship built-in/reference `io.serviceradar.vantage-alpr` pack (`vantage_pipelines/alpr-vehicle-plate.json`, `signal_schemas/alpr_plate_read.{schema,display}.json`, paused watchlist alert rule, health check, declarative overview dashboard, and bundled React `alpr-console` Dashboard SDK module).
  - Add synthetic unit, Ash/CNPG DB, and end-to-end tests using invented synthetic plates (`SR-0100`, `TEST-742`) and synthetic H.264/JPEG fixtures covering Ramp 1 execution, retention/quarantine purge, RBAC enforcement, and bundled dashboard-package approval gating.

## Phase 2: Open `vantage.worker.v1` Protocol, `serviceradar-sdk-vantage` (Rust + Python PyO3), and Dedicated ALPR Worker

- [ ] 2.1 **Generalized `vantage.worker.v1` Dispatch & Capability Registry (`elixir/serviceradar_core`, `elixir/web-ng`):**
  - Implement `ServiceRadar.Camera.VantagePipelineDispatcher` (transactional CNPG outbox -> JetStream `media.jobs.vantage.<capability_slug>.v1` & `.backfill.v1` with fallback to `camera_vlm` when configured and optional).
  - Implement worker capability heartbeat ingestion (`media.workers.heartbeat.v1`) and Catalog Gallery / Settings worker health visibility showing online capabilities, architectures, and queue lag.
  - Extend `POST /v1/media/workers/read-grants` (`ControlPlaneMediaWorkerGrants` / `VisualWorkerReadGrants`) to issue scoped read grants for authenticated `vantage_worker` identities bound to active `VantageJob` rows.
- [ ] 2.2 **`serviceradar-sdk-vantage` Repository (Rust Core + Python PyO3 Bindings):**
  - Bootstrap `carverauto/serviceradar-sdk-vantage` (Apache-2.0) with Rust crate `serviceradar-vantage-sdk` wrapping `serviceradar-media-core`, `rusty_h264-decoder`, Fragment Read Grant client, `longshore`/NVR range reader, SHA-256 verification, JetStream pull loop, `/healthz`/`/readyz`/`/metrics`, and the `VantageHandler` trait (`VantageFrameContext` supporting both `RecordedBlock` and `LiveKeyframeTap`).
  - Build Python bindings (`serviceradar-vantage`) via PyO3 + `maturin` exposing zero-copy NumPy RGB frames, `FrameContext`, `Observation`, `VantageWorker`, and `run_local_harness` with multi-arch Linux (`amd64`/`arm64`) wheel CI.
  - Add shared wire-format conformance test suite pinning `vantage.worker.v1` job, read-grant, and observation envelopes between Core, Rust SDK, and Python SDK.
- [ ] 2.3 **CLI Developer Workflow (`js/cli`):**
  - Add `serviceradar-cli vantage init <name> --template vlm|rust-worker|python-worker [--with-dashboard]`, `serviceradar-cli vantage dev --fixture <synthetic-clip>`, and `serviceradar-cli vantage validate` commands.
- [ ] 2.4 **Permissive Reference `vantage-worker-alpr` & Upgrade Verification:**
  - Build a standalone Apache-2.0/MIT reference ALPR worker (using `serviceradar-sdk-vantage` + permissive ONNX/Candle plate detector & OCR weights) advertising `vantage.alpr.v1` and verify `io.serviceradar.vantage-alpr` upgrades automatically from Ramp 1 (`camera_vlm`) to Ramp 2 (`vantage.alpr.v1`) without modifying schemas, rules, or dashboards.
  - Document the external-worker integration boundary for third-party/AGPL/commercial engines (e.g., OpenALPR or commercial ALPR APIs) operating strictly outside ServiceRadar OSS.

## Phase 3: Live Keyframe Tap (`source_mode: :live_keyframe_tap`) for Sub-Second Operational Guidance

- [ ] 3.1 **Bounded Live Keyframe Tap Feeder (`elixir/serviceradar_core_elx`, `rust/media-core`):**
  - Wire an opt-in per-pipeline live keyframe tap composing with the bounded camera-sharded `longshore_mailbox` (`<= 8` frames/camera, drop-oldest backpressure, explicit drop metrics) to emit `VantageFrameContext` (`source_mode: :live_keyframe_tap`) onto `media.live.vantage.<capability_slug>.v1`.
  - Enforce deployment camera-cap admission and strict isolation so worker crashes or mailbox overflow never stall Membrane live viewers or CMAF recording.
- [ ] 3.2 **SDK Live-Tap Consumer & Low-Latency Observation Streaming (`serviceradar-sdk-vantage`, `elixir/serviceradar_core`, `elixir/web-ng`):**
  - Enable `VantageWorker` in both Rust and Python SDKs to consume `live_keyframe_tap` frames using the identical `process_frame(ctx)` handler interface and publish low-latency observations to `media.results.vantage.v1` (with pipeline-configured `live_observation_retention_days` cleanup).
  - Verify real-time observation delivery to Vantage live player overlays and Dashboard SDK `useDashboardEvents` / `CameraGrid` overlays.
- [ ] 3.3 **Synthetic Low-Latency Guidance Benchmark & Failure Injection:**
  - Build a synthetic real-time vehicle/equipment bay-approach docking guidance fixture and reference worker (`vantage.bay_guidance.v1`), measuring p50/p95/p99 frame-to-overlay latency and proving recording/viewer health under worker crash and overload injection.
