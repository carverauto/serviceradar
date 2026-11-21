//! Pure-Rust ISO-BMFF / CMAF box parser (`ftyp`/`moov`/`avcC`/`hvcC`/`moof`/`traf`/`trun`/`mdat`)
//! and synthetic CMAF test-pattern generator (`0.4`, `2.3`). Keyframe decoding lives behind
//! `crate::keyframe_decoder::KeyframeDecoder`.
//!
//! The synthetic fixtures use programmatic geometric patterns. See
//! [`generate_synthetic_cmaf_block`] for their payload format.

use crate::errors::MediaWorkerError;
use crate::grants::{FragmentSlicePlan, InitSlicePlan};
use crate::keyframe_decoder::KeyframeDecodeError;
use crate::vision::{ObjectClass, RgbFrame};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

const SYNTHETIC_IDR_MAGIC: &[u8; 6] = b"SRIDR1";
/// Largest accepted picture width or height, in the container and in the coded bitstream.
pub(crate) const MAX_FRAME_DIMENSION: u32 = 4096;
/// Most NAL units accepted in one keyframe sample.
const MAX_SAMPLE_NAL_UNITS: usize = 4096;

/// Codec signaled in `init.mp4` (`avc1`/`avc3` or `hvc1`/`hev1`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum VideoCodec {
    H264,
    Hevc,
}

impl VideoCodec {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::H264 => "h264",
            Self::Hevc => "hevc",
        }
    }
}

/// Parsed metadata from an ISO-BMFF `init.mp4` segment.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ParsedInitSegment {
    codec: VideoCodec,
    in_band_avc_sets: bool,
    width: u32,
    height: u32,
    timescale: u32,
    nal_length_size: u8,
    parameter_sets: Vec<Vec<u8>>,
}

impl ParsedInitSegment {
    pub fn codec(&self) -> VideoCodec {
        self.codec
    }

    pub fn width(&self) -> u32 {
        self.width
    }

    pub fn height(&self) -> u32 {
        self.height
    }

    pub fn timescale(&self) -> u32 {
        self.timescale
    }

    pub fn nal_length_size(&self) -> u8 {
        self.nal_length_size
    }

    pub fn parameter_sets(&self) -> &[Vec<u8>] {
        &self.parameter_sets
    }
}

/// Parsed metadata and IDR sync sample NAL units from a CMAF `media.m4s` fragment.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ParsedMediaFragment {
    sequence_number: u32,
    timing: SampleTiming,
    first_sample_size: usize,
    idr_nal_units: Vec<Vec<u8>>,
    in_band_parameter_sets: Vec<Vec<u8>>,
}

impl ParsedMediaFragment {
    pub fn sequence_number(&self) -> u32 {
        self.sequence_number
    }

    pub fn base_decode_time_ticks(&self) -> u64 {
        self.timing.decode_ticks
    }

    pub fn media_pts_ns(&self, timescale: u32) -> u64 {
        self.timing.pts_ns(timescale)
    }

    pub fn first_sample_size(&self) -> usize {
        self.first_sample_size
    }

    /// IDR slice NAL units of the first (sync) sample, in bitstream order.
    pub fn idr_nal_units(&self) -> &[Vec<u8>] {
        &self.idr_nal_units
    }

    /// Parameter sets carried in-band in the first sample (`avc3`), in
    /// bitstream order. They override init-segment sets with the same id.
    pub fn in_band_parameter_sets(&self) -> &[Vec<u8>] {
        &self.in_band_parameter_sets
    }
}

#[derive(Debug, Clone, Copy)]
struct BoxView<'a> {
    box_type: [u8; 4],
    payload: &'a [u8],
}

fn read_box<'a>(buf: &mut &'a [u8]) -> Result<BoxView<'a>, MediaWorkerError> {
    if buf.len() < 8 {
        return Err(MediaWorkerError::invalid_container(
            "truncated ISO-BMFF box header (< 8 bytes)",
        ));
    }
    let size32 = u32::from_be_bytes([buf[0], buf[1], buf[2], buf[3]]);
    let box_type = [buf[4], buf[5], buf[6], buf[7]];

    let (header_len, total_len) = match size32 {
        0 => (8usize, buf.len()),
        1 => {
            if buf.len() < 16 {
                return Err(MediaWorkerError::invalid_container(
                    "truncated 64-bit largesize ISO-BMFF box header",
                ));
            }
            let size64 = u64::from_be_bytes([
                buf[8], buf[9], buf[10], buf[11], buf[12], buf[13], buf[14], buf[15],
            ]);
            let len = usize::try_from(size64).map_err(|_| {
                MediaWorkerError::invalid_container("64-bit box size overflows usize")
            })?;
            if len < 16 {
                return Err(MediaWorkerError::invalid_container(
                    "invalid 64-bit box size < 16",
                ));
            }
            (16usize, len)
        }
        n if n < 8 => {
            return Err(MediaWorkerError::invalid_container(format!(
                "invalid ISO-BMFF box size {n} < 8"
            )));
        }
        n => (8usize, n as usize),
    };

    if total_len > buf.len() {
        return Err(MediaWorkerError::invalid_container(format!(
            "ISO-BMFF box '{}' size {} exceeds remaining {} bytes",
            core::str::from_utf8(&box_type).unwrap_or("????"),
            total_len,
            buf.len()
        )));
    }

    let payload = &buf[header_len..total_len];
    *buf = &buf[total_len..];
    Ok(BoxView { box_type, payload })
}

fn scan_boxes(mut buf: &[u8]) -> (Vec<BoxView<'_>>, Result<(), MediaWorkerError>) {
    let mut boxes = Vec::new();
    while !buf.is_empty() {
        match read_box(&mut buf) {
            Ok(view) => boxes.push(view),
            Err(err) => return (boxes, Err(err)),
        }
    }
    (boxes, Ok(()))
}

struct InitScan {
    codec: Option<VideoCodec>,
    status: Result<(), MediaWorkerError>,
}

impl InitScan {
    fn boxes<'a>(&mut self, bytes: &'a [u8]) -> Vec<BoxView<'a>> {
        let (boxes, status) = scan_boxes(bytes);
        if self.status.is_ok() {
            self.status = status;
        }
        boxes
    }
}

/// Parses an ISO-BMFF / CMAF `init.mp4` segment (`ftyp` + `moov`).
pub fn parse_init_segment(init_bytes: &[u8]) -> Result<ParsedInitSegment, MediaWorkerError> {
    parse_init_segment_with_codec(init_bytes).1
}

pub(crate) fn parse_init_segment_with_codec(
    init_bytes: &[u8],
) -> (
    Option<VideoCodec>,
    Result<ParsedInitSegment, MediaWorkerError>,
) {
    let mut scan = InitScan {
        codec: None,
        status: Ok(()),
    };
    let init = parse_movie(init_bytes, &mut scan);
    (scan.codec, scan.status.and(init))
}

fn parse_movie(
    init_bytes: &[u8],
    scan: &mut InitScan,
) -> Result<ParsedInitSegment, MediaWorkerError> {
    let top_boxes = scan.boxes(init_bytes);
    let has_ftyp = top_boxes.iter().any(|b| &b.box_type == b"ftyp");
    if !has_ftyp {
        scan.status = Err(MediaWorkerError::invalid_container(
            "init.mp4 missing required 'ftyp' box",
        ));
    }
    let moov = top_boxes
        .iter()
        .find(|b| &b.box_type == b"moov")
        .ok_or_else(|| {
            MediaWorkerError::invalid_container("init.mp4 missing required 'moov' box")
        })?;

    let moov_children = scan.boxes(moov.payload);
    let mut movie_timescale = 90_000u32;
    if let Some(mvhd) = moov_children.iter().find(|b| &b.box_type == b"mvhd")
        && let Some(ts) = parse_mvhd_or_mdhd_timescale(mvhd.payload)
    {
        movie_timescale = ts;
    }

    for trak in moov_children.iter().filter(|b| &b.box_type == b"trak") {
        if let Some(parsed) = parse_video_trak(trak.payload, movie_timescale, scan)? {
            return Ok(parsed);
        }
    }

    Err(MediaWorkerError::invalid_container(
        "init.mp4 contains no supported H.264 (avc1/avc3) or HEVC (hvc1/hev1) video track",
    ))
}

