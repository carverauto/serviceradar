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
struct SpsInfo {
    frame_num_bits: u32,
    frame_mbs_only: bool,
    poc_lsb_bits: Option<u32>,
    delta_poc_present: bool,
    crop_left: u32,
    crop_top: u32,
    coded_width: u32,
    coded_height: u32,
    display_width: u32,
    display_height: u32,
    /// `video_full_range_flag`, when the VUI carries a video signal type.
    full_range: Option<bool>,
    /// `matrix_coefficients`, when the VUI carries a colour description.
    matrix_coefficients: Option<u8>,
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

    let mut sps_by_id = HashMap::new();
    let mut pps_by_id = HashMap::new();
    for &nal in parameter_sets {
        if nal.len() > MAX_PARAMETER_SET_BYTES {
            return Err(KeyframeDecodeError::limit_exceeded(
                "parameter set exceeds byte limit",
            ));
        }
        match nal_type(nal) {
            Some(NAL_SPS) => {
                let rbsp = nal_rbsp(nal, 16)?;
                let mut reader = BitReader::new(&rbsp);
                reader.read_bits(24)?;
                sps_by_id.insert(reader.read_ue_max(31, "seq_parameter_set_id")?, nal);
            }
            Some(NAL_PPS) => {
                let rbsp = nal_rbsp(nal, 16)?;
                let mut reader = BitReader::new(&rbsp);
                pps_by_id.insert(reader.read_ue_max(255, "pic_parameter_set_id")?, nal);
            }
            _ => continue,
        }
    }
    let slice_bytes: usize = slices.iter().map(|slice| slice.len() + 4).sum();
    if slice_bytes > MAX_KEYFRAME_ACCESS_UNIT_BYTES {
        return Err(KeyframeDecodeError::limit_exceeded(
            "keyframe access unit exceeds byte limit",
        ));
    }

    let headers: Vec<_> = slices
        .iter()
        .map(|slice| slice_header_prefix(slice))
        .collect::<Result<_, _>>()?;
    let (_, _, pps_id) = slice_start(&mut BitReader::new(&headers[0]))?;
    let pps = *pps_by_id.get(&pps_id).ok_or_else(|| {
        KeyframeDecodeError::malformed_bitstream("IDR slice references missing PPS")
    })?;
    let pps_rbsp = nal_rbsp(pps, pps.len())?;
    let mut r = BitReader::new(&pps_rbsp);
    r.read_ue()?;
    let sps_id = r.read_ue_max(31, "seq_parameter_set_id")?;
    let sps_nal = *sps_by_id
        .get(&sps_id)
        .ok_or_else(|| KeyframeDecodeError::malformed_bitstream("PPS references missing SPS"))?;
    let sps = parse_sps(sps_nal)?;
    let active_pps = rusty_h264_decoder::Pps::parse(&pps_rbsp).map_err(classify_decode_error)?;
    if active_pps.chroma_qp_index_offset != active_pps.second_chroma_qp_index_offset {
        return Err(KeyframeDecodeError::unsupported_codec(
            "unequal Cb and Cr QP offsets",
        ));
    }
    let colour = colour_spec(&sps)?;

    let total_bytes = slice_bytes + sps_nal.len() + pps.len() + 8;
    if total_bytes > MAX_KEYFRAME_ACCESS_UNIT_BYTES {
        return Err(KeyframeDecodeError::limit_exceeded(
            "keyframe access unit exceeds byte limit",
        ));
    }
    validate_picture_slices(
        &headers,
        pps_id,
        &sps,
        active_pps.bottom_field_pic_order_present,
    )?;

    let mut annex_b = Vec::with_capacity(total_bytes);
    for nal in [sps_nal, pps].into_iter().chain(slices.iter().copied()) {
        annex_b.extend_from_slice(&[0, 0, 0, 1]);
        annex_b.extend_from_slice(nal);
    }
    let frame = rusty_h264_decoder::Decoder::new()
        .decode(&annex_b)
        .map_err(classify_decode_error)?
        .ok_or_else(|| KeyframeDecodeError::malformed_bitstream("incomplete IDR picture"))?;

    let (width, height) = (frame.width, frame.height);
    let luma_len = width.checked_mul(height);
    let chroma_len = (width / 2).checked_mul(height / 2);
    if width != (sps.display_width + sps.crop_left) as usize
        || height != (sps.display_height + sps.crop_top) as usize
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
        width: sps.display_width as usize,
        height: sps.display_height as usize,
        y: crop_plane(
            frame.y,
            width,
            sps.crop_left as usize,
            sps.crop_top as usize,
        ),
        u: crop_plane(
            frame.u,
            width / 2,
            sps.crop_left as usize / 2,
            sps.crop_top as usize / 2,
        ),
        v: crop_plane(
            frame.v,
            width / 2,
            sps.crop_left as usize / 2,
            sps.crop_top as usize / 2,
        ),
        colour,
    })
}

