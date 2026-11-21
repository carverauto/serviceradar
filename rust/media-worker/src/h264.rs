//! H.264 IDR keyframe decode: parameter-set admission, the `rusty_h264-decoder` call and
//! colour-correct YUV 4:2:0 to RGB8 conversion.
//!
//! Parameter sets are parsed here before any decoder runs, for three reasons: to refuse
//! profiles and formats outside the supported set with a typed error, to refuse oversized
//! pictures before anything allocates for them, and to read the VUI colour description,
//! which the decoder ignores.

use crate::cmaf::{MAX_FRAME_DIMENSION, ParsedInitSegment, ParsedMediaFragment};
use crate::keyframe_decoder::{
    KeyframeDecodeError, MAX_KEYFRAME_ACCESS_UNIT_BYTES, MAX_KEYFRAME_SLICES,
    MAX_PARAMETER_SET_BYTES,
};
use crate::vision::RgbFrame;
use std::collections::HashMap;

const NAL_SPS: u8 = 7;
const NAL_PPS: u8 = 8;
const NAL_IDR: u8 = 5;

const PROFILE_BASELINE: u8 = 66;
const PROFILE_MAIN: u8 = 77;
const PROFILE_HIGH: u8 = 100;

/// `profile_idc` values whose SPS carries `chroma_format_idc`, bit depths and scaling lists
/// (ITU-T H.264 7.3.2.1.1).
const HIGH_FAMILY_PROFILES: [u8; 13] =
    [100, 110, 122, 244, 44, 83, 86, 118, 128, 138, 139, 134, 135];

/// Luma/chroma matrix used for YCbCr to RGB.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum YuvMatrix {
    Bt601,
    Bt709,
    Bt2020,
}

/// Colour interpretation of a decoded picture.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct ColourSpec {
    pub(crate) matrix: YuvMatrix,
    pub(crate) full_range: bool,
}

/// The fields of an SPS this module acts on.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct SpsInfo {
    pub(crate) sps_id: u32,
    pub(crate) profile_idc: u8,
    pub(crate) chroma_format_idc: u32,
    pub(crate) bit_depth_luma: u32,
    pub(crate) bit_depth_chroma: u32,
    pub(crate) coded_width: u32,
    pub(crate) coded_height: u32,
    pub(crate) display_width: u32,
    pub(crate) display_height: u32,
    /// `video_full_range_flag`, when the VUI carries a video signal type.
    pub(crate) full_range: Option<bool>,
    /// `matrix_coefficients`, when the VUI carries a colour description.
    pub(crate) matrix_coefficients: Option<u8>,
}

/// A decoded, cropped I420 picture.
#[derive(Debug, Clone)]
pub(crate) struct DecodedPicture {
    pub(crate) width: usize,
    pub(crate) height: usize,
    pub(crate) y: Vec<u8>,
    pub(crate) u: Vec<u8>,
    pub(crate) v: Vec<u8>,
    pub(crate) colour: ColourSpec,
}

/// Decodes the IDR keyframe of `fragment` (H.264) to RGB8.
pub(crate) fn decode_keyframe(
    init: &ParsedInitSegment,
    fragment: &ParsedMediaFragment,
) -> Result<RgbFrame, KeyframeDecodeError> {
    let parameter_sets: Vec<&[u8]> = init
        .parameter_sets()
        .iter()
        .chain(fragment.in_band_parameter_sets())
        .map(Vec::as_slice)
        .collect();
    let slices: Vec<&[u8]> = fragment.idr_nal_units().iter().map(Vec::as_slice).collect();
    let picture = decode_access_unit(&parameter_sets, &slices)?;
    picture_to_rgb(&picture)
}

