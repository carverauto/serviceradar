# Design: Vantage ML Pipeline Extensibility, Solution Pack Bundling, and Vantage Worker SDK

## Context

ServiceRadar Vantage's media plane currently comprises:
1. **Capture, Recording & Archive** (`ServiceRadar.Camera.RecordingCatalogEntry`, packed CMAF/fMP4 blocks, S3 via `longshore` or local NVR storage, execution-time scoped Fragment Read Grants at `POST /v1/media/workers/read-grants`).
2. **Stage 1/2 GPU Media Worker** (`rust/media-worker` + `rust/media-core`: pure-Rust `rusty_h264-decoder`, `TwoTierFrameGate`, `YOLOX-s/x`, `MultiObjectTracker` with `BestKeyframeSnapshot`, `SigLIP` embeddings, bounded `480x270` JFIF thumbnails, JetStream `CAMERA_MEDIA_JOBS` / `CAMERA_MEDIA_RESULTS`).
3. **Stage 3 VLM Server** (`serviceradar-camera-vlm`: `crane-serve` + Qwen3.5-4B on arm64 DGX Spark CUDA, or `llama-server` / external OpenAI-compatible endpoints, currently called by `ServiceRadar.Camera.VisualCaptionWorker`).
4. **Solution Packs** (`ServiceRadar.Catalog.*`, `pack_format_version: 1`: deterministic secret-free `.srpack` archives and GitOps trees bundling declarative checks, rules, and authored dashboards).
5. **Dashboard SDK** (`@carverauto/serviceradar-dashboard-sdk` + `@carverauto/serviceradar-cli`: trusted `dashboard-browser-module-v1` React modules with `CameraGrid`, `useDashboardEvents`, `useDashboardActions`, and `useFrameRows`).

Two forces motivate this design:
- **Developer extensibility & license isolation:** Outside developers and enterprise teams want to build domain-specific video ML pipelines (ALPR, PPE compliance, safety zones, equipment docking guidance) without modifying ServiceRadar core. Many ML engines carry copyleft (e.g., AGPLv3 OpenALPR) or commercial licenses, or depend on Python/PyTorch/ONNX/TensorRT ecosystems that do not belong inside the BEAM cluster or the core Apache-2.0 `media-worker` binary.
- **Turnkey operator UX:** Installing a capability like ALPR should feel like installing a single Solution Pack from the Catalog Gallery—provisioning the video pipeline triggers, observation schema, display contract, watchlist alert rules, and custom React Dashboard SDK console together, with safe `managed` + `template_fingerprint` upgrades.

## Goals / Non-Goals

### Goals
- Define a single canonical **Vantage ML Pipeline** (`vantage_pipelines/*.json`) and **Vantage Observation** (`platform.camera_vantage_observations`) contract shared across declarative VLM pipelines, external ML workers, and future live keyframe tap feeds.
- Enable **zero-code Ramp 1 pipelines** using the existing `serviceradar-camera-vlm` (`crane-serve` Qwen3.5-4B or external OpenAI-compatible VLM) over **full-resolution object/ROI crops** rather than `480x270` full-scene thumbnails.
- Define the open, language-agnostic **`vantage.worker.v1`** protocol (NATS JetStream + Scoped Fragment Read Grants + SHA-256 verification) and design **`serviceradar-sdk-vantage`** with a **Rust core** (`serviceradar-media-core` + `rusty_h264` + grant/NATS client) and **Python bindings (PyO3)** so both Rust and Python ML engineers inherit ServiceRadar's exact security and decoding guarantees without boilerplate.
- Extend **Solution Packs** to bundle `vantage_pipelines/`, `signal_schemas/`, `worker_dependencies`, and **`dashboard_packages/` (`dashboard-browser-module-v1`)** with strict digest verification and explicit admin approval gating.
- Preserve a **forward-compatible live keyframe tap** contract (`source_mode: :live_keyframe_tap`) so sub-second operational guidance workloads (such as automated vehicle/equipment bay docking or real-time gate control) reuse the exact same worker SDK and observation schema in Phase 3.
- Deliver **ALPR (`io.serviceradar.vantage-alpr`)** as the first reference Solution Pack, working out-of-the-box on Ramp 1 (`camera_vlm`) and upgrading seamlessly to Ramp 2 (`vantage.alpr.v1`).

