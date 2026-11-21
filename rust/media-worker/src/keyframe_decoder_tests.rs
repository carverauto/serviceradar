//! Keyframe decoder tests. Every bitstream here is generated from a programmatic test
//! pattern: in-test with the pure-Rust `rusty_h264-encoder`, or (one High-profile fixture)
//! offline with x264 from the pattern described on `HIGH_FIXTURE`. No camera media.

use crate::cmaf::{avcc_box, build_fragment_m4s, build_init_mp4};
use crate::h264::decode_access_unit;
use crate::keyframe_decoder::{DefaultKeyframeDecoder, KeyframeDecodeErrorKind, KeyframeDecoder};
use crate::{
    ParsedInitSegment, ParsedMediaFragment, RgbFrame, parse_init_segment, parse_media_fragment,
};
use rusty_h264_common::nal::{NalUnit, NalUnitType};
use rusty_h264_common::{BitWriter, Profile, YuvFrame};
use rusty_h264_encoder::{Encoder, EncoderConfig};
use sha2::{Digest, Sha256};

/// High profile, CABAC, `transform_8x8_mode_flag = 1` with I_8x8 macroblocks (x264
/// `--partitions i8x8`), 120x88 display cropped from 128x96, VUI full range with
/// `matrix_coefficients = 5` (BT.601). Encoded by x264 at QP 10 from the full-range BT.601
/// I420 rendering of this pattern, SEI removed:
/// - top half (y < 44): quadrants split at x = 60 and y = 22, RGB `HIGH_FIXTURE_QUADRANTS`
///   in raster order, converted with Y = 0.299R + 0.587G + 0.114B,
///   U = 128 + 0.564(B - Y), V = 128 + 0.713(R - Y);
/// - bottom half: luma diagonal stripes (190 when ((x + y) / 3) is odd, else 60), U = V = 128.
const HIGH_FIXTURE: &[u8] =
    include_bytes!("../testdata/high_cabac_8x8_cropped_full_range_idr.h264");
const HIGH_FIXTURE_QUADRANTS: [[u8; 3]; 4] =
    [[200, 200, 200], [220, 40, 40], [40, 180, 60], [40, 70, 210]];
/// SHA-256 of FFmpeg's decode of `HIGH_FIXTURE` as cropped I420 (Y, then U, then V).
const HIGH_FIXTURE_FFMPEG_I420_SHA256: &str =
    "8e34de8903137cc6d3115063a5795db607316ca104e33c472f11d82bce77a7ce";

const W: usize = 128;
const H: usize = 96;

/// Smooth luma ramp with four flat chroma quadrants (limited-range YCbCr).
pub(crate) fn pattern(width: usize, height: usize) -> YuvFrame {
    let mut y = Vec::with_capacity(width * height);
    for row in 0..height {
        for col in 0..width {
            y.push((40 + col * 120 / width + row * 60 / height) as u8);
        }
    }
    let (cw, ch) = (width / 2, height / 2);
    let mut u = Vec::with_capacity(cw * ch);
    let mut v = Vec::with_capacity(cw * ch);
    for row in 0..ch {
        for col in 0..cw {
            u.push(if col < cw / 2 { 90 } else { 170 });
            v.push(if row < ch / 2 { 100 } else { 180 });
        }
    }
    YuvFrame {
        width,
        height,
        y,
        u,
        v,
    }
}

pub(crate) fn encode_idr(mut cfg: EncoderConfig, frame: &YuvFrame) -> Vec<u8> {
    cfg.qp = 14;
    cfg.bitrate = 0;
    cfg.gop_size = 1;
    cfg.lookahead = 0;
    cfg.scenecut = 0;
    cfg.mbtree = false;
    cfg.bframes = 0;
    let mut encoder = Encoder::new(cfg).expect("encoder config");
    encoder.try_encode(frame).expect("encode IDR")
}

/// Splits an Annex-B stream into NAL units (without start codes).
pub(crate) fn annex_b_nals(stream: &[u8]) -> Vec<&[u8]> {
    let mut starts = Vec::new();
    let mut i = 0;
    while i + 3 <= stream.len() {
        if stream[i..i + 3] == [0, 0, 1] {
            starts.push(i + 3);
            i += 3;
        } else {
            i += 1;
        }
    }
    starts
        .iter()
        .enumerate()
        .map(|(k, &start)| {
            let mut end = starts.get(k + 1).map_or(stream.len(), |&next| next - 3);
            while end > start && stream[end - 1] == 0 {
                end -= 1;
            }
            &stream[start..end]
        })
        .collect()
}

