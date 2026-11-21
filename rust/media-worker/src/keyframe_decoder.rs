//! Keyframe decoder abstraction: turns one verified CMAF keyframe sample into an RGB frame.
//!
//! The worker decodes only the first (IDR) sample of each sampled fragment, statelessly. A
//! decoder either returns the real decoded picture or a typed [`KeyframeDecodeError`]; it
//! never fabricates a frame. Callers record a failed keyframe as undecodable and keep
//! processing the rest of the block.
//!
//! [`DefaultKeyframeDecoder`] is the production implementation: pure-Rust H.264 through
//! `rusty_h264-decoder`, HEVC reported as unsupported. Another codec or a hardware decoder
//! is added as an arm here (or as another implementation), without touching callers.

use crate::cmaf::{ParsedInitSegment, ParsedMediaFragment, VideoCodec};
use crate::h264;
use crate::vision::RgbFrame;
use core::fmt::{self, Display, Formatter};

/// Largest keyframe access unit (parameter sets plus IDR slices) handed to a decoder. It
/// equals the per-fragment fetch bound, so a valid fragment never trips it; it exists so the
/// decoder input stays bounded even if that fetch bound changes.
pub const MAX_KEYFRAME_ACCESS_UNIT_BYTES: usize = 4 * 1024 * 1024;

/// Most IDR slice NAL units accepted for one picture. One slice per macroblock row of a
/// 4096-line picture is 256; cameras use far fewer.
pub const MAX_KEYFRAME_SLICES: usize = 1024;

/// Largest single SPS/PPS NAL unit accepted (in-band or from the init segment).
pub const MAX_PARAMETER_SET_BYTES: usize = 4096;

/// Why a keyframe could not be decoded. Each variant maps to one bounded `reason` string.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
#[non_exhaustive]
pub enum KeyframeDecodeErrorKind {
    /// The codec, profile or coding tool is outside what this worker decodes (for example
    /// HEVC, H.264 High 10, 4:2:2 chroma or interlaced coding).
    UnsupportedCodec(String),
    /// The bitstream is invalid, incomplete or inconsistent.
    MalformedBitstream(String),
    /// The keyframe exceeds a hard resource limit (dimensions, bytes, slice count).
    LimitExceeded(String),
}

/// Typed, per-keyframe decode failure.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct KeyframeDecodeError(KeyframeDecodeErrorKind);

impl KeyframeDecodeError {
    pub fn unsupported_codec(detail: impl Into<String>) -> Self {
        Self(KeyframeDecodeErrorKind::UnsupportedCodec(detail.into()))
    }

    pub fn malformed_bitstream(detail: impl Into<String>) -> Self {
        Self(KeyframeDecodeErrorKind::MalformedBitstream(detail.into()))
    }

    pub fn limit_exceeded(detail: impl Into<String>) -> Self {
        Self(KeyframeDecodeErrorKind::LimitExceeded(detail.into()))
    }

    pub fn kind(&self) -> &KeyframeDecodeErrorKind {
        &self.0
    }

    /// Bounded reason identifier, used in result payloads and metric labels.
    pub fn reason(&self) -> &'static str {
        match &self.0 {
            KeyframeDecodeErrorKind::UnsupportedCodec(_) => "unsupported_codec",
            KeyframeDecodeErrorKind::MalformedBitstream(_) => "malformed_bitstream",
            KeyframeDecodeErrorKind::LimitExceeded(_) => "limit_exceeded",
        }
    }

    pub fn detail(&self) -> &str {
        match &self.0 {
            KeyframeDecodeErrorKind::UnsupportedCodec(d)
            | KeyframeDecodeErrorKind::MalformedBitstream(d)
            | KeyframeDecodeErrorKind::LimitExceeded(d) => d,
        }
    }
}

impl Display for KeyframeDecodeError {
    fn fmt(&self, f: &mut Formatter<'_>) -> fmt::Result {
        write!(f, "{}: {}", self.reason(), self.detail())
    }
}

impl std::error::Error for KeyframeDecodeError {}

/// Decodes the IDR keyframe of one parsed CMAF fragment into an RGB8 frame.
pub trait KeyframeDecoder: Send + Sync {
    fn decode_keyframe(
        &self,
        init: &ParsedInitSegment,
        fragment: &ParsedMediaFragment,
    ) -> Result<RgbFrame, KeyframeDecodeError>;
}

/// Production decoder: H.264 (Constrained Baseline, Main and High; 8-bit 4:2:0 progressive)
/// in pure Rust. HEVC is reported as unsupported.
#[derive(Debug, Clone, Copy, Default)]
pub struct DefaultKeyframeDecoder;

impl DefaultKeyframeDecoder {
    pub fn new() -> Self {
        Self
    }
}

impl KeyframeDecoder for DefaultKeyframeDecoder {
    fn decode_keyframe(
        &self,
        init: &ParsedInitSegment,
        fragment: &ParsedMediaFragment,
    ) -> Result<RgbFrame, KeyframeDecodeError> {
        match init.codec() {
            VideoCodec::H264 => h264::decode_keyframe(init, fragment),
            VideoCodec::Hevc => Err(KeyframeDecodeError::unsupported_codec(
                "hevc: this worker decodes H.264 only",
            )),
        }
    }
}