### Non-Goals
- Running heavy CNN/Transformer inference inside `wazero` WASM (no CUDA/GPU acceleration; WASM remains for control-plane/edge logic, external API bridging, and northbound actions).
- Linking AGPLv3 (e.g., OpenALPR) or proprietary inference SDKs into ServiceRadar OSS binaries.
- Allowing ML workers direct CNPG, StarRocks, or raw S3 bucket credentials.
- Shipping unverified burned-in video transcoding on the live or archival path (overlays remain non-destructive client-side SVG/canvas layers over immutable CMAF footage).
- Replacing `VisualIndexDispatcher` (`YOLOX` + `SigLIP`) or `VisualCaptionWorker` (VLM action captioning); Vantage ML pipelines compose downstream of Stage 1 detections or alongside them on sealed blocks and live taps.

## Decisions

### Decision 1: Three Progressive Compute Ramps Unified by One Solution Pack Output

Every Vantage extension outputs a **Solution Pack (`.srpack` / GitOps tree)** regardless of how inference runs:

| Ramp | Runtime | Best For | Extra Deployment | License Boundary |
| --- | --- | --- | --- | --- |
| **Ramp 1: Declarative VLM** | Existing `serviceradar-camera-vlm` (`crane-serve` Qwen3.5-4B / `llama-server` / external OpenAI-compatible endpoint) | Rapid OCR/ALPR, PPE, hazard/state checks, semantic inspection | None (pure `.srpack`) | Apache-2.0 JSON pack |
| **Ramp 2: External Vantage Worker** | Standalone process/container built with `serviceradar-sdk-vantage` (Rust core + Python PyO3) speaking `vantage.worker.v1` | High-FPS or low-latency specialized CV (FastALPR/ONNX, PaddleOCR, PyTorch, TensorRT, Candle, SAM2, OpenALPR) | Worker Deployment / sidecar / edge service | Full process + network isolation (AGPL/commercial safe) |
| **Ramp 3: WASM Logic & Action Bridge** | Existing `serviceradar-agent` `wazero` plugins (`serviceradar-sdk-go` / `serviceradar-sdk-rust`) | Watchlist lookups against external APIs, external SaaS CV calls with brokered creds, northbound gate/PLC actions | Existing agent runtime | Sandboxed WASI |

**Rationale:** Trying to force ML inference into a single runtime either cripples GPU ML authors (WASM-only) or forces trivial prompt-based checks to manage custom Dockerfiles and GPU pods (container-only). Supporting Ramp 1 + Ramp 2 behind one observation schema lets the **same** ALPR pack run immediately on DGX Spark Qwen3.5-4B and later swap in a dedicated sub-20ms `vantage.alpr.v1` worker with zero schema, alert, or dashboard changes.

### Decision 2: Full-Resolution Crop Extraction for OCR/ALPR Accuracy

Today `VisualCaptionWorker` reads `platform.camera_visual_frames.thumbnail_jpeg` (`<= 480x270`, `<= 48 KiB`). For a wide-angle 1080p or 4K camera, a license plate occupies ~12–25 px in a `480x270` thumbnail—unreadable to both VLMs and dedicated OCR models.