pub(crate) fn nals_of_type<'a>(nals: &[&'a [u8]], nal_type: u8) -> Vec<&'a [u8]> {
    nals.iter()
        .copied()
        .filter(|n| n.first().is_some_and(|h| h & 0x1f == nal_type))
        .collect()
}

/// Wraps an Annex-B IDR access unit as a real CMAF init segment + fragment and parses both
/// back with the production container parser.
fn cmaf_keyframe(
    container_width: u32,
    container_height: u32,
    annex_b: &[u8],
) -> (ParsedInitSegment, ParsedMediaFragment) {
    let nals = annex_b_nals(annex_b);
    let sps = nals_of_type(&nals, 7);
    let pps = nals_of_type(&nals, 8);
    let mut sample: Vec<&[u8]> = vec![&[0x09, 0x10]];
    sample.extend(nals_of_type(&nals, 5));
    let init_bytes = build_init_mp4(
        container_width,
        container_height,
        90_000,
        b"avc1",
        &avcc_box(&sps, &pps),
    );
    let fragment_bytes = build_fragment_m4s(0, 0, 2_000_000_000, 90_000, &sample);
    let init = parse_init_segment(&init_bytes).expect("parse init");
    let fragment = parse_media_fragment(&fragment_bytes, &init).expect("parse fragment");
    (init, fragment)
}

/// BT.601 limited-range reference conversion (ITU-R BT.601 equations, in floating point).
fn bt601_limited_rgb(y: u8, u: u8, v: u8) -> [f64; 3] {
    let y = (f64::from(y) - 16.0) * 255.0 / 219.0;
    let u = (f64::from(u) - 128.0) * 255.0 / 224.0;
    let v = (f64::from(v) - 128.0) * 255.0 / 224.0;
    [
        y + 1.402 * v,
        y - 0.344_136 * u - 0.714_136 * v,
        y + 1.772 * u,
    ]
    .map(|c| c.clamp(0.0, 255.0))
}

/// Mean and max absolute RGB error of `frame` against the reference rendering of `source`.
fn rgb_error_vs_source(frame: &RgbFrame, source: &YuvFrame) -> (f64, f64) {
    let mut sum = 0.0;
    let mut max = 0.0_f64;
    for row in 0..source.height {
        for col in 0..source.width {
            let c = (row / 2) * (source.width / 2) + col / 2;
            let want =
                bt601_limited_rgb(source.y[row * source.width + col], source.u[c], source.v[c]);
            let got = frame.pixel_at(col as u32, row as u32);
            for (g, w) in got.iter().zip(want) {
                let err = (f64::from(*g) - w).abs();
                sum += err;
                max = max.max(err);
            }
        }
    }
    (sum / (source.width * source.height * 3) as f64, max)
}

#[test]
fn h264_idr_keyframes_decode_to_the_encoded_pattern_for_every_supported_profile() {
    let source = pattern(W, H);
    let main = {
        let mut cfg = EncoderConfig::new(W, H);
        cfg.profile = Profile::Main;
        cfg
    };
    let high_cavlc = {
        let mut cfg = EncoderConfig::new(W, H);
        cfg.cabac = false;
        cfg
    };
    let cases = [
        (
            "constrained baseline, CAVLC",
            EncoderConfig::baseline(W, H),
            66,
            false,
        ),
        ("main, CABAC", main, 77, true),
        (
            "high, CABAC, 8x8 transform",
            EncoderConfig::new(W, H),
            100,
            true,
        ),
        ("high, CAVLC, 8x8 transform", high_cavlc, 100, false),
    ];

    for (label, cfg, profile_idc, cabac) in cases {
        let annex_b = encode_idr(cfg, &source);
        let nals = annex_b_nals(&annex_b);
        let sps = nals_of_type(&nals, 7)[0];
        assert_eq!(sps[1], profile_idc, "{label}: profile actually encoded");
        // entropy_coding_mode_flag follows two ue(v) ids that are both 0 ("1" "1").
        let pps = nals_of_type(&nals, 8)[0];
        assert_eq!(
            pps[1] & 0x20 != 0,
            cabac,
            "{label}: entropy coder actually used"
        );

        let (init, fragment) = cmaf_keyframe(W as u32, H as u32, &annex_b);
        let frame = DefaultKeyframeDecoder::new()
            .decode_keyframe(&init, &fragment)
            .unwrap_or_else(|err| panic!("{label}: decode failed: {err}"));
        assert_eq!(
            (frame.width(), frame.height()),
            (W as u32, H as u32),
            "{label}"
        );
        let (mean, max) = rgb_error_vs_source(&frame, &source);
        assert!(
            mean < 3.0 && max < 40.0,
            "{label}: decoded RGB diverges from the encoded pattern (mean {mean:.2}, max {max:.1})"
        );
    }
}

