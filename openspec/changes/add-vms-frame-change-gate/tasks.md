## 1. Pure-Rust Tier 2 Gate (`serviceradar-media-core` & `serviceradar-media-worker`)

- [ ] 1.1 Extract pure-Rust frame-gate primitives into `rust/media-core` (`serviceradar-media-core`), computing box-averaged Y-plane spatial-grid (`32x18` / configurable) max-block L1 and changed-block ratio directly from `DecodedPicture.y`.
- [ ] 1.2 Reorder `rust/media-worker/src/vision.rs` so the Tier 2 spatial-block Y-plane gate executes **before** YUV-to-RGB conversion, Stage 1 object detection, and Stage 2 SigLIP embedding.
- [ ] 1.3 Bound per-camera luma-grid state with pre-allocated capacity and verify zero steady-state heap allocations in the gate hot loop using `longshore_common::io::alloc_guard`.
- [ ] 1.4 Remove all references to Elixir `BoomboxHelpers` / `Vix` (`libvips`) frame-change scoring; keep gating completely outside NVR recording and live relay playback paths.

## 2. Tier 1 Zero-Decode Metadata Gate (`serviceradar-anomaly-core` + Core/NVR)

- [ ] 2.1 Expose CMAF `trun` sync-sample (`first_sample_size`) and fragment byte-rate summaries from NVR frozen descriptors so Core can evaluate frame change without decoding video.
- [ ] 2.2 Gate `VisualIndexJob` admission using `serviceradar-anomaly-core` (`SlidingWindow`, `WelfordAcc`, `Cusum`) adaptive thresholds with a bounded `max_carry_forward_interval_ms` refresh ceiling.
- [ ] 2.3 Persist carried-forward validity intervals (`valid_from_us`, `valid_until_us`) on indexed anchor frames when static blocks or keyframes are suppressed.

## 3. Correctness, Simulation, and Replayer Measurement

- [ ] 3.1 Unit-test synthetic Y-plane sequences in memory: identical frames score `0`, small corner/region perturbations trigger spatial-block max-L1 above threshold without aliasing, and oversized/zero-dimension frames return typed errors cleanly.
- [ ] 3.2 Verify deterministic seeded replay of Tier-1 + Tier-2 carry-forward interval state transitions under simulated packet jitter and lighting drift.
- [ ] 3.3 Run synthetic `demo/rtsp-replayer` (`drone-highway`, `drone-quarry`, `drone-surf` via `rtsp://rtsp-replayer.serviceradar.svc.cluster.local:8554/<path>`) and designated test-node GB10 GPU timing benchmarks recording Tier-1 skip ratio, Tier-2 skip ratio, decode CPU core reduction, and Stage 1/2 GPU throughput savings without committing live-captured fixtures or hostnames.
