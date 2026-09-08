#![allow(dead_code)]
// The concrete IronRDP graphics loop is still fail-closed; keep the SRDP
// encoder compiled and tested while backend output mapping lands incrementally.

use std::error::Error;
use std::fmt;

use crate::protocol::DesktopScreenPolicy;

const DESKTOP_MEDIA_MAGIC: &[u8; 4] = b"SRDP";
const DESKTOP_MEDIA_VERSION: u8 = 1;
const DESKTOP_MEDIA_HEADER_SIZE: usize = 48;
const DESKTOP_MEDIA_MAX_METADATA: usize = 64 * 1024;
const DESKTOP_MAX_FRAME_DATA: usize = 1_048_576;

pub(crate) const DESKTOP_MEDIA_FLAG_KEYFRAME: u8 = 0x01;
pub(crate) const DESKTOP_MEDIA_FLAG_FULL_FRAME: u8 = 0x02;
pub(crate) const DESKTOP_MEDIA_FLAG_CURSOR_UPDATE: u8 = 0x04;
pub(crate) const DESKTOP_MEDIA_FLAG_END_OF_STREAM: u8 = 0x08;
pub(crate) const DESKTOP_MEDIA_FLAG_DISCONTINUITY: u8 = 0x10;
const DESKTOP_MEDIA_ALLOWED_FLAGS: u8 = DESKTOP_MEDIA_FLAG_KEYFRAME
    | DESKTOP_MEDIA_FLAG_FULL_FRAME
    | DESKTOP_MEDIA_FLAG_CURSOR_UPDATE
    | DESKTOP_MEDIA_FLAG_END_OF_STREAM
    | DESKTOP_MEDIA_FLAG_DISCONTINUITY;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum DesktopMediaPayloadFamily {
    Video,
    DirtyRect,
    Tile,
    Cursor,
    Metadata,
}

impl DesktopMediaPayloadFamily {
    fn id(self) -> u8 {
        match self {
            Self::Video => 1,
            Self::DirtyRect => 2,
            Self::Tile => 3,
            Self::Cursor => 4,
            Self::Metadata => 5,
        }
    }

    fn requires_dimensions(self) -> bool {
        matches!(self, Self::Video | Self::DirtyRect | Self::Tile)
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) struct DesktopMediaFrame<'a> {
    pub session_binding_id: &'a str,
    pub media_session_id: &'a str,
    pub sequence: u64,
    pub timestamp_unix_nano: i64,
    pub width: u32,
    pub height: u32,
    pub payload_family: DesktopMediaPayloadFamily,
    pub encoding: &'a str,
    pub metadata: &'a [u8],
    pub payload: &'a [u8],
    pub flags: u8,
}

#[derive(Debug, Eq, PartialEq)]
pub(crate) enum DesktopMediaFrameError {
    MissingSessionBinding,
    MissingMediaSession,
    StringFieldTooLarge,
    InvalidStringField,
    MetadataTooLarge,
    PayloadTooLarge,
    UnsupportedFlags,
    DimensionsExceedPolicy,
    FrameLengthOverflow,
}

impl fmt::Display for DesktopMediaFrameError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::MissingSessionBinding => {
                f.write_str("desktop media frame missing session binding")
            }
            Self::MissingMediaSession => f.write_str("desktop media frame missing media session"),
            Self::StringFieldTooLarge => {
                f.write_str("desktop media frame string field is too large")
            }
            Self::InvalidStringField => f.write_str("desktop media frame string field is invalid"),
            Self::MetadataTooLarge => f.write_str("desktop media frame metadata is too large"),
            Self::PayloadTooLarge => f.write_str("desktop media frame payload is too large"),
            Self::UnsupportedFlags => f.write_str("desktop media frame flags are unsupported"),
            Self::DimensionsExceedPolicy => {
                f.write_str("desktop media frame dimensions exceed policy")
            }
            Self::FrameLengthOverflow => f.write_str("desktop media frame length overflow"),
        }
    }
}