#[test]
fn high_profile_fixture_matches_ffmpeg_bit_exactly_and_honours_crop_and_vui_colour() {
    let nals = annex_b_nals(HIGH_FIXTURE);
    let parameter_sets: Vec<&[u8]> = nals
        .iter()
        .copied()
        .filter(|n| matches!(n[0] & 0x1f, 7 | 8))
        .collect();
    let slices = nals_of_type(&nals, 5);
    let picture = decode_access_unit(&parameter_sets, &slices).expect("decode fixture");
    assert_eq!(
        (picture.width, picture.height),
        (120, 88),
        "SPS cropping applied"
    );

    let mut hasher = Sha256::new();
    hasher.update(&picture.y);
    hasher.update(&picture.u);
    hasher.update(&picture.v);
    assert_eq!(
        hex::encode(hasher.finalize()),
        HIGH_FIXTURE_FFMPEG_I420_SHA256,
        "decoded I420 differs from FFmpeg's decode of the same bitstream"
    );

    // Through the container and colour conversion: the fixture signals full-range BT.601,
    // so the flat quadrants come back as the RGB they were generated from. Treating it as
    // the default limited range would lift the grey quadrant from 200 to about 214.
    let (init, fragment) = cmaf_keyframe(120, 88, HIGH_FIXTURE);
    let frame = DefaultKeyframeDecoder::new()
        .decode_keyframe(&init, &fragment)
        .expect("decode fixture to RGB");
    for (index, want) in HIGH_FIXTURE_QUADRANTS.iter().enumerate() {
        let (x, y) = (15 + 60 * (index as u32 % 2), 6 + 22 * (index as u32 / 2));
        let got = frame.pixel_at(x, y);
        for (g, w) in got.iter().zip(want) {
            assert!(
                g.abs_diff(*w) <= 6,
                "quadrant {index} at ({x},{y}): got {got:?}, want {want:?}"
            );
        }
    }
}

#[test]
fn hevc_keyframe_is_reported_unsupported_instead_of_fabricated() {
    // Minimal hvcC: 23-byte header, no parameter-set arrays.
    let mut hvcc = vec![1u8];
    hvcc.extend_from_slice(&[0; 20]);
    hvcc.push(0x03); // lengthSizeMinusOne = 3
    hvcc.push(0); // numOfArrays
    let mut config = Vec::new();
    config.extend_from_slice(&((8 + hvcc.len()) as u32).to_be_bytes());
    config.extend_from_slice(b"hvcC");
    config.extend_from_slice(&hvcc);
    let init_bytes = build_init_mp4(W as u32, H as u32, 90_000, b"hvc1", &config);
    let init = parse_init_segment(&init_bytes).expect("parse hvc1 init");
    for nal_type in 16..=21 {
        let idr: [u8; 8] = [nal_type << 1, 0x01, 0xaf, 0x10, 0x22, 0x5c, 0x81, 0x3e];
        let fragment_bytes = build_fragment_m4s(
            0,
            0,
            2_000_000_000,
            90_000,
            &[&[0x40, 1], &[0x42, 1], &[0x44, 1], &idr],
        );
        let fragment = parse_media_fragment(&fragment_bytes, &init).expect("parse hevc fragment");

        assert!(fragment.in_band_parameter_sets().is_empty());
        let err = DefaultKeyframeDecoder::new()
            .decode_keyframe(&init, &fragment)
            .expect_err("HEVC must not yield a frame");
        assert_eq!(err.reason(), "unsupported_codec");
    }
}

