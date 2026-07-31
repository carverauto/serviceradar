use crate::icmpv6::{NdpOptionHeader, NdpOptionReadError, NdpOptionType};

/// MTU option slice (RFC 4861, Section 4.6.4, type 5).
///
/// The option layout is:
/// ```text
///  0                   1                   2                   3
///  0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
/// +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
/// |     Type      |    Length     |           Reserved            |
/// +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
/// |                              MTU                              |
/// +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
/// ```
///
/// This slice stores the full serialized option, including the
/// `Type` and `Length` bytes.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct MtuOptionSlice<'a> {
    slice: &'a [u8; MtuOptionSlice::LEN],
}

impl<'a> MtuOptionSlice<'a> {
    /// Serialized MTU option length in bytes.
    pub const LEN: usize = 8;
    const LENGTH_UNITS: u8 = 1;

    pub fn from_slice(slice: &'a [u8]) -> Result<Self, NdpOptionReadError> {
        let slice = <&[u8; MtuOptionSlice::LEN]>::try_from(slice).map_err(|_| {
            NdpOptionReadError::UnexpectedSize {
                option_id: NdpOptionType::MTU,
                expected_size: MtuOptionSlice::LEN,
                actual_size: slice.len(),
            }
        })?;

        let header = NdpOptionHeader::from_bytes([slice[0], slice[1]]);
        if header.option_type != NdpOptionType::MTU || header.length_units != Self::LENGTH_UNITS {
            return Err(NdpOptionReadError::UnexpectedHeader {
                expected_option_id: NdpOptionType::MTU,
                actual_option_id: header.option_type,
                expected_length_units: Self::LENGTH_UNITS,
                actual_length_units: header.length_units,
            });
        }

        Ok(Self { slice })
    }

    /// Returns the option type value (5).
    pub const fn option_type(&self) -> NdpOptionType {
        NdpOptionType::MTU
    }

    /// Returns the serialized option bytes.
    pub fn as_bytes(&self) -> &'a [u8] {
        self.slice
    }

    /// Returns the MTU value carried by the option.
    pub fn mtu(&self) -> u32 {
        u32::from_be_bytes([self.slice[4], self.slice[5], self.slice[6], self.slice[7]])
    }
}