fn parse_mvhd_or_mdhd_timescale(payload: &[u8]) -> Option<u32> {
    if payload.len() < 4 {
        return None;
    }
    let version = payload[0];
    let ts_offset = match version {
        0 => 4 + 4 + 4, // version/flags + creation(4) + modification(4)
        1 => 4 + 8 + 8, // version/flags + creation(8) + modification(8)
        _ => return None,
    };
    if payload.len() < ts_offset + 4 {
        return None;
    }
    let ts = u32::from_be_bytes([
        payload[ts_offset],
        payload[ts_offset + 1],
        payload[ts_offset + 2],
        payload[ts_offset + 3],
    ]);
    (ts > 0).then_some(ts)
}

fn parse_tkhd_dimensions(payload: &[u8]) -> Option<(u32, u32)> {
    if payload.len() < 4 {
        return None;
    }
    let version = payload[0];
    // FullBox(4) + timestamps/track_id/reserved/duration + reserved(8) + layer/alt/vol/res(8) + matrix(36) =
    // v0: 4 + 20 + 8 + 8 + 36 = 76, followed by width(16.16) + height(16.16) = 84 bytes
    // v1: 4 + 32 + 8 + 8 + 36 = 88, followed by width(16.16) + height(16.16) = 96 bytes
    let dim_offset = match version {
        0 => 76usize,
        1 => 88usize,
        _ => return None,
    };
    if payload.len() < dim_offset + 8 {
        return None;
    }
    let width_fixed = u32::from_be_bytes([
        payload[dim_offset],
        payload[dim_offset + 1],
        payload[dim_offset + 2],
        payload[dim_offset + 3],
    ]);
    let height_fixed = u32::from_be_bytes([
        payload[dim_offset + 4],
        payload[dim_offset + 5],
        payload[dim_offset + 6],
        payload[dim_offset + 7],
    ]);
    Some((width_fixed >> 16, height_fixed >> 16))
}

fn parse_video_trak(
    trak_payload: &[u8],
    default_timescale: u32,
    scan: &mut InitScan,
) -> Result<Option<ParsedInitSegment>, MediaWorkerError> {
    let trak_children = scan.boxes(trak_payload);
    let tkhd_dims = trak_children
        .iter()
        .find(|b| &b.box_type == b"tkhd")
        .and_then(|b| parse_tkhd_dimensions(b.payload));

    let Some(mdia) = trak_children.iter().find(|b| &b.box_type == b"mdia") else {
        return Ok(None);
    };
    let mdia_children = scan.boxes(mdia.payload);

    let mut timescale = default_timescale;
    if let Some(mdhd) = mdia_children.iter().find(|b| &b.box_type == b"mdhd")
        && let Some(ts) = parse_mvhd_or_mdhd_timescale(mdhd.payload)
    {
        timescale = ts;
    }

    if let Some(hdlr) = mdia_children.iter().find(|b| &b.box_type == b"hdlr")
        && hdlr.payload.len() >= 12
        && &hdlr.payload[8..12] != b"vide"
    {
        return Ok(None);
    }

    let Some(minf) = mdia_children.iter().find(|b| &b.box_type == b"minf") else {
        return Ok(None);
    };
    let minf_children = scan.boxes(minf.payload);
    let Some(stbl) = minf_children.iter().find(|b| &b.box_type == b"stbl") else {
        return Ok(None);
    };
    let stbl_children = scan.boxes(stbl.payload);
    let Some(stsd) = stbl_children.iter().find(|b| &b.box_type == b"stsd") else {
        return Ok(None);
    };

    parse_stsd(stsd.payload, timescale, tkhd_dims, scan)
}

fn parse_stsd(
    stsd_payload: &[u8],
    timescale: u32,
    tkhd_dims: Option<(u32, u32)>,
    scan: &mut InitScan,
) -> Result<Option<ParsedInitSegment>, MediaWorkerError> {
    if stsd_payload.len() < 8 {
        return Err(MediaWorkerError::invalid_container("truncated 'stsd' box"));
    }
    let entry_count = u32::from_be_bytes([
        stsd_payload[4],
        stsd_payload[5],
        stsd_payload[6],
        stsd_payload[7],
    ]);
    if entry_count == 0 {
        return Ok(None);
    }

    let entries = scan.boxes(&stsd_payload[8..]);
    for entry in entries {
        let codec = match &entry.box_type {
            b"avc1" | b"avc3" => VideoCodec::H264,
            b"hvc1" | b"hev1" => VideoCodec::Hevc,
            _ => continue,
        };
        scan.codec = Some(codec);

        // VisualSampleEntry fixed fields span 78 bytes before nested configuration boxes:
        // reserved(6) + data_ref_idx(2) + pre_defined/reserved(16) + width(2) + height(2) +
        // horizres(4) + vertres(4) + reserved(4) + frame_count(2) + compressorname(32) +
        // depth(2) + pre_defined(2) = 78 bytes.
        if entry.payload.len() < 78 {
            return Err(MediaWorkerError::invalid_container(
                "truncated VisualSampleEntry (< 78 bytes)",
            ));
        }
        let sample_w = u32::from(u16::from_be_bytes([entry.payload[24], entry.payload[25]]));
        let sample_h = u32::from(u16::from_be_bytes([entry.payload[26], entry.payload[27]]));
        let (fallback_w, fallback_h) = tkhd_dims.unwrap_or((0, 0));
        let width = if sample_w > 0 { sample_w } else { fallback_w };
        let height = if sample_h > 0 { sample_h } else { fallback_h };

        if width == 0 || height == 0 {
            return Err(MediaWorkerError::invalid_container(format!(
                "invalid video sample dimensions {width}x{height}"
            )));
        }

        let config_boxes = scan.boxes(&entry.payload[78..]);
        match codec {
            VideoCodec::H264 => {
                let avcc = config_boxes
                    .iter()
                    .find(|b| &b.box_type == b"avcC")
                    .ok_or_else(|| {
                        MediaWorkerError::invalid_container(
                            "avc1/avc3 sample entry missing 'avcC' box",
                        )
                    })?;
                let (nal_length_size, parameter_sets) = parse_avcc(avcc.payload)?;
                return Ok(Some(ParsedInitSegment {
                    codec,
                    in_band_avc_sets: &entry.box_type == b"avc3",
                    width,
                    height,
                    timescale,
                    nal_length_size,
                    parameter_sets,
                }));
            }
            VideoCodec::Hevc => {
                let hvcc = config_boxes
                    .iter()
                    .find(|b| &b.box_type == b"hvcC")
                    .ok_or_else(|| {
                        MediaWorkerError::invalid_container(
                            "hvc1/hev1 sample entry missing 'hvcC' box",
                        )
                    })?;
                let (nal_length_size, parameter_sets) = parse_hvcc(hvcc.payload)?;
                return Ok(Some(ParsedInitSegment {
                    codec,
                    in_band_avc_sets: false,
                    width,
                    height,
                    timescale,
                    nal_length_size,
                    parameter_sets,
                }));
            }
        }
    }

    Ok(None)
}

