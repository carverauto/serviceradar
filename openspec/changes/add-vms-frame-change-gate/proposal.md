# Change: Two-tier pure-Rust and Core VMS frame-change gate

## Why

At ~8,000-camera production scale (`0.2-0.5` keyframes/s/camera, `1,600-4,000` keyframes/s), running H.264 IDR decode (`11-38 ms`/frame = `44-152` CPU cores) and Stage 1 / Stage 2 neural inference (`~91` NVIDIA GB10 GPUs un-gated at `0.5 fps`) on static scenes is non-viable. Meanwhile, the shipped pixel gate in `rust/media-worker/src/vision.rs` executes `downsampled_l1_delta` **after** H.264 decode and **after** Stage 1 detection, saving zero decode or detector compute, and point-samples a 16x16 RGB grid that can alias small foreground subjects. An earlier draft targeted Elixir `BoomboxHelpers` and C `Vix`/`libvips`; post-#6920 (`22aabc7681`), recording uses `Membrane.MP4.Muxer.CMAF` without BEAM frame decode and visual indexing runs in standalone Rust `serviceradar-media-worker`.

## What Changes

- Retarget the frame-change gate from Elixir `BoomboxHelpers` / `Vix` (`libvips`) to a **two-tier pure-Rust + Core metadata gate**:
  - **Tier 1 (Core/NVR zero-decode metadata gate):** Evaluate CMAF `trun` sync-sample (`first_sample_size`) and block byte-rate deltas per camera against a DeepCausality adaptive baseline (`serviceradar-anomaly-core` `SlidingWindow` + `WelfordAcc` + `Cusum`) before `VisualIndexDispatcher` / `VisualIndexDispatchWorker` admits a `VisualIndexJob`.
  - **Tier 2 (Rust `serviceradar-media-core` / `serviceradar-media-worker` pre-Stage-1 pixel gate):** Compute a box-averaged Y-plane spatial-block max-L1 delta directly from decoded luma (`DecodedPicture.y`, before YUV-to-RGB and **before** Stage 1 object detection and Stage 2 embedding).
- Persist interval carry-forward validity metadata (`valid_from_us`, `valid_until_us`, or carried embedding validity span) when a static block or static keyframe is gated, so timestamped semantic searches continue matching static periods without duplicate vector rows.
- Keep gating isolated from NVR recording and live relay playback, and enforce `longshore_common::io::alloc_guard` steady-state zero-allocation tests in `serviceradar-media-core`.
- Establish synthetic and `demo/rtsp-replayer` (`drone-highway`, `drone-quarry`, `drone-surf`) gate-admission and GB10 GPU timing criteria before fleet pool sizing.

## Impact

- Affected specs: `vms-media-workers` (ADDED requirements).
- Related changes: [add-vms-storage-playback-engine](../add-vms-storage-playback-engine/proposal.md) (tasks 3.2, 3.7), [update-video-pipeline-nlp-search-and-live-tracking](../update-video-pipeline-nlp-search-and-live-tracking/proposal.md).
- Affected code (when implemented): `rust/media-core` (extracted from `rust/media-worker`), `rust/media-worker/src/vision.rs`, `rust/anomaly-core`, `elixir/serviceradar_core/lib/serviceradar/camera/visual_index_dispatcher.ex`.
- Tracking: [ServiceRadar #6658](https://github.com/carverauto/serviceradar/issues/6658).
- Zero `Vix` / `libvips` or BEAM-side video decode dependencies introduced.
