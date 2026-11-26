# Change: Vantage ML Pipeline Extensibility, Solution Pack Video & Dashboard Bundling, and Vantage Worker SDK

## Why

ServiceRadar Vantage already runs pure-Rust GPU video indexing (`serviceradar-media-worker` + `serviceradar-media-core` with `YOLOX`, `SigLIP`, and `rusty_h264`) and an in-cluster Vision-Language Model (`serviceradar-camera-vlm`, `crane-serve` + Qwen3.5-4B), alongside a signed Solution Pack catalog (`pack_format_version: 1`) and a React/JS Dashboard SDK (`@carverauto/serviceradar-dashboard-sdk`). Today, however, all video analytics stages are hardcoded inside the ServiceRadar monorepo: external developers and operators cannot build, package, or install custom video ML pipelines (such as Automatic License Plate Recognition (ALPR), PPE compliance, hazard detection, or low-latency bay/gate approach guidance) without forking `rust/media-worker`, `elixir/serviceradar_core`, and `elixir/web-ng`.

In addition, many widely used third-party computer vision engines carry copyleft (e.g., AGPLv3 OpenALPR) or commercial licenses that cannot be linked into Apache-2.0 ServiceRadar core, and Solution Packs currently bundle declarative authored dashboards only—not `dashboard-browser-module-v1` Dashboard SDK packages—preventing vertical packs from delivering rich custom camera consoles in a single install.

## What Changes

- **Canonical Vantage ML Pipeline & Observation Contract (`vantage-ml-pipelines`):**
  - Introduce declarative `vantage_pipelines/*.json` definitions backed by Ash resource `ServiceRadar.Camera.VantagePipeline` so packs can attach custom video analytics pipelines to cameras via SRQL/policy selectors, Stage 1 detection triggers (e.g., `vehicle`, `person`), ROI zones, sampling/cropping policies, and per-track rate limits.
  - Introduce a generic, retention-coupled `platform.camera_vantage_observations` projection (`ServiceRadar.Camera.VantageObservation`) fed exclusively through NATS JetStream (`media.results.vantage.v1` -> Core `EventWriter`), with pack-defined JSON Schema validation, generated `tsvector` full-text indexing, optional bounded crop JPEGs (`<= 32 KiB`), optional OCSF event projection for alerting/live UI streams, SRQL queryability (`in:camera_observations`), and automatic rendering on Vantage's timeline rail, clip playback bounding-box overlays, and search.
- **Three Progressive Compute Ramps (Single Packaging Output = Solution Pack):**
  - **Ramp 1 — Declarative VLM / Prompt Pipelines (Zero Code):** Execute pack-defined structured JSON VLM prompts against existing `serviceradar-camera-vlm` (`crane-serve` / `llama-server` / external OpenAI-compatible endpoints) using **full-resolution cropped IDR keyframes** around Stage 1 detections (fixing the readability ceiling of `480x270` full-scene thumbnails for OCR/ALPR) and multi-frame track consensus.
  - **Ramp 2 — External Vantage Workers (`vantage.worker.v1`) & `serviceradar-sdk-vantage`:** Generalize `media-worker`'s JetStream pull consumer, execution-time scoped Fragment Read Grants (`POST /v1/media/workers/read-grants`), SHA-256 verification, and pure-Rust H.264 decode into an open `vantage.worker.v1` protocol and a companion **`serviceradar-sdk-vantage`** repository (Rust core crate wrapping `serviceradar-media-core` + Python PyO3 bindings + synthetic local dev harness). Keeps third-party engines (AGPLv3, commercial, PyTorch, ONNX, TensorRT, Candle) cleanly isolated across a process/network boundary.
  - **Ramp 3 — WASM Control/Logic Bridge:** Connect Vantage observations and OCSF events to existing `wazero` WASM plugins for deterministic post-processing, external watchlist/API enrichment via brokered CNPG credentials, and northbound actions (e.g., gate/relay control).
- **Forward-Compatible Live Keyframe Tap Path (Phase 3):**
  - Design the `vantage.worker.v1` input frame envelope (`source_mode: :recorded_block | :live_keyframe_tap`) and SDK handler interface from day one so Phase 1 executes safely against sealed `RecordingCatalogEntry` blocks via Fragment Read Grants, while Phase 3 feeds sub-second live keyframes from the bounded camera-sharded live-tap lane (`longshore_mailbox`) into the **same** worker handler for real-time operational guidance (e.g., automated vehicle/equipment bay docking guidance and real-time gate ALPR) without redesigning the SDK or Solution Pack format.
- **Solution Pack Extensions (`solution-packs-catalog` + `dashboard-sdk`):**
  - Extend Solution Packs to support `vantage_pipelines/`, `signal_schemas/`, `worker_dependencies`, and bundled or referenced **Dashboard SDK browser modules** (`dashboard_packages/`, `dashboard-browser-module-v1`) with strict SHA-256 digest verification, explicit admin trust/approval gating (never silently auto-enabling untrusted JS or overwriting an enabled version), and managed route binding.