fn parse_avcc(payload: &[u8]) -> Result<(u8, Vec<Vec<u8>>), MediaWorkerError> {
    if payload.len() < 7 || payload[0] != 1 {
        return Err(MediaWorkerError::invalid_container(
            "invalid or truncated AVCDecoderConfigurationRecord ('avcC')",
        ));
    }
    let nal_length_size = (payload[4] & 0x03) + 1;
    if nal_length_size == 3 {
        return Err(MediaWorkerError::invalid_container(
            "unsupported 3-byte NAL length size in avcC",
        ));
    }
    let num_sps = usize::from(payload[5] & 0x1f);
    let mut cursor = 6usize;
    let mut param_sets = Vec::new();

    for _ in 0..num_sps {
        if cursor + 2 > payload.len() {
            return Err(MediaWorkerError::invalid_container("truncated SPS in avcC"));
        }
        let len = usize::from(u16::from_be_bytes([payload[cursor], payload[cursor + 1]]));
        cursor += 2;
        if cursor + len > payload.len() {
            return Err(MediaWorkerError::invalid_container(
                "SPS length exceeds avcC box",
            ));
        }
        param_sets.push(payload[cursor..cursor + len].to_vec());
        cursor += len;
    }

    if cursor >= payload.len() {
        return Err(MediaWorkerError::invalid_container(
            "missing PPS count in avcC",
        ));
    }
    let num_pps = usize::from(payload[cursor]);
    cursor += 1;
    for _ in 0..num_pps {
        if cursor + 2 > payload.len() {
            return Err(MediaWorkerError::invalid_container("truncated PPS in avcC"));
        }
        let len = usize::from(u16::from_be_bytes([payload[cursor], payload[cursor + 1]]));
        cursor += 2;
        if cursor + len > payload.len() {
            return Err(MediaWorkerError::invalid_container(
                "PPS length exceeds avcC box",
            ));
        }
        param_sets.push(payload[cursor..cursor + len].to_vec());
        cursor += len;
    }

    Ok((nal_length_size, param_sets))
}

fn parse_hvcc(payload: &[u8]) -> Result<(u8, Vec<Vec<u8>>), MediaWorkerError> {
    if payload.len() < 23 || payload[0] != 1 {
        return Err(MediaWorkerError::invalid_container(
            "invalid or truncated HEVCDecoderConfigurationRecord ('hvcC')",
        ));
    }
    let nal_length_size = (payload[21] & 0x03) + 1;
    if nal_length_size == 3 {
        return Err(MediaWorkerError::invalid_container(
            "unsupported 3-byte NAL length size in hvcC",
        ));
    }
    let num_arrays = usize::from(payload[22]);
    let mut cursor = 23usize;
    let mut param_sets = Vec::new();

    for _ in 0..num_arrays {
        if cursor + 3 > payload.len() {
            return Err(MediaWorkerError::invalid_container(
                "truncated NALU array header in hvcC",
            ));
        }
        let num_nalus = usize::from(u16::from_be_bytes([
            payload[cursor + 1],
            payload[cursor + 2],
        ]));
        cursor += 3;
        for _ in 0..num_nalus {
            if cursor + 2 > payload.len() {
                return Err(MediaWorkerError::invalid_container(
                    "truncated NALU in hvcC",
                ));
            }
            let len = usize::from(u16::from_be_bytes([payload[cursor], payload[cursor + 1]]));
            cursor += 2;
            if cursor + len > payload.len() {
                return Err(MediaWorkerError::invalid_container(
                    "NALU length exceeds hvcC box",
                ));
            }
            param_sets.push(payload[cursor..cursor + len].to_vec());
            cursor += len;
        }
    }

    Ok((nal_length_size, param_sets))
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct SampleTiming {
    decode_ticks: u64,
    cts_offset: i64,
}

impl SampleTiming {
    fn pts_ns(self, timescale: u32) -> u64 {
        if timescale == 0 {
            return 0;
        }
        let ticks = (self.decode_ticks as i128) + i128::from(self.cts_offset);
        let clamped = ticks.max(0) as u128;
        let ns = clamped.saturating_mul(1_000_000_000) / u128::from(timescale);
        u64::try_from(ns).unwrap_or(u64::MAX)
    }
}

/// Parses a single CMAF `media.m4s` fragment (`moof` + `mdat`) and extracts the
/// first sync (`IDR`) sample's NAL units.
pub fn parse_media_fragment(
    fragment_bytes: &[u8],
    init: &ParsedInitSegment,
) -> Result<ParsedMediaFragment, MediaWorkerError> {
    parse_timed_fragment(fragment_bytes, init).1
}

pub(crate) fn parse_timed_fragment(
    bytes: &[u8],
    init: &ParsedInitSegment,
) -> (u64, Result<ParsedMediaFragment, MediaWorkerError>) {
    let mut timing = SampleTiming {
        decode_ticks: 0,
        cts_offset: 0,
    };
    let sample = parse_fragment_sample(bytes, &mut timing);
    let parsed = if init.width > MAX_FRAME_DIMENSION || init.height > MAX_FRAME_DIMENSION {
        Err(KeyframeDecodeError::limit_exceeded("container picture exceeds dimension limit").into())
    } else {
        sample.and_then(|(sequence_number, bytes)| {
            let (idr_nal_units, in_band_parameter_sets) = extract_keyframe_nal_units(bytes, init)?;
            Ok(ParsedMediaFragment {
                sequence_number,
                timing,
                first_sample_size: bytes.len(),
                idr_nal_units,
                in_band_parameter_sets,
            })
        })
    };
    (timing.pts_ns(init.timescale()), parsed)
}

fn parse_fragment_sample<'a>(
    fragment_bytes: &'a [u8],
    timing: &mut SampleTiming,
) -> Result<(u32, &'a [u8]), MediaWorkerError> {
    let (boxes, boxes_status) = scan_boxes(fragment_bytes);
    let moof = boxes
        .iter()
        .find(|b| &b.box_type == b"moof")
        .ok_or_else(|| MediaWorkerError::invalid_container("CMAF fragment missing 'moof' box"))?;
    let (moof_children, moof_status) = scan_boxes(moof.payload);
    let sequence_number = moof_children
        .iter()
        .find(|b| &b.box_type == b"mfhd")
        .and_then(|b| {
            (b.payload.len() >= 8).then(|| {
                u32::from_be_bytes([b.payload[4], b.payload[5], b.payload[6], b.payload[7]])
            })
        })
        .unwrap_or(0);

    let traf = moof_children
        .iter()
        .find(|b| &b.box_type == b"traf")
        .ok_or_else(|| {
            MediaWorkerError::invalid_container("CMAF 'moof' missing 'traf' track fragment box")
        })?;
    let (traf_children, traf_status) = scan_boxes(traf.payload);

    let default_sample_size = traf_children
        .iter()
        .find(|b| &b.box_type == b"tfhd")
        .and_then(|b| parse_tfhd_default_sample_size(b.payload));

    timing.decode_ticks = traf_children
        .iter()
        .find(|b| &b.box_type == b"tfdt")
        .and_then(|b| parse_tfdt(b.payload))
        .unwrap_or(0);

    let trun = traf_children
        .iter()
        .find(|b| &b.box_type == b"trun")
        .ok_or_else(|| {
            MediaWorkerError::invalid_container("CMAF 'traf' missing 'trun' track run box")
        })?;

    let sample = parse_trun_first_sample(trun.payload, default_sample_size)?;
    timing.cts_offset = sample.cts_offset;
    boxes_status.and(moof_status).and(traf_status)?;
    if !sample.sync {
        return Err(MediaWorkerError::invalid_container(
            "first sample in CMAF fragment is non-sync",
        ));
    }
    let mdat = boxes
        .iter()
        .find(|b| &b.box_type == b"mdat")
        .ok_or_else(|| MediaWorkerError::invalid_container("CMAF fragment missing 'mdat' box"))?;
    let size = sample.size.map_or(mdat.payload.len(), |size| size as usize);
    let bytes = mdat
        .payload
        .get(..size)
        .filter(|bytes| !bytes.is_empty())
        .ok_or_else(|| {
            MediaWorkerError::invalid_container(format!(
                "invalid first sample size {size} for mdat payload"
            ))
        })?;
    Ok((sequence_number, bytes))
}

fn parse_tfhd_default_sample_size(payload: &[u8]) -> Option<u32> {
    if payload.len() < 8 {
        return None;
    }
    let flags = u32::from_be_bytes([0, payload[1], payload[2], payload[3]]);
    let mut cursor = 8usize; // version/flags(4) + track_id(4)
    if flags & 0x000001 != 0 {
        cursor += 8; // base_data_offset
    }
    if flags & 0x000002 != 0 {
        cursor += 4; // sample_description_index
    }
    if flags & 0x000008 != 0 {
        cursor += 4; // default_sample_duration
    }
    if flags & 0x000010 != 0 {
        if cursor + 4 > payload.len() {
            return None;
        }
        return Some(u32::from_be_bytes([
            payload[cursor],
            payload[cursor + 1],
            payload[cursor + 2],
            payload[cursor + 3],
        ]));
    }
    None
}