/// Decodes one IDR access unit, given its parameter sets (init segment first, then in-band,
/// so a later set with the same id wins) and its IDR slice NAL units, all without start
/// codes or length prefixes.
pub(crate) fn decode_access_unit(
    parameter_sets: &[&[u8]],
    slices: &[&[u8]],
) -> Result<DecodedPicture, KeyframeDecodeError> {
    if slices.is_empty() {
        return Err(KeyframeDecodeError::malformed_bitstream(
            "keyframe sample carries no IDR slice",
        ));
    }
    if slices.len() > MAX_KEYFRAME_SLICES {
        return Err(KeyframeDecodeError::limit_exceeded(format!(
            "{} IDR slices exceed the limit of {MAX_KEYFRAME_SLICES}",
            slices.len()
        )));
    }

    let mut sps_by_id: HashMap<u32, SpsInfo> = HashMap::new();
    let mut pps_to_sps: HashMap<u32, u32> = HashMap::new();
    let mut total_bytes = 0usize;
    let mut kept_parameter_sets: Vec<&[u8]> = Vec::with_capacity(parameter_sets.len());
    for nal in parameter_sets {
        if nal.len() > MAX_PARAMETER_SET_BYTES {
            return Err(KeyframeDecodeError::limit_exceeded(format!(
                "parameter set of {} bytes exceeds the limit of {MAX_PARAMETER_SET_BYTES}",
                nal.len()
            )));
        }
        match nal_type(nal) {
            Some(NAL_SPS) => {
                let sps = parse_sps(nal)?;
                sps_by_id.insert(sps.sps_id, sps);
            }
            Some(NAL_PPS) => {
                let (pps_id, sps_id) = parse_pps_ids(nal)?;
                pps_to_sps.insert(pps_id, sps_id);
            }
            // Anything else in an avcC (SPS extension) or in-band is not needed for an IDR.
            _ => continue,
        }
        total_bytes = total_bytes.saturating_add(nal.len() + 4);
        kept_parameter_sets.push(nal);
    }

    for slice in slices {
        if nal_type(slice) != Some(NAL_IDR) {
            return Err(KeyframeDecodeError::malformed_bitstream(
                "keyframe slice list contains a non-IDR NAL unit",
            ));
        }
        total_bytes = total_bytes.saturating_add(slice.len() + 4);
    }
    if total_bytes > MAX_KEYFRAME_ACCESS_UNIT_BYTES {
        return Err(KeyframeDecodeError::limit_exceeded(format!(
            "keyframe access unit of {total_bytes} bytes exceeds the limit of \
             {MAX_KEYFRAME_ACCESS_UNIT_BYTES}"
        )));
    }

    let (first_mb, pps_id) = parse_slice_header_start(slices[0])?;
    if first_mb != 0 {
        // Arbitrary slice order is not supported; without a slice at macroblock 0 the
        // picture cannot be complete.
        return Err(KeyframeDecodeError::malformed_bitstream(format!(
            "first IDR slice starts at macroblock {first_mb}, not 0"
        )));
    }
    let sps_id = *pps_to_sps.get(&pps_id).ok_or_else(|| {
        KeyframeDecodeError::malformed_bitstream(format!(
            "IDR slice references PPS {pps_id}, which is not present"
        ))
    })?;
    let sps = sps_by_id.get(&sps_id).ok_or_else(|| {
        KeyframeDecodeError::malformed_bitstream(format!(
            "PPS {pps_id} references SPS {sps_id}, which is not present"
        ))
    })?;
    admit_sps(sps)?;
    let colour = colour_spec(sps)?;

    let mut annex_b = Vec::with_capacity(total_bytes);
    for nal in kept_parameter_sets.iter().chain(slices) {
        annex_b.extend_from_slice(&[0, 0, 0, 1]);
        annex_b.extend_from_slice(nal);
    }

    // A fresh decoder per keyframe: no state carries from one (possibly hostile) keyframe
    // into the next.
    let mut decoder = rusty_h264_decoder::Decoder::new();
    let frame = match decoder.decode(&annex_b) {
        Ok(Some(frame)) => frame,
        Ok(None) => {
            return Err(KeyframeDecodeError::malformed_bitstream(
                "IDR slices do not cover a complete picture",
            ));
        }
        Err(rusty_h264_decoder::DecodeError::Unsupported(tool)) => {
            return Err(KeyframeDecodeError::unsupported_codec(format!(
                "h264 coding tool not supported: {tool}"
            )));
        }
        Err(err) => {
            return Err(KeyframeDecodeError::malformed_bitstream(format!(
                "h264 decode failed: {err}"
            )));
        }
    };

    let (width, height) = (frame.width, frame.height);
    let luma_len = width.checked_mul(height);
    let chroma_len = (width / 2).checked_mul(height / 2);
    if width != sps.display_width as usize
        || height != sps.display_height as usize
        || width % 2 != 0
        || height % 2 != 0
        || luma_len != Some(frame.y.len())
        || chroma_len != Some(frame.u.len())
        || chroma_len != Some(frame.v.len())
    {
        return Err(KeyframeDecodeError::malformed_bitstream(format!(
            "decoded picture {width}x{height} does not match the SPS display size {}x{}",
            sps.display_width, sps.display_height
        )));
    }

    Ok(DecodedPicture {
        width,
        height,
        y: frame.y,
        u: frame.u,
        v: frame.v,
        colour,
    })
}