/// Builds a High 10 SPS (`bit_depth_luma_minus8 = 2`) for `sps_id` 0 at 128x96.
fn high10_sps() -> Vec<u8> {
    let mut w = rusty_h264_common::BitWriter::new();
    w.write_bits(110, 8); // profile_idc: High 10
    w.write_bits(0, 8); // constraint flags
    w.write_bits(30, 8); // level_idc
    w.write_ue(0); // seq_parameter_set_id
    w.write_ue(1); // chroma_format_idc 4:2:0
    w.write_ue(2); // bit_depth_luma_minus8
    w.write_ue(2); // bit_depth_chroma_minus8
    w.write_bit(false); // qpprime_y_zero_transform_bypass_flag
    w.write_bit(false); // seq_scaling_matrix_present_flag
    w.write_ue(0); // log2_max_frame_num_minus4
    w.write_ue(2); // pic_order_cnt_type
    w.write_ue(1); // max_num_ref_frames
    w.write_bit(false); // gaps_in_frame_num_value_allowed_flag
    w.write_ue(7); // pic_width_in_mbs_minus1
    w.write_ue(5); // pic_height_in_map_units_minus1
    w.write_bit(true); // frame_mbs_only_flag
    w.write_bit(true); // direct_8x8_inference_flag
    w.write_bit(false); // frame_cropping_flag
    w.write_bit(false); // vui_parameters_present_flag
    w.rbsp_trailing_bits();
    let mut nal = vec![0x67];
    nal.extend_from_slice(&w.into_bytes());
    nal
}

/// `(label, parameter sets, IDR slices, expected reason)`.
type RejectionCase<'a> = (&'a str, Vec<&'a [u8]>, Vec<&'a [u8]>, &'a str);

#[test]
fn malformed_unsupported_and_oversized_keyframes_return_typed_errors_without_panicking() {
    let source = pattern(W, H);
    let baseline = encode_idr(EncoderConfig::baseline(W, H), &source);
    let nals = annex_b_nals(&baseline);
    let (sps, pps, slice) = (
        nals_of_type(&nals, 7)[0],
        nals_of_type(&nals, 8)[0],
        nals_of_type(&nals, 5)[0],
    );
    let truncated = &slice[..slice.len() / 2];
    let wide = encode_idr(EncoderConfig::baseline(4112, 16), &pattern(4112, 16));
    let wide_nals = annex_b_nals(&wide);
    let too_many_slices = vec![slice; 1025];
    let high10 = high10_sps();

    let cases: [RejectionCase<'_>; 7] = [
        (
            "truncated CAVLC slice",
            vec![sps, pps],
            vec![truncated],
            "malformed_bitstream",
        ),
        (
            "slice header only",
            vec![sps, pps],
            vec![&slice[..2]],
            "malformed_bitstream",
        ),
        ("missing PPS", vec![sps], vec![slice], "malformed_bitstream"),
        (
            "no IDR slice",
            vec![sps, pps],
            vec![],
            "malformed_bitstream",
        ),
        (
            "High 10 SPS",
            vec![&high10, pps],
            vec![slice],
            "unsupported_codec",
        ),
        (
            "coded width over the limit",
            vec![
                nals_of_type(&wide_nals, 7)[0],
                nals_of_type(&wide_nals, 8)[0],
            ],
            nals_of_type(&wide_nals, 5),
            "limit_exceeded",
        ),
        (
            "too many slices",
            vec![sps, pps],
            too_many_slices,
            "unsupported_codec",
        ),
    ];
    for (label, parameter_sets, slices, reason) in cases {
        let err = decode_access_unit(&parameter_sets, &slices)
            .expect_err(&format!("{label}: must not decode"));
        assert_eq!(err.reason(), reason, "{label}: {err}");
    }

    // Deterministic byte corruption of a CABAC keyframe (parameter sets included) must
    // yield an error or a consistent picture, never a panic.
    let main = {
        let mut cfg = EncoderConfig::new(W, H);
        cfg.profile = Profile::Main;
        encode_idr(cfg, &source)
    };
    let main_nals = annex_b_nals(&main);
    let parameter_sets: Vec<Vec<u8>> = main_nals
        .iter()
        .filter(|n| matches!(n[0] & 0x1f, 7 | 8))
        .map(|n| n.to_vec())
        .collect();
    let idr = nals_of_type(&main_nals, 5)[0].to_vec();
    let mut seed = 0x9e37_79b9_7f4a_7c15_u64;
    for _ in 0..200 {
        let mut sets = parameter_sets.clone();
        let mut slice = idr.clone();
        for _ in 0..4 {
            seed ^= seed << 13;
            seed ^= seed >> 7;
            seed ^= seed << 17;
            let target = if seed.is_multiple_of(4) {
                let index = (seed >> 8) as usize % sets.len();
                &mut sets[index]
            } else {
                &mut slice
            };
            let index = 1 + (seed >> 16) as usize % (target.len() - 1);
            target[index] ^= (seed >> 40) as u8 | 1;
        }
        let set_refs: Vec<&[u8]> = sets.iter().map(Vec::as_slice).collect();
        let outcome = std::panic::catch_unwind(|| decode_access_unit(&set_refs, &[&slice]));
        match outcome.expect("decoder panicked on corrupted input") {
            Ok(picture) => assert_eq!(
                picture.y.len(),
                picture.width * picture.height,
                "corrupted input produced an inconsistent picture"
            ),
            Err(err) => assert!(matches!(
                err.kind(),
                KeyframeDecodeErrorKind::MalformedBitstream(_)
                    | KeyframeDecodeErrorKind::UnsupportedCodec(_)
                    | KeyframeDecodeErrorKind::LimitExceeded(_)
            )),
        }
    }
}

