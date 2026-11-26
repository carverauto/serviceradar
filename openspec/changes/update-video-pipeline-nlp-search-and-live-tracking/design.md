## Context

This design reconciles ServiceRadar's video processing architecture on post-#6920 `origin/staging` (`22aabc7681`) across natural-language video search, live object detection/tracking, pure-Rust shared crate extraction, explicit accelerator/codec blockers, and ~8,000-camera production scale.

Detailed codebase evidence and 8,000-camera derivations live in [docs/video-pipeline-openspec-audit.md](../../../docs/video-pipeline-openspec-audit.md).

## Goals / Non-Goals

- Goals:
  - Apache-2.0 pure-Rust `YOLOX` detection with torso/lower-body HSV sub-crop attributes recorded alongside each detection.
  - Pure-Rust live object detection and multi-object tracking (`YOLOX` + `trackforge` `ByteTrack`/`BotSort` stateful per-camera `ClipTracker`) sharing existing camera ingests without duplicate camera sessions.
  - 8,000-camera viability (`2-4 Mbit/s`, `0.2-0.5 fps`) via two-tier gating (`add-vms-frame-change-gate`), bounded live-tracking concurrency/substream/Tier-2 caps (`<= 1,000` opt-in cams @ `1 fps` or `8,000` cams @ `0.5 fps` substream + `10-15%` Tier-2 pass-through), binary/f16 result payloads, track-crop dedup, configurable JetStream stream budgets, PG18 `timeline_ts_us` partitioned `halfvec(768)` embeddings, and scaled outbox dispatch (`> 318 jobs/s` continuous arrival, `>= 500 jobs/s` burst drain).
  - Shared pure-Rust workspace consolidation (`serviceradar-media-core`, `serviceradar-nats`, `serviceradar-spool`, `serviceradar-service-probes`, `serviceradar-anomaly-core`, `longshore >= 0.2.0`, selective `ultragraphdb_core_*` patterns) and `rusty_h264` fork adoption (`carverauto/0.17.3-fixes` `4439375cf`).
  - Mandatory Phase 0 security & correctness prerequisites (`R44`, scoped NATS grants, `NVRWorker` abort veto fix, demo NATS `36G` profile).
- Non-Goals:
  - Python/PyTorch `tamserve` or porting SAM 2 / EdgeTAM pixel masks (`3-5k` LoC + Meta license; remains deferred).
  - Unbounded CNPG raw `vms_ai_events` firehose or direct worker-to-CNPG writes.
  - Opening second RTSP/RTSPS camera connections for live tracking when a relay/recorder ingest already exists.

## Decisions

### 1. Decoupled Model Identity & Pure-Rust Apache-2.0 Detector (`YOLOX`)
- **Decision:** Separate `detector_model_id` / `detector_model_version` from `embedder_model_id` / `embedder_model_version` in Core (`VisualIndexDispatcher`), Helm (`media-worker.yaml`), and `serviceradar-media-worker`. Replace AGPL-3.0 YOLOv8 weights with pure-Rust **YOLOX** (Apache-2.0, `candle-nn` CSPDarknet + PAFPN + decoupled anchor-free head). Keep `SigLIP-b16-384` (`768`-dim) for Stage 2 embeddings and text RPC (`2.20 ms` p50 on GB10 F16).
- **Attribute Binding Fix:** Extend `vision.rs` `classify_dominant_colors` from full-bbox averaging to **upper-body (torso) vs lower-body (legs/skirt) sub-crop HSV histograms** and structured attributes (`upper_color`, `lower_color`, `object_class`), stored alongside crop embeddings.
- **SPS Dimension Fallback:** When `camera_stream_profiles.metadata` reports `fps=0, width=0, height=0` (observed on inventory bootstrap), derive frame geometry from decoded SPS / `ParsedInitSegment` (`cmaf.rs`) so bounding-box normalization and tracking never divide by zero.