fn nal_type(nal: &[u8]) -> Option<u8> {
    let header = *nal.first()?;
    (header & 0x80 == 0).then_some(header & 0x1f)
}

fn admit_sps(sps: &SpsInfo) -> Result<(), KeyframeDecodeError> {
    if !matches!(
        sps.profile_idc,
        PROFILE_BASELINE | PROFILE_MAIN | PROFILE_HIGH
    ) {
        return Err(KeyframeDecodeError::unsupported_codec(format!(
            "h264 profile_idc {} (supported: 66 Baseline, 77 Main, 100 High)",
            sps.profile_idc
        )));
    }
    if sps.chroma_format_idc != 1 {
        return Err(KeyframeDecodeError::unsupported_codec(format!(
            "h264 chroma_format_idc {} (supported: 1, 4:2:0)",
            sps.chroma_format_idc
        )));
    }
    if sps.bit_depth_luma != 8 || sps.bit_depth_chroma != 8 {
        return Err(KeyframeDecodeError::unsupported_codec(format!(
            "h264 bit depth {}/{} (supported: 8-bit)",
            sps.bit_depth_luma, sps.bit_depth_chroma
        )));
    }
    if sps.coded_width > MAX_FRAME_DIMENSION || sps.coded_height > MAX_FRAME_DIMENSION {
        return Err(KeyframeDecodeError::limit_exceeded(format!(
            "coded picture {}x{} exceeds the {MAX_FRAME_DIMENSION}x{MAX_FRAME_DIMENSION} limit",
            sps.coded_width, sps.coded_height
        )));
    }
    Ok(())
}

/// Picks the YCbCr matrix and range from the VUI. Absent or unspecified values default to
/// limited range and, by picture height, BT.601 (576 lines or fewer) or BT.709 (taller).
fn colour_spec(sps: &SpsInfo) -> Result<ColourSpec, KeyframeDecodeError> {
    let by_size = if sps.display_height > 576 {
        YuvMatrix::Bt709
    } else {
        YuvMatrix::Bt601
    };
    let matrix = match sps.matrix_coefficients {
        Some(1) | Some(7) => YuvMatrix::Bt709,
        Some(4..=6) => YuvMatrix::Bt601,
        Some(9) | Some(10) => YuvMatrix::Bt2020,
        Some(code @ (0 | 8 | 11..=14)) => {
            return Err(KeyframeDecodeError::unsupported_codec(format!(
                "h264 VUI matrix_coefficients {code} is not a supported YCbCr matrix"
            )));
        }
        // 2 = unspecified, 3 and 15..=255 = reserved.
        _ => by_size,
    };
    Ok(ColourSpec {
        matrix,
        full_range: sps.full_range.unwrap_or(false),
    })
}

/// Converts a decoded I420 picture to packed RGB8. Chroma is upsampled by sample
/// replication (each chroma sample covers its 2x2 luma block).
pub(crate) fn picture_to_rgb(picture: &DecodedPicture) -> Result<RgbFrame, KeyframeDecodeError> {
    let (width, height) = (picture.width, picture.height);
    let coeffs = RgbCoefficients::new(picture.colour);
    let chroma_width = width / 2;
    let mut rgb = vec![0u8; width * height * 3];
    for (row, out_row) in rgb.chunks_exact_mut(width * 3).enumerate() {
        let y_row = &picture.y[row * width..(row + 1) * width];
        let c_start = (row / 2) * chroma_width;
        let u_row = &picture.u[c_start..c_start + chroma_width];
        let v_row = &picture.v[c_start..c_start + chroma_width];
        for (col, px) in out_row.as_chunks_mut::<3>().0.iter_mut().enumerate() {
            *px = coeffs.convert(y_row[col], u_row[col / 2], v_row[col / 2]);
        }
    }
    let width = u32::try_from(width)
        .map_err(|_| KeyframeDecodeError::limit_exceeded("picture width overflows u32"))?;
    let height = u32::try_from(height)
        .map_err(|_| KeyframeDecodeError::limit_exceeded("picture height overflows u32"))?;
    RgbFrame::from_rgb8(width, height, rgb)
        .map_err(|err| KeyframeDecodeError::malformed_bitstream(err.to_string()))
}