fn baseline_sps(mbs: [u32; 2], crop: [u32; 4], matrix: u8, full: bool) -> Vec<u8> {
    let mut w = BitWriter::new();
    w.write_bits(0x42401f, 24);
    for value in [0, 0, 0, 4, 1] {
        w.write_ue(value);
    }
    w.write_bit(false);
    w.write_ue(mbs[0] - 1);
    w.write_ue(mbs[1] - 1);
    w.write_bit(true);
    w.write_bit(true);
    w.write_bit(true);
    for offset in crop {
        w.write_ue(offset);
    }
    w.write_bit(true);
    w.write_bit(false);
    w.write_bit(false);
    w.write_bit(true);
    w.write_bits(5, 3);
    w.write_bit(full);
    w.write_bit(true);
    w.write_bits(0x0202, 16);
    w.write_bits(u32::from(matrix), 8);
    w.write_bits(0, 6);
    w.rbsp_trailing_bits();
    NalUnit::new(3, NalUnitType::Sps, w.into_bytes()).to_annex_b()[4..].to_vec()
}

fn idr_header(mb: u32, qp_delta: i32, deblocking_control: bool) -> BitWriter {
    let mut w = BitWriter::new();
    for value in [mb, 7, 0] {
        w.write_ue(value);
    }
    w.write_bits(0, 4);
    w.write_ue(0);
    w.write_bits(0, 8);
    w.write_bits(0, 2);
    w.write_se(qp_delta);
    if deblocking_control {
        // Disable filtering for exact PCM samples until the decoder uses deblocking QP zero.
        w.write_ue(1);
    }
    w
}

fn pcm_slice(mb: u32) -> Vec<u8> {
    pcm_slice_with_header(mb..mb + 1, idr_header(mb, 0, true))
}

fn pcm_slice_with_header(macroblocks: std::ops::Range<u32>, mut w: BitWriter) -> Vec<u8> {
    for mb in macroblocks {
        w.write_ue(25);
        w.align_zero();
        for (size, base) in [(16, 100), (8, 90), (8, 180)] {
            for y in 0..size {
                for x in 0..size {
                    w.write_bits(base + mb % 2 * size + x + mb / 2 * size + y, 8);
                }
            }
        }
    }
    w.rbsp_trailing_bits();
    NalUnit::new(3, NalUnitType::IdrSlice, w.into_bytes()).to_annex_b()[4..].to_vec()
}

#[test]
fn complete_two_slice_idr_is_refused() {
    let stream = encode_idr(EncoderConfig::baseline(32, 16), &pattern(32, 16));
    let nals = annex_b_nals(&stream);
    let pps = nals_of_type(&nals, 8)[0];
    let sps = baseline_sps([2, 1], [0; 4], 2, false);
    let err = decode_access_unit(&[&sps, pps], &[&pcm_slice(0), &pcm_slice(1)]).unwrap_err();
    assert_eq!(err.reason(), "unsupported_codec");
    assert_eq!(err.detail(), "multi-slice pictures not yet supported");
}

