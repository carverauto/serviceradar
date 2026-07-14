use super::NDP_OPTION_HEADER_LEN;
use crate::icmpv6::{NdpOptionHeader, NdpOptionReadError, NdpOptionType};

/// Source Link-Layer Address option slice (RFC 4861, Section 4.6.1, type 1).
///
/// The option layout is:
/// ```text
///  0                   1                   2                   3
///  0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
/// +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
/// |     Type      |    Length     |    Link-Layer Address ...
/// +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
/// ```
///
/// This slice stores the full serialized option, including the
/// `Type` and `Length` bytes.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SourceLinkLayerAddressOptionSlice<'a> {
    slice: &'a [u8],
}

impl<'a> SourceLinkLayerAddressOptionSlice<'a> {
    pub fn from_slice(slice: &'a [u8]) -> Result<Self, NdpOptionReadError> {
        let (header, _) = NdpOptionHeader::from_slice(slice)?;

        if NdpOptionType::SOURCE_LINK_LAYER_ADDRESS != header.option_type {
            return Err(NdpOptionReadError::UnexpectedHeader {
                expected_option_id: NdpOptionType::SOURCE_LINK_LAYER_ADDRESS,
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

    /// Returns the option type value (1).
    pub const fn option_type(&self) -> NdpOptionType {
        NdpOptionType::SOURCE_LINK_LAYER_ADDRESS
    }

    /// Returns the serialized option bytes.
    pub fn as_bytes(&self) -> &'a [u8] {
        self.slice
    }

    /// Returns the link-layer address bytes carried by the option.
    pub fn link_layer_address(&self) -> &'a [u8] {
        &self.slice[NDP_OPTION_HEADER_LEN..]
    }
}