/// 16.16 fixed-point YCbCr to RGB coefficients for one matrix and range.
#[derive(Debug, Clone, Copy)]
struct RgbCoefficients {
    y_offset: i32,
    y_scale: i32,
    r_v: i32,
    g_u: i32,
    g_v: i32,
    b_u: i32,
}

impl RgbCoefficients {
    fn new(colour: ColourSpec) -> Self {
        let (kr, kb) = match colour.matrix {
            YuvMatrix::Bt601 => (0.299_f64, 0.114_f64),
            YuvMatrix::Bt709 => (0.2126, 0.0722),
            YuvMatrix::Bt2020 => (0.2627, 0.0593),
        };
        let kg = 1.0 - kr - kb;
        let (y_offset, y_scale, c_scale) = if colour.full_range {
            (0, 1.0, 1.0)
        } else {
            (16, 255.0 / 219.0, 255.0 / 224.0)
        };
        let fixed = |v: f64| (v * 65_536.0).round() as i32;
        Self {
            y_offset,
            y_scale: fixed(y_scale),
            r_v: fixed(c_scale * 2.0 * (1.0 - kr)),
            g_u: fixed(c_scale * 2.0 * kb * (1.0 - kb) / kg),
            g_v: fixed(c_scale * 2.0 * kr * (1.0 - kr) / kg),
            b_u: fixed(c_scale * 2.0 * (1.0 - kb)),
        }
    }

    fn convert(&self, y: u8, u: u8, v: u8) -> [u8; 3] {
        let y = (i32::from(y) - self.y_offset) * self.y_scale;
        let u = i32::from(u) - 128;
        let v = i32::from(v) - 128;
        let clamp = |value: i32| ((value + 32_768) >> 16).clamp(0, 255) as u8;
        [
            clamp(y + self.r_v * v),
            clamp(y - self.g_u * u - self.g_v * v),
            clamp(y + self.b_u * u),
        ]
    }
}

// ---------------------------------------------------------------------------------------
// Bitstream parsing
// ---------------------------------------------------------------------------------------

/// Removes emulation-prevention bytes (`00 00 03` -> `00 00`) from a NAL payload.
fn rbsp_from_nal_payload(payload: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(payload.len());
    let mut zeros = 0usize;
    for &byte in payload {
        if zeros >= 2 && byte == 3 {
            zeros = 0;
            continue;
        }
        zeros = if byte == 0 { zeros + 1 } else { 0 };
        out.push(byte);
    }
    out
}

struct BitReader<'a> {
    data: &'a [u8],
    bit: usize,
}

impl<'a> BitReader<'a> {
    fn new(data: &'a [u8]) -> Self {
        Self { data, bit: 0 }
    }

    fn read_bit(&mut self) -> Result<u32, KeyframeDecodeError> {
        let byte = self.data.get(self.bit / 8).ok_or_else(|| {
            KeyframeDecodeError::malformed_bitstream("h264 parameter set truncated")
        })?;
        let value = (byte >> (7 - (self.bit % 8))) & 1;
        self.bit += 1;
        Ok(u32::from(value))
    }

    fn read_bits(&mut self, count: u32) -> Result<u32, KeyframeDecodeError> {
        let mut value = 0u32;
        for _ in 0..count {
            value = (value << 1) | self.read_bit()?;
        }
        Ok(value)
    }

    fn read_flag(&mut self) -> Result<bool, KeyframeDecodeError> {
        Ok(self.read_bit()? == 1)
    }

    fn read_ue(&mut self) -> Result<u32, KeyframeDecodeError> {
        let mut leading_zeros = 0u32;
        while self.read_bit()? == 0 {
            leading_zeros += 1;
            if leading_zeros > 31 {
                return Err(KeyframeDecodeError::malformed_bitstream(
                    "h264 Exp-Golomb code longer than 32 bits",
                ));
            }
        }
        let suffix = self.read_bits(leading_zeros)?;
        let value = (1u64 << leading_zeros) - 1 + u64::from(suffix);
        u32::try_from(value).map_err(|_| {
            KeyframeDecodeError::malformed_bitstream("h264 Exp-Golomb value overflows u32")
        })
    }

