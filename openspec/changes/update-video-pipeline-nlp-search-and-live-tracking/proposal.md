# Change: Reconcile video pipeline for pure-Rust NLP search, live tracking, and 8,000-camera scale

## Why

Post-#6920 `origin/staging` (`22aabc7681`) ships `camera-semantic-search`, `vms-media-workers`, `rust/media-worker/` (`rusty_h264-decoder`, `candle`, `trackforge`), and NVR `seal-to-catalog`. However, four gaps prevent accurate natural-language retrieval (e.g., `"find the man in the red dress"`), live object detection/tracking, and ~8,000-camera production scale:

1. **Detector & Attribute-Binding Gap:** `VisualIndexDispatcher` and `feat/helm-media-worker-gpu-runtime` pin `"rtdetr-r18"` (which `candle 0.11.1` cannot run due to missing `grid_sample`), while `rust/media-worker/src/yolo_v8.rs` only implements YOLOv8 (AGPL-3.0 weight risk), causing Helm to disable detection mounts entirely and reducing indexing to whole-scene SigLIP only.
2. **8,000-Camera Throughput & Storage Collapse:** Un-gated `0.5 fps` keyframe sampling across 8,000 cameras overwhelms `VisualIndexDispatchWorker` (`16.7 jobs/s` ceiling vs `318 blocks/s`), overflows hardcoded `CAMERA_MEDIA_JOBS` (`512 MiB` = ~39 min < 72 h floor) and `CAMERA_MEDIA_RESULTS` (`2 GiB` JSON `Vec<f32>` = 18-64 s overflow), and saturates unpartitioned `pgvector` HNSW (`~6.1 TB/day` un-gated).
3. **Missing Live Detection & Tracking Path:** `rust/media-worker/src/tracking.rs` wraps pure-Rust `trackforge` (`ByteTrack`, `BotSort`, `DeepOcSort`) per sealed clip only (`ClipTracker`), with no live-frame ingest tap, no cross-block camera-sharded state, and no live JetStream track event stream.
4. **Pre-Enablement Security & Codec Gaps:** `R44` in `visual_worker_read_grants.ex`, broad NATS `$JS.API.>` / `>` grants, `NVRWorker` abort veto (`nvr_worker.ex:651, 689`), single-slice/equal-QP H.264 refusals (`rusty_h264-decoder = "=0.17.3"` vs `carverauto/0.17.3-fixes`), `camera_stream_profiles` `0x0` bootstrap metadata, and undocumented pure-Rust blockers (CUDA `nvcc`/`cudarc`, HEVC decode, SAM 2/EdgeTAM) remain unresolved.

## What Changes

- **Pure-Rust NLP Search & Compositional Attribute Precision:**
  - Decouple `detector_model_id` from `embedder_model_id` across Core, Helm, and worker manifests; replace AGPL YOLOv8 with pure-Rust Apache-2.0 **YOLOX** (`candle-nn`) alongside `SigLIP-b16-384` (`768`-dim).
  - Add torso/lower-body HSV sub-crop color and structured attribute extraction in the worker.
  - Enforce SPS/container dimension fallback when `camera_stream_profiles.metadata` reports `fps=0, width=0, height=0`.
- **Pure-Rust Live Object Detection & Tracking:**
  - Add a bounded live-frame tap on existing Core/recorder relays (or edge `retina` RTSP ingest) without opening a second upstream camera pull.
  - Run stateful per-camera `ClipTracker` actors (`trackforge` `ByteTrack`/`BotSort`) using camera-sharded `longshore_mailbox` affinity and `InboxTurn` bounded turns, publishing live detections, `track_id` trajectories, and per-track attribute/Re-ID summaries to JetStream (`CAMERA_LIVE_TRACKS` / `media.events.live_tracks.v1`).
- **8,000-Camera Scale, JetStream Budgets, & Partitioned Storage:**
  - Time-range partition `platform.camera_visual_embeddings` (`timeline_ts_us`), migrate `vector(768)` -> `halfvec(768)`, add `(state, deadline_at)` index on `platform.camera_visual_index_jobs`, and raise `VisualIndexDispatchWorker` throughput above `318 jobs/s`.
  - Honor `SERVICERADAR_JS_CAMERA_MEDIA_JOBS_MAX_BYTES`, `SERVICERADAR_JS_CAMERA_MEDIA_RESULTS_MAX_BYTES`, and `SERVICERADAR_JS_CAMERA_LIVE_TRACKS_MAX_BYTES` in workers and Helm budget checks; switch result vectors from JSON `Vec<f32>` to compact binary/f16 (`~1.5 KB`/vec) + track-crop deduplication.
- **Shared Rust Crates, Decoder Fork, Security Gates, & Explicit Blockers:**
  - Extract `rust/media-core`, `rust/nats-client`, `rust/disk-spool`, and `rust/service-probes`; adopt `serviceradar-anomaly-core`, `longshore_s3 >= 0.2.0` / `longshore_crc` / `longshore_mailbox` / `alloc_guard`, selective `ultragraphdb_core_{ids,codec,algo,tok}` patterns, and `~/src/rusty_h264` `carverauto/0.17.3-fixes` (`4439375cf`).
  - Enforce mandatory Phase 0 security gates (`R44` ownership verification before cancellation, scoped NATS grants, `NVRWorker` abort veto fix, demo NATS `36G` profile).
  - Document pure-Rust blockers and review options explicitly (`candle/cuda` vs `burn-wgpu`, HEVC `rusty_h265` vs Vulkan Video vs FFI, `candle` missing `grid_sample` for RT-DETR, SAM 2/EdgeTAM deferred).
- **Synthetic & Designated Verification Plans:**
  - Define reproducible synthetic `demo/rtsp-replayer` (`drone-highway`, `drone-quarry`, `drone-surf`) and RFC-5737 edge RTSPS (`192.0.2.90`, `cam-synth-0001`, `Gate North`) test gates.

## Impact

- Affected specs: `camera-semantic-search`, `vms-media-workers`, `camera-streaming`, `jetstream-storage-budget` (`## ADDED Requirements` only — zero `MODIFIED` collisions with active recording or JetStream scaling PRs).
- Related changes: [add-vms-frame-change-gate](../add-vms-frame-change-gate/proposal.md), [add-vms-storage-playback-engine](../add-vms-storage-playback-engine/proposal.md), [update-media-worker-real-keyframe-decode](../update-media-worker-real-keyframe-decode/proposal.md), [add-scalable-camera-recording-plane](../add-scalable-camera-recording-plane/proposal.md), [add-longshore-object-storage](../add-longshore-object-storage/proposal.md).
- Affected code (when implemented): `rust/media-core`, `rust/media-worker`, `rust/nats-client`, `rust/disk-spool`, `rust/service-probes`, `elixir/serviceradar_core`, `elixir/serviceradar_core_elx`, `elixir/web-ng`, `helm/serviceradar`.
