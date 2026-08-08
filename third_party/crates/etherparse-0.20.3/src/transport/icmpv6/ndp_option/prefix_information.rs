use crate::icmpv6::{NdpOptionReadError, NdpOptionType};

/// Prefix Information option payload defined in RFC 4861.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Ord, PartialOrd, Hash)]
pub struct PrefixInformation {
    /// Number of leading bits in the prefix that are valid.
    pub prefix_length: u8,
    /// "On-link" flag.
    pub on_link: bool,
    /// "Autonomous address-configuration" flag.
    pub autonomous_address_configuration: bool,
    /// Lifetime in seconds for which the prefix is valid.
    pub valid_lifetime: u32,
    /// Lifetime in seconds for which addresses generated from the prefix remain preferred.
    pub preferred_lifetime: u32,
    /// The advertised prefix.
    pub prefix: [u8; 16],
}

impl PrefixInformation {
    /// Length of a prefix information option in units of 8 octets.
    const LENGTH_UNITS: u8 = 4;

    /// Serialized length in bytes.
    pub const LEN: usize = 32;

    /// Mask to read the "on-link" flag.
    pub const ON_LINK_MASK: u8 = 0b1000_0000;

    /// Mask to read the "autonomous address-configuration" flag.
    pub const AUTONOMOUS_ADDRESS_CONFIGURATION_MASK: u8 = 0b0100_0000;

    /// Decode the option from the on-the-wire bytes.
    pub fn from_bytes(bytes: [u8; Self::LEN]) -> Result<PrefixInformation, NdpOptionReadError> {
        let bytes = bytes.as_slice();
        // Safe to unwrap because `bytes` originates from `[u8; Self::LEN]` and
        // the chunk sizes below exactly cover `Self::LEN` (32 bytes).
        let (type_and_len, rest) = bytes.split_first_chunk::<2>().unwrap();
        if *type_and_len != [NdpOptionType::PREFIX_INFORMATION.0, Self::LENGTH_UNITS] {
            return Err(NdpOptionReadError::UnexpectedHeader {
                expected_option_id: NdpOptionType::PREFIX_INFORMATION,
                actual_option_id: NdpOptionType(type_and_len[0]),
                expected_length_units: Self::LENGTH_UNITS,
                actual_length_units: type_and_len[1],
            });
        }
        let (prefix_length_and_flags, rest) = rest.split_first_chunk::<2>().unwrap();
        let (valid_lifetime, rest) = rest.split_first_chunk::<4>().unwrap();
        let (preferred_lifetime, rest) = rest.split_first_chunk::<4>().unwrap();
        let (_reserved2, prefix) = rest.split_first_chunk::<4>().unwrap();
        let prefix = *prefix.first_chunk::<16>().unwrap();

        Ok(PrefixInformation {
            prefix_length: prefix_length_and_flags[0],
            on_link: 0 != prefix_length_and_flags[1] & Self::ON_LINK_MASK,
            autonomous_address_configuration: 0
                != prefix_length_and_flags[1] & Self::AUTONOMOUS_ADDRESS_CONFIGURATION_MASK,
            valid_lifetime: u32::from_be_bytes(*valid_lifetime),
            preferred_lifetime: u32::from_be_bytes(*preferred_lifetime),
            prefix,
        })
    }

    /// Decode the option from a byte slice.
    ///
    /// The slice must contain exactly [`PrefixInformation::LEN`] bytes.
    pub fn from_slice(bytes: &[u8]) -> Result<PrefixInformation, NdpOptionReadError> {
        let bytes: &[u8; Self::LEN] =
            bytes
                .try_into()
                .map_err(|_| NdpOptionReadError::UnexpectedSize {
                    option_id: NdpOptionType::PREFIX_INFORMATION,
                    expected_size: Self::LEN,
                    actual_size: bytes.len(),
                })?;
        PrefixInformation::from_bytes(*bytes)
    }