    fn read_se(&mut self) -> Result<i64, KeyframeDecodeError> {
        let code = i64::from(self.read_ue()?);
        Ok(if code % 2 == 1 {
            (code + 1) / 2
        } else {
            -(code / 2)
        })
    }

    fn read_ue_max(&mut self, max: u32, field: &str) -> Result<u32, KeyframeDecodeError> {
        let value = self.read_ue()?;
        if value > max {
            return Err(KeyframeDecodeError::malformed_bitstream(format!(
                "h264 {field} {value} exceeds {max}"
            )));
        }
        Ok(value)
    }
}

fn nal_rbsp(nal: &[u8]) -> Result<Vec<u8>, KeyframeDecodeError> {
    match nal.get(1..) {
        Some(payload) if !payload.is_empty() => Ok(rbsp_from_nal_payload(payload)),
        _ => Err(KeyframeDecodeError::malformed_bitstream(
            "h264 NAL unit has no payload",
        )),
    }
}

/// Parses the SPS fields this module needs (ITU-T H.264 7.3.2.1.1 and E.1.1).
pub(crate) fn parse_sps(nal: &[u8]) -> Result<SpsInfo, KeyframeDecodeError> {
    let rbsp = nal_rbsp(nal)?;
    let mut r = BitReader::new(&rbsp);
    let profile_idc = r.read_bits(8)? as u8;
    let _constraint_flags_and_reserved = r.read_bits(8)?;
    let _level_idc = r.read_bits(8)?;
    let sps_id = r.read_ue_max(31, "seq_parameter_set_id")?;

    let mut chroma_format_idc = 1;
    let mut bit_depth_luma = 8;
    let mut bit_depth_chroma = 8;
    if HIGH_FAMILY_PROFILES.contains(&profile_idc) {
        chroma_format_idc = r.read_ue_max(3, "chroma_format_idc")?;
        if chroma_format_idc == 3 {
            let _separate_colour_plane = r.read_flag()?;
        }
        bit_depth_luma = 8 + r.read_ue_max(6, "bit_depth_luma_minus8")?;
        bit_depth_chroma = 8 + r.read_ue_max(6, "bit_depth_chroma_minus8")?;
        let _qpprime_y_zero_transform_bypass = r.read_flag()?;
        if r.read_flag()? {
            let lists = if chroma_format_idc == 3 { 12 } else { 8 };
            for index in 0..lists {
                if r.read_flag()? {
                    skip_scaling_list(&mut r, if index < 6 { 16 } else { 64 })?;
                }
            }
        }
    }

    let _log2_max_frame_num_minus4 = r.read_ue_max(12, "log2_max_frame_num_minus4")?;
    match r.read_ue_max(2, "pic_order_cnt_type")? {
        0 => {
            let _log2_max_poc_lsb_minus4 =
                r.read_ue_max(12, "log2_max_pic_order_cnt_lsb_minus4")?;
        }
        1 => {
            let _delta_pic_order_always_zero = r.read_flag()?;
            let _offset_for_non_ref_pic = r.read_se()?;
            let _offset_for_top_to_bottom_field = r.read_se()?;
            let cycle = r.read_ue_max(255, "num_ref_frames_in_pic_order_cnt_cycle")?;
            for _ in 0..cycle {
                let _offset_for_ref_frame = r.read_se()?;
            }
        }
        _ => {}
    }
    let _max_num_ref_frames = r.read_ue()?;
    let _gaps_in_frame_num_allowed = r.read_flag()?;
    // Bounded so the multiplications below cannot overflow; the admission check applies the
    // real dimension limit.
    let width_in_mbs = r.read_ue_max(1023, "pic_width_in_mbs_minus1")? + 1;
    let height_in_map_units = r.read_ue_max(1023, "pic_height_in_map_units_minus1")? + 1;
    let frame_mbs_only = r.read_flag()?;
    if !frame_mbs_only {
        let _mb_adaptive_frame_field = r.read_flag()?;
    }
    let _direct_8x8_inference = r.read_flag()?;
    let coded_width = width_in_mbs * 16;
    let coded_height = height_in_map_units * 16 * if frame_mbs_only { 1 } else { 2 };

    let (mut crop_x, mut crop_y) = (0u32, 0u32);
    if r.read_flag()? {
        let left = r.read_ue()?;
        let right = r.read_ue()?;
        let top = r.read_ue()?;
        let bottom = r.read_ue()?;
        // CropUnitX/Y for 4:2:0 (7-19, 7-20); other formats are refused at admission, so
        // their display size is never used.
        let unit_y = if frame_mbs_only { 2 } else { 4 };
        crop_x = left
            .checked_add(right)
            .and_then(|sum| sum.checked_mul(2))
            .unwrap_or(u32::MAX);
        crop_y = top
            .checked_add(bottom)
            .and_then(|sum| sum.checked_mul(unit_y))
            .unwrap_or(u32::MAX);
        if crop_x >= coded_width || crop_y >= coded_height {
            return Err(KeyframeDecodeError::malformed_bitstream(
                "h264 SPS cropping window exceeds the coded picture",
            ));
        }
    }

    let (full_range, matrix_coefficients) = if r.read_flag()? {
        // The VUI does not affect decoding. A VUI that cannot be read as far as the colour
        // description falls back to the defaults instead of rejecting a decodable picture.
        parse_vui_colour(&mut r).unwrap_or((None, None))
    } else {
        (None, None)
    };

    Ok(SpsInfo {
        sps_id,
        profile_idc,
        chroma_format_idc,
        bit_depth_luma,
        bit_depth_chroma,
        coded_width,
        coded_height,
        display_width: coded_width - crop_x,
        display_height: coded_height - crop_y,
        full_range,
        matrix_coefficients,
    })
}

