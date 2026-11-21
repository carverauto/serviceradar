# serviceradar-media-worker

Standalone worker that indexes sealed camera recording blocks for semantic search. It pulls
jobs from `media.jobs.visual_index.v1`, fetches `init.mp4` and the sampled keyframe
fragments through a read grant, verifies every byte range against the frozen descriptor
SHA-256, decodes one IDR keyframe per sampled fragment, runs detection and embedding, and
publishes `media.results.visual_index.v1` before acknowledging the job.

Spec: `openspec/specs/vms-media-workers/spec.md` and
`openspec/changes/update-media-worker-real-keyframe-decode/`.

## Keyframe decoding

`src/keyframe_decoder.rs` defines the `KeyframeDecoder` trait. The production
implementation, `DefaultKeyframeDecoder`, decodes H.264 in pure Rust with
`rusty_h264-decoder` (see `src/h264.rs`). Each keyframe gets a fresh decoder.

Supported:

- H.264 Constrained Baseline, Main and High profile;
- 8-bit 4:2:0, frame (progressive) coding;
- CAVLC and CABAC, 8x8 transform, scaling matrices, multiple slices per picture;
- SPS cropping;
- parameter sets from `avcC` and in-band (`avc3`); in-band sets win.

Colour: the VUI `matrix_coefficients` picks BT.709, BT.601 or BT.2020 and
`video_full_range_flag` picks the range. Without them the worker uses limited range and
BT.709 above 576 lines, BT.601 otherwise.

Not supported, reported as `unsupported_codec`: HEVC, other H.264 profiles (High 10,
4:2:2, 4:4:4 and so on), interlaced/MBAFF coding, FMO, SP/SI slices, lossless macroblocks,
CABAC I_PCM, and non-YCbCr VUI matrices.

A keyframe that cannot be decoded is never replaced by a fabricated frame. It is listed in
the result envelope's `undecodable_keyframes` (`fragment_sequence`, `reason`, `codec`,
`detail`) and counted in `keyframes_undecodable_total{reason}`. Reasons:
`unsupported_codec`, `malformed_bitstream`, `limit_exceeded`, `invalid_container`. The rest
of the block is still indexed and the job completes.

Limits enforced before the decoder runs: coded picture at most 4096x4096 (from the SPS),
access unit at most 4 MiB, at most 1024 IDR slices, parameter sets at most 4096 bytes, at
most 4096 NAL units per sample. Decoding has no wall-clock timeout (the call cannot be
interrupted); these limits bound its work instead.

Known gap: a CABAC slice truncated inside its macroblock data decodes to a picture with a
wrong tail instead of an error (the decoder zero-fills past the end). CAVLC truncation is
detected.

## Tests

`src/keyframe_decoder_tests.rs` encodes programmatic patterns with `rusty_h264-encoder` at
test time and decodes them through the real container parser.
`testdata/high_cabac_8x8_cropped_full_range_idr.h264` is the one stored bitstream: an x264
encode of a synthetic pattern documented in that test file, checked bit-exact against
FFmpeg's decode. Worker tests that need exact pixels use the generator's `SRIDR1` raster
keyframes with the test-only `SyntheticRasterKeyframeDecoder`, injected through
`VisualIndexProcessor::with_keyframe_decoder`.

```sh
cargo test -p serviceradar-media-worker
bazel test --config=remote //rust/media-worker:all
```