impl Error for DesktopMediaFrameError {}

pub(crate) fn encode_desktop_media_frame(
    frame: &DesktopMediaFrame<'_>,
    policy: &DesktopScreenPolicy,
) -> Result<Vec<u8>, DesktopMediaFrameError> {
    validate_desktop_media_frame(frame, policy)?;

    let session_binding = frame.session_binding_id.as_bytes();
    let media_session = frame.media_session_id.as_bytes();
    let encoding = frame.encoding.as_bytes();
    let total_length = DESKTOP_MEDIA_HEADER_SIZE
        .checked_add(session_binding.len())
        .and_then(|length| length.checked_add(media_session.len()))
        .and_then(|length| length.checked_add(encoding.len()))
        .and_then(|length| length.checked_add(frame.metadata.len()))
        .and_then(|length| length.checked_add(frame.payload.len()))
        .ok_or(DesktopMediaFrameError::FrameLengthOverflow)?;

    let mut output = vec![0u8; total_length];
    output[0..4].copy_from_slice(DESKTOP_MEDIA_MAGIC);
    output[4] = DESKTOP_MEDIA_VERSION;
    output[5] = frame.flags;
    output[6] = frame.payload_family.id();
    output[8..16].copy_from_slice(&frame.sequence.to_be_bytes());
    output[16..24].copy_from_slice(&frame.timestamp_unix_nano.to_be_bytes());
    output[24..28].copy_from_slice(&frame.width.to_be_bytes());
    output[28..32].copy_from_slice(&frame.height.to_be_bytes());
    output[32..36].copy_from_slice(
        &u32::try_from(frame.metadata.len())
            .map_err(|_| DesktopMediaFrameError::MetadataTooLarge)?
            .to_be_bytes(),
    );
    output[36..40].copy_from_slice(
        &u32::try_from(frame.payload.len())
            .map_err(|_| DesktopMediaFrameError::PayloadTooLarge)?
            .to_be_bytes(),
    );
    output[40..42].copy_from_slice(
        &u16::try_from(encoding.len())
            .map_err(|_| DesktopMediaFrameError::StringFieldTooLarge)?
            .to_be_bytes(),
    );
    output[42..44].copy_from_slice(
        &u16::try_from(session_binding.len())
            .map_err(|_| DesktopMediaFrameError::StringFieldTooLarge)?
            .to_be_bytes(),
    );
    output[44..46].copy_from_slice(
        &u16::try_from(media_session.len())
            .map_err(|_| DesktopMediaFrameError::StringFieldTooLarge)?
            .to_be_bytes(),
    );

    let mut offset = DESKTOP_MEDIA_HEADER_SIZE;
    output[offset..offset + session_binding.len()].copy_from_slice(session_binding);
    offset += session_binding.len();
    output[offset..offset + media_session.len()].copy_from_slice(media_session);
    offset += media_session.len();
    output[offset..offset + encoding.len()].copy_from_slice(encoding);
    offset += encoding.len();
    output[offset..offset + frame.metadata.len()].copy_from_slice(frame.metadata);
    offset += frame.metadata.len();
    output[offset..offset + frame.payload.len()].copy_from_slice(frame.payload);

    Ok(output)
}