fn classify_decode_error(err: rusty_h264_decoder::DecodeError) -> KeyframeDecodeError {
    match err {
        rusty_h264_decoder::DecodeError::Unsupported(
            tool @ ("slice groups (FMO)" | "transform-bypass (lossless) macroblock"),
        ) => KeyframeDecodeError::unsupported_codec(tool),
        _ => KeyframeDecodeError::malformed_bitstream(err.to_string()),
    }
}

fn validate_picture_slices(
    headers: &[Vec<u8>],
    pps_id: u32,
    sps: &SpsInfo,
    bottom_field_poc_present: bool,
) -> Result<(), KeyframeDecodeError> {
    let mut previous_mb = None;
    let mut picture_id = None;
    let mb_count = (sps.coded_width / 16) * (sps.coded_height / 16);
    for header in headers {
        let mut r = BitReader::new(header);
        let (mb, slice_type, slice_pps) = slice_start(&mut r)?;
        if slice_pps != pps_id {
            return Err(KeyframeDecodeError::malformed_bitstream(
                "inconsistent IDR slice PPS",
            ));
        }
        match slice_type {
            2 | 7 => {}
            4 | 9 => return Err(KeyframeDecodeError::unsupported_codec("SI slice")),
            _ => {
                return Err(KeyframeDecodeError::malformed_bitstream(
                    "non-intra slice in IDR",
                ));
            }
        }
        let frame_num = r.read_bits(sps.frame_num_bits)?;
        if !sps.frame_mbs_only && r.read_flag()? {
            return Err(KeyframeDecodeError::unsupported_codec("field picture"));
        }
        if mb >= mb_count || previous_mb.map_or(mb != 0, |prev| mb <= prev) {
            return Err(KeyframeDecodeError::malformed_bitstream(
                "inconsistent IDR slice order",
            ));
        }
        let idr_pic_id = r.read_ue_max(65_535, "idr_pic_id")?;
        let poc_lsb = sps.poc_lsb_bits.map(|bits| r.read_bits(bits)).transpose()?;
        let delta = if sps.delta_poc_present {
            r.read_se()?
        } else {
            0
        };
        let bottom = if bottom_field_poc_present && (poc_lsb.is_some() || sps.delta_poc_present) {
            r.read_se()?
        } else {
            0
        };
        let id = (frame_num, idr_pic_id, poc_lsb, delta, bottom);
        if picture_id.replace(id).is_some_and(|first| first != id) {
            return Err(KeyframeDecodeError::malformed_bitstream(
                "IDR slices belong to different pictures",
            ));
        }
        previous_mb = Some(mb);
    }

    Ok(())
}

fn crop_plane(mut plane: Vec<u8>, stride: usize, left: usize, top: usize) -> Vec<u8> {
    if left != 0 || top != 0 {
        let width = stride - left;
        let rows = plane.len() / stride - top;
        for row in 0..rows {
            let start = (row + top) * stride + left;
            plane.copy_within(start..start + width, row * width);
        }
        plane.truncate(rows * width);
    }
    plane
}