### 2. Pure-Rust Live Object Detection & Tracking
- **Decision:** Introduce a bounded live-frame tap on active Core/recorder Membrane relays (`camera-streaming` analysis branch) or edge `retina` RTSP/RTP ingest (for edge-local tracking without cloud media round-trips). Route sampled live frames to camera-sharded stateful `ClipTracker` workers using `longshore_mailbox` (`0.2.0`) bounded `Copy` queues (`<= 8` frames/camera) and `InboxTurn`-bounded processing loops (`<= 32` frames/turn).
- **8,000-Camera Policy Bounds:** Un-bounded live tracking across 8,000 cameras at `1 fps` (`8,000 frames/s`) would require `88-304` CPU decode cores and `~32-40` GB10 GPUs for Stage 1 YOLOX (`~4 ms` F16) plus `~4.0 MB/s` (`~345 GB/day`) on `CAMERA_LIVE_TRACKS`. Production deployments MUST enforce explicit policy bounds: either an opt-in concurrent camera cap (`<= 1,000` cameras @ `1 fps`) or `0.5 fps` substream tap (`360p`/`720p`) gated by Tier-2 pre-Stage-1 Y-plane change detection (`10-15%` pass-through = `150` to `400-600` GPU-admitted frames/s -> `1-3` GB10s for YOLOX + `1-2` GB10s for track-deduped SigLIP, `~75-400 KB/s` into `CAMERA_LIVE_TRACKS`).
- **Statefulness:** Maintain persistent per-camera `ClipTracker` instances (`trackforge` `ByteTrack` or `BotSort`) keyed by `camera_source_id` with bounded tracklet capacity (`MAX_TRACKS_PER_CAMERA <= 128`, `30 s` idle TTL eviction -> `~130-256 MiB` total RAM at `8,000` cameras, `~16-32 MiB` at `1,000` cameras). Assign stable `track_id`s across live frames (not reset every 25 s NVR block), emit compact `media.events.live_tracks.v1` events (`~500 B` delta/summary on track change or `<= 0.5-1 Hz`) to JetStream (`CAMERA_LIVE_TRACKS`, `512 MiB` in `small` / `2-4 GiB` in `large`, `DiscardPolicy::Old`, `max_age = 1800-3600 s`), and deduplicate Stage 2 SigLIP crop embeddings per active track (`best_quality_crop` + periodic refresh) to cut Stage 2 GPU load by ~50-80%.
- **Viewer Delivery:** Honor latency budgets (drop stale live overlays rather than queue behind playback) and leave recorded CMAF bytes unmodified.

### 3. ~8,000-Camera Storage, JetStream, & Dispatch Scaling
- **CNPG Partitioning & `halfvec`:** Range-partition `platform.camera_visual_embeddings` by `timeline_ts_us` (daily/weekly PG18 partitions) and migrate `vector(768)` -> `halfvec(768)` (`2x` RAM/disk reduction, partition `DROP` instead of HNSW `DELETE`/VACUUM). Add `(state, deadline_at)` index on `platform.camera_visual_index_jobs`.
- **Dispatch Throughput:** Replace `VisualIndexDispatchWorker`'s `10 * 100 / min = 16.7 jobs/s` cap with event-driven / camera-sharded parallel dispatch sustaining `> 318 jobs/s` continuous arrival and `>= 500 jobs/s` burst drain (and pair with `add-longshore-object-storage` task `2.2` multipart `128 MiB` blocks to drop steady block rate from `318/s` to `~30/s`).
- **JetStream & Binary Results:** Remove hardcoded `512 MiB` / `2 GiB` in `rust/media-worker/src/worker.rs:1546, 1559`; read `SERVICERADAR_JS_CAMERA_MEDIA_JOBS_MAX_BYTES`, `SERVICERADAR_JS_CAMERA_MEDIA_RESULTS_MAX_BYTES`, and `SERVICERADAR_JS_CAMERA_LIVE_TRACKS_MAX_BYTES` (with Helm render-time budget accounting). Encode embeddings in `media.results.visual_index.v1` as compact binary/f16 (`~1.5 KB`/vec vs `~9 KB` JSON `Vec<f32>`), cutting result stream bandwidth ~6x.
- **GB10 GPU Concurrency:** Prefer 1 worker process per physical/MIG GPU slice rather than 2 time-sliced processes (`runA`/`runB` contention halved per-process throughput from `101-110` to `52.3-59.8 img/s` e2e, `~105-114 img/s` combined, with `batch=8` e2e at `52.3` and `52.8 img/s` -> `105.1 img/s` combined), and keep parallel CPU preprocessing (`cores / concurrency`).

