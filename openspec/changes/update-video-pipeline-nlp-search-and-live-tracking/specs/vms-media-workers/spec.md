## ADDED Requirements

### Requirement: Pure-Rust permissive detector, decoder fork, and SPS fallback
The system SHALL run Stage 1 object detection in pure Rust using an Apache-2.0 `YOLOX` model in `candle-nn` (replacing AGPL-3.0 YOLOv8 weights and `candle`-incompatible `rtdetr-r18`), SHALL adopt `rusty_h264-decoder` `carverauto/0.17.3-fixes` (with `default-features = false` and Bazel-hermetic vendoring/mirroring) to decode multi-slice progressive 8-bit 4:2:0 H.264 keyframes, and SHALL fall back to decoded SPS / `ParsedInitSegment` dimensions when `camera_stream_profiles.metadata` reports `fps = 0`, `width = 0`, or `height = 0`.

#### Scenario: Multi-slice H.264 IDR keyframe from real camera decodes without artificial refusal
- **WHEN** `serviceradar-media-core` decodes a progressive 8-bit 4:2:0 raster-ordered multi-slice H.264 IDR frame or one with unequal Cb/Cr quantization offsets
- **THEN** `DefaultKeyframeDecoder` SHALL decode the real picture bytes using `carverauto/0.17.3-fixes` instead of emitting `unsupported_codec`
- **AND** Core SHALL persist any remaining `undecodable_keyframes` (such as HEVC) cleanly per keyframe

#### Scenario: Bootstrap profile with zero dimensions resolves geometry from SPS
- **WHEN** `camera_stream_profiles.metadata` for `cam-synth-0001` (`192.0.2.90`, `Gate North`) contains `width = 0`, `height = 0`, `fps = 0`
- **THEN** the worker SHALL extract canonical frame width and height from the CMAF `init.mp4` / H.264 SPS before normalizing detection boxes or tracking coordinates

### Requirement: Stateful live object detection and multi-object tracking
The system SHALL support a pure-Rust live detection and tracking mode that maintains persistent per-camera `ClipTracker` state (`trackforge` `ByteTrack` or `BotSort`) over camera-sharded bounded `longshore_mailbox` (`0.2.0`) lanes (`<= 8` frames/camera) and `InboxTurn` bounded turns (`<= 32` frames/turn), enforces bounded tracklet capacity (`<= 128` active tracks/camera with `30 s` idle TTL eviction) and fleet admission bounds (opt-in active camera cap `<= 1,000` at `1 fps` or `<= 0.5 fps` substream tap gated by pre-Stage-1 Tier-2 Y-plane motion pass-through so Stage 1 YOLOX sees `<= 150-600` frames/s at 8,000-camera scale), and emits continuous cross-frame `track_id` trajectories and per-track attribute summaries without running Python `tamserve` or SAM 2 / EdgeTAM pixel masks.

#### Scenario: Live object trajectory preserves track_id across continuous live stream
- **WHEN** a tracked person or vehicle moves across `drone-highway` or `drone-surf` live frames arriving over the bounded live tap
- **THEN** the camera-sharded stateful `ClipTracker` SHALL maintain a continuous `track_id`, class, bounding box, dwell duration, and upper/lower HSV color attributes across consecutive frames without resetting every NVR block
- **AND** overloaded camera mailboxes (`> 8` pending frames) SHALL drop excess frames with explicit backpressure metrics and `ClipTracker` SHALL cap active state at `<= 128` tracks per camera with `30 s` idle TTL eviction rather than growing unboundedly

### Requirement: Shared Rust media core and explicit accelerator boundary
The system SHALL isolate pure-Rust media parsing, H.264 decoding, range reading, tokenization, `ClipTracker`, and Tier-2 frame-change gating into `rust/media-core` (`serviceradar-media-core`) alongside shared `serviceradar-nats`, `serviceradar-disk-spool`, and `serviceradar-service-probes` crates following Ultra Style conventions, and SHALL explicitly document non-pure-Rust boundaries (`candle/cuda` `nvcc`+`cudarc` vs `burn-wgpu`, and HEVC `rusty_h265` vs Vulkan Video vs isolated FFI) in capability manifests and design records.

#### Scenario: Edge pure-Rust binary compiles without Candle or CUDA dependencies
- **WHEN** an edge frame-change gate or live RTSP tracker builds against `serviceradar-media-core`, `serviceradar-anomaly-core`, and `serviceradar-nats`
- **THEN** it SHALL compile and pass `cargo check` / `bazel test` with zero `candle`, `nvcc`, `Vix`, `onig_sys`, or `esaxx-rs` C++ dependencies

#### Scenario: GPU worker runs single process per GPU slice to avoid time-slice contention
- **WHEN** `serviceradar-media-worker-cuda` schedules on an `arm64` GPU node (`gpu-node-01`)
- **THEN** deployment scheduling SHALL target one worker process per allocated GPU slice (`100.6-110.2 img/s` F16 e2e single-process vs `52.3-59.8 img/s` e2e per process under 2-process contention) and publish explicit capability/accelerator boundary metadata on `/readyz`

### Requirement: Compact binary result payloads and track-crop deduplication
The system SHALL encode embedding vectors in `media.results.visual_index.v1` using compact binary `f16` representation (`~1.5 KB` per 768-d vector rather than `~8-9 KB` JSON `Vec<f32>`) and SHALL deduplicate Stage 2 SigLIP crop embeddings per active `track_id` (`best_quality_crop` + periodic refresh) so `CAMERA_MEDIA_RESULTS` and CNPG writes fit ~8,000-camera production bounds.

#### Scenario: Track-crop deduplication and binary f16 encoding reduce result bandwidth
- **WHEN** a stationary or slowly moving tracked object appears in 10 consecutive admitted keyframes within a block
- **THEN** `serviceradar-media-worker` SHALL compute Stage 2 SigLIP embeddings for the highest-quality representative crop(s) of that `track_id` rather than every redundant frame, and serialize embeddings in compact binary `f16` format
