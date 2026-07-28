use crate::{
    err,
    err::Layer,
    icmpv6::{NdpOptionsIterator, RedirectPayload},
    LenSource,
};
use core::net::Ipv6Addr;

/// Borrowed payload of a Redirect message (RFC 4861, Section 4.5).
///
/// The full packet layout is:
/// ```text
///  0                   1                   2                   3
///  0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
/// +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
/// |     Type      |     Code      |          Checksum             |
/// +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
/// |                           Reserved                            |
/// +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
/// |                                                               |
/// +                                                               +
/// |                                                               |
/// +                       Target Address                          +
/// |                                                               |
/// +                                                               +
/// |                                                               |
/// +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
/// |                                                               |
/// +                                                               +
/// |                                                               |
/// +                     Destination Address                       +
/// |                                                               |
/// +                                                               +
/// |                                                               |
/// +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
/// |   Options ...
/// +-+-+-+-+-+-+-+-+-+-+-+-
/// ```
///
/// In this crate, the first 8 bytes (including `Reserved`) are represented by
/// [`crate::Icmpv6Type::Redirect`]. This slice starts after that fixed part and
/// contains:
/// - `Target Address`
/// - `Destination Address`
/// - options
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RedirectPayloadSlice<'a> {
    slice: &'a [u8],
}

impl<'a> RedirectPayloadSlice<'a> {
    const IPV6_ADDRESS_LEN: usize = (Ipv6Addr::BITS / 8) as usize;

    /// Length of the fixed payload part (`Target Address` + `Destination Address`) in bytes.
    pub const FIXED_PART_LEN: usize = RedirectPayload::LEN;

    /// Creates a payload slice from the bytes after the ICMPv6 header.
    pub fn from_slice(slice: &'a [u8]) -> Result<Self, err::LenError> {
        if slice.len() < Self::FIXED_PART_LEN {
            Err(err::LenError {
                required_len: Self::FIXED_PART_LEN,
                len: slice.len(),
                len_source: LenSource::Slice,
                layer: Layer::Icmpv6,
                layer_start_offset: 0,
            })
        } else {
            Ok(Self { slice })
        }
    }

    /// Returns the full payload slice.
    pub fn slice(&self) -> &'a [u8] {
        self.slice
    }

    /// Better first-hop target address.
    pub fn target_address(&self) -> Ipv6Addr {
        // Safe to unwrap because `from_slice` guarantees
        // `self.slice.len() >= FIXED_PART_LEN`, and `FIXED_PART_LEN` includes
        // the first 16-byte IPv6 address field.
        Ipv6Addr::from(*self.slice.first_chunk().unwrap())
    }

    /// Destination address being redirected.
    pub fn destination_address(&self) -> Ipv6Addr {
        // Safe to unwrap because `from_slice` guarantees
        // `self.slice.len() >= FIXED_PART_LEN`, and `FIXED_PART_LEN` includes
        // both 16-byte IPv6 address fields.
        Ipv6Addr::from(*self.slice[Self::IPV6_ADDRESS_LEN..].first_chunk().unwrap())
    }

    /// Returns the Neighbor Discovery options.
    pub fn options(&self) -> &'a [u8] {
        &self.slice[Self::FIXED_PART_LEN..]
    }

    /// Returns an iterator over Neighbor Discovery options.
    pub fn options_iterator(&self) -> NdpOptionsIterator<'a> {
        NdpOptionsIterator::from_slice(self.options())
    }

    /// Convert to an owned structured payload and return trailing options.
    pub fn to_payload(&self) -> (RedirectPayload, &'a [u8]) {
        (
            RedirectPayload {
                target_address: self.target_address(),
                destination_address: self.destination_address(),
            },
            self.options(),
        )
    }
}
