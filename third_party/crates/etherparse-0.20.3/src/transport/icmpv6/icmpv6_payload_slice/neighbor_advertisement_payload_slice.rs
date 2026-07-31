use crate::{
    err,
    err::Layer,
    icmpv6::{NdpOptionsIterator, NeighborAdvertisementPayload},
    LenSource,
};
use core::net::Ipv6Addr;

/// Borrowed payload of a Neighbor Advertisement message (RFC 4861, Section 4.4).
///
/// The full packet layout is:
/// ```text
///  0                   1                   2                   3
///  0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
/// +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
/// |     Type      |     Code      |          Checksum             |
/// +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
/// |R|S|O|                     Reserved                            |
/// +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
/// |                                                               |
/// +                                                               +
/// |                                                               |
/// +                       Target Address                          +
/// |                                                               |
/// +                                                               +
/// |                                                               |
/// +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
/// |   Options ...
/// +-+-+-+-+-+-+-+-+-+-+-+-
/// ```
///
/// In this crate, `R`, `S`, and `O` are represented by
/// [`crate::icmpv6::NeighborAdvertisementHeader`] in
/// [`crate::Icmpv6Type::NeighborAdvertisement`]. This slice starts after that fixed part
/// and contains the fixed `Target Address` followed by options.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct NeighborAdvertisementPayloadSlice<'a> {
    slice: &'a [u8],
}

impl<'a> NeighborAdvertisementPayloadSlice<'a> {
    /// Length of the fixed payload part (the `Target Address`) in bytes.
    pub const FIXED_PART_LEN: usize = NeighborAdvertisementPayload::LEN;

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

    /// Target address carried in the payload.
    pub fn target_address(&self) -> Ipv6Addr {
        // Safe to unwrap because `from_slice` guarantees
        // `self.slice.len() >= FIXED_PART_LEN`, and `FIXED_PART_LEN` includes
        // the full 16-byte target address field.
        Ipv6Addr::from(*self.slice.first_chunk().unwrap())
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
    pub fn to_payload(&self) -> (NeighborAdvertisementPayload, &'a [u8]) {
        (
            NeighborAdvertisementPayload {
                target_address: self.target_address(),
            },
            self.options(),
        )
    }
}