- **Reference ALPR Solution Pack (`io.serviceradar.vantage-alpr`):**
  - Ship a first-party Apache-2.0 ALPR Solution Pack that works out-of-the-box on Ramp 1 (`camera_vlm` Qwen3.5-4B with full-res vehicle crops) and upgrades seamlessly to Ramp 2 when an operator deploys a compatible `vantage.alpr.v1` worker (e.g., permissive MIT/Apache-2.0 ONNX/Candle plate+OCR reference worker built with `serviceradar-sdk-vantage`, or an operator-supplied external worker).

## Phased Delivery

| Phase | Scope | Exit Gate |
| --- | --- | --- |
| **P1** | Generic `VantagePipeline` + `VantageObservation` Ash resources, JetStream `media.results.vantage.v1` projection, SRQL `in:camera_observations`, full-res bbox crop extraction, Ramp 1 Declarative VLM runner, Solution Pack `vantage_pipelines/` + `signal_schemas/` + `dashboard_packages/` support, and Vantage timeline/overlay/search rendering | Synthetic end-to-end ALPR Ramp 1 pass (vehicle detection -> full-res crop -> structured JSON VLM -> observation + OCSF alert + timeline overlay + search); strict retention/quarantine/hold purge tests |
| **P2** | `vantage.worker.v1` external worker protocol, capability registration/discovery, `VantagePipelineDispatcher` capability routing, `serviceradar-sdk-vantage` (Rust core + Python PyO3 bindings + local synthetic dev harness), `serviceradar-cli vantage` commands, and reference Apache/MIT `vantage-worker-alpr` | External Rust and Python workers built purely against `serviceradar-sdk-vantage` process synthetic H.264 blocks via scoped read grants and pass `io.serviceradar.vantage-alpr` end-to-end; zero DB creds on worker |
| **P3** | Live keyframe tap feeder (`source_mode: :live_keyframe_tap`) composing with the bounded camera-sharded live-tap lane (`longshore_mailbox`), low-latency observation streaming (`useDashboardEvents`), and synthetic docking/bay-guidance benchmark | Bounded p95 end-to-end live-frame latency measured on synthetic stream; worker crash or mailbox overflow causes zero disruption to recording or live viewer playback |

## Impact

- **Affected specs:**
  - `vantage-ml-pipelines` (added)
  - `solution-packs-catalog` (added requirements for Vantage pipelines, signal schemas, worker dependencies, and `dashboard-browser-module-v1` bundling)
  - `vms-media-workers` (added requirements for full-resolution crop extraction, generalized `vantage.worker.v1` capability & read-grant protocol, and forward-compatible live-tap frame envelope)
  - `dashboard-sdk` (added requirements for Solution Pack browser-module packaging/build integration and camera observation consumption)
- **Affected code (when approved for implementation):**
  - `elixir/serviceradar_core/lib/serviceradar/camera/` (`VantagePipeline`, `VantagePipelineJob`, `VantageObservation`, `VantagePipelineDispatcher`, `VantageVlmRunner`, `VantageObservationProjector`, `VisualWorkerReadGrants`, `SemanticSearch`, retention/quarantine purge paths)
  - `elixir/serviceradar_core/lib/serviceradar/catalog/` (`PackManifest`, `Reconciler`, `DependencyChecker`, `PackExporter`, `PackArchive`)
  - `elixir/serviceradar_core/lib/serviceradar/dashboards/` (`PackageImport`, `DashboardPackage`, `DashboardInstance` pack provenance)
  - `elixir/serviceradar_core/lib/serviceradar/event_writer/processors/` (`CameraVantageObservations`)
  - `rust/media-core/` & `rust/media-worker/` (full-resolution bbox/ROI cropper, shared `vantage_protocol` types, live-tap envelope support)
  - `rust/srql/` (`in:camera_observations` entity translation via AshAdapter)
  - `elixir/web-ng/` (Vantage timeline rail, clip overlay, search fusion, Catalog Gallery worker/dashboard-package UI)
  - `js/cli/` (`serviceradar-cli pack` dashboard-package bundling + `serviceradar-cli vantage init|dev|validate`)
  - Companion external repo (P2): `serviceradar-sdk-vantage` (Rust core crate + Python PyO3 package + synthetic local harness + example ALPR worker)
- **Architectural invariants preserved:**
  - All observations and telemetry traverse NATS JetStream first (`EventWriter`); media/ML workers never receive CNPG or StarRocks credentials.
  - All external inference or watchlist credentials reside exclusively in `platform.network_credential_secrets` and flow via `CredentialBrokerGrant` / `ServiceRadar.HTTP.EgressClient`.
  - Recording capture, archive publication, and live viewer playback remain isolated from ML worker failure or saturation.
  - No real customer/site footage, license plates, hostnames, or identifiers appear in specs, tests, fixtures, or reference packs.
