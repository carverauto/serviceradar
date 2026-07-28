use core::net::Ipv4Addr;

use crate::{ArpHardwareId, EtherType};

use super::{ArpOperation, ArpPacket};

/// An ethernet & IPv4 "Address Resolution Protocol" Packet (a specific
/// version of [`crate::ArpPacket`]).
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct ArpEthIpv4Packet {
    /// Specifies the operation that the sender is performing.
    pub operation: ArpOperation,

    /// Sender MAC address.
    pub sender_mac: [u8; 6],

    /// Sender IPv4 address.
    pub sender_ipv4: [u8; 4],

    /// Sender MAC address.
    pub target_mac: [u8; 6],

    /// Target IPv4 address.
    pub target_ipv4: [u8; 4],
}

impl ArpEthIpv4Packet {
    /// Number of octets/bytes of the serialized packet.
    pub const LEN: usize = 8 + 6 * 2 + 4 * 2;

    /// Sender IPv4 address as [`core::net::Ipv4Addr`].
    #[inline]
    pub const fn sender_ipv4_addr(&self) -> Ipv4Addr {
        Ipv4Addr::new(
            self.sender_ipv4[0],
            self.sender_ipv4[1],
            self.sender_ipv4[2],
            self.sender_ipv4[3],
        )
    }

    /// Target IPv4 address as [`core::net::Ipv4Addr`].
    #[inline]
    pub const fn target_ipv4_addr(&self) -> Ipv4Addr {
        Ipv4Addr::new(
            self.target_ipv4[0],
            self.target_ipv4[1],
            self.target_ipv4[2],
            self.target_ipv4[3],
        )
    }

    /// Returns the serialized header.
    pub const fn to_bytes(&self) -> [u8; Self::LEN] {
        const ETH_HW_TYPE: [u8; 2] = ArpHardwareId::ETHERNET.0.to_be_bytes();
        const IPV4_ETH_TYPE: [u8; 2] = EtherType::IPV4.0.to_be_bytes();
        let op = self.operation.0.to_be_bytes();
        [
            ETH_HW_TYPE[0],
            ETH_HW_TYPE[1],
            IPV4_ETH_TYPE[0],
            IPV4_ETH_TYPE[1],
            6,
            4,
            op[0],
            op[1],
            self.sender_mac[0],
            self.sender_mac[1],
            self.sender_mac[2],
            self.sender_mac[3],
            self.sender_mac[4],
            self.sender_mac[5],
            self.sender_ipv4[0],
            self.sender_ipv4[1],
            self.sender_ipv4[2],
            self.sender_ipv4[3],
            self.target_mac[0],
            self.target_mac[1],
            self.target_mac[2],
            self.target_mac[3],
            self.target_mac[4],
            self.target_mac[5],
            self.target_ipv4[0],
            self.target_ipv4[1],
            self.target_ipv4[2],
            self.target_ipv4[3],
        ]
    }

    /// Converts the packet to generic arp packet.
    #[inline]
    pub const fn to_arp_packet(&self) -> ArpPacket {
        // SAFETY: This is safe as
        // * Both the hardware addresses have matching length 6 which is bellow the max of 255.
        // * Both the protocol addresses have matching length 6 which is bellow the max of 255.
        unsafe {
            ArpPacket::new_unchecked(
                ArpHardwareId::ETHERNET,
                EtherType::IPV4,
                self.operation,
                &self.sender_mac,
                &self.sender_ipv4,
                &self.target_mac,
                &self.target_ipv4,
            )
        }
    }
}

impl From<ArpEthIpv4Packet> for ArpPacket {
    fn from(value: ArpEthIpv4Packet) -> Self {
        value.to_arp_packet()
    }
}

impl TryFrom<ArpPacket> for ArpEthIpv4Packet {
    type Error = crate::err::arp::ArpEthIpv4FromError;

    fn try_from(value: ArpPacket) -> Result<Self, Self::Error> {
        value.try_eth_ipv4()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::test_gens::*;
    use proptest::prelude::*;

    proptest! {
        #[test]
        fn sender_ipv4_addr(
            arp in arp_eth_ipv4_packet_any()
        ) {
            assert_eq!(
                arp.sender_ipv4_addr(),
                Ipv4Addr::new(
                    arp.sender_ipv4[0],
                    arp.sender_ipv4[1],
                    arp.sender_ipv4[2],
                    arp.sender_ipv4[3]
                )
            )
        }
    }

    proptest! {
        #[test]
        fn target_ipv4_addr(
            arp in arp_eth_ipv4_packet_any()
        ) {
            assert_eq!(
                arp.target_ipv4_addr(),
                Ipv4Addr::new(
                    arp.target_ipv4[0],
                    arp.target_ipv4[1],
                    arp.target_ipv4[2],
                    arp.target_ipv4[3]
                )
            )
        }
    }

    proptest! {
        #[test]
        fn to_bytes(
            arp in arp_eth_ipv4_packet_any()
        ) {
            assert_eq!(
                &arp.to_bytes()[..],
                &arp.to_arp_packet().to_bytes()[..]
            );
        }
    }

    proptest! {
        #[test]
        fn to_arp_packet(
            arp in arp_eth_ipv4_packet_any()
        ) {
            let actual = arp.to_arp_packet();
            assert_eq!(ArpHardwareId::ETHERNET, actual.hw_addr_type);
            assert_eq!(EtherType::IPV4, actual.proto_addr_type);
            assert_eq!(6, actual.hw_addr_size());
            assert_eq!(4, actual.protocol_addr_size());
            assert_eq!(&arp.target_mac[..], actual.target_hw_addr());
            assert_eq!(&arp.target_ipv4[..], actual.target_protocol_addr());
            assert_eq!(&arp.sender_mac[..], actual.sender_hw_addr());
            assert_eq!(&arp.sender_ipv4[..], actual.sender_protocol_addr());
        }
    }

    proptest! {
        #[test]
        fn into_arp_packet(
            arp in arp_eth_ipv4_packet_any()
        ) {
            let actual = ArpPacket::from(arp.clone());
            assert_eq!(actual, arp.to_arp_packet());
        }
    }

    proptest! {
        #[test]
        fn try_from_arp_packet(
            arp in arp_packet_any()
        ) {
            let actual = ArpEthIpv4Packet::try_from(arp.clone());
            assert_eq!(actual, arp.clone().try_eth_ipv4());
        }
    }
}
