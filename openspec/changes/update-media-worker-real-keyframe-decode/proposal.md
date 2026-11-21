# Change: Decode real H.264 keyframes in the media worker

## Why

`serviceradar-media-worker` could not decode real camera video. Its keyframe decoder read
only a synthetic `SRIDR1` test raster; for any real H.264 or HEVC IDR it returned a solid
frame whose colour came from a SHA-256 of the NAL bytes. Semantic search over real
recordings would therefore index fabricated pictures.

## What Changes

- Decode H.264 IDR keyframes for real, in pure Rust (`rusty_h264-decoder`, exact-pinned),
  behind a `KeyframeDecoder` trait so HEVC or a hardware decoder can be added later without
  touching callers.
- Supported: Constrained Baseline, Main and High profile; 8-bit 4:2:0; progressive (frame)
  coding; equal Cb and Cr quantization offsets; CAVLC and CABAC; 8x8 transform; scaling matrices;
  multiple slices with uniform deblocking mode and offsets; SPS cropping;
  VUI colour description (matrix and range).
- Remove the solid-colour fallback. A keyframe that cannot be decoded produces a typed
  outcome (`unsupported_codec`, `malformed_bitstream`, `limit_exceeded`,
  `invalid_container`), recorded per keyframe in the result envelope as
  `undecodable_keyframes` and counted in `keyframes_undecodable_total{reason}`. It never
  produces a frame.
- HEVC (and other codecs or H.264 profiles outside the supported set) is reported as
  `unsupported_codec`.
- Once the worker has a grant and has verified the block, it indexes the remaining
  keyframes even if one fails to decode. The grant service rejects the entire job before
  decoding if any sampled fragment exceeds 4 MiB.
- The synthetic `SRIDR1` raster decoder becomes test-only and is selected by injection,
  never by sniffing bitstream bytes.
- Hard limits ahead of the decoder: 4096x4096 coded picture, 4 MiB access unit, 1024 IDR
  slices, 4096-byte parameter sets, 4096 NAL units per sample.

## Impact

- Affected specs: `vms-media-workers`.
- Affected code: `rust/media-worker` (`keyframe_decoder.rs`, `h264.rs`, `cmaf.rs`,
  `worker.rs`, `metrics.rs`), root `Cargo.toml`/`Cargo.lock`, crate mirror.
- Result schema: `media.results.visual_index.v1` gains an optional
  `undecodable_keyframes` array (omitted when empty). The current core projector ignores
  unknown keys, so this is backward compatible; persisting it is a follow-up in core.
