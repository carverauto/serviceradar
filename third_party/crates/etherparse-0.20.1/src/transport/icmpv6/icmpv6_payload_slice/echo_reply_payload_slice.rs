use crate::err;

/// Borrowed payload of an Echo Reply message (RFC 4443, Section 4.2).
///
/// The full packet layout is:
/// ```text
///  0                   1                   2                   3
///  0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
/// +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
/// |     Type      |     Code      |          Checksum             |
/// +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
/// |           Identifier          |        Sequence Number        |
/// +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
/// |     Data ...
/// +-+-+-+-+-+-+-+-+-
/// ```
///
/// In this crate, `Type`, `Code`, `Identifier`, and `Sequence Number` are
/// represented by [`crate::Icmpv6Type::EchoReply`]. This slice represents
/// the echoed data after that fixed part.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct EchoReplyPayloadSlice<'a> {
    slice: &'a [u8],
}

impl<'a> EchoReplyPayloadSlice<'a> {
    /// Creates a payload slice from the bytes after the ICMPv6 header.
    pub fn from_slice(slice: &'a [u8]) -> Result<Self, err::LenError> {
        Ok(Self { slice })
    }

    /// Returns the full payload slice.
    pub fn slice(&self) -> &'a [u8] {
        self.slice
    }

    /// Returns the echoed data bytes.
    pub fn data(&self) -> &'a [u8] {
        self.slice
    }
}