    /// Convert the prefix information to the on-the-wire bytes.
    pub fn to_bytes(&self) -> [u8; Self::LEN] {
        let mut bytes = [0u8; Self::LEN];
        // Safe to unwrap because chunk sizes below exactly cover `Self::LEN` (32 bytes).
        let (type_and_len, rest) = bytes.as_mut_slice().split_first_chunk_mut::<2>().unwrap();
        let (prefix_length_and_flags, rest) = rest.split_first_chunk_mut::<2>().unwrap();
        let (valid_lifetime, rest) = rest.split_first_chunk_mut::<4>().unwrap();
        let (preferred_lifetime, rest) = rest.split_first_chunk_mut::<4>().unwrap();
        let (_reserved2, prefix) = rest.split_first_chunk_mut::<4>().unwrap();
        let prefix = prefix.first_chunk_mut::<16>().unwrap();

        *type_and_len = [NdpOptionType::PREFIX_INFORMATION.into(), Self::LENGTH_UNITS];
        *prefix_length_and_flags = [
            self.prefix_length,
            (if self.on_link { Self::ON_LINK_MASK } else { 0 })
                | if self.autonomous_address_configuration {
                    Self::AUTONOMOUS_ADDRESS_CONFIGURATION_MASK
                } else {
                    0
                },
        ];
        *valid_lifetime = self.valid_lifetime.to_be_bytes();
        *preferred_lifetime = self.preferred_lifetime.to_be_bytes();
        *prefix = self.prefix;

        bytes
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use proptest::prelude::*;

    proptest! {
        #[test]
        fn to_and_from_bytes(
            prefix_length in any::<u8>(),
            on_link in any::<bool>(),
            autonomous_address_configuration in any::<bool>(),
            valid_lifetime in any::<u32>(),
            preferred_lifetime in any::<u32>(),
            prefix in any::<[u8;16]>()
        ) {
            let value = PrefixInformation {
                prefix_length,
                on_link,
                autonomous_address_configuration,
                valid_lifetime,
                preferred_lifetime,
                prefix,
            };
            assert_eq!(PrefixInformation::from_bytes(value.to_bytes()), Ok(value));
            assert_eq!(PrefixInformation::from_slice(&value.to_bytes()), Ok(value));
        }
    }

    #[test]
    fn from_slice_len_error() {
        assert_eq!(
            PrefixInformation::from_slice(&[0u8; PrefixInformation::LEN - 1]),
            Err(NdpOptionReadError::UnexpectedSize {
                option_id: NdpOptionType::PREFIX_INFORMATION,
                expected_size: PrefixInformation::LEN,
                actual_size: PrefixInformation::LEN - 1,
            })
        );
        assert_eq!(
            PrefixInformation::from_slice(&[0u8; PrefixInformation::LEN + 1]),
            Err(NdpOptionReadError::UnexpectedSize {
                option_id: NdpOptionType::PREFIX_INFORMATION,
                expected_size: PrefixInformation::LEN,
                actual_size: PrefixInformation::LEN + 1,
            })
        );
    }

    #[test]
    fn from_bytes_invalid_header() {
        let mut bytes = PrefixInformation {
            prefix_length: 64,
            on_link: true,
            autonomous_address_configuration: true,
            valid_lifetime: 1,
            preferred_lifetime: 2,
            prefix: [3; 16],
        }
        .to_bytes();

        bytes[0] = NdpOptionType::MTU.0;
        assert_eq!(
            PrefixInformation::from_bytes(bytes),
            Err(NdpOptionReadError::UnexpectedHeader {
                expected_option_id: NdpOptionType::PREFIX_INFORMATION,
                actual_option_id: NdpOptionType::MTU,
                expected_length_units: 4,
                actual_length_units: 4,
            })
        );

        let mut bytes = PrefixInformation {
            prefix_length: 64,
            on_link: true,
            autonomous_address_configuration: true,
            valid_lifetime: 1,
            preferred_lifetime: 2,
            prefix: [3; 16],
        }
        .to_bytes();
        bytes[1] = 1;
        assert_eq!(
            PrefixInformation::from_bytes(bytes),
            Err(NdpOptionReadError::UnexpectedHeader {
                expected_option_id: NdpOptionType::PREFIX_INFORMATION,
                actual_option_id: NdpOptionType::PREFIX_INFORMATION,
                expected_length_units: 4,
                actual_length_units: 1,
            })
        );
    }
}
