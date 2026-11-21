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
CABAC slice. It was kept as the fallback: it is C++ on attacker-influenced input and needs
a C++ build in every Bazel action that links it. libavcodec covers HEVC but is LGPL C with
a heavy hermetic build; it is the candidate for HEVC together with hardware decode.

## Known gaps

`rusty_h264-decoder` zero-fills past the end of a CABAC slice. A CABAC slice truncated
inside its macroblock data decodes to a full-size picture whose tail is wrong instead of
an error. CAVLC truncation is detected. Fragment bytes are SHA-256 verified against the
frozen descriptor, so this needs a recorder or camera that writes short NAL units. Tracked
as a follow-up (an upstream overread check).

An IDR picture must start at macroblock zero and have strictly increasing slice starts
inside the coded picture. For CAVLC and CABAC, the end of each slice is private to the
decoder. A missing middle slice or an overlap with increasing starts can therefore pass
admission. Request an upstream check for contiguous decoded macroblock coverage.

The pinned decoder reconstructs both chroma planes with the Cb quantization offset.
An active PPS with unequal Cb and Cr offsets produces `unsupported_codec`.

The decoder can finish filtering a macroblock row with the last slice's deblocking
settings. Admission returns `unsupported_codec` if slices differ in deblocking mode,
alpha offset or beta offset.

The owner accepts approximate decoding for I_PCM macroblocks, which camera encoders
rarely emit. In both CAVLC and CABAC, decoder 0.17.3 uses the running slice QP to
filter their edges. H.264 specifies QP zero. Differences are confined to pixels at
I_PCM macroblock edges.

## Bounded work

Decoding is a synchronous call that cannot be interrupted, so there is no wall-clock
timeout. Work is bounded by the input instead: the coded picture size is checked from the
SPS before the decoder allocates, and the access unit size and slice count are capped.
All slices must refer to one picture and its admitted PPS and SPS. Only those sets reach
the fresh decoder and count toward the access-unit byte limit along with the slices and
Annex B start codes. The worker runs decode on the blocking pool under the index permit.

## Colour

The VUI `matrix_coefficients` selects BT.709 (1), BT.601 (5 or 6) or BT.2020
non-constant luminance (9). An absent or unspecified value (2) selects BT.709 above 576
display lines and BT.601 otherwise. All other codes produce `unsupported_codec`.
`video_full_range_flag` selects the range and defaults to limited. Chroma uses sample
replication.
