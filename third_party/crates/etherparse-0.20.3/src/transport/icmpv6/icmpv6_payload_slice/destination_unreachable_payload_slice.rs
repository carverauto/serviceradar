use crate::{err, LaxIpSlice};

/// Borrowed payload of a Destination Unreachable message (RFC 4443, Section 3.1).
///
/// The full packet layout is:
/// ```text
///  0                   1                   2                   3
///  0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
/// +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
/// |     Type      |     Code      |          Checksum             |
/// +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
/// |                             Unused                            |
/// +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
/// |                    As much of invoking packet                 |
/// +                as possible without the ICMPv6 packet          +
/// |                exceeding the minimum IPv6 MTU [IPv6]          |
/// ```
///
/// In this crate, `Type`, `Code`, and `Unused` are represented by
/// [`crate::Icmpv6Type::DestinationUnreachable`]. This slice represents the
/// invoking packet bytes after that fixed part.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct DestinationUnreachablePayloadSlice<'a> {
    slice: &'a [u8],
}

impl<'a> DestinationUnreachablePayloadSlice<'a> {
    /// Creates a payload slice from the bytes after the ICMPv6 header.
    pub fn from_slice(slice: &'a [u8]) -> Result<Self, err::LenError> {
        Ok(Self { slice })
    }

    /// Returns the full payload slice.
    pub fn slice(&self) -> &'a [u8] {
        self.slice
    }

    /// Returns the invoking packet bytes carried by the message.
    pub fn invoking_packet(&self) -> &'a [u8] {
        self.slice
    }

    /// Decodes the invoking packet bytes as a lax IP slice.
    pub fn as_lax_ip_slice(
        &self,
    ) -> Result<
        (
            LaxIpSlice<'a>,
            Option<(err::ipv6_exts::HeaderSliceError, err::Layer)>,
        ),
        err::ip::LaxHeaderSliceError,
    > {
        LaxIpSlice::from_slice(self.invoking_packet())
    }
}
