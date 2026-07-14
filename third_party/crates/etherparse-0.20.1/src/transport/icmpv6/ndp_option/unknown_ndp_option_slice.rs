use super::NDP_OPTION_HEADER_LEN;
use crate::icmpv6::{NdpOptionHeader, NdpOptionReadError, NdpOptionType};

/// Unknown Neighbor Discovery option slice.
///
/// All ND options begin with this common prefix:
/// ```text
///  0                   1
///  0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5
/// +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
/// |     Type      |    Length     |
/// +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
/// ```
///
/// This slice stores the full serialized option, including the
/// `Type` and `Length` bytes.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct UnknownNdpOptionSlice<'a> {
    slice: &'a [u8],
}

impl<'a> UnknownNdpOptionSlice<'a> {
    pub fn from_slice(slice: &'a [u8]) -> Result<Self, NdpOptionReadError> {
        let (header, _) = NdpOptionHeader::from_slice(slice)?;
        if 0 == header.length_units {
            return Err(NdpOptionReadError::ZeroLength {
                option_id: header.option_type,
            });
        }

        let expected_size = header.byte_len();
        if expected_size != slice.len() {
            return Err(NdpOptionReadError::UnexpectedSize {
                option_id: header.option_type,
                expected_size,
                actual_size: slice.len(),
            });
        }

        Ok(Self { slice })
    }

    /// Returns the option type value.
    pub fn option_type(&self) -> NdpOptionType {
        NdpOptionType(self.slice[0])
    }

    /// Returns the serialized option bytes.
    pub fn as_bytes(&self) -> &'a [u8] {
        self.slice
    }

    /// Returns the option data bytes after the type/length fields.
    pub fn data(&self) -> &'a [u8] {
        &self.slice[NDP_OPTION_HEADER_LEN..]
    }
}
