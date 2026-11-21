## ADDED Requirements

### Requirement: Two-tier pre-inference frame-change gate
The system SHALL evaluate frame change using a pure-Rust and Core metadata two-tier gate—combining a Tier 1 zero-decode CMAF `trun` sync-sample and fragment byte-rate delta scored via `serviceradar-anomaly-core` before `VisualIndexJob` admission with a Tier 2 pure-Rust box-averaged Y-plane spatial-block max-L1 gate executed before YUV-to-RGB conversion, Stage 1 object detection, and Stage 2 embedding—without adding `Vix`/`libvips` FFI or stalling NVR recording or live playback.

#### Scenario: Static scene suppressed before Stage 1 detection and Stage 2 embedding
- **WHEN** two consecutive sampled keyframes from a camera have identical or static Y-plane spatial blocks within the configured gate threshold and within the `max_carry_forward_interval_ms` ceiling
- **THEN** Tier 2 SHALL return a zero or sub-threshold spatial-block max-L1 score before Stage 1 object detection or Stage 2 SigLIP inference runs
- **AND** the worker SHALL skip Stage 1 detection and Stage 2 embedding while extending the prior anchor keyframe's validity interval

#### Scenario: Small localized foreground subject triggers spatial-block gate without aliasing
- **WHEN** a small foreground subject (such as a person or package occupying less than 2% of a 1080p frame) enters a bounded corner or region of an otherwise static synthetic Y-plane frame
- **THEN** the box-averaged spatial-block max-L1 score SHALL exceed the identical-frame score and admit the frame for Stage 1 detection and Stage 2 embedding even when global frame mean L1 remains below `0.02`

#### Scenario: Tier 1 metadata gate skips static block before decoding
- **WHEN** a sealed CMAF block exhibits stationary `trun` sync-sample (`first_sample_size`) and fragment byte-rate telemetry within the camera's `serviceradar-anomaly-core` (`SlidingWindow`/`WelfordAcc`/`Cusum`) baseline and within `max_carry_forward_interval_ms`
- **THEN** Core SHALL suppress `VisualIndexJob` dispatch for that block without decoding keyframes or consuming GPU worker capacity, while recording the carried-forward validity interval

#### Scenario: Invalid frame dimensions or gate failure isolates recording and live view
- **WHEN** a sampled keyframe has mismatched dimensions, zero dimensions, or corrupt luma buffers
- **THEN** the Tier 2 gate SHALL return a typed error (`MediaWorkerError` / `KeyframeDecodeError`) without panicking or allocating unbounded memory
- **AND** NVR recording and live relay viewing SHALL continue unaffected

### Requirement: Synthetic frame-change gate and decode benchmarking
The system SHALL validate Tier 1 and Tier 2 frame-change gating on deterministic synthetic CMAF/Y-plane inputs (including zero-allocation hot-path checks via `longshore_common::io::alloc_guard`) and measure gate admission ratios, CPU decode core usage, and GPU Stage 1/2 savings against the synthetic `rtsp-replayer` catalog (`drone-highway`, `drone-quarry`, `drone-surf`) before sizing production ~8,000-camera worker pools.

#### Scenario: Zero-allocation steady-state gate hot loop
- **WHEN** the Tier 2 spatial-block Y-plane gate runs over pre-allocated per-camera grid buffers under `longshore_common::io::alloc_guard::sealed`
- **THEN** steady-state frame comparisons SHALL perform zero heap allocations

#### Scenario: Replayer gate measurement precedes 8,000-camera GPU sizing
- **WHEN** the benchmark executes against `rtsp://rtsp-replayer.serviceradar.svc.cluster.local:8554/drone-highway`, `drone-quarry`, and `drone-surf` on a designated `arm64` GPU node
- **THEN** the benchmark record SHALL capture Tier 1 admission ratio, Tier 2 admission ratio, H.264 CPU decode ms/IDR, Stage 1+2 GPU images/s, and missed-event error rate using only synthetic or public CC-licensed replayer streams without committing live-captured fixtures or internal hostnames