fn parse_tfdt(payload: &[u8]) -> Option<u64> {
    if payload.len() < 8 {
        return None;
    }
    match payload[0] {
        0 => Some(u64::from(u32::from_be_bytes([
            payload[4], payload[5], payload[6], payload[7],
        ]))),
        1 if payload.len() >= 12 => Some(u64::from_be_bytes([
            payload[4],
            payload[5],
            payload[6],
            payload[7],
            payload[8],
            payload[9],
            payload[10],
            payload[11],
        ])),
        _ => None,
    }
}

struct FirstSample {
    size: Option<u32>,
    sync: bool,
    cts_offset: i64,
}

fn parse_trun_first_sample(
    payload: &[u8],
    default_sample_size: Option<u32>,
) -> Result<FirstSample, MediaWorkerError> {
    if payload.len() < 8 {
        return Err(MediaWorkerError::invalid_container("truncated 'trun' box"));
    }
    let version = payload[0];
    let flags = u32::from_be_bytes([0, payload[1], payload[2], payload[3]]);
    let sample_count = u32::from_be_bytes([payload[4], payload[5], payload[6], payload[7]]);
    if sample_count == 0 {
        return Err(MediaWorkerError::invalid_container(
            "'trun' box contains 0 samples",
        ));
    }

    let mut sync = true;
    let mut cursor = 8usize;
    if flags & 0x000001 != 0 {
        cursor += 4; // data_offset
    }
    if flags & 0x000004 != 0 {
        if cursor + 4 > payload.len() {
            return Err(MediaWorkerError::invalid_container(
                "truncated first_sample_flags in 'trun'",
            ));
        }
        let first_flags = u32::from_be_bytes([
            payload[cursor],
            payload[cursor + 1],
            payload[cursor + 2],
            payload[cursor + 3],
        ]);
        // ISO 14496-12 bit 16 (`0x0001_0000`) is `sample_is_non_sync_sample`.
        sync = first_flags & 0x0001_0000 == 0;
        cursor += 4;
    }

    if flags & 0x000100 != 0 {
        cursor += 4; // sample_duration
    }

    let sample_size = if flags & 0x000200 != 0 {
        if cursor + 4 > payload.len() {
            return Err(MediaWorkerError::invalid_container(
                "truncated sample_size in 'trun'",
            ));
        }
        let sz = u32::from_be_bytes([
            payload[cursor],
            payload[cursor + 1],
            payload[cursor + 2],
            payload[cursor + 3],
        ]);
        cursor += 4;
        Some(sz)
    } else {
        default_sample_size
    };

    if flags & 0x000400 != 0 {
        if cursor + 4 > payload.len() {
            return Err(MediaWorkerError::invalid_container(
                "truncated sample_flags in 'trun'",
            ));
        }
        let sample_flags = u32::from_be_bytes([
            payload[cursor],
            payload[cursor + 1],
            payload[cursor + 2],
            payload[cursor + 3],
        ]);
        if flags & 0x000004 == 0 {
            sync = sample_flags & 0x0001_0000 == 0;
        }
        cursor += 4;
    }

    let cts_offset = if flags & 0x000800 != 0 {
        if cursor + 4 > payload.len() {
            return Err(MediaWorkerError::invalid_container(
                "truncated sample_composition_time_offset in 'trun'",
            ));
        }
        let raw = [
            payload[cursor],
            payload[cursor + 1],
            payload[cursor + 2],
            payload[cursor + 3],
        ];
        if version == 0 {
            i64::from(u32::from_be_bytes(raw))
        } else {
            i64::from(i32::from_be_bytes(raw))
        }
    } else {
        0
    };

    Ok(FirstSample {
        size: sample_size,
        cts_offset,
        sync,
    })
}

/// NAL units of one sample, each without its length prefix.
type NalUnits = Vec<Vec<u8>>;

/// Splits a length-prefixed sync sample into its IDR slice NAL units and its in-band
/// parameter sets. Other NAL units (AUD, SEI, ...) are dropped.
fn extract_keyframe_nal_units(
    sample_bytes: &[u8],
    init: &ParsedInitSegment,
) -> Result<(NalUnits, NalUnits), MediaWorkerError> {
    let nal_length_size = init.nal_length_size();
    let codec = init.codec();
    let len_bytes = usize::from(nal_length_size);
    let mut cursor = 0usize;
    let mut idr_nals = Vec::new();
    let mut parameter_sets = Vec::new();
    let mut nal_count = 0usize;

    while cursor < sample_bytes.len() {
        nal_count += 1;
        if nal_count > MAX_SAMPLE_NAL_UNITS {
            return Err(KeyframeDecodeError::limit_exceeded(format!(
                "keyframe sample holds more than {MAX_SAMPLE_NAL_UNITS} NAL units"
            ))
            .into());
        }
        if cursor + len_bytes > sample_bytes.len() {
            return Err(MediaWorkerError::invalid_container(
                "truncated length-prefixed NAL unit header in mdat",
            ));
        }
        let nal_len = match nal_length_size {
            1 => usize::from(sample_bytes[cursor]),
            2 => usize::from(u16::from_be_bytes([
                sample_bytes[cursor],
                sample_bytes[cursor + 1],
            ])),
            4 => u32::from_be_bytes([
                sample_bytes[cursor],
                sample_bytes[cursor + 1],
                sample_bytes[cursor + 2],
                sample_bytes[cursor + 3],
            ]) as usize,
            other => {
                return Err(MediaWorkerError::invalid_container(format!(
                    "unsupported NAL length size {other}"
                )));
            }
        };
        cursor += len_bytes;

        if nal_len == 0 || cursor + nal_len > sample_bytes.len() {
            return Err(MediaWorkerError::invalid_container(
                "NAL unit length in mdat exceeds sample boundary",
            ));
        }
        let nal = &sample_bytes[cursor..cursor + nal_len];
        cursor += nal_len;

        if is_idr_nal(nal, codec) {
            idr_nals.push(nal.to_vec());
        } else if codec == VideoCodec::H264 {
            if nal[0] & 0x80 != 0 {
                return Err(
                    KeyframeDecodeError::malformed_bitstream("invalid H.264 NAL header").into(),
                );
            }
            match nal[0] & 0x1f {
                19..=21 => {
                    return Err(KeyframeDecodeError::unsupported_codec(
                        "auxiliary or extension coded slice",
                    )
                    .into());
                }
                7 | 8 if !init.in_band_avc_sets => {}
                7 | 8 if idr_nals.is_empty() => parameter_sets.push(nal.to_vec()),
                1..=4 | 7 | 8 => {
                    return Err(KeyframeDecodeError::malformed_bitstream(
                        "unexpected slice or parameter set in IDR sample",
                    )
                    .into());
                }
                _ => {}
            }
        }
    }

    if idr_nals.is_empty() {
        return Err(KeyframeDecodeError::malformed_bitstream(
            "CMAF sample contains no H.264/HEVC IDR keyframe NAL unit",
        )
        .into());
    }
    Ok((idr_nals, parameter_sets))
}

fn is_idr_nal(nal: &[u8], codec: VideoCodec) -> bool {
    if nal.is_empty() {
        return false;
    }
    match codec {
        VideoCodec::H264 => {
            let forbidden_zero = nal[0] & 0x80;
            let nal_type = nal[0] & 0x1f;
            forbidden_zero == 0 && nal_type == 5
        }
        VideoCodec::Hevc => {
            if nal.len() < 2 {
                return false;
            }
            let forbidden_zero = nal[0] & 0x80;
            let nal_type = (nal[0] >> 1) & 0x3f;
            forbidden_zero == 0 && matches!(nal_type, 16..=21)
        }
    }
}

/// Test-only decoder for the synthetic generator's `SRIDR1` raster keyframes.
///
/// It exists so vision and worker tests can run on exact, lossless pixels. It is compiled
/// only into tests and is selected explicitly by injection, never by sniffing bitstream
/// bytes, so no production code path can reach it.
#[cfg(test)]
#[derive(Debug, Clone, Copy, Default)]
pub(crate) struct SyntheticRasterKeyframeDecoder;