- **Decision:** Add a bounded crop extraction capability in `serviceradar-media-core` / `serviceradar-media-worker` (and `serviceradar-sdk-vantage`):
  - When a `VantagePipeline` declares `input.mode = "detection_crop"` (e.g., `trigger.object_classes = ["vehicle"]`, `crop_padding_ratio = 0.15`, `max_crop_dimension = 640`, `max_crop_bytes = 98304`, `frames_per_track = 3`), the worker fetches the exact sampled IDR fragment via a scoped **Fragment Read Grant**, verifies SHA-256, decodes the full-resolution keyframe with `rusty_h264`, crops the padded detection bounding box at native camera pixel density before resizing only if it exceeds `max_crop_dimension`, and encodes a crisp JPEG crop.
  - For **Ramp 1 (Declarative VLM)** pipelines, `serviceradar-media-worker` (or a dedicated lightweight cropper lane inside `media-worker`) executes `media.jobs.vantage.vlm.v1`: it extracts the full-res crop(s) via the Fragment Read Grant, invokes the configured `camera_vlm` endpoint with the pack's versioned system/user prompt and JSON schema constraints (bounding `max_tokens` and rejecting `<think>`/malformed JSON), performs optional multi-frame track consensus (e.g., majority/confidence vote across up to 3 best keyframes per `track_id`), and publishes normalized `VantageObservation` batches to `media.results.vantage.v1`.
  - **Why run Ramp 1 VLM jobs in `media-worker` rather than Core Oban?** Core BEAM pods never hold H.264 decoders or fetch raw S3 recording fragments; `media-worker` already holds scoped read grants, `rusty_h264`, `longshore`, and local NVR analysis read pools. Keeping decode+crop in `media-worker` preserves the zero-media-bytes-in-BEAM and zero-media-bytes-in-JetStream invariants.

### Decision 3: Generic `VantageObservation` Storage, OCSF Projection, and Retention Coupling

Introduce `platform.camera_vantage_observations` (Ash resource `ServiceRadar.Camera.VantageObservation`) and `platform.camera_vantage_pipelines` (`ServiceRadar.Camera.VantagePipeline`) + `platform.camera_vantage_jobs` (`ServiceRadar.Camera.VantageJob`):