fn validate_desktop_media_frame(
    frame: &DesktopMediaFrame<'_>,
    policy: &DesktopScreenPolicy,
) -> Result<(), DesktopMediaFrameError> {
    if frame.session_binding_id.is_empty() {
        return Err(DesktopMediaFrameError::MissingSessionBinding);
    }
    if frame.media_session_id.is_empty() {
        return Err(DesktopMediaFrameError::MissingMediaSession);
    }
    if frame.session_binding_id.len() > u16::MAX as usize
        || frame.media_session_id.len() > u16::MAX as usize
        || frame.encoding.len() > u16::MAX as usize
    {
        return Err(DesktopMediaFrameError::StringFieldTooLarge);
    }
    if invalid_media_string(frame.session_binding_id)
        || invalid_media_string(frame.media_session_id)
        || invalid_media_string(frame.encoding)
    {
        return Err(DesktopMediaFrameError::InvalidStringField);
    }
    if frame.metadata.len() > DESKTOP_MEDIA_MAX_METADATA {
        return Err(DesktopMediaFrameError::MetadataTooLarge);
    }
    if frame.payload.len() > DESKTOP_MAX_FRAME_DATA {
        return Err(DesktopMediaFrameError::PayloadTooLarge);
    }
    if frame.flags & !DESKTOP_MEDIA_ALLOWED_FLAGS != 0 {
        return Err(DesktopMediaFrameError::UnsupportedFlags);
    }
    if frame.payload_family.requires_dimensions() && (frame.width == 0 || frame.height == 0) {
        return Err(DesktopMediaFrameError::DimensionsExceedPolicy);
    }
    if frame.width > policy.max_width || frame.height > policy.max_height {
        return Err(DesktopMediaFrameError::DimensionsExceedPolicy);
    }

    Ok(())
}

