use crate::{
    err,
    err::Layer,
    icmpv6::{NdpOptionsIterator, RouterAdvertisementPayload},
    LenSource,
};

/// Borrowed payload of a Router Advertisement message (RFC 4861, Section 4.2).
///
/// The full packet layout is:
/// ```text
///  0                   1                   2                   3
///  0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
/// +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
/// |     Type      |     Code      |          Checksum             |
/// +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
/// | Cur Hop Limit |M|O|  Reserved |       Router Lifetime         |
/// +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
/// |                         Reachable Time                        |
/// +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
/// |                          Retrans Timer                        |
/// +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
/// |   Options ...
/// +-+-+-+-+-+-+-+-+-+-+-+-
/// ```
///
/// In this crate, `Cur Hop Limit`, `M`, `O`, and `Router Lifetime` are represented by
/// [`crate::icmpv6::RouterAdvertisementHeader`] in [`crate::Icmpv6Type::RouterAdvertisement`].
/// This slice starts after that fixed part and contains:
/// - `Reachable Time`
/// - `Retrans Timer`
/// - options
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RouterAdvertisementPayloadSlice<'a> {
    slice: &'a [u8],
}

impl<'a> RouterAdvertisementPayloadSlice<'a> {
    const U32_FIELD_LEN: usize = (u32::BITS / 8) as usize;
    const RETRANS_TIMER_OFFSET: usize = Self::U32_FIELD_LEN;

    /// Length of the fixed payload part (`Reachable Time` and `Retrans Timer`) in bytes.
    pub const FIXED_PART_LEN: usize = RouterAdvertisementPayload::LEN;

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

    /// Reachable time in milliseconds.
    pub fn reachable_time(&self) -> u32 {
        // Safe to unwrap because `from_slice` guarantees `self.slice.len() >= FIXED_PART_LEN`,
        // and `FIXED_PART_LEN` includes this full 4-byte field.
        u32::from_be_bytes(*self.slice.first_chunk().unwrap())
    }

    /// Retransmit timer in milliseconds.
    pub fn retrans_timer(&self) -> u32 {
        // Safe to unwrap because `from_slice` guarantees `self.slice.len() >= FIXED_PART_LEN`,
        // and `FIXED_PART_LEN` includes this full 4-byte field at the given offset.
        u32::from_be_bytes(
            *self.slice[Self::RETRANS_TIMER_OFFSET..]
                .first_chunk()
                .unwrap(),
        )
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
    pub fn to_payload(&self) -> (RouterAdvertisementPayload, &'a [u8]) {
        (
            RouterAdvertisementPayload {
                reachable_time: self.reachable_time(),
                retrans_timer: self.retrans_timer(),
            },
            self.options(),
        )
    }
}