- **Schema (`camera_vantage_observations`):**
  - Identity & provenance: `id` (UUIDv7), `pack_id`, `pipeline_id`, `pipeline_version`, `worker_kind`, `model_id`, `model_version`, `job_id` (nullable for Phase 3 live-tap observations), `observation_key` (deterministic idempotency key per `(pipeline_id, catalog_entry_id|live_session_id, fragment_sequence|frame_seq, track_id, category)`).
  - Media linkage: `catalog_entry_id` (nullable UUID FK `on_delete: :delete` to `camera_recording_catalog` for recorded observations), `camera_source_id` (FK `on_delete: :delete`), `stream_profile_id`, `source_mode` (`:recorded_block | :live_keyframe_tap`), `fragment_sequence`, `media_pts_ns`, `timeline_ts_us`, `time_basis` (`:received | :camera_reported`), `track_id`.
  - Spatial & visual: `category` (e.g., `"license_plate"`, `"bay_alignment"`), `label` (primary display string, e.g., `"SR-0100"`), `confidence` (`float` `0.0..1.0`), `bbox` (`[x1, y1, x2, y2]` normalized `0.0..1.0`), `crop_jpeg` (optional validated Baseline JFIF JPEG `<= 32 KiB`, check-constrained).
  - Structured domain payload: `attributes` (`jsonb`, validated against the pipeline's `signal_schema` before persistence), `signal_schema_id`, `signal_schema_version`, `display_contract_id`, `search_tsv` (generated `tsvector` over `label` + declared searchable attribute paths, GIN-indexed).
- **JetStream-first ingestion:** Workers publish bounded JSON envelopes (`<= 960 KiB`, respecting NATS `1 MiB` payload headroom) to `media.results.vantage.v1` on `CAMERA_MEDIA_RESULTS`. Core's `EventWriter` processor (`CameraVantageObservations`) validates schema, digest/job identity, and recording liveness, upserts `camera_vantage_observations` idempotently, and—when the pipeline has `emit_ocsf_events: true`—emits a canonical OCSF Event Log Activity carrying `metadata.service_radar.signal_schema` + `camera_source_id` + `catalog_entry_id` + `timeline_ts_us` + `attributes`.
- **Automatic Vantage UI & Search Integration:**
  - **Search:** `ServiceRadar.Camera.SemanticSearch` adds an authorized `camera_vantage_observations` FTS/exact-attribute leg (pre-filtered by caller's authorized `camera_source_id`s, time window, and playable non-quarantined recordings) so searching `"SR-0100"` or `plate_text:SR-0100` jumps directly to the matching clip timestamp.
  - **Timeline & Clip Overlay:** `camera_live/recordings.ex` renders pack observations on the scrubber event rail (badge color/icon from `display_contract`) and draws non-destructive SVG/canvas bounding boxes + labels + crop previews in the clip playback modal.
  - **SRQL:** Expose `in:camera_observations` through `AshAdapter` (enforcing `devices.view` + `devices.cameras.recordings.view` RBAC) so authored dashboards and Dashboard SDK browser modules can query structured observations directly (`in:camera_observations category:license_plate time:last_24h`).
- **Retention, Quarantine, and Hold Alignment:**
  - Recorded observations follow the exact same cascade/purge contract as `VisualFrame` and `VisualClipCaption`: terminal recording deletion or `quarantine_in_place` immediately purges associated `camera_vantage_observations` and cancels pending `camera_vantage_jobs`; accepted `RecordingHold`s preserve them until released.
  - Phase 3 live-tap observations (which may have `catalog_entry_id = nil` if recording is off, or link asynchronously when the overlapping block seals) obey an explicit pipeline `live_observation_retention_days` policy (default `30` days, bounded) and are purged on camera source deletion.

### Decision 4: Open `vantage.worker.v1` Protocol and `serviceradar-sdk-vantage` (Rust Core + Python PyO3)

To make external ML worker authoring feel as smooth as `serviceradar-sdk-dashboard`:

1. **Protocol (`vantage.worker.v1`):**
   - **Capability Advertisement & Health:** Each worker exposes `/healthz` and `/readyz` (reporting `worker_kind`, `capabilities: ["vantage.alpr.v1"]`, `supported_source_modes: ["recorded_block", "live_keyframe_tap"]`, `execution_backend`, `architecture`, `model_id`, `model_version`, `max_concurrency`) and publishes periodic signed/authenticated heartbeats on `media.workers.heartbeat.v1` (bounded TTL in Core worker registry) so Catalog UI and `VantagePipelineDispatcher` know which capabilities have healthy workers online.
   - **Subject Topology (JetStream):**
     - Recorded-block jobs: `media.jobs.vantage.<capability_slug>.v1` (durable pull consumer per capability group, `CAMERA_MEDIA_JOBS` stream, `Nats-Msg-Id` idempotency, `MaxDeliver` terminal reconciliation).
     - Backfill jobs: `media.jobs.vantage.<capability_slug>.backfill.v1` (lower priority queue so live/recent work is never starved).
     - Results: `media.results.vantage.v1` (worker publishes verified results before ACK; Core `EventWriter` projects idempotently).
   - **Zero-Trust Media Access:** Workers authenticate to `POST /v1/media/workers/read-grants` with a workload-scoped `vantage_worker` credential/SVID (same `ControlPlaneRuntimeAuth` headers as `media-worker`), receive short-lived `:reader`-only `CredentialBrokerGrant` or NVR analysis read tokens locked to the exact `catalog_entry_id` and sampled fragment byte ranges, and verify SHA-256 before decoding.
   - **Unified Frame Input Envelope (Recorded + Live Forward Compatibility):**
     Both recorded-block and Phase 3 live-tap jobs deliver the **same logical frame abstraction** to the SDK handler:
     ```rust
     pub struct VantageFrameContext {
         pub source_mode: SourceMode,              // RecordedBlock | LiveKeyframeTap
         pub camera_source_id: Uuid,
         pub stream_profile_id: Uuid,
         pub catalog_entry_id: Option<Uuid>,       // Some(...) in P1/P2; optional in P3 live tap
         pub fragment_sequence: Option<u32>,
         pub frame_sequence: u64,
         pub timeline_ts_us: i64,
         pub time_basis: TimeBasis,                // Received | CameraReported
         pub rgb_frame: RgbFrame,                  // Full-res decoded RGB (or pre-cropped ROI)
         pub upstream_detections: Vec<Detection>,  // Stage 1 YOLOX boxes + track_ids when triggered
         pub pipeline_config: serde_json::Value,   // Validated pack config parameters
     }
     ```
     **Why this matters for Phase 3 (Live Keyframe Tap):** When Phase 3 connects the bounded camera-sharded live-tap lane (`longshore_mailbox`, `<= 8` frames/camera, drop-oldest backpressure, `<= 128` active tracks/camera) to a Vantage worker over a low-latency core-NATS subject (`media.live.vantage.<capability_slug>.v1` with bounded frame payloads or shared-memory/local-relay read token), the worker author's `process_frame(ctx)` code does **not** change—the SDK handles transport decoding identically, and low-latency observations (such as bay docking distance/alignment vectors or real-time gate plate reads) stream directly back to Vantage UI and Dashboard SDK `useDashboardEvents` in sub-second latency while leaving recording and live viewer playback isolated.

2. **`serviceradar-sdk-vantage` Repository Layout (Rust Core + Python PyO3):**
   - `crates/serviceradar-vantage-sdk/` (Rust, Apache-2.0):
     - Re-exports/wraps `serviceradar-media-core` (`RgbFrame`, `Detection`, `RoiGridMask`, `MultiObjectTracker`, `encode_jpeg_thumbnail`), `rusty_h264-decoder`, `grants` client, `longshore`/NVR range reader, SHA-256 verifier, JetStream pull loop, `/healthz` + `/readyz` + `/metrics`, and `VantageHandler` trait (`fn capabilities() -> WorkerCapabilities`, `fn process_frame(&self, ctx: &VantageFrameContext) -> Result<Vec<Observation>>`).
   - `python/` (`serviceradar-vantage`, built with `maturin` / PyO3):
     - Exposes `VantageWorker`, `FrameContext` (zero-copy `numpy.ndarray` RGB view from Rust `RgbFrame`!), `Observation`, and `run_local_harness(clip_path, handler, schema_path)`.
     - Python ML developers run `pip install serviceradar-vantage`, implement `def process_frame(ctx: FrameContext) -> list[Observation]` using PyTorch/ONNX/FastALPR/PaddleOCR/TensorRT, test locally on synthetic MP4/JPEG clips with zero K8s/NATS/CNPG dependencies, and ship a container + `.srpack` Solution Pack.
   - `conformance/` — shared wire-format fixtures ensuring Rust SDK, Python bindings, and Core Elixir projector stay bit-for-bit compatible.

### Decision 5: Extending Solution Packs for Vantage Pipelines AND Dashboard SDK Browser Modules

Extend `ServiceRadar.Catalog.PackManifest` (`pack_format_version: 2`, while continuing to accept `pack_format_version: 1` unchanged for full backward compatibility):

```text
packs/vantage-alpr/
  manifest.json
  README.md
  vantage_pipelines/
    alpr-vehicle-plate.json
  signal_schemas/
    alpr_plate_read.schema.json
    alpr_plate_read.display.json
  checks/
    alpr-worker-health.json
  rules/
    alpr-watchlist-alert.json
  dashboards/
    alpr-overview.json                  # declarative authored dashboard (optional)
  dashboard_packages/
    alpr-console/
      manifest.json                     # dashboard-browser-module-v1 manifest
      renderer.js                       # built by serviceradar-cli dashboard build
  assets/
    architecture.svg
```

Key security & lifecycle rules for `dashboard_packages` inside Solution Packs:
1. **Two supported modes in `manifest.json`:**
   - **Bundled (`resources.dashboard_packages`):** Ships `dashboard_packages/<slug>/manifest.json` + `renderer.js` inside the `.srpack` archive (all covered by `manifest.files` SHA-256 digests and ed25519 pack signature; bounded by a dedicated per-renderer size cap of `8 MiB` and pack archive ceiling adjustment to `32 MiB` compressed / `96 MiB` uncompressed when `dashboard_packages` are present).
   - **External reference (`dashboard_package_dependencies`):** References an already-published `dashboard_id@version` (useful for lightweight GitOps trees that prefer not to store compiled JS bundles in Git).
2. **Explicit trust & approval gate (no silent script execution):**
   - Importing a `.srpack` containing a bundled `dashboard-browser-module-v1` stages the `DashboardPackage` via `ServiceRadar.Dashboards.PackageImport` (reusing all existing manifest validation, renderer SHA-256 verification, and `version_already_published` immutability checks).
   - Activating/enabling a bundled browser module and binding its route slug (`DashboardInstance`) requires the installer to hold BOTH `catalog.packs.install` AND `cli.dashboard.publish` / `dashboards.packages.manage` (or leaves the dashboard package `:staged` for an authorized admin to approve in Settings -> Dashboards, identical to `plugin_dependencies`!).
   - Uninstall detaches or disables pack-managed `DashboardInstance` bindings cleanly without deleting operator-customized copies.
3. **CLI integration (`@carverauto/serviceradar-cli`):**
   - `serviceradar-cli pack validate|build|sign|index` validates `vantage_pipelines/*.json`, `signal_schemas/*.json`, `worker_dependencies`, and `dashboard_packages/*/` (verifying renderer SHA-256 matches both the dashboard manifest and `manifest.files`, and running `SecretFreeValidator` over manifests/JSON while exempting minified JS only from false-positive key checks while still scanning for token literals like `ghp_`, `github_pat_`, PEM headers).
   - `serviceradar-cli vantage init|dev|validate` scaffolds a Vantage Solution Pack (with `--template vlm`, `--template rust-worker`, or `--template python-worker`, plus optional `--with-dashboard` scaffolding a React Dashboard SDK module inside `dashboard_packages/`) and runs a local synthetic test loop.

### Decision 6: Reference ALPR Pack (`io.serviceradar.vantage-alpr`) and License Isolation

- **OpenALPR license isolation:** OpenALPR OSS is AGPLv3 and commercial Rekor SDK is proprietary. Neither is linked or vendored into ServiceRadar OSS or `serviceradar-sdk-vantage`. Any operator wanting OpenALPR or a commercial ALPR API can run a separate external worker container implementing `vantage.worker.v1` (or a WASM HTTP bridge with a CNPG `credential_slot`), while installing the exact same Apache-2.0 `io.serviceradar.vantage-alpr` Solution Pack.
- **First-party reference ALPR pack (`io.serviceradar.vantage-alpr`, Apache-2.0):**
  - Triggers on Stage 1 `vehicle` detections (configured ROI zones, `min_confidence: 0.55`, up to 3 best keyframes per `track_id`).
  - Declares `worker_dependencies: [{capability: "vantage.alpr.v1", optional: true, fallback_runner: "camera_vlm"}]`.
  - **Out-of-the-box Ramp 1 mode:** Runs on existing `serviceradar-camera-vlm` (`crane-serve` Qwen3.5-4B) using full-resolution vehicle crops and a versioned JSON prompt returning `{plate_text, region, vehicle_color, vehicle_type, confidence}`, normalized (`A-Z0-9-`, length 2–12) and consensus-voted across the track's frames.
  - **High-throughput Ramp 2 mode:** When a healthy worker advertising `vantage.alpr.v1` (such as a companion permissive MIT/Apache-2.0 ONNX/Candle plate detector + OCR worker built with `serviceradar-sdk-vantage`) connects, `VantagePipelineDispatcher` automatically routes jobs to `media.jobs.vantage.vantage_alpr_v1.v1` instead of `camera_vlm`.
  - Ships: `alpr_plate_read.schema.json` + `.display.json`, watchlist alert rule (paused by default until operator configures watchlist parameter), worker/queue health check, declarative overview dashboard, and a bundled React Dashboard SDK `alpr-console` package (live `CameraGrid`, searchable plate log via `in:camera_observations`, cropped plate thumbnails, and live `useDashboardEvents` watchlist banner).

## Risks / Trade-offs

- **GPU contention between Stage 1/2 (`YOLOX`+`SigLIP`), Stage 3 (`camera-vlm`), and custom Vantage Workers:**
  - *Mitigation:* Isolate worker pools via separate JetStream pull consumers, per-pipeline rate/concurrency budgets (`max_jobs_per_minute`, `max_frames_per_track`), and separate Kubernetes Deployments/GPU slices. Worker saturation queues or drops excess custom pipeline work without affecting NVR recording, live playback, or Stage 1/2 indexing.
- **VLM OCR hallucinations or false positives on blurry plates (Ramp 1):**
  - *Mitigation:* Enforce full-resolution vehicle cropping (never `480x270` thumbnails), minimum bbox pixel area gate (`min_bbox_width_px >= 96`) before invoking VLM, multi-frame track consensus across 2–3 best keyframes, strict JSON schema + regex post-validation, and explicit confidence thresholds.
- **Bundled JavaScript supply-chain risk in Solution Packs (`dashboard_packages/`):**
  - *Mitigation:* Require ed25519 pack signature on `:release_catalog` imports, verify renderer SHA-256 against both `manifest.files` and `dashboard_package/manifest.json`, enforce explicit admin approval/RBAC (`dashboards.packages.manage` / `cli.dashboard.publish`) before enabling a bundled browser module, and preserve `version_already_published` immutability.
- **Live keyframe tap backpressure destabilizing live viewer relays (Phase 3):**
  - *Mitigation:* Reuse the bounded camera-sharded `longshore_mailbox` (`<= 8` frames/camera, drop-oldest) with strict per-deployment opt-in camera caps and explicit drop counters; live-tap workers never block the Membrane viewer egress or CMAF recorder.
- **PyO3 / multi-arch wheel build complexity for `serviceradar-sdk-vantage`:**
  - *Mitigation:* Keep `serviceradar-sdk-vantage` in its own repository with dedicated CI publishing Linux `amd64` + `arm64` manylinux wheels and a crates.io Rust crate, pinned against versioned wire-format conformance fixtures shared with ServiceRadar core.

## Migration Plan

1. **Additive CNPG migrations (`mix ash.codegen`):** Create `platform.camera_vantage_pipelines`, `platform.camera_vantage_jobs`, `platform.camera_vantage_observations`, and `platform.vantage_worker_registrations`; add nullable `pack_id`, `pack_version`, `managed`, `template_fingerprint` columns to `platform.dashboard_packages` / `platform.dashboard_instances` where needed for Solution Pack provenance.
2. **Backward-compatible Solution Pack v2:** Keep `pack_format_version: 1` fully supported; `pack_format_version: 2` enables `vantage_pipelines`, `signal_schemas`, `worker_dependencies`, and `dashboard_packages`.
3. **Feature-gated rollout:** Vantage ML pipeline dispatch defaults to disabled unless `SERVICERADAR_VANTAGE_PIPELINES_ENABLED=true` (and `SERVICERADAR_CAMERA_RECORDING_ENABLED=true` for recorded-block pipelines).
4. **Rollback:** Disabling or uninstalling a Vantage Solution Pack stops new job admission immediately; existing observations remain cleanly governed by `RecordingCatalogEntry` retention or explicit pack uninstall cleanup.

## Open Questions

- Should `serviceradar-sdk-vantage` live as a sibling public GitHub repo (`carverauto/serviceradar-sdk-vantage`, matching `serviceradar-sdk-go`, `serviceradar-sdk-rust`, and `serviceradar-sdk-dashboard`) with wire-schema conformance tests synced against `carverauto/serviceradar`? *(Assumed yes in P2 tasks; confirm before repo bootstrap.)*
- For Phase 3 live-tap operational guidance (e.g., bay docking alignment), should real-time telemetry observations optionally publish directly to a low-latency WebSocket/LiveView channel (`dashboard_frame_channel` / `useDashboardEvents`) in parallel with durable JetStream persistence, or exclusively via JetStream -> EventWriter -> PubSub? *(Design assumes JetStream -> EventWriter -> PubSub first, benchmarking end-to-end latency in P3 before adding any ephemeral fast-path.)*
