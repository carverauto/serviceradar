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

- H.264 Constrained Baseline, Main and High profile with equal Cb and Cr quantization offsets;
- 8-bit 4:2:0, frame (progressive) coding;
- CAVLC and CABAC, 8x8 transform, scaling matrices, single-slice IDR pictures;
- SPS cropping;
- parameter sets from `avcC` for `avc1`; `avc3` also accepts in-band replacements.

The worker uses VUI colour metadata to convert decoded pixels to RGB. See the
[colour conversion rules](../../openspec/changes/update-media-worker-real-keyframe-decode/design.md#colour)
for supported matrices and defaults.

Not supported, reported as `unsupported_codec`: HEVC, other H.264 profiles (High 10,
4:2:2, 4:4:4 and so on), interlaced/MBAFF coding, FMO, SI slices, lossless macroblocks,
unequal Cb and Cr quantization offsets, multi-slice pictures, auxiliary and
extension coded slices, and unsupported VUI matrices. An SP slice in an IDR picture is
malformed and produces `malformed_bitstream`.

The per-keyframe outcome applies to granted, verified fragments. If any sampled fragment
exceeds 4 MiB, the read-grant service rejects the whole request before the worker can
fetch the fragments. The worker handles that rejection as a job-level failure.

For each verified sample it cannot decode, the worker adds an entry to
`undecodable_keyframes` with the fragment sequence (`fragment_sequence`), the sample-entry
codec (`codec`, or `unknown` if unidentified), and a `reason`. The reasons are
`unsupported_codec`, `malformed_bitstream`, `limit_exceeded`, and `invalid_container`.
The counter at `/metrics` is `serviceradar_media_worker_keyframes_undecodable_total`,
labelled by `reason`.

Only decoded samples produce frames, detections, or embeddings. A refused sample still
advances the tracker at its timestamp, so a gap longer than the track buffer ends the
track. The worker publishes the result even if every sample was refused. If all samples
decode, it omits `undecodable_keyframes`. If the verified track init cannot be parsed,
every sampled sequence gets `invalid_container`.

The worker checks both the container dimensions and the SPS coded dimensions before
decoding. Each may be at most 4096 pixels wide and 4096 pixels high. It also caps the
access unit at 4 MiB, each parameter set at 4096 bytes, and each sample at 4096 NAL
units. These limits bound the synchronous decoder call, which has no wall-clock timeout.

Truncated CABAC data can produce a picture with incorrect trailing pixels. Pictures with
I_PCM macroblocks can also have approximate edge pixels when deblocking is enabled.
See the [decoder design](../../openspec/changes/update-media-worker-real-keyframe-decode/design.md#known-gaps)
for the CAVLC truncation behavior and the reasons for the single-slice restriction.

## Tests

`src/keyframe_decoder_tests.rs` encodes programmatic patterns with `rusty_h264-encoder` at
test time and decodes them through the real container parser.
`testdata/high_cabac_8x8_cropped_full_range_idr.h264` is the one stored bitstream: an x264
encode of a synthetic pattern documented in that test file, checked bit-exact against
FFmpeg's decode. Worker tests that need exact pixels use the generator's `SRIDR1` raster
keyframes with the test-only `SyntheticRasterKeyframeDecoder`, injected through
`VisualIndexProcessor::with_keyframe_decoder`.

```sh
bazel test --config=remote //rust/media-worker:all
```