#[test]
fn single_slice_four_sided_crop_preserves_luma_and_chroma_coordinates() {
    let stream = encode_idr(EncoderConfig::baseline(32, 32), &pattern(32, 32));
    let nals = annex_b_nals(&stream);
    let pps = nals_of_type(&nals, 8)[0];
    let sps = baseline_sps([2, 2], [2, 1, 3, 2], 2, false);
    let slice = pcm_slice_with_header(0..4, idr_header(0, 0, true));
    let picture =
        decode_access_unit(&[pps, &sps], &[&slice]).expect("cropped single-slice picture");
    assert_eq!((picture.width, picture.height), (26, 22));
    for (plane, width, height, first) in [
        (&picture.y, 26, 22, 100 + 4 + 6),
        (&picture.u, 13, 11, 90 + 2 + 3),
        (&picture.v, 13, 11, 180 + 2 + 3),
    ] {
        for y in 0..height {
            for x in 0..width {
                assert_eq!(plane[y * width + x], (first + x + y) as u8);
            }
        }
    }
}

#[test]
fn avc3_replacement_decodes_with_only_the_active_parameter_sets() {
    let source = pattern(W, H);
    let stream = encode_idr(EncoderConfig::baseline(W, H), &source);
    let nals = annex_b_nals(&stream);
    let sps = nals_of_type(&nals, 7)[0];
    let pps = nals_of_type(&nals, 8)[0];
    let idr = nals_of_type(&nals, 5)[0];
    let bytes = build_init_mp4(
        W as u32,
        H as u32,
        90_000,
        b"avc3",
        &avcc_box(&[&high10_sps()], &[pps]),
    );
    let init = parse_init_segment(&bytes).unwrap();
    let bytes = build_fragment_m4s(0, 0, 1, 90_000, &[sps, pps, idr]);
    let fragment = parse_media_fragment(&bytes, &init).unwrap();
    let frame = DefaultKeyframeDecoder
        .decode_keyframe(&init, &fragment)
        .unwrap();
    let (mean, max) = rgb_error_vs_source(&frame, &source);
    assert!(mean < 3.0 && max < 40.0);
}

#[test]
fn avc1_uses_its_sample_entry_and_refuses_auxiliary_and_extension_slices() {
    let source = pattern(W, H);
    let stream = encode_idr(EncoderConfig::baseline(W, H), &source);
    let nals = annex_b_nals(&stream);
    let sps = nals_of_type(&nals, 7)[0];
    let pps = nals_of_type(&nals, 8)[0];
    let idr = nals_of_type(&nals, 5)[0];
    let init = parse_init_segment(&build_init_mp4(
        W as u32,
        H as u32,
        90_000,
        b"avc1",
        &avcc_box(&[sps], &[pps]),
    ))
    .unwrap();
    let replacement = high10_sps();
    let bytes = build_fragment_m4s(
        0,
        0,
        1,
        90_000,
        &[&replacement, pps, idr, &replacement, pps],
    );
    let fragment = parse_media_fragment(&bytes, &init).unwrap();
    let frame = DefaultKeyframeDecoder
        .decode_keyframe(&init, &fragment)
        .unwrap();
    let (mean, max) = rgb_error_vs_source(&frame, &source);
    assert!(mean < 3.0 && max < 40.0);
    for kind in [19, 20, 21] {
        let extension = [0x60 | kind, 0x80];
        for sample in [[idr, &extension], [&extension, idr]] {
            let bytes = build_fragment_m4s(0, 0, 1, 90_000, &sample);
            assert_eq!(
                parse_media_fragment(&bytes, &init)
                    .unwrap_err()
                    .error_class(),
                "unsupported_codec"
            );
        }
    }
}

fn quantizer_pps(cb: i32, cr: i32, initial_qp_minus26: i32, deblocking_control: bool) -> Vec<u8> {
    let mut w = BitWriter::new();
    w.write_ue(0);
    w.write_ue(0);
    w.write_bits(0, 2);
    for _ in 0..3 {
        w.write_ue(0);
    }
    w.write_bits(0, 3);
    w.write_se(initial_qp_minus26);
    w.write_se(0);
    w.write_se(cb);
    w.write_bits(u32::from(deblocking_control) << 2, 3);
    w.write_bits(0, 2);
    w.write_se(cr);
    w.rbsp_trailing_bits();
    NalUnit::new(3, NalUnitType::Pps, w.into_bytes()).to_annex_b()
}

