# ServiceRadar Video Pipeline OpenSpec Audit, Decision Record, and Action Plan

**Date:** 2026-11-21
**Baseline:** `origin/staging` at `22aabc7681f83ecfe7d92c6d2821137cf2890bbf` (post-PR #6920 `seal-to-catalog` and post-PR #6917 `rust/media-worker` H.264 decode)
**Scope:** Docs and OpenSpec reconciliation only (zero product code changes)

---

## 1. Executive Summary

This document audits ServiceRadar's video recording, semantic clip search, frame-change gating, and media-worker OpenSpec proposals and prior architectural decisions against the post-#6920 `origin/staging` codebase (`22aabc7681`), active recovery/feature branches, GPU benchmark logs (`/Volumes/Build/scratch/claude-gpu-spike/`), the `~/src/rusty_h264` fork (`carverauto/0.17.3-fixes`), and internal Rust repositories (`~/src/longshore`, `~/src/ultragraphdb`, and `rust/`).

### Key Findings
1. **Local Checkout vs `origin/staging` Drift:** The primary local checkout (`be23c1d10d`) predated `openspec/specs/camera-semantic-search/`, `openspec/specs/vms-media-workers/`, `rust/media-worker/` (PR #6917), and NVR `seal-to-catalog` (PR #6920 at `22aabc7681`). Uncommitted local OpenSpec proposals (`add-vms-frame-change-gate/` and edits to `add-vms-storage-playback-engine/`) targeted the obsolete Elixir `BoomboxHelpers` / `Vix` (`libvips`) path rather than the shipped Rust `serviceradar-media-worker` and NVR CMAF pipeline.
2. **Active Branch / Model-Identity Mismatch:** `VisualIndexDispatcher` (`elixir/serviceradar_core/lib/serviceradar/camera/visual_index_dispatcher.ex:42-45`) and `feat/helm-media-worker-gpu-runtime` (`f5e51a1cbf`) hardcode `detector_model_id = "rtdetr-r18"`, whereas `rust/media-worker/src/yolo_v8.rs` only implements YOLOv8 (whose Ultralytics weights carry AGPL-3.0 risk). As a result, the chart PR disables detector mounts entirely (`whole-scene` SigLIP only), breaking wide-angle attribute/subject retrieval such as `"find the man in the red dress"`. Replacing AGPL YOLOv8 with pure-Rust **Apache-2.0 YOLOX** (`candle-nn`) and decoupling `detector_model_id` from `embedder_model_id` resolves both licensing and small-object recall.
3. **~8,000-Camera Scale Bottlenecks:** Un-gated `0.5 fps` keyframe indexing across 8,000 cameras (`4,000 keyframes/s`, `318 blocks/s` at `4 Mbit/s` / `12 MiB` cap) overwhelms:
   - `VisualIndexDispatchWorker` (`16.7 jobs/s` cap -> **19x behind**),
   - hardcoded `CAMERA_MEDIA_JOBS` (`512 MiB` -> **~39 min** eviction vs `72 h` re-dispatch floor),
   - hardcoded `CAMERA_MEDIA_RESULTS` (`2 GiB` with JSON `Vec<f32>` -> **18-64 s** overflow),
   - unpartitioned `pgvector` HNSW (`~6.1 TB/day` un-gated -> requires time-range partitioning + `halfvec(768)` + 90%+ two-tier gating),
   - `rust/media-worker/src/vision.rs:460-467, 565-572` (runs Stage 1 neural detector **before** `downsampled_l1_delta`),
   - NVR 16-session cap (`500+` pods) and `core-elx` transit (`32-64 Gbit/s`) until `add-scalable-camera-recording-plane` + Longshore multipart (`>16 MiB` -> `128 MiB` blocks) land.
4. **Live Object Detection & Tracking Gap:** `rust/media-worker/src/tracking.rs` already wraps pure-Rust `trackforge = "0.5"` (`ByteTrack`, `BotSort`, `DeepOcSort`), and recovery commit `463daf5208` stores `track_id` in `camera_visual_frames.detections`. However, `ClipTracker` is stateless per sealed block and has no live-frame ingest tap. Live detection/tracking can be achieved in pure Rust using **YOLOX + `trackforge` + camera-sharded stateful `ClipTracker` (`longshore_mailbox`)** fed by a bounded live relay tap or pure-Rust `retina` RTSP ingest, while keeping SAM 2 / EdgeTAM (`tamserve`) deferred.
5. **Pre-Enablement Security & Correctness Blockers:** Visual indexing MUST NOT be enabled in any multi-identity deployment until (a) `R44` in `visual_worker_read_grants.ex:132, 283-294` (job cancellation before verifying catalog/digest ownership), (b) broad NATS `$JS.API.>` / `>` grants across non-media identities, (c) `NVRWorker` abort veto (`nvr_worker.ex:651, 689`), and (d) the `demo` NATS `30G` file-store budget gap (`~863 MB` over 85% limit) are resolved.

---

## 2. Verified Baseline & Branch / Recovery Commit Inventory

All claims below were verified directly against `origin/staging` (`22aabc7681`), `~/.no-mistakes/repos/6e905cacf9f4.git`, `~/src/rusty_h264`, `~/src/longshore`, `~/src/ultragraphdb`, and `/Volumes/Build/scratch/claude-gpu-spike/`.

| Item / Branch | Ref / Commit | Parent / Base | Verified State & Open Issues |
|---|---|---|---|
| `origin/staging` (post-#6920, post-#6917) | `22aabc7681` | `c6efe093a1` | Ships `openspec/specs/{camera-semantic-search,vms-media-workers}/spec.md`, `rust/media-worker/` (`rusty_h264-decoder = "=0.17.3"`, `candle-* = "0.11"`, `trackforge = "0.5"`, `longshore_s3 = "0.2.0"`), migration `20261117223000_add_camera_semantic_clip_search.exs`, `VisualIndexDispatcher`, `SemanticSearch`, and `NVRWorker` `freeze_and_catalog/6`. Carries open #6920 defect at `nvr_worker.ex:651, 689`: `refusal_reason = state.abort_reason || capture_error(...)` vetoes sealed-block registration even when `send_result` is `{:ok, %{status: :sealed_local, ...}}`. |
| Local `staging` checkout | `be23c1d10d` | -- | Pre-#6917 / pre-#6920 checkout holding uncommitted local edits in `openspec/changes/add-vms-storage-playback-engine/` (4 files) and untracked `openspec/changes/add-vms-frame-change-gate/`. Folded and retargeted in this worktree without mutating local `staging`. |
| NVR Read Path (`feat/nvr-read-path`) | `d4d464297f` | `b12606743b` | 56 files (+2,492/-344): dedicated NVR read listener (port 8444), `CameraTimelineReader.NVRLocal`, Helm `nvr.read` config/NetworkPolicies, `add-nvr-retention-and-timeline-playback/{design,tasks}.md` updates. Built on pre-review #6920; requires linear rebuild onto `22aabc7681` + removing `NVRWorker` abort veto. |
| NVR Status/Lookup/Ledger (`feat/nvr-status-lookup-ledger`) | `c31c25eb90` | `d4d464297f` | 62 files (+3,719/-440): `GET /v1/status`, `POST /v1/blocks/lookup`, `GET /v1/blocks`, `SERVICERADAR_NVR_MAX_BLOCKS` (default 131,072), updates `add-nvr-operator-settings/tasks.md` and `add-nvr-retention-and-timeline-playback/{design,tasks}.md`. |
| GPU Worker CUDA (`feat/media-worker-cuda-runtime`) | `6294ea3747` + recovery `246b7e8d87` | `b5c6374b4b` | Preserved in mirror `refs/no-mistakes/recover/01M7ZQ8SGNDWQK1V1W24HD7SYB`. Adds `MEDIA_WORKER_DTYPE=auto\|f32\|f16`, embedding-width admission, blocking-thread GPU warmup, CUDA JIT cache (`/var/cache/serviceradar-media-worker/cuda`), parallel preprocessing, `.github/workflows/publish-media-worker-cuda.yml`, `add-media-worker-cuda-runtime/`. Predates #6917 (`rusty_h264-decoder`) and chart inbox prefix; needs rebase onto `22aabc7681`. |
| Search Loop (`feat/visual-index-dispatch-and-results`) | `ab4d250c36` + recovery `463daf5208` | `b5c6374b4b` | Preserved in mirror `refs/no-mistakes/recover/01M7ZM575E36C7V9V6XKGNF5QK`. Adds `VisualIndexDispatchWorker`, CAS `mark_dispatched`, 72 h floor, EventWriter `CAMERA_MEDIA_RESULTS` consumer, `add-visual-index-dispatch-and-result-consumer/`. **Verified R44 bug (`visual_worker_read_grants.ex:132, 283-294`):** `load_and_check_catalog_entry` calls `maybe_cancel_job(job_id, loaders)` BEFORE `load_and_check_job` and `verify_descriptor_sha` prove job ownership and digest. Also flags `R43`-`R48` and broad NATS grants. |
| Chart PR (`feat/helm-media-worker-gpu-runtime`) | `f5e51a1cbf` (supersedes `0b5ddd2d5d`) | `c6efe093a1` | 31 files (+2,755/-196): source-side `NetworkPolicy` isolation, `CN=serviceradar-media-worker` NATS identity, `_INBOX.media-worker` prefix, pinned `"rtdetr-r18"`/`"siglip-b16-384"` (`2026.1`/`768`), explicitly refuses `detectorPath`/`detectorSha256` (mounts 3 SigLIP files only), adds `CAMERA_MEDIA_JOBS` (`512 MiB`) + `CAMERA_MEDIA_RESULTS` (`2 GiB`) to JetStream budget, flags `values-demo.yaml` `30G` `maxFileStore` over-budget by `~863 MB`. |
| Decoder Fork (`~/src/rusty_h264`) | `carverauto/0.17.3-fixes` (`4439375cf`) | `v0.17.3` (`a9b9c6f`) | 9 commits ahead of `v0.17.3` (8 decoder fixes + README cleanup) verified byte-exact vs FFmpeg 9.0.2 on progressive 8-bit 4:2:0 raster-ordered multi-slice streams. Not yet consumed in `serviceradar`. |
| Deferred / Parked Runs (`name-not-identity` PR 2 / AWX docs) | `be7548ad9f` / `54725ac331` | -- | Preserved in mirror (`01M7YAGCSBP0HV983K4QZTETTC`, `01M7ZMWS9FY1KX647K12GJYTFF`); unrelated to video/NVR/VMS. |

---

## 3. Point-by-Point OpenSpec & Prior Decision Audit (5-Point Rubric)

Rubric columns:
- **(a) Currency:** Alignment with post-#6920 `origin/staging` (`22aabc7681`) and active branches.
- **(b) Soundness & Pragmatism:** Technical validity, risk control, and operational realism.
- **(c) ~8,000-Camera Scale Impact:** Concrete effect at 8,000 cameras (`2-4 Mbit/s`, `0.2-0.5 fps`).
- **(d) Pure-Rust Feasibility:** Conformance with pure-Rust pipeline vs documented blockers.
- **(e) Internal Rust Reuse:** Shared crate and pattern alignment (`longshore`, `ultragraphdb`, `rust/`).

### 3.1 OpenSpec Specifications & Pending Proposals

| Item | (a) Currency | (b) Soundness & Pragmatism | (c) ~8,000-Cam Scale | (d) Pure-Rust Feasibility | (e) Internal Rust Reuse & Disposition |
|---|---|---|---|---|---|
| `openspec/specs/camera-semantic-search/spec.md` | **Shipped (`22aabc7681`).** Defines opt-in outbox, two-stage crop+scene embeddings, pre-filtered `pgvector` HNSW, retention/hold coupling, timeline overlay. | **Sound core contract**, but hardcodes single `"rtdetr-r18"`/`"siglip-b16-384"` pair in dispatcher and leaves `pgvector` HNSW unpartitioned. | **Bottlenecked without updates:** `0.5 fps` un-gated -> `~6.1 TB/day` HNSW; unpartitioned `DELETE` causes VACUUM/tombstone bloat; lacks binary results & batch scaling. | Compatible (Elixir control plane + Rust worker). | Supplemented by `update-video-pipeline-nlp-search-and-live-tracking` (no conflicting `MODIFIED` deltas). |
| `openspec/specs/vms-media-workers/spec.md` | **Shipped (`22aabc7681`).** Defines GPU worker capability admission, scoped read grants + SHA-256 verification, 250 ms text-embed RPC. | **Sound isolation boundary.** Needs explicit detector decoupling, precision-independent manifest, and live-tracking capability rules. | `120-130 img/s` F16 SigLIP on GB10 means un-gated indexing needs ~91 GB10s; pre-Stage-1 gate + binary results mandatory. | `candle/cuda` uses `nvcc`+`cudarc`; needs documented boundary vs `burn-wgpu`. | Extract `serviceradar-media-core`, `serviceradar-nats`, `serviceradar-service-probes`. |
| `openspec/specs/camera-streaming/spec.md` | **Shipped (`22aabc7681`).** Single upstream ingest + Membrane fanout + relay analysis branches (`camera_analysis_input.v1`). | **Sound single-ingest guarantee.** Must extend cleanly to feed live pure-Rust tracking without opening a second camera session. | Critical for 8k cams: forbids duplicate camera pulls for live viewing + recording + live tracking. | Compatible; live tap feeds Rust `media-worker` / edge `retina` ingest. | Reuses `camera-streaming` analysis branch contract; new delta in `update-video-pipeline-nlp-search-and-live-tracking`. |
| `openspec/specs/jetstream-storage-budget/spec.md` | **Shipped (`22aabc7681`).** Render-time 85% check, `SERVICERADAR_JS_<STREAM>_MAX_BYTES` env overrides, finite `max_bytes`. | **Sound governance.** However `rust/media-worker/src/worker.rs:1546, 1559` hardcodes `512 MiB` / `2 GiB`, bypassing env override spec! | At 8k cams, hardcoded `2 GiB` overflows in **18-64 s** (JSON) and `512 MiB` evicts in **39 min** (`< 72 h` floor). | Pure Rust (`async-nats = "0.52.0"` + `serviceradar-cert-policy`). | Standardize stream ensure/override via shared `serviceradar-nats` crate. |
| `add-vms-frame-change-gate` (untracked local) | **Stale as drafted.** Targeted Elixir `BoomboxHelpers` + `Vix 0.42.0` (`libvips`). | **Gate concept is mandatory**, but Vix/Boombox adds C `libvips` FFI on BEAM and ignores `rust/media-worker/src/vision.rs`. | Must gate **before** decode (Tier 1 metadata) AND **before** Stage 1 detector (Tier 2 Y-plane) to cut 44-152 decode cores and ~91 GB10s by ~90%. | Retargeting eliminates C `libvips` FFI via pure-Rust `vision.rs` + `serviceradar-anomaly-core`. | **Folded & retargeted** in this branch to Tier 1 Core + Tier 2 `serviceradar-media-core` + `serviceradar-anomaly-core`. |
| `add-vms-storage-playback-engine` (4 local diffs) | **Partially superseded** in recording/search by `add-nvr-*`, `add-scalable-*`, and shipped `camera-semantic-search`. | **Local thesis sound** (measure gate cost before sizing GPU pool), but text cited `BoomboxSidecarWorker` and Vix/libvips. | Prevents premature GPU sizing from unmeasured sketches. | Retargeted references to Rust `serviceradar-media-worker` + pure-Rust gate. | **Folded & reconciled** in this branch (`README.md`, `media-workers.md`, `proposal.md`, `tasks.md` `3.2`, `3.7`). |
| `update-media-worker-real-keyframe-decode` | **Merged (#6917)** in `22aabc7681`, **unarchived**. Open follow-ups `3.1-3.9`. | **Sound.** Replaced fake `SRIDR1` fallback with real H.264 decode + `undecodable_keyframes`. | Single-slice/equal-QP workaround rejects real multi-slice cameras until `carverauto/0.17.3-fixes` is adopted; `11-38 ms`/IDR bounds CPU decode. | Pure-Rust `rusty_h264-decoder = "=0.17.3"` (`std`+`asm`, zero `nasm`/FFI). | Adopt `carverauto/0.17.3-fixes` (`4439375cf`), move `h264.rs`/`cmaf.rs`/`keyframe_decoder.rs` into `rust/media-core`, then archive #6917 deltas. |
| `add-media-worker-cuda-runtime` (`246b7e8d87`) | **Pre-#6917 base (`b5c6374b4b`).** Needs rebase onto `22aabc7681`. | **Sound.** `MEDIA_WORKER_DTYPE=auto\|f32\|f16`, width check, off-runtime warmup, parallel preprocess, separate CUDA image. | Single GB10 F16 e2e improves from 1.6 img/s (CPU) to 100.6-110.2 img/s (`2,896 MiB` VRAM); avoids 2-proc contention (`52.3-59.8 img/s` e2e each). | **Explicit boundary:** `candle/cuda` uses `nvcc` + `cudarc` + proprietary CUDA 13 (`libcuda.so.1` host-injected), not pure-Rust GPU. | Keep separate `serviceradar-media-worker-cuda` arm64 image; align with `feat/helm-media-worker-gpu-runtime` and YOLOX + tracking specs. |
| `add-visual-index-dispatch-and-result-consumer` (`463daf5208`) | **Pre-#6920 base (`b5c6374b4b`).** Parked in mirror (`01M7ZM575E36C7V9V6XKGNF5QK`). | **Sound outbox/EventWriter design**, EXCEPT open `R43`-`R48` (`R44` auth bug in `visual_worker_read_grants.ex:132`), broad NATS grants, and missing `(state, deadline_at)` index. | `VisualIndexDispatchWorker` (`10*100/min = 16.7 jobs/s`) is **19x too slow** for 8k cameras; 72 h floor assumes `CAMERA_MEDIA_JOBS` never evicts early. | N/A (Elixir Core + EventWriter). | Enforce R44 + NATS grant fixes before enablement; address dispatch throughput + index in Phase 2. |
| `add-nvr-retention-and-timeline-playback` + `add-nvr-operator-settings` | **Active NVR authority.** #6920 checked B.5-B.7; `d4d464297f` & `c31c25eb90` carry D.1-D.5 & A.5 updates. | **Sound.** Honest `time_basis`, A6/C1 state machines, quarantine isolation. Must fix `NVRWorker` abort veto (`nvr_worker.ex:651`). | Explicit 8k limits: `SERVICERADAR_NVR_MAX_SESSIONS` cap = `16` (`config.ex:27` -> `500+` NVR pods), `12 MiB` block cap -> `159-318 blocks/s`, `~1,200-2,870 tx/s`. | N/A (Elixir NVR + Longshore NIF). | Leave active PRs (`d4d464297f`/`c31c25eb90`) intact to avoid branch conflicts; document 8k handoff to `add-scalable-camera-recording-plane`. |
| `add-scalable-camera-recording-plane` | **Active Phase 3 scale authority** for >1,000 cameras. | **Essential.** Removes `core-elx` from media path (`32-64 Gbit/s`) and removes 16-session NVR bottleneck via independent recorder pools. | Mandatory for 8,000-camera production recording without saturating `core-elx` NICs or ERTS pods. | Compatible with Rust `media-core` / `longshore_s3`. | Keep `camera-streaming` `MODIFIED` deltas intact; new tracking proposal uses `ADDED` only so zero merge/archive conflict. |
| `add-longshore-object-storage` | **Partially shipped** (`longshore_s3 = "0.2.0"` in `media-worker` & NIF). Task `2.2` multipart upload remains open. | **Sound.** Coalesced range reads (`<= 4 MiB` / `256 KiB` gap) and 64 MiB registered pool (`alloc_guard`, `crc64_nvme`) work hermetically. | **8k blocker:** `16 MiB` single-PUT limit locks NVR blocks at `12 MiB` (`27.46M rows/day`). Multipart upload enables `128 MiB` blocks (**10.7x** fewer blocks/jobs). | Pure Rust + `aws-lc-sys` (`MODULE.bazel:468-482` already configured). | Upgrade `serviceradar_object_storage` NIF + NVR to multipart (`>16 MiB`) and standardize `longshore_s3 >= 0.2.0` + `longshore_crc` + `longshore_mailbox`. |
| `add-persistent-camera-spool` / `add-edge-recording-archive` / `define-nvr-*` | **Active/partial foundations** (spool identity merged; reconciliation & local-copy registration pending). | **Sound.** Fences local recovery and reconciles uncertain blocks without losing footage. | Bounded spools prevent unbounded edge disk churn. | Compatible with extracted `serviceradar-spool` crate for edge Rust agents. | Preserve as-is; reference from action plan. |
| `update-cnpg-pg18-and-search-extension-strategy` | **Active.** PG18 + `pgvector` + ParadeDB (`pg_search`). | **Sound.** PG18 declarative range partitioning + `pgvector` (`halfvec`) directly unlocks multi-million-row visual embedding tables. | Enables partition `DROP` instead of HNSW `DELETE` / `VACUUM` collapse at 34M-864M embeddings/day. | N/A (CNPG database tier). | Align `platform.camera_visual_embeddings` partitioning and `halfvec(768)` migration with PG18 target. |
| `resolve-camera-stream-sources-at-edge` / `restore-unifi-protect-camera-streams` | **Active edge authority.** Keeps stream secrets out of `camera_sources`. | **Sound.** Note observed gap: `protect-bootstrap` sets `fps=0, width=0, height=0` in `camera_stream_profiles.metadata`. | Eliminates credential leakage; live tracking must consume the same resolved edge relay/ingest. | Compatible (agent-originated relay or edge Rust worker). | Document mandatory SPS/container dimension fallback when profile metadata contains zeroes. |
| `add-showcase-demo-portfolio` (`specs/camera-streaming/spec.md`) | **Pending.** Defines `camera_analysis_result.v1` multi-detections, latency-budgeted viewer delivery, real HTTP worker. | **Compatible.** Note our new live tracking spec uses JetStream + `trackforge` `ClipTracker` with `ADDED` requirements that do not collide with `add-showcase-demo-portfolio`. | Latency budget drop semantics match bounded live tracking requirements. | Compatible with Rust `media-worker` / `serviceradar-media-core`. | Keep distinct requirement names; cross-reference live viewer detection delivery. |

### 3.2 Evaluation of Prior Handoff Decisions (`handoff_2026-11-21_nvr_vms_semantic_search.md`)

1. **Detector Identity & Licensing (`"rtdetr-r18"` vs AGPL YOLOv8 vs Apache-2.0 YOLOX):**
   - **Verified Reality:** `VisualIndexDispatcher` (`visual_index_dispatcher.ex:42`) and `feat/helm-media-worker-gpu-runtime` (`media-worker.yaml`) pin `"rtdetr-r18"`, `rust/media-worker/src/yolo_v8.rs` only implements YOLOv8 (AGPL-3.0 weights), and the chart explicitly refuses `detectorPath`/`detectorSha256`, forcing whole-scene SigLIP only.
   - **Audit Verdict:** **Sound & critical.** Whole-scene SigLIP suffers attribute-binding collapse on multi-object scenes (`"find the man in the red dress"`). Replacing AGPL YOLOv8 with **Apache-2.0 YOLOX** (`~250-400 LoC` in `candle-nn`, standard Conv/SiLU/CSPDarknet/PAFPN/decoupled head, zero unsupported ops) and decoupling `detector_model_id` from `embedder_model_id` in Core + Helm + Worker is the pragmatic pure-Rust path.
2. **Live Object Detection & Tracking (`tamserve` / SAM 2 / EdgeTAM vs `trackforge`):**
   - **Verified Reality:** `tamserve` is Python/PyTorch SAM 2 / EdgeTAM (restrictive Meta license, requires 3-5k LoC Candle port). Meanwhile, `rust/media-worker/src/tracking.rs` already integrates pure-Rust `trackforge = "0.5"` (`ByteTrack`, `BotSort`, `DeepOcSort`; MIT, `nalgebra`-only) per sealed clip, and `463daf5208` stores `track_id` in `camera_visual_frames.detections`.
   - **Audit Verdict:** **Split & refine per R2.** Keep SAM 2 / EdgeTAM pixel-mask tracking deferred (explicit blocker documented), AND unlock live object detection + tracking immediately in pure Rust using **YOLOX + persistent camera-sharded `ClipTracker` (`trackforge` + `longshore_mailbox`)** over a bounded live-frame tap (Core relay tap or edge `retina` RTSP ingest) publishing to a dedicated JetStream live-track stream.
3. **Pure-Rust Decoder Fork (`~/src/rusty_h264` `carverauto/0.17.3-fixes` at `4439375cf`):**
   - **Verified Reality:** Fixes 8 real bugs (multi-slice, per-slice deblocking, chroma QP offset, I_PCM QP, CABAC/CAVLC truncation, incomplete picture, I_8x8 corner, out-of-range QP), verified byte-exact vs FFmpeg 9.0.2 on progressive 8-bit 4:2:0 raster-ordered multi-slice streams. `rusty_h264` is BSD-2-Clause with pure-Rust SIMD intrinsics (`crates/rusty_h264-accel/src/lib.rs`, zero `nasm`, zero C/C++; `crates/rusty_h264-common/build.rs` emits pure-Rust `rustc-cfg` flags only).
   - **Audit Verdict:** **Adopt immediately**, verifying Bazel `third_party/crate_mirror/sync.py` compatibility (checksum-less git deps are skipped by `sync.py`, so test `crate_universe` RBE fetch or vendor via `third_party/rust_patches/` / mirror tarball), then lift temporary single-slice and equal-QP refusals in `rust/media-worker/src/h264.rs:97-101, 583`.
4. **Pre-Enablement Security & Correctness Gates (`R44`, NATS grants, `NVRWorker` abort veto, Demo NATS PVC):**
   - **Audit Verdict:** **Mandatory Phase 0 gates.** `visual_worker_read_grants.ex:132, 283-294` (`R44`) lets a caller cancel an arbitrary `job_id` before verifying ownership/digest. Broad NATS `$JS.API.>` / `>` grants expose camera jobs/results to non-media identities. `NVRWorker` (`nvr_worker.ex:651, 689`) drops valid sealed-block registration on `abort_reason`. Demo NATS (`30G` `maxFileStore`, `22.52 GB` reserved) overflows the `25.50 GB` 85% ceiling by `~863 MB` until moved to the `36G` `small` profile (`local-path` PVCs are directory-backed, recreated via `StatefulSet --cascade=orphan`).

---

## 4. ~8,000-Camera Production Scale & Bottleneck Math

Baseline assumptions (from `add-nvr-retention-and-timeline-playback/design.md` A1 and `22aabc7681` defaults): **8,000 cameras**, `2-4 Mbit/s` H.264, `12 MiB` (`12,582,912 B`) capture ceiling (`nvr_worker.ex:98`, `elixir/serviceradar_core/lib/serviceradar/camera/retention_calculator.ex:38`), `@lease_ms = 30_000` (`nvr_worker.ex:87`), `SERVICERADAR_NVR_MAX_SESSIONS <= 16` (`config.ex:27`), `visual_index_min_interval_ms = 2000` (`0.5 fps`) vs `5000` (`0.2 fps`).

### 4.1 Recording Plane & CNPG Catalog Bounds
- **Ingest Bandwidth:** `8,000 * 2 Mbit/s = 16 Gbit/s (2.0 GB/s = 172.8 TB/day)` up to `8,000 * 4 Mbit/s = 32 Gbit/s (4.0 GB/s = 345.6 TB/day)`. While `core-elx` proxies gateway ingest to NVR, `core-elx` handles both legs = **`32-64 Gbit/s` aggregate pod NIC traffic**.
- **NVR Pod Floor:** `8,000 / 16 sessions/pod = 500` NVR pods minimum (**550-600 pods** with N+1 headroom) until `add-scalable-camera-recording-plane` removes the 16-session NVR cap.
- **Block & Catalog Row Rate (`12 MiB` blocks):**
  - At `2 Mbit/s`: `12 MiB` fills in `~50.3 s` -> `1,717 blocks/cam/day` -> **`13.74M blocks/day` (`159 blocks/s`)**.
  - At `4 Mbit/s`: `12 MiB` fills in `~25.2 s` -> `3,433 blocks/cam/day` -> **`27.46M blocks/day` (`318 blocks/s`)**.
  - Moving to `128 MiB` blocks via Longshore multipart upload cuts block/catalog/job rate **10.7x** -> **`~30 blocks/s` (`2.57M rows/day`)**.
- **CNPG Recording Write Load (single-primary CNPG):**
  - Block lifecycle (reserve + `freeze_and_catalog` + claim release + archive receipt): `~4 tx/block` -> **`636-1,272 write tx/s`**.
  - Recorder lease renewals (`30 s` lease, `5-15 s` renewal): **`533-1,600 write tx/s`**.
  - **Total recording-only CNPG load:** **`~1,200-2,870 write tx/s`** before any visual indexing, search, or telemetry writes.

### 4.2 Visual Indexing, JetStream, `pgvector` HNSW, CPU Decode & GPU Bounds

Measured GB10 GPU spike benchmarks (`/Volumes/Build/scratch/claude-gpu-spike/results/run{1,2,3,A,B}.log`, arm64 DGX Spark NVIDIA GB10 `sm_121`, CUDA `13.0.3`, `google/siglip-base-patch16-384`, `dim=768`):
- **CPU F32 (8 cores, `run1.log`):** `1.6-1.8 img/s` (`636.4 ms` b=1, `17.76 s` b=32); text p50 `75.90 ms`; RSS `1,060 MiB`.
- **CUDA F32 (`run1.log`):** `51.4-53.2 img/s` model (`47.2-49.8 img/s` e2e 1-thread preprocess); text p50 `5.56 ms`; cold JIT `8,814 ms`; VRAM `5,552 MiB`; `max_abs_diff = 2.310e-7`.
- **CUDA F16 single-process (`run1.log`, `run3.log`):**
  - Model-only: **`130.9 img/s` (b=1), `128.5 img/s` (b=8), `123.1 img/s` (b=32), `120.9 img/s` (b=64)** (`run3.log`).
  - End-to-end (1-thread preprocess): **`110.2 img/s` (b=1), `107.8 img/s` (b=8), `101.7 img/s` (b=32), `100.6 img/s` (b=64)** (`run3.log`; `run1.log` b=1 reached `112.3 img/s` e2e).
  - Text query p50 **`2.20-2.23 ms`**; warm JIT `302-336 ms`; VRAM **`2,896 MiB`**; min cosine vs CPU F32 **`0.9999983`**.
- **CUDA F16 2-process contention (`runA.log` + `runB.log`):** Each process dropped to **`52.3-59.8 img/s` e2e** (`~105-114 img/s` combined, with `batch=8` e2e at `52.3` and `52.8 img/s` -> `105.1 img/s` combined), proving linear time-slicing contention when sharing one GB10 across processes (`gpu.sharing-strategy=time-slicing`).

Extrapolated 8,000-camera pipeline bounds (assuming `~1.5` admitted subject crops/frame average -> `2.5` SigLIP calls/admitted frame, `~1.5 KB` JSON job msg, `~8-9 KB` JSON f32 vector vs `~1.5 KB` packed binary f16 vector):

| Pipeline Stage / Store | 8,000 cams @ `0.5 fps` (no gate) | 8,000 cams @ `0.2 fps` (no gate) | 8,000 cams @ `0.2 fps` + **90% 2-tier gate** | Shipped Limit / Verdict |
|---|---|---|---|---|
| **Sampled Keyframes/s** | `4,000 kf/s` (`345.6M/day`) | `1,600 kf/s` (`138.2M/day`) | `160 kf/s` (`13.8M/day`, if Tier-1 gated) | Post-decode gate still decodes all `1,600-4,000 kf/s`. |
| **H.264 CPU Decode (`11-38 ms`/1080p IDR)** | **44-152 full CPU cores** | **18-61 full CPU cores** | **1.8-6.1 CPU cores** (with Tier-1 pre-decode gate) | Current `vision.rs` gates *after* decode & Stage 1! |
| **Stage 1 Detector (YOLOX-s/YOLOv8 @ ~4 ms F16)** | `~16 GPU-s/s` -> ~16-20 GB10s | `~6.4 GPU-s/s` -> ~7-8 GB10s | `~0.64 GPU-s/s` -> **<1 GB10** (pre-Stage-1 gate) | `vision.rs:460-467` runs Stage 1 **before** `downsampled_l1_delta`. |
| **Stage 2 SigLIP F16 (`101-110 img/s` e2e)** | `10,000 img/s` -> **~91 GB10 GPUs** | `4,000 img/s` -> **~37 GB10 GPUs** | `400 img/s` (+ track dedup ~`200/s`) -> **2-4 GB10 GPUs** | Un-gated indexing is economically non-viable on Spark nodes. |
| **`VisualIndexDispatchWorker` (`463daf5208`)** | `318 jobs/s` (`4 Mbit/s`) | `318 jobs/s` (`4 Mbit/s`) | `~32-64 jobs/s` (Tier-1 block skip + `128 MiB` -> `~3-6/s`) | Hardcoded `10 * 100 / min = 16.7 jobs/s` ceiling -> **19x lag!** |
| **`CAMERA_MEDIA_JOBS` (`512 MiB`, `worker.rs:1546`)** | `~477 KB/s` -> fills in **~18-39 min** | `~477 KB/s` -> fills in **~18-39 min** | `~5-50 KB/s` -> **~3-30 hrs** | Evicts far before `72 h` re-dispatch floor; must use `SERVICERADAR_JS_*_MAX_BYTES`. |
| **`CAMERA_MEDIA_RESULTS` (`2 GiB`, `worker.rs:1559`)** | `~80-111 MB/s` JSON -> fills in **18-25 s** | `~32-45 MB/s` JSON -> fills in **45-64 s** | `~3.2-4.5 MB/s` JSON -> **`~0.6-0.9 MB/s` binary f16** (**~38 min**) | **CRITICAL:** JSON `Vec<f32>` overflows `2 GiB` in **18-64 s**; EventWriter `batch=10, ack_pending=60` saturates. |
| **`camera_visual_embeddings` HNSW (`20261117223000`)** | `864M rows/day` -> **~6.1 TB/day** | `345M rows/day` -> **~2.4 TB/day** | `34.5M rows/day` -> **~245 GB/day** (halfvec `~125 GB/day`) | Unpartitioned single HNSW blows out `shared_buffers` & `DELETE`/`VACUUM`. Needs PG18 partitions + `halfvec(768)` + track dedup. |

### 4.3 Live Object Detection & Tracking Bounds (`CAMERA_LIVE_TRACKS` & `ClipTracker`)

Live tracking (`media.events.live_tracks.v1` on `CAMERA_LIVE_TRACKS`) taps an existing relay or edge `retina` ingest without opening a second camera session, but **un-bounded** live tracking across 8,000 cameras is even heavier than sealed-block indexing:

| Resource / Store | Un-bounded `8,000` cams @ `1 fps` | Bounded Opt-In (`<= 1,000` cams @ `1 fps` + `15%` Tier-2 gate) | Bounded Fleet (`8,000` cams @ `0.5 fps` substream + `10-15%` Tier-2 gate) | Enforced Policy Bound |
|---|---|---|---|---|
| **Live Frames Tapped / Gated** | `8,000 frames/s` (`691.2M/day`) | `1,000/s` tapped -> **`150 frames/s`** past Tier-2 Y-plane gate | `4,000/s` tapped -> **`400-600 frames/s`** past Tier-2 Y-plane gate | Opt-in camera cap or `0.5 fps` substream + pre-Stage-1 Tier-2 Y-plane gate |
| **H.264 CPU Decode (`11-38 ms` 1080p; `3-10 ms` substream)** | **88-304 CPU cores** (1080p) / `24-80` (substream) | **11-38 cores** (1080p) / **3-10 cores** (substream) | **12-40 cores** (substream; `0` extra if shared with Tier-2 decode) | Substream IDR tap (`360p`/`720p`) or shared Tier-2 Y-plane |
| **Stage 1 YOLOX (`~4 ms` F16 on GB10)** | `32 GPU-s/s` -> **~32-40 GB10s** | `0.60 GPU-s/s` -> **1 GB10** | `1.6-2.4 GPU-s/s` -> **2-3 GB10s** | Stage 1 runs only after Tier-2 Y-plane admission |
| **Stage 2 SigLIP (track-deduped `~0.25` crops/admitted frame)** | `~1,200 img/s` -> **~11-12 GB10s** (`~110` un-deduped) | `~38 img/s` -> **<0.5 GB10** | `100-150 img/s` -> **1-2 GB10s** | `best_quality_crop` + periodic refresh per `track_id` |
| **`ClipTracker` State RAM (`DashMap`/shards + `longshore_mailbox`)** | `8,000` cams x `<= 128` tracks x `~128 B` -> **`~130-256 MiB`** | `1,000` cams x `<= 128` tracks -> **`~16-32 MiB`** | **`~130-256 MiB`** across camera shards | `MAX_TRACKS_PER_CAMERA <= 128` (30 s TTL), mailbox `<= 8` frames/cam |
| **`media.events.live_tracks.v1` Rate (`~500 B`/msg lean delta)** | `8,000 msg/s` (`~4.0 MB/s`, `~345 GB/day`) | `150-300 msg/s` (**`~75-150 KB/s`**) | `400-800 msg/s` (**`~200-400 KB/s`**) | Emit on track spawn/update/exit + `<= 0.5-1 Hz` summary |
| **`CAMERA_LIVE_TRACKS` (`DiscardPolicy::Old`, R1)** | `512 MiB` lasts **~2.1 min** | `512 MiB` lasts **~60-120 min** | `2 GiB` lasts **~89-178 min** (`512 MiB` pilot = `~22-44 min`) | `SERVICERADAR_JS_CAMERA_LIVE_TRACKS_MAX_BYTES` (`512 MiB` `small` fits `< 28.50 GiB`; `2-4 GiB` `large`) |

- **Helm Budget Fit:** In `small` (`36G`, 85% ceiling `28.50 GiB`, 3-server base `23.72 GiB`), `CAMERA_MEDIA_JOBS` (`512 MiB`, R1) + `CAMERA_MEDIA_RESULTS` (`2 GiB`, R1) + `CAMERA_LIVE_TRACKS` (`512 MiB`, R1) raises `need` from `23.72` to `~24.72 GiB`, preserving `~3.78 GiB` headroom below the `28.50 GiB` limit while giving opt-in pilots `~1-2 hr` of live track retention. Production 8,000-camera deployments use `large` (`500G`) or explicit `SERVICERADAR_JS_CAMERA_LIVE_TRACKS_MAX_BYTES` (`2-4 GiB`, `max_age = 1800-3600 s`).

---

## 5. Pure-Rust Feasibility, Blockers & Review Options

### 5.1 Pure-Rust Boundary Classification

| Component | Classification | Concrete Evidence (`22aabc7681` / Crates) |
|---|---|---|
| `cmaf.rs`, `PureRustTokenizer`, `vision.rs` | **Genuine Pure Rust** | Zero native build deps (`tokenizer.rs` parses `tokenizer.json` without `onig_sys` or `esaxx-rs/cpp`). |
| `rusty_h264-decoder` (`0.17.3` / `carverauto/0.17.3-fixes`) | **Genuine Pure Rust** | `crates/rusty_h264-accel/src/lib.rs`: portable SSE2/AVX2/NEON intrinsics only; `crates/rusty_h264-decoder` has no `build.rs` and zero C/`nasm` FFI, while `crates/rusty_h264-common/build.rs` emits pure-Rust `rustc-cfg` flags only; core `#![forbid(unsafe_code)]`. Must pass `default-features = false` to avoid `global-alloc`. |
| `trackforge` `0.5.1` (`default-features = false`) | **Genuine Pure Rust** | `Cargo.lock`: depends solely on `nalgebra 0.35.0`; optional `ort`/`opencv`/`pyo3` disabled. |
| `candle-core` `0.11.1` (CPU) | **Genuine Pure Rust** | `gemm 0.19.0` + `pulp` + `rayon`; pulls `tokenizers 0.23.2` (`Cargo.lock:8885`, `[fancy-regex]`) with `esaxx-rs 0.1.10 []` (`Cargo.lock:2737`, `cpp` feature disabled so C++ `esaxx.cpp` is not compiled). |
| `longshore_s3 >= 0.2.0` + `aws-lc-sys` | **Rust + AWS-LC Crypto** | Already Bazel-hermetic via `@aws-lc 5.1.0.bcr.2` (`MODULE.bazel:468-482`). Linux `io_uring` requires kernel >= 6.1, seccomp allowlist, `RLIMIT_MEMLOCK`. |
| `candle-core` `0.11.1` (`cuda` feature) | **C/CUDA FFI + Proprietary GPU Runtime** | `candle-kernels` compiles `.cu` via `nvcc` (`CUDA_COMPUTE_CAP=121`); `cudarc` loads `libcuda.so.1`, `libcudart.so.13`, `libcublas*.so.13`, `libnvrtc.so.13`. |
| `ort_loader.rs` / `Vix` (`libvips`) | **C/C++ FFI (Rejected for Core Data Path)** | `ort_loader.rs` `dlopen`s `libonnxruntime.so`; `Vix` wraps C `libvips`. |

### 5.2 Explicit Pure-Rust Blockers & Options for Owner Decision

1. **Blocker B1 -- GPU Inference (`candle/cuda` vs Pure-Rust WGPU/CubeCL):**
   - *Evidence:* `candle`'s `cuda` feature invokes `nvcc` and links proprietary CUDA 13 libraries (`CUDA_COMPUTE_CAP=121` in `246b7e8d87:scripts/build-media-worker-cuda.sh:236` and `246b7e8d87:docs/media-worker-cuda-image.md:77`; omitting it in `manifest-nogpu.yaml` failed in `b-nocap.log:306-310`).
   - *Option A (Recommended near-term):* Keep `candle/cuda` behind the isolated `serviceradar-media-worker-cuda` arm64 image (measured `120-130 img/s` F16, `2.20 ms` text p50 on GB10), clearly labelled as CUDA-accelerated rather than pure-Rust GPU.
   - *Option B (Pure-Rust GPU boundary):* Evaluate `burn` + `burn-wgpu` / `cubecl` (compiles WGSL/SPIR-V in pure Rust, crossing only the host Vulkan ICD `libvulkan.so.1`), gated on measuring GB10 F16 throughput parity against `120-130 img/s`.
2. **Blocker B2 -- H.265 / HEVC Camera Decoding:**
   - *Evidence:* `rusty_h264` has 0 matches for `hevc`/`h265`; `DefaultKeyframeDecoder` (`keyframe_decoder.rs:116`) explicitly emits `undecodable_keyframes` (`unsupported_codec`) for HEVC.
   - *Option A (Pure Rust):* Evaluate `rusty_h265` (BSD-2-Clause, pure Rust) against FFmpeg bit-exactness behind `KeyframeDecoder`.
   - *Option B (Hardware Vulkan Video):* Probe `VK_KHR_video_decode_queue` (`ash` / `gpu-video`) on target `arm64` GPU nodes (`gpu-node-01`/`gpu-node-02` NVIDIA driver 580 capability unverified).
   - *Option C (Isolated FFI fallback):* Run `libavcodec` / NVDEC (`libnvcuvid.so`) inside an isolated, seccomp-confined decoder sidecar/image if pure-Rust HEVC fails qualification or fleet CPU decode exceeds budget (`44-152` cores un-gated).
3. **Blocker B3 -- Transformer Detectors (`RT-DETR` / `RF-DETR`) & Attribute Binding (`"man in the red dress"`):**
   - *Evidence:* `candle-core` and `candle-nn` `0.11.1` contain `0` occurrences of `grid_sample`, blocking multi-scale deformable attention used by RT-DETR / D-FINE / RF-DETR. Meanwhile, YOLOv8 weights are AGPL-3.0, and SigLIP whole-crop embeddings suffer attribute-binding collapse on composite queries (`"man in the red dress"` vs `"woman in red shirt"`).
   - *Option A (Recommended):* Port **YOLOX** (Apache-2.0, anchor-free decoupled head, ~250-400 LoC in `candle-nn`, zero missing ops) for Stage 1 detection, pair with **torso vs lower-body HSV sub-crop histograms** (`vision.rs`) + optional lightweight attribute classifier / query-time **top-K VLM reranking** (`qwen3_vl` or `moondream` already present in `candle-transformers 0.11.1`, bounded to <= 20 candidate frames at query time, never ingestion).
   - *Option B:* Implement custom CPU + CUDA `grid_sample` op in `candle` fork or use `burn` for RT-DETR.
4. **Blocker B4 -- Pixel-Level Segmentation Masks (`tamserve` / SAM 2 / EdgeTAM):**
   - *Evidence:* `~/src/tamserve` is Python/PyTorch with restrictive Meta licensing and requires a 3,000-5,000 LoC Candle port.
   - *Decision:* Remain **deferred**; pure-Rust live tracking uses **YOLOX + `trackforge` (`ByteTrack` / `BotSort`)** for bounding boxes, `track_id` trajectories, dwell times, and per-track Re-ID/color summaries.
5. **Blocker B5 -- Bazel `crate_mirror` Git Dependencies (`rusty_h264` fork):**
   - *Evidence:* `handoff_2026-11-21` section 10 notes `third_party/crate_mirror/sync.py` skips checksum-less git packages.
   - *Options:* Verify Bazel `crate_universe` / RBE git fetch policy for `rev = "4439375cf627c916ccf9b2ef627f219d50a7e8b7"`, or vendor into `third_party/rust_patches/` / publish a tagged internal crate tarball to the mirror.

---

## 6. Internal Rust Reuse & Shared-Crate Extraction Plan

| Source (`~/src/longshore`, `~/src/ultragraphdb`, `rust/`) | Target in `serviceradar` | Pipeline Role & Integration Notes |
|---|---|---|
| `rust/media-worker/src/{cmaf,h264,keyframe_decoder,range_reader,tracking,tokenizer}.rs` | Extract **`rust/media-core` (`serviceradar-media-core`)** | Decouples pure-Rust CMAF parsing, H.264 IDR decode, coalesced range reads, `ClipTracker`, `PureRustTokenizer`, and Tier-2 pixel gate from `candle-*` / CUDA so edge gate, live tracker, and GPU worker share one crate. |
| `rust/anomaly-core` (`serviceradar-anomaly-core`) | Direct workspace dependency | Provides DeepCausality `SlidingWindow`, `WelfordAcc`, `Cusum` for Tier-1 compressed byte-rate adaptive thresholding (satisfies `AGENTS.md` ban on parallel rolling z-score/CUSUM implementations). |
| `longshore_s3 >= 0.2.0`, `longshore_crc`, `longshore_common::io::alloc_guard`, `longshore_mailbox = "0.2.0"` | Direct `crates.io` workspace deps | Zero-copy range reads, hardware CRC-64/NVME & CRC-32C checksums, `alloc_guard` steady-state zero-alloc test assertions, and bounded `Copy` `longshore_mailbox` (`0.2.0` from `crates.io`, `Cargo.lock:4266`, pulled by `longshore_s3 0.2.0`; not present in local `~/src/longshore` `0.1.1` checkout) for camera-sharded live tracking. Requires Linux >= 6.1 `io_uring` seccomp + `RLIMIT_MEMLOCK` >= 64 MiB. |
| `rust/otel/src/nats/` + `rust/flow-collector/src/publisher.rs` + `rust/cert-policy` | Extract **`rust/nats-client` (`serviceradar-nats`)** | Unifies `async-nats = "0.52.0"`, `cert-policy` mTLS admission, JetStream stream shape/env override (`SERVICERADAR_JS_*_MAX_BYTES`), and 900 KiB chunking across `media-worker`, live trackers, and collectors. |
| `rust/otel/src/agent_forward/spool/` | Extract **`rust/disk-spool` (`serviceradar-spool`)** | Torn-tail-safe bounded edge disk spool (`min_free_disk_bytes` floor, oldest eviction) for disconnected edge frame/track events. |
| `rust/media-worker/src/http_server.rs` + `rust/config-bootstrap` | Extract **`rust/service-probes`** + reuse `config-bootstrap` | Standardized Axum `/healthz`, `/readyz` (`CapabilityManifest`), `/metrics` across all Rust video services. |
| `ultragraphdb_core_ids`, `_codec`, `_algo`, `_tok`; `ultragraphdb_common_*`; Ultra Style (`~/src/ultragraphdb/{AGENTS.md,openspec/protocols/ULTRA_STYLE.md}`) + `rust/README_RUST.md` | Selective crate extraction / pattern adoption | 128-bit `SystemId` + `UidPack` + `intersect_sorted_packed` for fast `camera AND time AND class AND color` pre-filtering; `ultragraphdb_core_tok` for pure-Rust Bleve-compatible text/OCR tokenization; `InboxTurn` bounded per-turn draining (`Ultra Style` in `~/src/ultragraphdb`); ServiceRadar Cargo/Bazel layout and tuple-struct error rules in `rust/README_RUST.md`. **Caveats:** `ultragraphdb` uses `edition = "2024"`, `rust-version = "1.99.1"` (vs ServiceRadar `1.98.0`), and `compio` (vs `tokio`), so extract runtime-agnostic core modules rather than importing workspace crates directly. `ultragraphdb_store_hnsw` uses scalar `as_chunks::<4>()` over `fjall` without SIMD/quantization, so keep CNPG PG18 `pgvector` partitioned `halfvec` as primary vector index unless sharded/quantized ANN is later needed. |

---

## 7. Prioritized Action Plan & Synthetic Verification Targets

### Phase 0: Security & Pre-Enablement Gates (Mandatory Before Enabling Visual Search Anywhere)
1. **Fix `R44` in `visual_worker_read_grants.ex:132, 283-294`** (verify `load_and_check_job` + `verify_descriptor_sha` BEFORE calling `maybe_cancel_job`) and close `R43`/`R45`-`R48` in `463daf5208`.
2. **Scope NATS Grants:** Restrict `media.jobs.visual_index.*`, `media.results.visual_index.*`, and `media.rpc.visual_text_embed.*` away from broad `$JS.API.>` / `>` non-media roles.
3. **Fix `NVRWorker` Abort Veto (`nvr_worker.ex:651, 689`):** Fold into `feat/nvr-read-path` rebuild onto `22aabc7681` so verified `:sealed_local` blocks always register.
4. **Resolve Demo JetStream PVC Budget:** Move `values-demo.yaml` from `30G` `maxFileStore` to `small` profile (`36G` / `36Gi` PVC via `StatefulSet --cascade=orphan` per `docs/nats-jetstream-profile-runbook.md`), clearing the `~863 MB` over-budget failure.

### Phase 1: Pure-Rust Foundation, Decoder Fork, & Two-Tier Gate (`add-vms-frame-change-gate` + `media-core`)
1. **Adopt `~/src/rusty_h264` `carverauto/0.17.3-fixes` (`4439375cf`)** via Bazel-compatible vendoring/mirroring, lifting single-slice and equal-QP refusals in `h264.rs` and persisting `undecodable_keyframes` in Core.
2. **Extract `rust/media-core`** and shared `serviceradar-nats` / `serviceradar-service-probes` crates following `rust/README_RUST.md` layout/error rules and `Ultra Style` (`~/src/ultragraphdb/openspec/protocols/ULTRA_STYLE.md`) bounded-actor patterns.
3. **Implement Two-Tier Frame-Change Gate (`add-vms-frame-change-gate`):**
   - Tier 1 (Core/NVR metadata, zero-decode): `trun` sync-sample / block byte-rate delta + `serviceradar-anomaly-core` (`SlidingWindow` + `WelfordAcc` + `Cusum`) prior to `VisualIndexJob` admission.
   - Tier 2 (`serviceradar-media-core`, pre-Stage-1): Y-plane box-averaged spatial-block max-L1 delta executed **before** Stage 1 detection and Stage 2 embedding, emitting interval carry-forward validity windows (`[valid_from_us, valid_until_us]`).
4. **Replace AGPL YOLOv8 & Blocked `rtdetr-r18`:** Implement Apache-2.0 **YOLOX** in `candle-nn`, decouple `detector_model_id` from `embedder_model_id` in Core (`VisualIndexDispatcher`) and Helm (`media-worker.yaml`), and add torso/lower-body HSV color sub-cropping + SPS resolution fallback (`camera_stream_profiles` `0x0` metadata tolerance).

### Phase 2: Live Detection/Tracking & 8,000-Camera Indexing Throughput (`update-video-pipeline-nlp-search-and-live-tracking`)
1. **Live Object Detection & Tracking:** Add a bounded live-frame tap on existing Core/recorder relays (or edge `retina` RTSP ingest) feeding camera-sharded stateful `ClipTracker` actors (`trackforge` `ByteTrack`/`BotSort` + `longshore_mailbox` `<= 8` frames/cam + `InboxTurn` bounded turns, `MAX_TRACKS_PER_CAMERA <= 128` with 30 s TTL), enforcing opt-in camera / `0.5 fps` substream + Tier-2 pre-Stage-1 gating (`<= 150-600` GPU-admitted frames/s) and publishing compact track/detection events to `CAMERA_LIVE_TRACKS` (`media.events.live_tracks.v1`, `512 MiB` `small` / `2-4 GiB` `large`, `DiscardPolicy::Old`) without opening a second camera session.
2. **Fix JetStream & Result Serialization Bottlenecks:** Honor `SERVICERADAR_JS_CAMERA_MEDIA_JOBS_MAX_BYTES`, `SERVICERADAR_JS_CAMERA_MEDIA_RESULTS_MAX_BYTES`, and `SERVICERADAR_JS_CAMERA_LIVE_TRACKS_MAX_BYTES` in `media-worker` + Helm budget checks; switch embeddings in `media.results.visual_index.v1` from JSON `Vec<f32>` to compact binary/f16 (`~1.5 KB`/vec) + track-crop deduplication.
3. **Scale CNPG Storage & Dispatch:** Time-range partition `platform.camera_visual_embeddings` on PG18 (`timeline_ts_us`), migrate `vector(768)` -> `halfvec(768)`, add `(state, deadline_at)` index on `platform.camera_visual_index_jobs`, and raise `VisualIndexDispatchWorker` from its `16.7 jobs/s` ceiling to sustain `> 318 jobs/s` continuous arrival with `>= 500 jobs/s` burst drain via event-driven / sharded parallel dispatch.

### Phase 3: Fleet-Scale Recording & Codec Expansion (8,000 Cameras)
1. Complete **Longshore multipart upload (`add-longshore-object-storage` task 2.2)** to raise NVR block ceiling from `12 MiB` to `128 MiB` (**10.7x** fewer blocks/catalog rows/jobs).
2. Land **`add-scalable-camera-recording-plane`** independent recorder pools to eliminate the 16-session NVR cap and `32-64 Gbit/s` `core-elx` media transit.
3. Resolve **HEVC decode** (qualify pure-Rust `rusty_h265` vs Vulkan Video `VK_KHR_video_decode_queue` vs isolated `libavcodec`/NVDEC) and optional query-time VLM top-K reranking (`qwen3_vl`/`moondream` in `candle-transformers`).

### 7.1 Synthetic & Designated Verification Targets (Hygiene-Compliant)
- **Tier 1 Synthetic Stream Cluster (`demo/rtsp-replayer/paths.json`):** `drone-highway` (1080p29.97 vehicles), `drone-quarry` (1080p29.97 machinery), `drone-surf` (720p30 people), transcoded per `demo/rtsp-replayer/README.md:63` (`-c:v libx264 -preset slow -crf 20 -bf 0 -g 60 -pix_fmt yuv420p -an`, H.264 High profile implicit/observed in SDP) and served by `serviceradar-rtsp-replayer` (`rtsp-replayer` template, e.g. `rtsp://rtsp-replayer.serviceradar.svc.cluster.local:8554/<path>`). Verifies two-tier gate admission ratio, multi-slice decode parity, YOLOX + SigLIP NLP queries (`"excavator in quarry"`, `"person in red swimwear"`), and continuous `track_id` persistence across block boundaries.
- **Tier 2 Synthetic Edge RTSPS Acceptance:** Synthetic RFC-5737 edge target (`192.0.2.90`, `rtsps://nvr-01.example.com:7441/cam-01`, `cam-synth-0001`, `Gate North`, `agent-edge-01`, `gpu-node-01`) with `fps=0, width=0, height=0` bootstrap profile metadata to verify SPS dimension fallback, profile switches, and zero credential/frame leakage into JetStream or OpenSpec artifacts.