#[cfg(test)]
impl crate::keyframe_decoder::KeyframeDecoder for SyntheticRasterKeyframeDecoder {
    fn decode_keyframe(
        &self,
        init: &ParsedInitSegment,
        fragment: &ParsedMediaFragment,
    ) -> Result<RgbFrame, crate::keyframe_decoder::KeyframeDecodeError> {
        use crate::keyframe_decoder::KeyframeDecodeError;
        tracing::debug!("decoding synthetic raster keyframe");
        let first_idr = fragment.idr_nal_units().first().ok_or_else(|| {
            KeyframeDecodeError::malformed_bitstream("no IDR NAL unit available to decode")
        })?;
        let slice_body = first_idr.get(1..).unwrap_or_default();
        if !slice_body.starts_with(SYNTHETIC_IDR_MAGIC) {
            return Err(KeyframeDecodeError::malformed_bitstream(
                "not a synthetic SRIDR1 raster keyframe",
            ));
        }
        decode_synthetic_rle_idr(slice_body, init.width(), init.height())
            .map_err(|err| KeyframeDecodeError::malformed_bitstream(err.to_string()))
    }
}

#[cfg(test)]
fn decode_synthetic_rle_idr(
    slice_body: &[u8],
    expected_w: u32,
    expected_h: u32,
) -> Result<RgbFrame, MediaWorkerError> {
    // Layout: "SRIDR1"(6) + width:u16(2) + height:u16(2) + run_count:u32(4) + runs * (run_len:u16 + r,g,b)
    if slice_body.len() < 14 {
        return Err(MediaWorkerError::invalid_container(
            "truncated synthetic IDR raster header",
        ));
    }
    let w = u32::from(u16::from_be_bytes([slice_body[6], slice_body[7]]));
    let h = u32::from(u16::from_be_bytes([slice_body[8], slice_body[9]]));
    if w != expected_w || h != expected_h {
        return Err(MediaWorkerError::invalid_container(format!(
            "synthetic IDR dimensions {w}x{h} mismatch init.mp4 {expected_w}x{expected_h}"
        )));
    }
    let run_count = u32::from_be_bytes([
        slice_body[10],
        slice_body[11],
        slice_body[12],
        slice_body[13],
    ]) as usize;

    let expected_pixels = (w as usize).saturating_mul(h as usize);
    let mut pixels = Vec::with_capacity(expected_pixels * 3);
    let mut cursor = 14usize;

    for _ in 0..run_count {
        if cursor + 5 > slice_body.len() {
            return Err(MediaWorkerError::invalid_container(
                "truncated RLE run in synthetic IDR slice",
            ));
        }
        let len = usize::from(u16::from_be_bytes([
            slice_body[cursor],
            slice_body[cursor + 1],
        ]));
        let rgb = [
            slice_body[cursor + 2],
            slice_body[cursor + 3],
            slice_body[cursor + 4],
        ];
        cursor += 5;

        if pixels.len() / 3 + len > expected_pixels {
            return Err(MediaWorkerError::invalid_container(
                "synthetic IDR RLE pixel count exceeds frame dimensions",
            ));
        }
        for _ in 0..len {
            pixels.extend_from_slice(&rgb);
        }
    }

    if pixels.len() != expected_pixels * 3 {
        return Err(MediaWorkerError::invalid_container(
            "synthetic IDR RLE pixel count shorter than frame dimensions",
        ));
    }

    RgbFrame::from_rgb8(w, h, pixels)
}

// ============================================================================
// Stage 0.4: Programmatic Synthetic CMAF Test-Pattern Generator
// ============================================================================

/// Canonical synthetic palette for deterministic test-pattern generation (`0.4`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SyntheticColor {
    Red,
    Blue,
    White,
    Black,
    Yellow,
    Green,
    Gray,
    Orange,
    Brown,
}

impl SyntheticColor {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Red => "red",
            Self::Blue => "blue",
            Self::White => "white",
            Self::Black => "black",
            Self::Yellow => "yellow",
            Self::Green => "green",
            Self::Gray => "gray",
            Self::Orange => "orange",
            Self::Brown => "brown",
        }
    }

    pub fn rgb(self) -> [u8; 3] {
        match self {
            Self::Red => [224, 30, 38],
            Self::Blue => [30, 96, 228],
            Self::White => [244, 246, 248],
            Self::Black => [12, 12, 14],
            Self::Yellow => [240, 212, 28],
            Self::Green => [34, 182, 68],
            Self::Gray => [138, 142, 148],
            Self::Orange => [238, 128, 24],
            Self::Brown => [144, 86, 42],
        }
    }
}

/// Ground-truth foreground object drawn into a synthetic CMAF keyframe (`0.4`).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct SyntheticObjectSpec {
    object_class: ObjectClass,
    color: SyntheticColor,
    bbox_norm: [f32; 4],
}

impl SyntheticObjectSpec {
    pub fn new(object_class: ObjectClass, color: SyntheticColor, bbox_norm: [f32; 4]) -> Self {
        Self {
            object_class,
            color,
            bbox_norm,
        }
    }

    pub fn object_class(&self) -> ObjectClass {
        self.object_class
    }

    pub fn color(&self) -> SyntheticColor {
        self.color
    }

    pub fn bbox_norm(&self) -> [f32; 4] {
        self.bbox_norm
    }
}

/// Specification for one synthetic CMAF fragment inside a synthetic recording block.
#[derive(Debug, Clone)]
pub struct SyntheticFragmentSpec {
    sequence: u32,
    start_ns: u64,
    duration_ns: u64,
    background_rgb: [u8; 3],
    objects: Vec<SyntheticObjectSpec>,
}

impl SyntheticFragmentSpec {
    pub fn new(
        sequence: u32,
        start_ns: u64,
        duration_ns: u64,
        background_rgb: [u8; 3],
        objects: Vec<SyntheticObjectSpec>,
    ) -> Self {
        Self {
            sequence,
            start_ns,
            duration_ns,
            background_rgb,
            objects,
        }
    }

    pub fn sequence(&self) -> u32 {
        self.sequence
    }

    pub fn start_ns(&self) -> u64 {
        self.start_ns
    }

    pub fn duration_ns(&self) -> u64 {
        self.duration_ns
    }

    pub fn background_rgb(&self) -> [u8; 3] {
        self.background_rgb
    }

    pub fn objects(&self) -> &[SyntheticObjectSpec] {
        &self.objects
    }
}

/// Complete synthetic ISO-BMFF / CMAF recording block (`init.mp4`, `media.m4s`,
/// frozen `descriptor.json`, and per-fragment SHA-256 digests).
#[derive(Debug, Clone)]
pub struct SyntheticCmafBlock {
    width: u32,
    height: u32,
    timescale: u32,
    init_mp4: Vec<u8>,
    init_sha256: String,
    media_m4s: Vec<u8>,
    media_sha256: String,
    descriptor: serde_json::Value,
    descriptor_sha256: String,
    init_plan: InitSlicePlan,
    fragment_plans: Vec<FragmentSlicePlan>,
}

impl SyntheticCmafBlock {
    pub fn width(&self) -> u32 {
        self.width
    }

    pub fn height(&self) -> u32 {
        self.height
    }

    pub fn timescale(&self) -> u32 {
        self.timescale
    }

    pub fn init_mp4(&self) -> &[u8] {
        &self.init_mp4
    }

    pub fn init_sha256(&self) -> &str {
        &self.init_sha256
    }

    pub fn media_m4s(&self) -> &[u8] {
        &self.media_m4s
    }

    pub fn media_sha256(&self) -> &str {
        &self.media_sha256
    }

    pub fn descriptor(&self) -> &serde_json::Value {
        &self.descriptor
    }

    pub fn descriptor_sha256(&self) -> &str {
        &self.descriptor_sha256
    }

    pub fn init_plan(&self) -> &InitSlicePlan {
        &self.init_plan
    }

    pub fn fragment_plans(&self) -> &[FragmentSlicePlan] {
        &self.fragment_plans
    }