#[test]
fn invalid_chroma_initial_and_slice_quantizers_are_malformed() {
    let sps = baseline_sps([1, 1], [0; 4], 2, false);
    for control in [false, true] {
        for (cb, cr, initial, delta) in [
            (-13, -13, 0, 0),
            (13, 13, 0, 0),
            (0, -13, 0, 0),
            (13, 0, 0, 0),
            (0, 0, -27, 1),
            (0, 0, 26, -1),
            (0, 0, -26, -1),
            (0, 0, 25, 1),
            (0, 0, i32::MAX - 1, 0),
        ] {
            let pps = quantizer_pps(cb, cr, initial, control);
            let slice = pcm_slice_with_header(0..1, idr_header(0, delta, control));
            assert_eq!(
                decode_access_unit(&[&sps, &pps[4..]], &[&slice])
                    .unwrap_err()
                    .reason(),
                "malformed_bitstream"
            );
        }
        for (chroma, initial, delta) in [(-12, -26, 51), (12, 25, -51)] {
            let pps = quantizer_pps(chroma, chroma, initial, control);
            let slice = pcm_slice_with_header(0..1, idr_header(0, delta, control));
            assert_eq!(
                decode_access_unit(&[&sps, &pps[4..]], &[&slice])
                    .unwrap()
                    .width,
                16
            );
        }
    }
}

#[test]
fn active_pps_requires_equal_chroma_qp_offsets_and_raster_slice_groups() {
    let cfg = EncoderConfig::new(16, 16);
    let sps = rusty_h264_encoder::Sps::from_config(&cfg)
        .to_nal()
        .to_annex_b();
    for (cb, cr) in [(0, 6), (-2, -2)] {
        let pps = quantizer_pps(cb, cr, 0, true);
        let picture = decode_access_unit(&[&sps[4..], &pps[4..]], &[&pcm_slice(0)]);
        if cb == cr {
            assert_eq!(picture.unwrap().y[0], 100);
        } else {
            assert_eq!(picture.unwrap_err().reason(), "unsupported_codec");
        }
    }
    let mut w = BitWriter::new();
    w.write_ue(0);
    w.write_ue(0);
    w.write_bits(0, 2);
    w.write_ue(1);
    w.write_ue(0);
    w.write_ue(0);
    w.write_ue(0);
    w.write_ue(0);
    w.write_ue(0);
    w.write_bits(0, 3);
    for _ in 0..3 {
        w.write_se(0);
    }
    w.write_bits(4, 3);
    w.rbsp_trailing_bits();
    let fmo = NalUnit::new(3, NalUnitType::Pps, w.into_bytes()).to_annex_b();
    assert_eq!(
        decode_access_unit(
            &[&baseline_sps([2, 1], [0; 4], 2, false), &fmo[4..]],
            &[&pcm_slice(1)]
        )
        .unwrap_err()
        .reason(),
        "unsupported_codec"
    );
}

#[test]
fn unsupported_chroma_format_is_classified_before_420_cropping() {
    let mut w = BitWriter::new();
    w.write_bits(0xf4001e, 24);
    w.write_ue(0);
    w.write_ue(3);
    w.write_bit(false);
    w.write_ue(0);
    w.write_ue(0);
    w.write_bits(0, 2);
    for value in [0, 0, 4, 1] {
        w.write_ue(value);
    }
    w.write_bit(false);
    w.write_ue(0);
    w.write_ue(0);
    w.write_bits(7, 3);
    for value in [8, 0, 0, 0] {
        w.write_ue(value);
    }
    w.write_bit(false);
    w.rbsp_trailing_bits();
    let sps = NalUnit::new(3, NalUnitType::Sps, w.into_bytes()).to_annex_b();
    let pps = rusty_h264_encoder::Pps::from_config(&EncoderConfig::baseline(16, 16))
        .to_nal()
        .to_annex_b();
    assert_eq!(
        decode_access_unit(&[&sps[4..], &pps[4..]], &[&pcm_slice(0)])
            .unwrap_err()
            .reason(),
        "unsupported_codec"
    );
}

#[test]
fn slice_escape_validation_includes_the_byte_beyond_the_header_prefix() {
    let sps = baseline_sps([1, 1], [0; 4], 2, false);
    let pps = rusty_h264_encoder::Pps::from_config(&EncoderConfig::baseline(16, 16))
        .to_nal()
        .to_annex_b();
    for start in [62, 130] {
        let mut slice = pcm_slice(0);
        slice[start..start + 3].copy_from_slice(&[0, 0, 1]);
        slice.insert(start + 2, 3);
        let good = decode_access_unit(&[&sps, &pps[4..]], &[&slice]).unwrap();
        assert!(good.y.windows(3).any(|bytes| bytes == [0, 0, 1]));
        slice[start + 3] = 4;
        assert_eq!(
            decode_access_unit(&[&sps, &pps[4..]], &[&slice])
                .unwrap_err()
                .reason(),
            "malformed_bitstream"
        );
    }
}

