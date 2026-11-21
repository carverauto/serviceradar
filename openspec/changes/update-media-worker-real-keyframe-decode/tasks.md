## 1. Implementation

- [x] 1.1 Add `KeyframeDecoder` and typed `KeyframeDecodeError` in the media worker.
- [x] 1.2 Decode H.264 IDR keyframes with `rusty_h264-decoder` (exact-pinned, default
  features off, SIMD on), with SPS/PPS admission, cropping and VUI colour handling.
- [x] 1.3 Remove the solid-colour fallback; make the `SRIDR1` decoder test-only and
  injected.
- [x] 1.4 Record undecodable keyframes per keyframe in the result envelope and metrics;
  keep indexing the rest of the block.
- [x] 1.5 Enforce dimension, access-unit, slice-count, parameter-set and NAL-count limits.

## 2. Validation

- [x] 2.1 Tests from generated streams: Baseline, Main CABAC, High CABAC 8x8 and High CAVLC
  (pure-Rust encoder) and an x264 High CABAC 8x8 fixture with cropping and full-range VUI,
  checked bit-exact against FFmpeg's decode.
- [x] 2.2 HEVC reported unsupported; malformed, unsupported and oversized input returns
  typed errors without panicking; old fabricated-frame behaviour fails the new tests.
- [x] 2.3 `bazel test --config=remote //rust/media-worker:all` and an arm64 Bazel build of
  the worker binary.

## 3. Follow-ups

- [ ] 3.1 Core projector: persist `undecodable_keyframes` and distinguish an all-undecodable
  block from an indexed one.
- [ ] 3.2 HEVC decode (libavcodec or hardware).
- [ ] 3.3 Hardware decode (NVDEC) for fleet-scale throughput.
- [ ] 3.4 Detect truncated CABAC slices (upstream overread check).
- [ ] 3.5 Request upstream continuity checks at CAVLC and CABAC slice boundaries.
- [ ] 3.6 Request upstream support for separate Cb and Cr quantization offsets.
- [ ] 3.7 Extend read grants to identify an oversized sampled fragment while granting
  its eligible siblings, so the worker can publish a partial result.
- [ ] 3.8 Request upstream per-slice deblocking mode and offset handling when finishing
  a macroblock row shared by multiple slices.
- [ ] 3.9 Request upstream deblocking QP zero for I_PCM macroblocks in decoder 0.17.3
  at `src/mb16.rs:3974` (CABAC) and `src/mb16.rs:5319` (CAVLC).
