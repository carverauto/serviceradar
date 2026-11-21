//! Keyframe decoder tests. Every bitstream here is generated from a programmatic test
//! pattern: in-test with the pure-Rust `rusty_h264-encoder`, or (one High-profile fixture)
//! offline with x264 from the pattern described on `HIGH_FIXTURE`. No camera media.

use crate::cmaf::{avcc_box, build_fragment_m4s, build_init_mp4};
use crate::h264::{decode_access_unit, parse_sps};
use crate::keyframe_decoder::{
    DefaultKeyframeDecoder, KeyframeDecodeErrorKind, KeyframeDecoder, MAX_KEYFRAME_SLICES,
};
use crate::{
    ParsedInitSegment, ParsedMediaFragment, RgbFrame, parse_init_segment, parse_media_fragment,
};
use rusty_h264_common::{Profile, YuvFrame};
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
        let sps = parse_sps(nals_of_type(&nals, 7)[0]).expect("parse encoder SPS");
        assert_eq!(
            sps.profile_idc, profile_idc,
            "{label}: profile actually encoded"
        );
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
    // IDR_W_RADL (type 19) NAL header followed by arbitrary slice bytes.
    let idr: [u8; 8] = [0x26, 0x01, 0xaf, 0x10, 0x22, 0x5c, 0x81, 0x3e];
    let fragment_bytes = build_fragment_m4s(0, 0, 2_000_000_000, 90_000, &[&idr]);
    let init = parse_init_segment(&init_bytes).expect("parse hvc1 init");
    let fragment = parse_media_fragment(&fragment_bytes, &init).expect("parse hevc fragment");

    let err = DefaultKeyframeDecoder::new()
        .decode_keyframe(&init, &fragment)
        .expect_err("HEVC must not yield a frame");
    assert_eq!(err.reason(), "unsupported_codec");
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
    let too_many_slices = vec![slice; MAX_KEYFRAME_SLICES + 1];
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
            "limit_exceeded",
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