    pub fn fragment_slice_bytes(&self, index: usize) -> Option<&[u8]> {
        let plan = self.fragment_plans.get(index)?;
        let start = plan.offset() as usize;
        let end = start + (plan.length() as usize);
        self.media_m4s.get(start..end)
    }
}

/// Generates a CMAF container fixture with an `init.mp4`, concatenated `media.m4s`
/// fragments and frozen descriptor digests. Its samples carry geometric scenes encoded
/// as `SRIDR1` rasters for the test-only decoder. Use a coded H.264 stream to exercise
/// production decoding.
pub fn generate_synthetic_cmaf_block(
    width: u32,
    height: u32,
    timescale: u32,
    fragment_specs: &[SyntheticFragmentSpec],
) -> Result<SyntheticCmafBlock, MediaWorkerError> {
    if width < 64 || height < 64 || width > MAX_FRAME_DIMENSION || height > MAX_FRAME_DIMENSION {
        return Err(MediaWorkerError::invalid_container(
            "synthetic CMAF dimensions must be within 64..=4096",
        ));
    }
    if timescale == 0 {
        return Err(MediaWorkerError::invalid_container(
            "synthetic CMAF timescale must be > 0",
        ));
    }

    // Fixed fixture SPS/PPS bytes accompany the synthetic SRIDR1 raster slices.
    let sps: [u8; 8] = [0x67, 0x42, 0x00, 0x1f, 0xe9, 0x01, 0x40, 0x7b];
    let pps: [u8; 4] = [0x68, 0xce, 0x06, 0xe2];
    let init_mp4 = build_init_mp4(
        width,
        height,
        timescale,
        b"avc1",
        &avcc_box(&[&sps], &[&pps]),
    );
    let fragments = fragment_specs.iter().map(|spec| {
        let frame = render_synthetic_pattern_frame(width, height, spec);
        let idr_nal = encode_synthetic_rle_idr_nal(&frame);
        // Access unit delimiter NAL (`0x09, 0x10`) + IDR slice NAL (`0x65...`).
        let aud_nal: [u8; 2] = [0x09, 0x10];
        let bytes = build_fragment_m4s(
            spec.sequence(),
            spec.start_ns(),
            spec.duration_ns(),
            timescale,
            &[&aud_nal, &idr_nal],
        );
        (spec.sequence(), spec.start_ns(), spec.duration_ns(), bytes)
    });
    assemble_cmaf_block(width, height, timescale, init_mp4, fragments)
}

/// Assembles a recording block (concatenated `media.m4s`, frozen descriptor and digests)
/// from an `init.mp4` and per-fragment `(sequence, start_ns, duration_ns, bytes)`.
pub(crate) fn assemble_cmaf_block(
    width: u32,
    height: u32,
    timescale: u32,
    init_mp4: Vec<u8>,
    fragments: impl IntoIterator<Item = (u32, u64, u64, Vec<u8>)>,
) -> Result<SyntheticCmafBlock, MediaWorkerError> {
    let init_sha256 = hex::encode(Sha256::digest(&init_mp4));
    let init_plan = InitSlicePlan::new(init_mp4.len() as u64, init_sha256.clone());

    let mut media_m4s = Vec::new();
    let fragments = fragments.into_iter();
    let mut fragment_plans = Vec::with_capacity(fragments.size_hint().0);
    let mut descriptor_fragments = Vec::with_capacity(fragments.size_hint().0);

    for (sequence, start_ns, duration_ns, frag_bytes) in fragments {
        let frag_sha = hex::encode(Sha256::digest(&frag_bytes));
        let offset = media_m4s.len() as u64;
        let length = frag_bytes.len() as u64;
        media_m4s.extend_from_slice(&frag_bytes);

        fragment_plans.push(FragmentSlicePlan::new(
            sequence,
            offset,
            length,
            start_ns,
            duration_ns,
            frag_sha.clone(),
        ));

        descriptor_fragments.push(serde_json::json!({
            "sequence": sequence,
            "offset": offset,
            "length": length,
            "start_ns": start_ns,
            "duration_ns": duration_ns,
            "keyframe": true,
            "sha256": frag_sha,
        }));
    }

    let media_sha256 = hex::encode(Sha256::digest(&media_m4s));
    let descriptor = serde_json::json!({
        "version": 1,
        "format": {
            "codec": "avc1.42001f",
            "timescale": timescale,
            "width": width,
            "height": height,
        },
        "init": {
            "offset": 0,
            "length": init_mp4.len(),
            "sha256": init_sha256,
        },
        "media": {
            "length": media_m4s.len(),
            "sha256": media_sha256,
        },
        "fragments": descriptor_fragments,
    });
    let descriptor_bytes = serde_json::to_vec(&descriptor).map_err(|err| {
        MediaWorkerError::invalid_container(format!("descriptor JSON serialization failed: {err}"))
    })?;
    let descriptor_sha256 = hex::encode(Sha256::digest(&descriptor_bytes));

    Ok(SyntheticCmafBlock {
        width,
        height,
        timescale,
        init_mp4,
        init_sha256,
        media_m4s,
        media_sha256,
        descriptor,
        descriptor_sha256,
        init_plan,
        fragment_plans,
    })
}

/// Renders programmatic geometric silhouettes into an `RgbFrame` (`0.4`).
pub fn render_synthetic_pattern_frame(
    width: u32,
    height: u32,
    spec: &SyntheticFragmentSpec,
) -> RgbFrame {
    let mut frame = RgbFrame::solid(width, height, spec.background_rgb());

    for obj in spec.objects() {
        let [nx1, ny1, nx2, ny2] = obj.bbox_norm();
        let x1 = ((nx1.clamp(0.0, 1.0) * (width as f32)).round() as u32).min(width - 1);
        let y1 = ((ny1.clamp(0.0, 1.0) * (height as f32)).round() as u32).min(height - 1);
        let x2 = ((nx2.clamp(0.0, 1.0) * (width as f32)).round() as u32).clamp(x1 + 1, width);
        let y2 = ((ny2.clamp(0.0, 1.0) * (height as f32)).round() as u32).clamp(y1 + 1, height);

        draw_geometric_object(
            &mut frame,
            x1,
            y1,
            x2,
            y2,
            obj.object_class(),
            obj.color().rgb(),
        );
    }

    frame
}

fn draw_geometric_object(
    frame: &mut RgbFrame,
    x1: u32,
    y1: u32,
    x2: u32,
    y2: u32,
    class: ObjectClass,
    rgb: [u8; 3],
) {
    let bw = (x2 - x1).max(1);
    let bh = (y2 - y1).max(1);

    for py in y1..y2 {
        let ry = ((py - y1) as f32 + 0.5) / (bh as f32);
        for px in x1..x2 {
            let rx = ((px - x1) as f32 + 0.5) / (bw as f32);
            let inside = match class {
                ObjectClass::Person => {
                    // Head in top 22% (centered 30%..70%), garment/torso/legs below.
                    if ry < 0.22 {
                        (0.30..=0.70).contains(&rx)
                    } else {
                        true
                    }
                }
                ObjectClass::Vehicle => {
                    // Full van/cargo body; cab step on top-right edge keeps realistic silhouette.
                    !(ry < 0.14 && rx > 0.86)
                }
                ObjectClass::Package => {
                    // Crisp solid rectangular parcel.
                    true
                }
                ObjectClass::Bicycle => {
                    // Two spoked wheel rings + crossbar frame (~42% fill ratio).
                    let left_dx = (rx - 0.25) * 2.2;
                    let right_dx = (rx - 0.75) * 2.2;
                    let wheel_dy = (ry - 0.70) * 2.2;
                    let left_r = (left_dx * left_dx + wheel_dy * wheel_dy).sqrt();
                    let right_r = (right_dx * right_dx + wheel_dy * wheel_dy).sqrt();
                    let on_wheel =
                        (0.34..=0.52).contains(&left_r) || (0.34..=0.52).contains(&right_r);
                    let on_frame = (0.32..=0.46).contains(&ry) && (0.20..=0.80).contains(&rx);
                    on_wheel || on_frame
                }
                ObjectClass::Animal => {
                    // Horizontal torso (ry 0.25..0.68) + head (top-left) + two leg columns (~62% fill).
                    let torso = (0.25..=0.68).contains(&ry);
                    let head = ry < 0.35 && rx < 0.28;
                    let legs =
                        ry > 0.68 && ((0.12..=0.30).contains(&rx) || (0.70..=0.88).contains(&rx));
                    torso || head || legs
                }
            };

            if inside {
                frame.set_pixel(px, py, rgb);
            }
        }
    }
}

