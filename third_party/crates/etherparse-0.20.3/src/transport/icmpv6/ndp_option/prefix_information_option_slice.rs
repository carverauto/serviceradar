use crate::icmpv6::{NdpOptionReadError, NdpOptionType, PrefixInformation};

/// Prefix Information option slice (RFC 4861, Section 4.6.2, type 3).
///
/// The option layout is:
/// ```text
///  0                   1                   2                   3
///  0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
/// +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
/// |     Type      |    Length     | Prefix Length |L|A| Reserved1 |
/// +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
/// |                         Valid Lifetime                        |
/// +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
/// |                       Preferred Lifetime                      |
/// +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
/// |                           Reserved2                           |
/// +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
/// |                                                               |
/// +                                                               +
/// |                                                               |
/// +                            Prefix                             +
/// |                                                               |
/// +                                                               +
/// |                                                               |
/// +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
/// ```
///
/// This slice stores the full serialized option, including the
/// `Type` and `Length` bytes.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PrefixInformationOptionSlice<'a> {
    slice: &'a [u8; PrefixInformation::LEN],
}

impl<'a> PrefixInformationOptionSlice<'a> {
    const PREFIX_LENGTH_OFFSET: usize = 2;
    const FLAGS_OFFSET: usize = 3;
    const VALID_LIFETIME_OFFSET: usize = 4;
    const PREFERRED_LIFETIME_OFFSET: usize = 8;
    const PREFIX_OFFSET: usize = 16;

    pub fn from_slice(slice: &'a [u8]) -> Result<Self, NdpOptionReadError> {
        let slice: &'a [u8; PrefixInformation::LEN] =
            slice
                .try_into()
                .map_err(|_| NdpOptionReadError::UnexpectedSize {
                    option_id: NdpOptionType::PREFIX_INFORMATION,
                    expected_size: PrefixInformation::LEN,
                    actual_size: slice.len(),
                })?;
        // Validate the encoded option header (`Type` and `Length`) as well.
        PrefixInformation::from_bytes(*slice)?;
        Ok(Self { slice })
    }

    /// Returns the option type value (3).
    pub const fn option_type(&self) -> NdpOptionType {
        NdpOptionType::PREFIX_INFORMATION
    }

    /// Returns the serialized option bytes.
    pub fn as_bytes(&self) -> &'a [u8; PrefixInformation::LEN] {
        self.slice
    }

    /// Returns the prefix length (in bits).
    pub fn prefix_length(&self) -> u8 {
        self.slice[Self::PREFIX_LENGTH_OFFSET]
    }

    /// Returns the `L` (on-link) flag.
    pub fn on_link(&self) -> bool {
        0 != self.slice[Self::FLAGS_OFFSET] & PrefixInformation::ON_LINK_MASK
    }

    /// Returns the `A` (autonomous address-configuration) flag.
    pub fn autonomous_address_configuration(&self) -> bool {
        0 != self.slice[Self::FLAGS_OFFSET]
            & PrefixInformation::AUTONOMOUS_ADDRESS_CONFIGURATION_MASK
    }

    /// Returns the valid lifetime in seconds.
    pub fn valid_lifetime(&self) -> u32 {
        // Safe to unwrap because `self.slice` is always exactly `PrefixInformation::LEN` bytes.
        u32::from_be_bytes(
            *self.slice[Self::VALID_LIFETIME_OFFSET..]
                .first_chunk()
                .unwrap(),
        )
    }

    /// Returns the preferred lifetime in seconds.
    pub fn preferred_lifetime(&self) -> u32 {
        // Safe to unwrap because `self.slice` is always exactly `PrefixInformation::LEN` bytes.
        u32::from_be_bytes(
            *self.slice[Self::PREFERRED_LIFETIME_OFFSET..]
                .first_chunk()
                .unwrap(),
        )
    }

    /// Returns the 128-bit prefix field.
    pub fn prefix(&self) -> [u8; 16] {
        // Safe to unwrap because `self.slice` is always exactly `PrefixInformation::LEN` bytes.
        *self.slice[Self::PREFIX_OFFSET..].first_chunk().unwrap()
    }

    /// Decodes the option as [`PrefixInformation`].
    pub fn prefix_information(&self) -> PrefixInformation {
        PrefixInformation {
            prefix_length: self.prefix_length(),
            on_link: self.on_link(),
            autonomous_address_configuration: self.autonomous_address_configuration(),
            valid_lifetime: self.valid_lifetime(),
            preferred_lifetime: self.preferred_lifetime(),
            prefix: self.prefix(),
        }
    }
}
