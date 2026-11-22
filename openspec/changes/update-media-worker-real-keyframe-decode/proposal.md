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
- Remove the solid-colour fallback. Record a refusal for each undecodable sample and
  continue indexing the verified block. The [worker README](../../../rust/media-worker/README.md#keyframe-decoding)
  describes codec support, resource limits and the Prometheus counter.
- The synthetic `SRIDR1` raster decoder becomes test-only and is selected by injection,
  never by sniffing bitstream bytes.

## Impact

- Affected specs: `vms-media-workers`.
- Affected code: `rust/media-worker` (`keyframe_decoder.rs`, `h264.rs`, `cmaf.rs`,
  `worker.rs`, `metrics.rs`), root `Cargo.toml`/`Cargo.lock`, crate mirror.
- Result schema: `media.results.visual_index.v1` gains an optional
  `undecodable_keyframes` array (omitted when empty). The current core projector ignores
  unknown keys, so this is backward compatible; persisting it is a follow-up in core.
