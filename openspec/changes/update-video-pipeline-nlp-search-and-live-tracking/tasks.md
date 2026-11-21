## 1. Phase 0: Security, Correctness & Budget Prerequisites

- [ ] 1.1 Fix `R44` in `elixir/serviceradar_core/lib/serviceradar/camera/visual_worker_read_grants.ex` so `load_and_check_job` and `verify_descriptor_sha` run **before** `maybe_cancel_job`, and close `R43`/`R45`-`R48` from recovery commit `463daf5208`.
- [ ] 1.2 Narrow NATS JetStream subject permissions so non-media identities cannot subscribe to or publish `media.jobs.visual_index.*`, `media.results.visual_index.*`, `media.rpc.visual_text_embed.*`, or `media.events.live_tracks.*`.
- [ ] 1.3 Remove the `NVRWorker` abort veto (`nvr_worker.ex:651, 689`) on verified `:sealed_local` receipts so sealed blocks always register in `camera_recording_catalog`.
- [ ] 1.4 Expand `values-demo.yaml` NATS JetStream profile to `small` (`36G` / `36Gi` PVCs via `StatefulSet --cascade=orphan` per `docs/nats-jetstream-profile-runbook.md`) and honor `SERVICERADAR_JS_CAMERA_MEDIA_JOBS_MAX_BYTES`, `SERVICERADAR_JS_CAMERA_MEDIA_RESULTS_MAX_BYTES`, and `SERVICERADAR_JS_CAMERA_LIVE_TRACKS_MAX_BYTES` in Rust workers + Helm budget checks.

## 2. Phase 1: Pure-Rust Foundation, Decoder Fork & Compositional NLP Search

- [ ] 2.1 Consume `github.com/carverauto/rusty_h264` `carverauto/0.17.3-fixes` (`4439375cf`, `default-features = false`) with Bazel `crate_universe` / `third_party/crate_mirror` verification; lift temporary single-slice and equal-QP refusals in `rust/media-worker/src/h264.rs` and persist `undecodable_keyframes` in Core.
- [ ] 2.2 Extract pure-Rust `rust/media-core` (`cmaf`, `h264`, `keyframe_decoder`, `range_reader`, `tracking`, `tokenizer`, Tier-2 pixel gate), `rust/nats-client`, `rust/disk-spool`, and `rust/service-probes` following Ultra Style conventions (`rust/README_RUST.md`).
- [ ] 2.3 Implement pure-Rust Apache-2.0 **YOLOX** in `candle-nn` (`detector_model_id: "yolox-s"`), decouple `detector_model_id` from `embedder_model_id` in `VisualIndexDispatcher` and Helm `media-worker.yaml`, and retire AGPL YOLOv8 / unimplemented `"rtdetr-r18"` defaults.
- [ ] 2.4 Add upper-body/lower-body HSV sub-crop color classification and structured attribute extraction in `vision.rs`, SPS/container dimension fallback for `0x0` `camera_stream_profiles.metadata`, and optional query-time top-K VLM reranking (`<= 20` candidates).

## 3. Phase 2: Live Object Detection/Tracking & 8,000-Camera Scale

- [ ] 3.1 Add bounded live-frame tap from existing Membrane relay (`camera-streaming`) or edge `retina` RTSP ingest into camera-sharded stateful `ClipTracker` workers (`trackforge` `ByteTrack`/`BotSort` + `longshore_mailbox` + `InboxTurn`), publishing live tracks and track-deduplicated crop summaries to `CAMERA_LIVE_TRACKS` (`media.events.live_tracks.v1`).
- [ ] 3.2 Switch `media.results.visual_index.v1` embeddings from JSON `Vec<f32>` to compact binary/f16 (`~1.5 KB`/vec) and enable track-crop deduplication.
- [ ] 3.3 Partition `platform.camera_visual_embeddings` by `timeline_ts_us` on PG18 with `halfvec(768)` HNSW indexes, add `(state, deadline_at)` index on `platform.camera_visual_index_jobs`, and raise `VisualIndexDispatchWorker` throughput above `16.7 jobs/s`.

## 4. Phase 3: Fleet Scale-Out & Blocker Resolution

- [ ] 4.1 Complete Longshore multipart upload (`add-longshore-object-storage` task `2.2`) to raise NVR block ceiling from `12 MiB` to `128 MiB`, and integrate `add-scalable-camera-recording-plane` recorder pools.
- [ ] 4.2 Resolve explicit owner decisions for documented pure-Rust blockers: (a) `candle/cuda` vs `burn-wgpu` GPU backend, and (b) H.265/HEVC decode (`rusty_h265` vs Vulkan Video vs isolated `libavcodec`/NVDEC).

## 5. Verification Gates

- [ ] 5.1 Unit-test YOLOX pure-Rust forward pass, torso/lower-body HSV sub-crop attributes, binary/f16 result round-trip, stateful cross-block `ClipTracker` ID continuity, and `longshore_common::io::alloc_guard` hot-path zero-alloc checks on synthetic fixtures.
- [ ] 5.2 Run Tier 1 `demo/rtsp-replayer` verification (`drone-highway`, `drone-quarry`, `drone-surf` at `rtsp://rtsp-replayer.serviceradar.svc.cluster.local:8554/<path>`): verify multi-slice H.264 decode, compositional NLP search hits, live `track_id` persistence, and `< 250 ms` text RPC + partitioned `halfvec` query p95.
- [ ] 5.3 Run Tier 2 synthetic RFC-5737 edge RTSPS verification (`192.0.2.90`, `rtsps://nvr-01.example.com:7441/cam-01`, `cam-synth-0001`, `Gate North`, `agent-edge-01`, `gpu-node-01`) confirming `0x0` bootstrap metadata SPS fallback, profile switching, `R44` denial on mismatched `job_id`/`catalog_entry_id`, and zero credential/frame leakage.
