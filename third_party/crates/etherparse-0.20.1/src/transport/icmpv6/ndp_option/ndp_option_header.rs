use super::NDP_OPTION_HEADER_LEN;
use crate::icmpv6::{NdpOptionReadError, NdpOptionType};

/// Header present at the beginning of every Neighbor Discovery option.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Ord, PartialOrd, Hash)]
pub struct NdpOptionHeader {
    /// Option `Type` field.
    pub option_type: NdpOptionType,
    /// Option `Length` field in units of 8 octets.
    pub length_units: u8,
}

impl NdpOptionHeader {
    /// Serialized size of the option header in bytes.
    pub const LEN: usize = NDP_OPTION_HEADER_LEN;

    /// Decodes a header from its serialized bytes.
    pub fn from_bytes(bytes: [u8; NDP_OPTION_HEADER_LEN]) -> Self {
        Self {
            option_type: NdpOptionType(bytes[0]),
            length_units: bytes[1],
        }
    }

    /// Encodes the header to serialized bytes.
    pub const fn to_bytes(&self) -> [u8; NDP_OPTION_HEADER_LEN] {
        [self.option_type.0, self.length_units]
    }

    /// Decodes the header from the start of a serialized options slice.
    pub fn from_slice(slice: &[u8]) -> Result<(Self, &[u8]), NdpOptionReadError> {
        let (bytes, rest) = slice
            .split_first_chunk::<NDP_OPTION_HEADER_LEN>()
            .ok_or_else(|| NdpOptionReadError::UnexpectedSize {
                option_id: NdpOptionType(slice.first().copied().unwrap_or(0)),
                expected_size: NDP_OPTION_HEADER_LEN,
                actual_size: slice.len(),
            })?;
        Ok((Self::from_bytes(*bytes), rest))
    }

    /// Returns the total serialized option size in bytes.
    pub const fn byte_len(&self) -> usize {
        (self.length_units as usize) * 8
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn from_to_bytes() {
        let header = NdpOptionHeader {
            option_type: NdpOptionType::MTU,
            length_units: 1,
        };
        assert_eq!(header, NdpOptionHeader::from_bytes(header.to_bytes()));
    }

    #[test]
    fn from_slice() {
        assert_eq!(
            Ok((
                NdpOptionHeader {
                    option_type: NdpOptionType::PREFIX_INFORMATION,
                    length_units: 4,
                },
                &[][..]
            )),
            NdpOptionHeader::from_slice(&[3, 4]),
        );
        assert_eq!(
            Ok((
                NdpOptionHeader {
                    option_type: NdpOptionType::PREFIX_INFORMATION,
                    length_units: 4,
                },
                &[1, 2, 3][..]
            )),
            NdpOptionHeader::from_slice(&[3, 4, 1, 2, 3]),
        );
        assert_eq!(
            Err(NdpOptionReadError::UnexpectedSize {
                option_id: NdpOptionType(250),
                expected_size: NdpOptionHeader::LEN,
                actual_size: 1,
            }),
            NdpOptionHeader::from_slice(&[250]),
        );
        assert_eq!(
            Err(NdpOptionReadError::UnexpectedSize {
                option_id: NdpOptionType(0),
                expected_size: NdpOptionHeader::LEN,
                actual_size: 0,
            }),
            NdpOptionHeader::from_slice(&[]),
        );
    }

    #[test]
    fn byte_len() {
        assert_eq!(
            32,
            NdpOptionHeader {
                option_type: NdpOptionType::PREFIX_INFORMATION,
                length_units: 4,
            }
            .byte_len()
        );
    }
}
