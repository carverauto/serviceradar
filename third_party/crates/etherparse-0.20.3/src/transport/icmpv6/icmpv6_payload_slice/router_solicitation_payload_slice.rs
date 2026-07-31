use crate::{
    err,
    icmpv6::{NdpOptionsIterator, RouterSolicitationPayload},
};

/// Borrowed payload of a Router Solicitation message (RFC 4861, Section 4.1).
///
/// The full packet layout is:
/// ```text
///  0                   1                   2                   3
///  0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
/// +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
/// |     Type      |     Code      |          Checksum             |
/// +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
/// |                            Reserved                           |
/// +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
/// |   Options ...
/// +-+-+-+-+-+-+-+-+-+-+-+-
/// ```
///
/// In this crate, the first 8 bytes (including `Reserved`) are represented by
/// [`crate::Icmpv6Type::RouterSolicitation`]. This slice represents the bytes
/// after that fixed part (i.e. the options area).
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RouterSolicitationPayloadSlice<'a> {
    slice: &'a [u8],
}

impl<'a> RouterSolicitationPayloadSlice<'a> {
    /// Creates a payload slice from the bytes after the ICMPv6 header.
    pub fn from_slice(slice: &'a [u8]) -> Result<Self, err::LenError> {
        Ok(Self { slice })
    }

    /// Returns the full payload slice.
    pub fn slice(&self) -> &'a [u8] {
        self.slice
    }

    /// Returns the Neighbor Discovery options.
    pub fn options(&self) -> &'a [u8] {
        self.slice
    }

    /// Returns an iterator over Neighbor Discovery options.
    pub fn options_iterator(&self) -> NdpOptionsIterator<'a> {
        NdpOptionsIterator::from_slice(self.options())
    }

    /// Convert to an owned structured payload and return trailing options.
    pub fn to_payload(&self) -> (RouterSolicitationPayload, &'a [u8]) {
        (RouterSolicitationPayload, self.options())
    }
}