fn invalid_media_string(value: &str) -> bool {
    value
        .bytes()
        .any(|byte| byte == 0 || (byte.is_ascii_control() && !byte.is_ascii_whitespace()))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn encode_desktop_media_frame_matches_srdp_wire_layout() {
        let policy = test_screen_policy();
        let frame = DesktopMediaFrame {
            session_binding_id: "session-1",
            media_session_id: "media-1",
            sequence: 42,
            timestamp_unix_nano: -7,
            width: 800,
            height: 600,
            payload_family: DesktopMediaPayloadFamily::DirtyRect,
            encoding: "raw_rgba",
            metadata: br#"{"x":1}"#,
            payload: &[1, 2, 3, 4],
            flags: DESKTOP_MEDIA_FLAG_KEYFRAME | DESKTOP_MEDIA_FLAG_FULL_FRAME,
        };

        let encoded = encode_desktop_media_frame(&frame, &policy).expect("encode frame");

        assert_eq!(&encoded[0..4], DESKTOP_MEDIA_MAGIC);
        assert_eq!(encoded[4], DESKTOP_MEDIA_VERSION);
        assert_eq!(
            encoded[5],
            DESKTOP_MEDIA_FLAG_KEYFRAME | DESKTOP_MEDIA_FLAG_FULL_FRAME
        );
        assert_eq!(encoded[6], DesktopMediaPayloadFamily::DirtyRect.id());
        assert_eq!(u64::from_be_bytes(encoded[8..16].try_into().unwrap()), 42);
        assert_eq!(i64::from_be_bytes(encoded[16..24].try_into().unwrap()), -7);
        assert_eq!(u32::from_be_bytes(encoded[24..28].try_into().unwrap()), 800);
        assert_eq!(u32::from_be_bytes(encoded[28..32].try_into().unwrap()), 600);
        assert_eq!(u32::from_be_bytes(encoded[32..36].try_into().unwrap()), 7);
        assert_eq!(u32::from_be_bytes(encoded[36..40].try_into().unwrap()), 4);
        assert_eq!(u16::from_be_bytes(encoded[40..42].try_into().unwrap()), 8);
        assert_eq!(u16::from_be_bytes(encoded[42..44].try_into().unwrap()), 9);
        assert_eq!(u16::from_be_bytes(encoded[44..46].try_into().unwrap()), 7);
        assert_eq!(u16::from_be_bytes(encoded[46..48].try_into().unwrap()), 0);
        assert_eq!(
            &encoded[DESKTOP_MEDIA_HEADER_SIZE..],
            b"session-1media-1raw_rgba{\"x\":1}\x01\x02\x03\x04"
        );
    }

    #[test]
    fn encode_desktop_media_frame_accepts_dimensionless_metadata_frame() {
        let policy = test_screen_policy();
        let frame = DesktopMediaFrame {
            session_binding_id: "session-1",
            media_session_id: "media-1",
            sequence: 1,
            timestamp_unix_nano: 0,
            width: 0,
            height: 0,
            payload_family: DesktopMediaPayloadFamily::Metadata,
            encoding: "json",
            metadata: b"{}",
            payload: &[],
            flags: 0,
        };

        let encoded = encode_desktop_media_frame(&frame, &policy).expect("encode metadata frame");

        assert_eq!(encoded[6], DesktopMediaPayloadFamily::Metadata.id());
    }

    #[test]
    fn encode_desktop_media_frame_rejects_invalid_bounds() {
        let policy = test_screen_policy();
        let too_wide = DesktopMediaFrame {
            session_binding_id: "session-1",
            media_session_id: "media-1",
            sequence: 1,
            timestamp_unix_nano: 0,
            width: policy.max_width + 1,
            height: 600,
            payload_family: DesktopMediaPayloadFamily::DirtyRect,
            encoding: "raw_rgba",
            metadata: &[],
            payload: &[1],
            flags: 0,
        };

        assert_eq!(
            encode_desktop_media_frame(&too_wide, &policy),
            Err(DesktopMediaFrameError::DimensionsExceedPolicy)
        );

        let missing_media = DesktopMediaFrame {
            media_session_id: "",
            ..too_wide
        };
        assert_eq!(
            encode_desktop_media_frame(&missing_media, &policy),
            Err(DesktopMediaFrameError::MissingMediaSession)
        );

        let large_metadata = vec![0u8; DESKTOP_MEDIA_MAX_METADATA + 1];
        let oversized_metadata = DesktopMediaFrame {
            width: 800,
            metadata: &large_metadata,
            ..too_wide
        };
        assert_eq!(
            encode_desktop_media_frame(&oversized_metadata, &policy),
            Err(DesktopMediaFrameError::MetadataTooLarge)
        );

        let unsupported_flags = DesktopMediaFrame {
            width: 800,
            flags: 0x20,
            ..too_wide
        };
        assert_eq!(
            encode_desktop_media_frame(&unsupported_flags, &policy),
            Err(DesktopMediaFrameError::UnsupportedFlags)
        );

        let invalid_session = DesktopMediaFrame {
            session_binding_id: "session\0-1",
            width: 800,
            ..too_wide
        };
        assert_eq!(
            encode_desktop_media_frame(&invalid_session, &policy),
            Err(DesktopMediaFrameError::InvalidStringField)
        );

        let invalid_encoding = DesktopMediaFrame {
            encoding: "raw\u{0007}",
            width: 800,
            ..too_wide
        };
        assert_eq!(
            encode_desktop_media_frame(&invalid_encoding, &policy),
            Err(DesktopMediaFrameError::InvalidStringField)
        );
    }

    #[test]
    fn encode_desktop_media_frame_exposes_all_family_and_flag_values() {
        assert_eq!(DesktopMediaPayloadFamily::Video.id(), 1);
        assert_eq!(DesktopMediaPayloadFamily::DirtyRect.id(), 2);
        assert_eq!(DesktopMediaPayloadFamily::Tile.id(), 3);
        assert_eq!(DesktopMediaPayloadFamily::Cursor.id(), 4);
        assert_eq!(DesktopMediaPayloadFamily::Metadata.id(), 5);
        assert_eq!(DESKTOP_MEDIA_FLAG_KEYFRAME, 0x01);
        assert_eq!(DESKTOP_MEDIA_FLAG_FULL_FRAME, 0x02);
        assert_eq!(DESKTOP_MEDIA_FLAG_CURSOR_UPDATE, 0x04);
        assert_eq!(DESKTOP_MEDIA_FLAG_END_OF_STREAM, 0x08);
        assert_eq!(DESKTOP_MEDIA_FLAG_DISCONTINUITY, 0x10);
    }

    fn test_screen_policy() -> DesktopScreenPolicy {
        DesktopScreenPolicy {
            max_width: 1920,
            max_height: 1080,
            color_depth: 0,
            frame_rate: 30,
            bitrate_bps: 8_000_000,
            idle_seconds: 900,
            ttl_seconds: 3600,
        }
    }
}