fn nal_type(nal: &[u8]) -> Option<u8> {
    let header = *nal.first()?;
    (header & 0x80 == 0).then_some(header & 0x1f)
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
        Some(1) => YuvMatrix::Bt709,
        Some(5 | 6) => YuvMatrix::Bt601,
        Some(9) => YuvMatrix::Bt2020,
        None | Some(2) => by_size,
        Some(code) => {
            return Err(KeyframeDecodeError::unsupported_codec(format!(
                "h264 VUI matrix_coefficients {code} is not a supported YCbCr matrix"
            )));
        }
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

fn nal_rbsp(nal: &[u8], retain: usize) -> Result<Vec<u8>, KeyframeDecodeError> {
    let payload = nal
        .get(1..)
        .filter(|p| !p.is_empty())
        .ok_or_else(|| KeyframeDecodeError::malformed_bitstream("h264 NAL unit has no payload"))?;
    let mut rbsp = Vec::with_capacity(retain.min(payload.len()));
    let mut zeros = 0;
    for (index, &byte) in payload.iter().enumerate() {
        if zeros == 2 {
            match byte {
                0..=2 => {
                    return Err(KeyframeDecodeError::malformed_bitstream(
                        "unescaped H.264 byte sequence",
                    ));
                }
                3 => match payload.get(index + 1) {
                    Some(0..=3) => {
                        zeros = 0;
                        continue;
                    }
                    None if nal_type(nal) == Some(NAL_IDR) => {}
                    _ => {
                        return Err(KeyframeDecodeError::malformed_bitstream(
                            "invalid H.264 emulation-prevention byte",
                        ));
                    }
                },
                _ => {}
            }
        }
        if rbsp.len() < retain {
            rbsp.push(byte);
        }
        zeros = if byte == 0 { zeros + 1 } else { 0 };
    }
    Ok(rbsp)
}

/// Parses the SPS fields this module needs (ITU-T H.264 7.3.2.1.1 and E.1.1).
fn parse_sps(nal: &[u8]) -> Result<SpsInfo, KeyframeDecodeError> {
    let rbsp = nal_rbsp(nal, nal.len())?;
    let mut r = BitReader::new(&rbsp);
    let profile_idc = r.read_bits(8)? as u8;
    let _constraint_flags_and_reserved = r.read_bits(8)?;
    let _level_idc = r.read_bits(8)?;
    r.read_ue_max(31, "seq_parameter_set_id")?;

    if !matches!(profile_idc, PROFILE_BASELINE | PROFILE_MAIN | PROFILE_HIGH) {
        return Err(KeyframeDecodeError::unsupported_codec(format!(
            "h264 profile_idc {profile_idc}"
        )));
    }
    if profile_idc == PROFILE_HIGH {
        if r.read_ue_max(3, "chroma_format_idc")? != 1 {
            return Err(KeyframeDecodeError::unsupported_codec(
                "non-4:2:0 chroma format",
            ));
        }
        let luma_depth = r.read_ue_max(6, "bit_depth_luma_minus8")?;
        let chroma_depth = r.read_ue_max(6, "bit_depth_chroma_minus8")?;
        if luma_depth != 0 || chroma_depth != 0 {
            return Err(KeyframeDecodeError::unsupported_codec("non-8-bit picture"));
        }
        let _qpprime_y_zero_transform_bypass = r.read_flag()?;
        if r.read_flag()? {
            for index in 0..8 {
                if r.read_flag()? {
                    skip_scaling_list(&mut r, if index < 6 { 16 } else { 64 })?;
                }
            }
        }
    }

    let frame_num_bits = 4 + r.read_ue_max(12, "log2_max_frame_num_minus4")?;
    let mut poc_lsb_bits = None;
    let mut delta_poc_present = false;
    match r.read_ue_max(2, "pic_order_cnt_type")? {
        0 => {
            poc_lsb_bits = Some(4 + r.read_ue_max(12, "log2_max_pic_order_cnt_lsb_minus4")?);
        }
        1 => {
            delta_poc_present = !r.read_flag()?;
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
    let width_in_mbs = 1 + u64::from(r.read_ue()?);
    let height_in_map_units = 1 + u64::from(r.read_ue()?);
    let frame_mbs_only = r.read_flag()?;
    if !frame_mbs_only && r.read_flag()? {
        return Err(KeyframeDecodeError::unsupported_codec("MBAFF picture"));
    }
    let _direct_8x8_inference = r.read_flag()?;
    let coded_width = width_in_mbs * 16;
    let coded_height = height_in_map_units * 16 * if frame_mbs_only { 1 } else { 2 };

    if coded_width > u64::from(MAX_FRAME_DIMENSION) || coded_height > u64::from(MAX_FRAME_DIMENSION)
    {
        return Err(KeyframeDecodeError::limit_exceeded(
            "coded picture exceeds dimension limit",
        ));
    }
    let (coded_width, coded_height) = (coded_width as u32, coded_height as u32);
    let (mut crop_left, mut crop_top) = (0, 0);
    let (mut crop_x, mut crop_y) = (0u32, 0u32);
    if r.read_flag()? {
        let left = r.read_ue()?;
        let right = r.read_ue()?;
        let top = r.read_ue()?;
        let bottom = r.read_ue()?;
        // CropUnitX/Y for 4:2:0 (7-19, 7-20); other formats are refused at admission, so
        // their display size is never used.
        let unit_y = if frame_mbs_only { 2 } else { 4 };
        crop_left = left.saturating_mul(2);
        crop_top = top.saturating_mul(unit_y);
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
        frame_num_bits,
        frame_mbs_only,
        poc_lsb_bits,
        delta_poc_present,
        crop_left,
        crop_top,
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

fn slice_header_prefix(nal: &[u8]) -> Result<Vec<u8>, KeyframeDecodeError> {
    if nal_type(nal) != Some(NAL_IDR) || nal[0] & 0x60 == 0 {
        return Err(KeyframeDecodeError::malformed_bitstream(
            "invalid IDR NAL header",
        ));
    }
    nal_rbsp(nal, 64)
}

fn slice_start(r: &mut BitReader<'_>) -> Result<(u32, u32, u32), KeyframeDecodeError> {
    Ok((
        r.read_ue()?,
        r.read_ue_max(9, "slice_type")?,
        r.read_ue_max(255, "pic_parameter_set_id")?,
    ))
}
