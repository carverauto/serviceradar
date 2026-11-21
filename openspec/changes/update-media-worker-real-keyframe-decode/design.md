# Design: real keyframe decoding

## Decoder choice

`rusty_h264-decoder` 0.17.3 (BSD-2-Clause, pure Rust) was chosen over OpenH264 (C++ via the
`openh264` crate) and libavcodec. Evidence gathered on 2026-11-21:

- Correctness: on x264 streams generated from a synthetic pattern (Constrained Baseline,
  Main CABAC, High CABAC with 8x8 transform, High CAVLC, 8 slices per picture, JVT scaling
  matrices, 1918x1078 cropping) the first IDR decoded byte-identical to FFmpeg. MBAFF is
  refused with a typed error. Its README still lists "High-profile 8x8 CABAC residual" as
  missing; the source and these results show it is implemented.
- Build: no C, no build-time tools. Its SIMD kernels are stable-Rust intrinsics (SSE2/AVX2,
  aarch64 NEON) in `rusty_h264-accel`; no nightly toolchain is needed. The arm64 Bazel
  build links the NEON kernels.
- Default features are turned off because they install a process-wide
  `#[global_allocator]`; `std` and `asm` (SIMD) are enabled explicitly.
- Speed (Apple M4, one core, SIMD on): 1080p IDRs of 57 KB, 261 KB and about 590 KB took
  about 11, 35-40 and 70 ms. SIMD saves 25-40%.

OpenH264 2.7 also decodes Main/High CABAC with 8x8 transform (its README says Constrained
Baseline only, but its source and the same tests disagree), and it detects a truncated
CABAC slice. OpenH264 remains an alternative for future evaluation. It would process
camera input in C++ and require a C++ build for actions that link it. libavcodec covers
HEVC and requires a heavy hermetic build of LGPL C code. It remains a candidate for HEVC
alongside hardware decoding.

## Known gaps

`rusty_h264-decoder` zero-fills past the end of a CABAC slice. A CABAC slice truncated
inside its macroblock data decodes to a full-size picture whose tail is wrong instead of
an error. CAVLC truncation that removes coded samples is detected. If all macroblock
data is present, the decoder can accept a missing trailing-bits byte. Fragment bytes are SHA-256 verified against the
frozen descriptor, so this needs a recorder or camera that writes short NAL units. Tracked
as a follow-up (an upstream overread check).

Only single-slice IDR pictures are admitted. With multiple slices, the decoder can use
the last slice's deblocking parameters for a shared row, use an unavailable upper-left
corner for I_8x8 prediction across a slice boundary, or return a picture with a missing
slice. Admission can lift this restriction once the worker adopts the fixes from the
[decoder fork](https://github.com/carverauto/rusty_h264).

The pinned decoder reconstructs both chroma planes with the Cb quantization offset.
An active PPS with unequal Cb and Cr offsets produces `unsupported_codec`.

The owner accepts approximate decoding for I_PCM macroblocks, which camera encoders
rarely emit. In both CAVLC and CABAC, decoder 0.17.3 uses the running slice QP to
filter their edges. H.264 specifies QP zero. Differences are confined to pixels at
I_PCM macroblock edges.

## Bounded work

Decoding is a synchronous call that cannot be interrupted, so there is no wall-clock
timeout. Work is bounded by the input instead: the coded picture size is checked from the
SPS before the decoder allocates, and only one slice is admitted.
Only the active SPS and PPS reach the fresh decoder. They count toward the access-unit
byte limit along with the slice and
Annex B start codes. The worker runs decode on the blocking pool under the index permit.

## Colour

The VUI `matrix_coefficients` selects BT.709 (1), BT.601 (5 or 6) or BT.2020
non-constant luminance (9). An absent or unspecified value (2) selects BT.709 above 576
display lines and BT.601 otherwise. All other codes produce `unsupported_codec`.
`video_full_range_flag` selects the range and defaults to limited. If the worker cannot
parse the VUI colour fields, it uses both defaults. Chroma uses sample replication.
