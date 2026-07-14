use crate::icmpv6::{NdpOptionHeader, NdpOptionReadError, NdpOptionType};

/// Redirected Header option slice (RFC 4861, Section 4.6.3, type 4).
///
/// The option layout is:
/// ```text
///  0                   1                   2                   3
///  0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
/// +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
/// |     Type      |    Length     |            Reserved           |
/// +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
/// |                           Reserved                            |
/// +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
/// |                                                               |
/// ~                       IP header + data                        ~
/// |                                                               |
/// +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
/// ```
///
/// This slice stores the full serialized option, including the
/// `Type` and `Length` bytes.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RedirectedHeaderOptionSlice<'a> {
    slice: &'a [u8],
}

impl<'a> RedirectedHeaderOptionSlice<'a> {
    /// Length in bytes of the fixed part (`Type`, `Length`, and reserved fields).
    const FIXED_PART_LEN: usize = 8;

    pub fn from_slice(slice: &'a [u8]) -> Result<Self, NdpOptionReadError> {
        if slice.len() < Self::FIXED_PART_LEN {
            return Err(NdpOptionReadError::UnexpectedSize {
                option_id: NdpOptionType::REDIRECTED_HEADER,
                expected_size: Self::FIXED_PART_LEN,
                actual_size: slice.len(),
            });
        }

        let (header, _) = NdpOptionHeader::from_slice(slice)?;
        if NdpOptionType::REDIRECTED_HEADER != header.option_type {
            return Err(NdpOptionReadError::UnexpectedHeader {
                expected_option_id: NdpOptionType::REDIRECTED_HEADER,
                actual_option_id: header.option_type,
                expected_length_units: header.length_units,
                actual_length_units: header.length_units,
            });
        }
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

    /// Returns the option type value (4).
    pub const fn option_type(&self) -> NdpOptionType {
        NdpOptionType::REDIRECTED_HEADER
    }

    /// Returns the serialized option bytes.
    pub fn as_bytes(&self) -> &'a [u8] {
        self.slice
    }

    /// Returns the redirected packet bytes carried by the option.
    ///
    /// Note that this slice may include trailing zero-padding, since the option
    /// length is encoded in 8-octet units. Callers must not assume all returned
    /// bytes are meaningful packet data. Trim or parse the embedded packet using
    /// its own length fields (or a helper that strips padding) before
    /// interpreting payload bytes.
    pub fn redirected_packet(&self) -> &'a [u8] {
        &self.slice[Self::FIXED_PART_LEN..]
    }
}