fn skip_scaling_list(r: &mut BitReader<'_>, size: usize) -> Result<(), KeyframeDecodeError> {
    let mut last_scale = 8i64;
    let mut next_scale = 8i64;
    for _ in 0..size {
        if next_scale != 0 {
            let delta = r.read_se()?;
            if !(-128..=127).contains(&delta) {
                return Err(KeyframeDecodeError::malformed_bitstream(
                    "h264 scaling list delta_scale out of range",
                ));
            }
            next_scale = (last_scale + delta + 256) % 256;
        }
        if next_scale != 0 {
            last_scale = next_scale;
        }
    }
    Ok(())
}

/// Reads the VUI as far as the colour description (E.1.1).
fn parse_vui_colour(
    r: &mut BitReader<'_>,
) -> Result<(Option<bool>, Option<u8>), KeyframeDecodeError> {
    if r.read_flag()? {
        let aspect_ratio_idc = r.read_bits(8)?;
        if aspect_ratio_idc == 255 {
            let _sar_width = r.read_bits(16)?;
            let _sar_height = r.read_bits(16)?;
        }
    }
    if r.read_flag()? {
        let _overscan_appropriate = r.read_flag()?;
    }
    if !r.read_flag()? {
        return Ok((None, None));
    }
    let _video_format = r.read_bits(3)?;
    let full_range = r.read_flag()?;
    let matrix = if r.read_flag()? {
        let _colour_primaries = r.read_bits(8)?;
        let _transfer_characteristics = r.read_bits(8)?;
        Some(r.read_bits(8)? as u8)
    } else {
        None
    };
    Ok((Some(full_range), matrix))
}

/// Returns `(pic_parameter_set_id, seq_parameter_set_id)` of a PPS.
fn parse_pps_ids(nal: &[u8]) -> Result<(u32, u32), KeyframeDecodeError> {
    let rbsp = nal_rbsp(nal)?;
    let mut r = BitReader::new(&rbsp);
    let pps_id = r.read_ue_max(255, "pic_parameter_set_id")?;
    let sps_id = r.read_ue_max(31, "seq_parameter_set_id")?;
    Ok((pps_id, sps_id))
}

/// Returns `(first_mb_in_slice, pic_parameter_set_id)` of a slice header.
fn parse_slice_header_start(nal: &[u8]) -> Result<(u32, u32), KeyframeDecodeError> {
    // The three leading Exp-Golomb fields fit well inside the first 16 payload bytes.
    let head = nal.get(1..nal.len().min(17)).unwrap_or_default();
    let rbsp = rbsp_from_nal_payload(head);
    let mut r = BitReader::new(&rbsp);
    let first_mb_in_slice = r.read_ue()?;
    let _slice_type = r.read_ue_max(9, "slice_type")?;
    let pps_id = r.read_ue_max(255, "pic_parameter_set_id")?;
    Ok((first_mb_in_slice, pps_id))
}