### 4. Shared Rust Crates & Explicit Pure-Rust Blockers
- **Shared Crates:** Extract `rust/media-core` (`cmaf`, `h264`, `keyframe_decoder`, `range_reader`, `tracking`, `tokenizer`, Tier-2 `vision` gate), `rust/nats-client` (`async-nats` + `cert-policy` + stream env overrides + chunking), `rust/disk-spool`, and `rust/service-probes`. Adopt `serviceradar-anomaly-core` for Tier-1 gating, `longshore_s3 >= 0.2.0` + `longshore_crc` + `alloc_guard` + `longshore_mailbox`, and selective `ultragraphdb_core_{ids,codec,algo,tok}` `UidPack` pre-filtering patterns (respecting `ultragraphdb`'s `1.99.1` / `compio` vs ServiceRadar's `1.98.0` / `tokio` boundary).
- **Documented Pure-Rust Blockers & Review Options:**
  1. *GPU Compute:* `candle/cuda` compiles `.cu` via `nvcc` and links CUDA 13 (`cudarc`). Pure-Rust alternative `burn-wgpu`/`cubecl` crosses only Vulkan ICD (`libvulkan.so.1`) but lacks measured GB10 F16 parity.
  2. *HEVC Decode:* `rusty_h264` is H.264-only. Options: evaluate pure-Rust `rusty_h265` (BSD-2), Vulkan Video (`VK_KHR_video_decode_queue`), or isolated `libavcodec`/NVDEC FFI.
  3. *Transformer Detectors:* `candle 0.11.1` has `0` `grid_sample` ops (blocks RT-DETR/RF-DETR). Resolved via Apache-2.0 YOLOX unless `grid_sample` or `burn` is added later.
  4. *Bazel RBE Git Dep:* `third_party/crate_mirror/sync.py` skips checksum-less git deps for `carverauto/0.17.3-fixes`; verify `crate_universe` RBE fetch or vendor/mirror tarball.

## Risks / Trade-offs

- **Time-sliced GPU contention:** Running multiple GPU pods on one GB10 halves per-pod throughput (`52.3-59.8 img/s` e2e). Mitigate with 1 worker replica per GPU and reserved interactive RPC capacity.
- **H.265 camera fleet share:** Until an HEVC option (B2) is chosen and qualified, HEVC cameras emit `undecodable_keyframes` (`unsupported_codec`) and require H.264 profile selection or sub-stream fallback.
- **No delta collisions:** Every spec delta in this change uses `## ADDED Requirements` with unique requirement names so active recording (`add-nvr-*`, `add-scalable-*`) and JetStream (`scale-*`) PRs merge and archive cleanly.

## Migration Plan

1. **Phase 0:** Fix `R44`, NATS subject grants, `NVRWorker` abort veto, and demo NATS `36G` PVC before enabling visual indexing.
2. **Phase 1:** Adopt `rusty_h264` fork, extract `rust/media-core`, wire two-tier frame gate (`add-vms-frame-change-gate`), land Apache-2.0 YOLOX + sub-crop HSV attributes.
3. **Phase 2:** Enable live tracking tap + `CAMERA_LIVE_TRACKS`, binary/f16 results, partitioned `halfvec(768)`, and scaled dispatch.
4. **Phase 3:** Land Longshore multipart `128 MiB` blocks, `add-scalable-camera-recording-plane`, and chosen HEVC decoder path.
