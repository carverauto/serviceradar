## Context

In post-#6920 `origin/staging` (`22aabc7681`), NVR recording seals CMAF blocks without decoding video (`Membrane.MP4.Muxer.CMAF`) and `serviceradar-media-worker` decodes sampled H.264 IDR keyframes in pure Rust (`rusty_h264-decoder`) before running Stage 1 detection and Stage 2 SigLIP-B/16-384 embeddings.

Two defects prevent effective gating today:
1. `rust/media-worker/src/vision.rs:460-467, 565-572` runs `detect_subjects_checked(frame)` **before** calling `downsampled_l1_delta`, and only skips Stage 2 whole-scene embedding when `detections.is_empty()` and global mean RGB L1 `< 0.02`.
2. A 16x16 point-sampled global mean delta aliases small objects (a person occupying ~1.5% of a 1080p frame shifts global mean L1 by `< 0.015`, falling below `0.02`), while decoding every keyframe across 8,000 cameras consumes `44-152` CPU cores (`11-38 ms`/1080p IDR).

An earlier draft proposed a `Vix` 0.42.0 (`libvips`) NIF in Elixir `BoomboxHelpers`. Retargeting to pure Rust + Core eliminates C `libvips` FFI, eliminates BEAM frame copies, and complies with the `AGENTS.md` DeepCausality rule (`serviceradar-anomaly-core`).

## Goals / Non-Goals

- Goals:
  - Tier 1 zero-decode compressed-domain gate in Core/NVR metadata using CMAF `trun` sync-sample sizes (`first_sample_size`) and block byte-rate deltas fed through `serviceradar-anomaly-core` (`SlidingWindow`, `WelfordAcc`, `Cusum`).
  - Tier 2 pure-Rust Y-plane box-averaged spatial-block max-L1 gate in `serviceradar-media-core` executed **before** YUV-to-RGB conversion, Stage 1 detection, and Stage 2 embedding.
  - Interval carry-forward validity metadata (`valid_from_us`..`valid_until_us`) so suppressed static keyframes preserve search recall across static intervals.
  - Steady-state zero-allocation verification via `longshore_common::io::alloc_guard` and deterministic simulation under `longshore_common::sim`.
- Non-goals:
  - `Vix` / `libvips` bindings, BEAM image decode, or hand-rolled parallel z-score/CUSUM implementations outside `serviceradar-anomaly-core`.
  - GPU compute kernels for pixel differencing or FPGA bitstreams.
  - Recording or live-view path coupling; gating failures or drops must never stall recording or live relays.

## Decisions

- **Tier 1 (Zero-Decode Metadata Gate):** Inspect CMAF `trun` `first_sample_size` (already parsed by `cmaf.rs:99`) and total fragment payload bytes per sealed block. Feed per-camera normalized deltas into `serviceradar-anomaly-core` (`SlidingWindow` + `WelfordAcc` + `Cusum`) to detect static periods (e.g., empty night hallways with steady minimal IDR/P byte budgets). Periodically admit forced refresh keyframes (`max_carry_forward_interval_ms`, e.g., 60 s) to guard against slow lighting/QP drift.
- **Tier 2 (Pre-Stage-1 Spatial-Block Y-Plane Gate):** Operate directly on decoded `DecodedPicture.y` luma planes in `serviceradar-media-core`, downscaled by **box-averaging** (not point sampling) into a coarse spatial grid (e.g., `32x18` or `64x36`) and scoring **max block L1** (plus fraction of changed blocks) rather than only global frame mean L1. Execute this gate strictly **before** YUV->RGB conversion, Stage 1 detector inference, and Stage 2 SigLIP inference.
- **Interval Validity Carry-Forward:** When Tier 1 or Tier 2 suppresses a block/keyframe as unchanged relative to the prior indexed anchor keyframe, extend the anchor keyframe's validity window (`valid_until_us`) in `camera_visual_frames` / search projections rather than duplicating vector embeddings.
- **Zero-Alloc & Bounded Memory:** Pre-allocate per-camera previous luma grid buffers (`32x18` = 576 bytes/camera; ~4.6 MB total for 8,000 cameras) at worker startup or bounded LRU cache; verify hot-path zero-alloc behavior with `longshore_common::io::alloc_guard`.
- **Synthetic & Replayer Validation:** Correctness tests build synthetic Y-plane/CMAF inputs in memory (no live camera captures); cluster validation uses `demo/rtsp-replayer` (`drone-highway`, `drone-quarry`, `drone-surf` at `rtsp://rtsp-replayer.serviceradar.svc.cluster.local:8554/<path>`) and measures CPU decode savings, Tier-1/Tier-2 admission ratios, and GB10 GPU savings.

## Risks / Trade-offs

- **IDR byte-size sensitivity to encoder QP/noise:** Tier 1 must never drop permanently without periodic forced keyframe refresh (`max_carry_forward_interval_ms`) and adaptive `Cusum` baselines rather than fixed byte thresholds.
- **Small distant subjects:** Solved by Tier 2 box-averaged spatial-block max-L1 (`32x18` block triggers even if only one 3% region changes), whereas global mean L1 misses small movers.
- **No `MODIFIED Requirements` collisions:** Uses `## ADDED Requirements` on `vms-media-workers` with unique requirement headers.