#[test]
fn access_unit_limit_counts_only_the_serialized_active_sets_and_slices() {
    let nals = annex_b_nals(HIGH_FIXTURE);
    let sps = nals_of_type(&nals, 7)[0];
    let pps = nals_of_type(&nals, 8)[0];
    let mut idr = nals_of_type(&nals, 5)[0].to_vec();
    let limit = crate::keyframe_decoder::MAX_KEYFRAME_ACCESS_UNIT_BYTES;
    let spare = limit - sps.len() - pps.len() - idr.len() - 12;
    for _ in 0..spare / 3 {
        idr.extend_from_slice(&[0, 0, 3]);
    }
    let inactive = high10_sps();
    let sets = [&inactive[..], sps, pps];
    let picture = decode_access_unit(&sets, &[&idr]).unwrap();
    let mut digest = Sha256::new();
    for plane in [&picture.y, &picture.u, &picture.v] {
        digest.update(plane);
    }
    assert_eq!(
        hex::encode(digest.finalize()),
        HIGH_FIXTURE_FFMPEG_I420_SHA256
    );
    idr.extend_from_slice(&[0, 0, 3]);
    assert_eq!(
        decode_access_unit(&sets, &[&idr]).unwrap_err().reason(),
        "limit_exceeded"
    );
}

#[test]
fn idr_admission_rejects_invalid_single_slice_headers_and_embedded_delimiters() {
    let stream = encode_idr(EncoderConfig::baseline(32, 32), &pattern(32, 32));
    let nals = annex_b_nals(&stream);
    let pps = nals_of_type(&nals, 8)[0];
    let sps = baseline_sps([2, 2], [0; 4], 2, false);
    let a = pcm_slice(0);
    let embedded = [a.as_slice(), &[0, 0, 1], a.as_slice()].concat();
    for slice in [pcm_slice(1), embedded] {
        assert_eq!(
            decode_access_unit(&[&sps, pps], &[&slice])
                .unwrap_err()
                .reason(),
            "malformed_bitstream"
        );
    }
    let mut invalid = idr_header(0, 0, true);
    invalid.write_ue(1);
    invalid.write_ue(4);
    invalid.rbsp_trailing_bits();
    let nal = NalUnit::new(3, NalUnitType::IdrSlice, invalid.into_bytes()).to_annex_b();
    assert_eq!(
        decode_access_unit(&[&sps, pps], &[&nal[4..]])
            .unwrap_err()
            .reason(),
        "malformed_bitstream"
    );
    for dims in [[1025, 1], [1, 1025]] {
        let oversized = baseline_sps(dims, [0; 4], 2, false);
        assert_eq!(
            decode_access_unit(&[&oversized, pps], &[&a])
                .unwrap_err()
                .reason(),
            "limit_exceeded"
        );
    }
}

#[test]
fn signalled_matrix_and_range_select_the_specified_rgb_transform() {
    let stream = encode_idr(EncoderConfig::baseline(16, 16), &pattern(16, 16));
    let nals = annex_b_nals(&stream);
    let pps = nals_of_type(&nals, 8)[0];
    let slice = pcm_slice(0);
    for code in 0..=u8::MAX {
        for full in [false, true] {
            let sps = baseline_sps([1, 1], [0; 4], code, full);
            let decoded = decode_access_unit(&[&sps, pps], &[&slice]);
            let expected = match (code, full) {
                (2 | 5 | 6, false) => [181, 70, 21],
                (2 | 5 | 6, true) => [173, 76, 33],
                (1, false) => [191, 78, 18],
                (1, true) => [182, 83, 29],
                (9, false) => [185, 71, 16],
                (9, true) => [177, 77, 29],
                _ => {
                    assert_eq!(
                        decoded.unwrap_err().reason(),
                        "unsupported_codec",
                        "matrix {code}"
                    );
                    continue;
                }
            };
            let rgb = crate::h264::picture_to_rgb(&decoded.unwrap()).unwrap();
            assert_eq!(rgb.pixel_at(0, 0), expected, "matrix {code}, full {full}");
        }
    }
}
