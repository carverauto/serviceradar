/// ICMPv6 router advertisement header (part of "Neighbor Discovery Protocol"
/// [RFC 4861](https://datatracker.ietf.org/doc/html/rfc4861)).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Ord, PartialOrd, Hash)]
pub struct RouterAdvertisementHeader {
    /// The default value that should be placed in the Hop Count
    /// field of the IP header for outgoing IP packets.
    ///
    /// A value of zero means unspecified (by this router).
    pub cur_hop_limit: u8,

    /// "Managed address configuration" flag.
    ///
    /// When set, it indicates that addresses are available via
    /// Dynamic Host Configuration Protocol [DHCPv6].
    ///
    /// If the M flag is set, the O flag is redundant and
    /// can be ignored because DHCPv6 will return all
    /// available configuration information.
    pub managed_address_config: bool,

    /// "Other configuration" flag.
    ///
    /// When set, it indicates that other configuration information
    /// is available via DHCPv6.  Examples of such information are
    /// DNS-related information or information on other servers
    /// within the network.
    pub other_config: bool,

    /// The lifetime associated with the default router in units of
    /// seconds.
    ///
    /// The field can contain values up to 65535 and receivers should
    /// handle any value, while the sending rules in Section 6 of
    /// [RFC 4861](https://datatracker.ietf.org/doc/html/rfc4861) limit
    /// the lifetime to 9000 seconds. A Lifetime of 0 indicates that
    /// the router is not a default router and SHOULD NOT appear on
    /// the default router list. The Router Lifetime applies only to
    /// the router's usefulness as a default router; it does not apply
    /// to information contained in other message fields or options.
    /// Options that need time limits for their information include
    /// their own lifetime fields.
    pub router_lifetime: u16,
}

impl RouterAdvertisementHeader {
    /// Mask to read out the "Managed Address Configuration" flag out of
    /// the 5th byte of the ICMPv6 header.
    pub const MANAGED_ADDRESS_CONFIG_MASK: u8 = 0b1000_0000;

    /// Mask to read out the "Other Configuration" flag out of the 5th
    /// byte of the ICMPv6 header.
    pub const OTHER_CONFIG_MASK: u8 = 0b0100_0000;

    /// Decodes the header from the on the wire bytes.
    pub fn from_bytes(bytes: [u8; 4]) -> Self {
        RouterAdvertisementHeader {
            cur_hop_limit: bytes[0],
            managed_address_config: 0 != bytes[1] & Self::MANAGED_ADDRESS_CONFIG_MASK,
            other_config: 0 != bytes[1] & Self::OTHER_CONFIG_MASK,
            router_lifetime: u16::from_be_bytes([bytes[2], bytes[3]]),
        }
    }

    /// Converts the header to the on the wire bytes.
    pub fn to_bytes(&self) -> [u8; 4] {
        let rl_be = self.router_lifetime.to_be_bytes();
        [
            self.cur_hop_limit,
            (if self.managed_address_config {
                Self::MANAGED_ADDRESS_CONFIG_MASK
            } else {
                0
            } | if self.other_config {
                Self::OTHER_CONFIG_MASK
            } else {
                0
            }),
            rl_be[0],
            rl_be[1],
        ]
    }
}

#[cfg(test)]
mod test {
    use super::*;
    use proptest::prelude::*;

    proptest! {
        #[test]
        fn to_and_from_bytes(
            cur_hop_limit in any::<u8>(),
            managed_address_config in any::<bool>(),
            other_config in any::<bool>(),
            router_lifetime in any::<u16>()
        ) {
            let expected = RouterAdvertisementHeader{
                cur_hop_limit,
                managed_address_config,
                other_config,
                router_lifetime
            };
            let actual = RouterAdvertisementHeader::from_bytes(
                expected.to_bytes()
            );
            assert_eq!(actual, expected);
        }
    }
}