fn encode_synthetic_rle_idr_nal(frame: &RgbFrame) -> Vec<u8> {
    let raw = frame.pixels();
    let total_pixels = (frame.width() as usize) * (frame.height() as usize);
    let mut runs: Vec<(u16, [u8; 3])> = Vec::new();

    let mut idx = 0usize;
    while idx < total_pixels {
        let base = idx * 3;
        let color = [raw[base], raw[base + 1], raw[base + 2]];
        let mut run_len = 1u16;
        while (idx + usize::from(run_len)) < total_pixels && run_len < u16::MAX {
            let next_base = (idx + usize::from(run_len)) * 3;
            let next_color = [raw[next_base], raw[next_base + 1], raw[next_base + 2]];
            if next_color != color {
                break;
            }
            run_len += 1;
        }
        runs.push((run_len, color));
        idx += usize::from(run_len);
    }

    // H.264 IDR slice NAL header (`0x65`: nal_ref_idc=3, nal_unit_type=5) + "SRIDR1" + RLE body.
    let mut nal = Vec::with_capacity(1 + 14 + runs.len() * 5);
    nal.push(0x65);
    nal.extend_from_slice(SYNTHETIC_IDR_MAGIC);
    nal.extend_from_slice(&(frame.width() as u16).to_be_bytes());
    nal.extend_from_slice(&(frame.height() as u16).to_be_bytes());
    nal.extend_from_slice(&(runs.len() as u32).to_be_bytes());
    for (len, rgb) in runs {
        nal.extend_from_slice(&len.to_be_bytes());
        nal.extend_from_slice(&rgb);
    }
    nal
}

fn mp4_box(box_type: &[u8; 4], payload: &[u8]) -> Vec<u8> {
    let total = (8 + payload.len()) as u32;
    let mut out = Vec::with_capacity(total as usize);
    out.extend_from_slice(&total.to_be_bytes());
    out.extend_from_slice(box_type);
    out.extend_from_slice(payload);
    out
}

fn mp4_full_box(box_type: &[u8; 4], version: u8, flags: u32, body: &[u8]) -> Vec<u8> {
    let total = (12 + body.len()) as u32;
    let mut out = Vec::with_capacity(total as usize);
    out.extend_from_slice(&total.to_be_bytes());
    out.extend_from_slice(box_type);
    let vf = ((u32::from(version)) << 24) | (flags & 0x00ff_ffff);
    out.extend_from_slice(&vf.to_be_bytes());
    out.extend_from_slice(body);
    out
}

/// Builds an `avcC` box (4-byte NAL lengths) carrying the given SPS and PPS NAL units.
pub(crate) fn avcc_box(sps: &[&[u8]], pps: &[&[u8]]) -> Vec<u8> {
    let profile = sps
        .first()
        .and_then(|s| s.get(1..4))
        .unwrap_or(&[0x42, 0x00, 0x1f]);
    let mut body = vec![1, profile[0], profile[1], profile[2], 0xff];
    body.push(0xe0 | (sps.len() as u8 & 0x1f));
    for nal in sps {
        body.extend_from_slice(&(nal.len() as u16).to_be_bytes());
        body.extend_from_slice(nal);
    }
    body.push(pps.len() as u8);
    for nal in pps {
        body.extend_from_slice(&(nal.len() as u16).to_be_bytes());
        body.extend_from_slice(nal);
    }
    mp4_box(b"avcC", &body)
}

/// Builds a CMAF `init.mp4` with one video track whose sample entry is `entry_type`
/// (`avc1`, `hvc1`, ...) carrying `config_box` (`avcC`, `hvcC`, ...).
pub(crate) fn build_init_mp4(
    width: u32,
    height: u32,
    timescale: u32,
    entry_type: &[u8; 4],
    config_box: &[u8],
) -> Vec<u8> {
    // 1. ftyp (`cmfc`, minor 0, compatible `cmfc`, `iso6`, `avc1`, `mp41`)
    let mut ftyp_body = Vec::with_capacity(24);
    ftyp_body.extend_from_slice(b"cmfc");
    ftyp_body.extend_from_slice(&0u32.to_be_bytes());
    ftyp_body.extend_from_slice(b"cmfciso6avc1mp41");
    let ftyp = mp4_box(b"ftyp", &ftyp_body);

    // 2. mvhd (v0)
    let mut mvhd_body = vec![0u8; 96];
    mvhd_body[8..12].copy_from_slice(&timescale.to_be_bytes());
    mvhd_body[16..20].copy_from_slice(&0x0001_0000u32.to_be_bytes()); // rate 1.0
    mvhd_body[20..22].copy_from_slice(&0x0100u16.to_be_bytes()); // volume 1.0
    mvhd_body[32..36].copy_from_slice(&0x0001_0000u32.to_be_bytes()); // unity matrix
    mvhd_body[48..52].copy_from_slice(&0x0001_0000u32.to_be_bytes());
    mvhd_body[64..68].copy_from_slice(&0x4000_0000u32.to_be_bytes());
    mvhd_body[92..96].copy_from_slice(&2u32.to_be_bytes()); // next_track_ID
    let mvhd = mp4_full_box(b"mvhd", 0, 0, &mvhd_body);

    // 3. tkhd (v0, flags=3 track_enabled|track_in_movie)
    let mut tkhd_body = vec![0u8; 80];
    tkhd_body[8..12].copy_from_slice(&1u32.to_be_bytes()); // track_id = 1
    tkhd_body[36..40].copy_from_slice(&0x0001_0000u32.to_be_bytes());
    tkhd_body[52..56].copy_from_slice(&0x0001_0000u32.to_be_bytes());
    tkhd_body[68..72].copy_from_slice(&0x4000_0000u32.to_be_bytes());
    tkhd_body[72..76].copy_from_slice(&(width << 16).to_be_bytes());
    tkhd_body[76..80].copy_from_slice(&(height << 16).to_be_bytes());
    let tkhd = mp4_full_box(b"tkhd", 0, 0x000003, &tkhd_body);

    // 4. mdhd + hdlr
    let mut mdhd_body = vec![0u8; 20];
    mdhd_body[8..12].copy_from_slice(&timescale.to_be_bytes());
    mdhd_body[16..18].copy_from_slice(&0x55c4u16.to_be_bytes()); // "und"
    let mdhd = mp4_full_box(b"mdhd", 0, 0, &mdhd_body);

    let mut hdlr_body = Vec::with_capacity(25);
    hdlr_body.extend_from_slice(&0u32.to_be_bytes());
    hdlr_body.extend_from_slice(b"vide");
    hdlr_body.extend_from_slice(&[0u8; 12]);
    hdlr_body.extend_from_slice(b"VideoHandler\0");
    let hdlr = mp4_full_box(b"hdlr", 0, 0, &hdlr_body);

    // 5. sample entry (+ codec configuration box) + stsd + stbl + minf
    let mut avc1_body = vec![0u8; 78];
    avc1_body[6..8].copy_from_slice(&1u16.to_be_bytes()); // data_reference_index = 1
    avc1_body[24..26].copy_from_slice(&(width as u16).to_be_bytes());
    avc1_body[26..28].copy_from_slice(&(height as u16).to_be_bytes());
    avc1_body[28..32].copy_from_slice(&0x0048_0000u32.to_be_bytes()); // 72 dpi
    avc1_body[32..36].copy_from_slice(&0x0048_0000u32.to_be_bytes());
    avc1_body[40..42].copy_from_slice(&1u16.to_be_bytes()); // frame_count = 1
    avc1_body[74..76].copy_from_slice(&0x0018u16.to_be_bytes()); // depth = 24
    avc1_body[76..78].copy_from_slice(&0xffffu16.to_be_bytes()); // pre_defined = -1
    avc1_body.extend_from_slice(config_box);
    let avc1 = mp4_box(entry_type, &avc1_body);

    let mut stsd_body = Vec::with_capacity(4 + avc1.len());
    stsd_body.extend_from_slice(&1u32.to_be_bytes()); // entry_count = 1
    stsd_body.extend_from_slice(&avc1);
    let stsd = mp4_full_box(b"stsd", 0, 0, &stsd_body);

    let empty_count = 0u32.to_be_bytes();
    let stts = mp4_full_box(b"stts", 0, 0, &empty_count);
    let stsc = mp4_full_box(b"stsc", 0, 0, &empty_count);
    let stsz = mp4_full_box(b"stsz", 0, 0, &[0u8; 8]);
    let stco = mp4_full_box(b"stco", 0, 0, &empty_count);

    let mut stbl_body = Vec::new();
    stbl_body.extend_from_slice(&stsd);
    stbl_body.extend_from_slice(&stts);
    stbl_body.extend_from_slice(&stsc);
    stbl_body.extend_from_slice(&stsz);
    stbl_body.extend_from_slice(&stco);
    let stbl = mp4_box(b"stbl", &stbl_body);

    let vmhd = mp4_full_box(b"vmhd", 0, 1, &[0u8; 8]);
    let url_box = mp4_full_box(b"url ", 0, 1, &[]);
    let mut dref_body = Vec::with_capacity(4 + url_box.len());
    dref_body.extend_from_slice(&1u32.to_be_bytes());
    dref_body.extend_from_slice(&url_box);
    let dref = mp4_full_box(b"dref", 0, 0, &dref_body);
    let dinf = mp4_box(b"dinf", &dref);

    let mut minf_body = Vec::new();
    minf_body.extend_from_slice(&vmhd);
    minf_body.extend_from_slice(&dinf);
    minf_body.extend_from_slice(&stbl);
    let minf = mp4_box(b"minf", &minf_body);

    let mut mdia_body = Vec::new();
    mdia_body.extend_from_slice(&mdhd);
    mdia_body.extend_from_slice(&hdlr);
    mdia_body.extend_from_slice(&minf);
    let mdia = mp4_box(b"mdia", &mdia_body);

    let mut trak_body = Vec::new();
    trak_body.extend_from_slice(&tkhd);
    trak_body.extend_from_slice(&mdia);
    let trak = mp4_box(b"trak", &trak_body);

    // 6. mvex -> trex
    let mut trex_body = Vec::with_capacity(20);
    trex_body.extend_from_slice(&1u32.to_be_bytes()); // track_id = 1
    trex_body.extend_from_slice(&1u32.to_be_bytes()); // default_sample_description_index = 1
    trex_body.extend_from_slice(&[0u8; 12]);
    let trex = mp4_full_box(b"trex", 0, 0, &trex_body);
    let mvex = mp4_box(b"mvex", &trex);

    let mut moov_body = Vec::new();
    moov_body.extend_from_slice(&mvhd);
    moov_body.extend_from_slice(&trak);
    moov_body.extend_from_slice(&mvex);
    let moov = mp4_box(b"moov", &moov_body);

    let mut init_mp4 = Vec::with_capacity(ftyp.len() + moov.len());
    init_mp4.extend_from_slice(&ftyp);
    init_mp4.extend_from_slice(&moov);
    init_mp4
}

/// Builds one CMAF fragment (`moof` + `mdat`) holding a single sync sample made of the
/// given NAL units, each written with a 4-byte length prefix.
pub(crate) fn build_fragment_m4s(
    sequence: u32,
    start_ns: u64,
    duration_ns: u64,
    timescale: u32,
    sample_nals: &[&[u8]],
) -> Vec<u8> {
    let mut sample_data = Vec::new();
    for nal in sample_nals {
        sample_data.extend_from_slice(&(nal.len() as u32).to_be_bytes());
        sample_data.extend_from_slice(nal);
    }

    let decode_ticks =
        u64::try_from(u128::from(start_ns).saturating_mul(u128::from(timescale)) / 1_000_000_000)
            .unwrap_or(0);
    let dur_ticks = u32::try_from(
        u128::from(duration_ns).saturating_mul(u128::from(timescale)) / 1_000_000_000,
    )
    .unwrap_or(timescale * 2);

    let mfhd = mp4_full_box(b"mfhd", 0, 0, &(sequence + 1).to_be_bytes());
    // tfhd flags `0x020000` (`default-base-is-moof`)
    let tfhd = mp4_full_box(b"tfhd", 0, 0x020000, &1u32.to_be_bytes());
    let tfdt = mp4_full_box(b"tfdt", 1, 0, &decode_ticks.to_be_bytes());

    // trun flags: `0x000004` (first_sample_flags) | `0x000100` (duration) | `0x000200` (size)
    let mut trun_body = Vec::with_capacity(16);
    trun_body.extend_from_slice(&1u32.to_be_bytes()); // sample_count = 1
    trun_body.extend_from_slice(&0x0200_0000u32.to_be_bytes()); // sync IDR (`sample_depends_on=2`, `non_sync=0`)
    trun_body.extend_from_slice(&dur_ticks.to_be_bytes());
    trun_body.extend_from_slice(&(sample_data.len() as u32).to_be_bytes());
    let trun = mp4_full_box(b"trun", 0, 0x000304, &trun_body);

    let mut traf_body = Vec::new();
    traf_body.extend_from_slice(&tfhd);
    traf_body.extend_from_slice(&tfdt);
    traf_body.extend_from_slice(&trun);
    let traf = mp4_box(b"traf", &traf_body);

    let mut moof_body = Vec::new();
    moof_body.extend_from_slice(&mfhd);
    moof_body.extend_from_slice(&traf);
    let moof = mp4_box(b"moof", &moof_body);
    let mdat = mp4_box(b"mdat", &sample_data);

    let mut frag = Vec::with_capacity(moof.len() + mdat.len());
    frag.extend_from_slice(&moof);
    frag.extend_from_slice(&mdat);
    frag
}

#[cfg(test)]
mod init_tests {
    use super::*;

    #[test]
    fn synthetic_fixture_exposes_its_container_metadata() {
        let block = generate_synthetic_cmaf_block(128, 96, 90_000, &[]).unwrap();
        let init = parse_init_segment(block.init_mp4()).unwrap();
        assert_eq!(init.codec(), VideoCodec::H264);
        assert_eq!(
            (init.width(), init.height(), init.timescale()),
            (128, 96, 90_000)
        );
    }

    #[test]
    fn trailing_box_errors_preserve_the_codec_of_a_complete_sample_entry() {
        for (entry, codec) in [
            (b"avc1", VideoCodec::H264),
            (b"avc3", VideoCodec::H264),
            (b"hvc1", VideoCodec::Hevc),
            (b"hev1", VideoCodec::Hevc),
        ] {
            let mut sample = vec![0; 78];
            sample[24..28].copy_from_slice(&[0, 16, 0, 16]);
            match codec {
                VideoCodec::H264 => sample.extend(avcc_box(&[], &[])),
                VideoCodec::Hevc => {
                    let mut hvcc = [0; 23];
                    hvcc[0] = 1;
                    hvcc[21] = 3;
                    sample.extend(mp4_box(b"hvcC", &hvcc));
                }
            }
            let levels = [b"stsd", b"stbl", b"minf", b"mdia", b"trak", b"moov"];
            for damaged in 0..=levels.len() {
                let mut child = mp4_box(entry, &sample);
                for (depth, tag) in levels.iter().enumerate() {
                    if damaged == depth {
                        child.push(0);
                    }
                    child = if *tag == b"stsd" {
                        mp4_full_box(tag, 0, 0, &[&1u32.to_be_bytes()[..], &child].concat())
                    } else {
                        mp4_box(tag, &child)
                    };
                }
                let mut bytes = mp4_box(b"ftyp", b"iso6\0\0\0\0iso6");
                bytes.extend(child);
                if damaged == levels.len() {
                    bytes.push(0);
                }
                let (identified, result) = parse_init_segment_with_codec(&bytes);
                assert_eq!(identified, Some(codec));
                assert_eq!(result.unwrap_err().error_class(), "invalid_container");
            }
        }
    }
}
