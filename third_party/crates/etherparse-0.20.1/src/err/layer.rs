/// Layers on which an error can occur.
#[derive(Copy, Clone, Debug, Eq, PartialEq, Ord, PartialOrd, Hash)]
pub enum Layer {
    /// Error occurred in the Linux Cooked Capture v1 (SLL) header.
    LinuxSllHeader,
    /// Error occurred in the ethernet 2 header.
    Ethernet2Header,
    /// Payload identified by an ether type number (e.g. after an ethernet 2 header).
    EtherPayload,
    /// Error occurred in the vlan header.
    VlanHeader,
    /// Error occurred in the MACsec header (also known as Sectag).
    MacsecHeader,
    /// Error occurred while verifying the total MACsec packet length is long enough
    /// for the "short length".
    MacsecPacket,
    /// Error occurred when decoding an IP header (v4 or v6).
    IpHeader,
    /// Error occurred in the IPv4 layer.
    Ipv4Header,
    /// Error occurred verifying the total length of an IPv4 packet.
    Ipv4Packet,
    /// Error occurred in the IP Authentication header.
    IpAuthHeader,
    /// Error occurred in the IPv6 layer.
    Ipv6Header,
    /// Error occurred verifying the payload length of an IPv6 packet.
    Ipv6Packet,
    /// Error occurred while decoding a generic IPv6 extension header.
    Ipv6ExtHeader,
    /// Error occurred while decoding "IPv6 Hop-by-Hop Option" extension header.
    Ipv6HopByHopHeader,
    /// Error occurred while decoding "IPv6 Destination Options" extension header.
    Ipv6DestOptionsHeader,
    /// Error occurred while decoding "IPv6 Routing" extension header.
    Ipv6RouteHeader,
    /// Error occurred while decoding an IPv6 fragment header.
    Ipv6FragHeader,
    /// Error occurred while decoding an UDP header.
    UdpHeader,
    /// Error occurred verifying the length of the UDP payload.
    UdpPayload,
    /// Error occurred while decoding a TCP header.
    TcpHeader,
    /// Error occurred while parsing an ICMP packet.
    Icmpv4,
    /// Error occurred while parsing an ICMP timestamp packet.
    Icmpv4Timestamp,
    /// Error occurred while parsing an ICMP timestamp reply packet.
    Icmpv4TimestampReply,
    /// Error occurred while parsing an ICMPv6 packet.
    Icmpv6,
    /// Error occurred while parsing an Address Resolution Protocol packet.
    Arp,
}

impl Layer {
    /// String that is used as a title for the error.
    pub fn error_title(&self) -> &'static str {
        use Layer::*;
        match self {
            LinuxSllHeader => "Linux Cooked Capture v1 Error",
            Ethernet2Header => "Ethernet 2 Header Error",
            EtherPayload => "Payload with Ether Type Error",
            VlanHeader => "VLAN Header Error",
            MacsecHeader => "MACsec Header Error",
            MacsecPacket => "MACsec Packet Error",
            IpHeader => "IP Header Error",
            Ipv4Header => "IPv4 Header Error",
            Ipv4Packet => "IPv4 Packet Error",
            IpAuthHeader => "IP Authentication Header Error",
            Ipv6Header => "IPv6 Header Error",
            Ipv6Packet => "IPv6 Packet Error",
            Ipv6ExtHeader => "IPv6 Extension Header Error",
            Ipv6HopByHopHeader => "IPv6 Hop-by-Hop Option Header Error",
            Ipv6DestOptionsHeader => "IPv6 Destination Options Header Error",
            Ipv6RouteHeader => "IPv6 Routing Header Error",
            Ipv6FragHeader => "IPv6 Fragment Header Error",
            UdpHeader => "UDP Header Error",
            UdpPayload => "UDP Payload Error",
            TcpHeader => "TCP Header Error",
            Icmpv4 => "ICMP Packet Error",
            Icmpv4Timestamp => "ICMP Timestamp Error",
            Icmpv4TimestampReply => "ICMP Timestamp Reply Error",
            Icmpv6 => "ICMPv6 Packet Error",
            Arp => "Address Resolution Protocol Packet Error",
        }
    }
}

impl core::fmt::Display for Layer {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        use Layer::*;
        match self {
            LinuxSllHeader => write!(f, "Linux Cooked Capture v1 header"),
            Ethernet2Header => write!(f, "Ethernet 2 header"),
            EtherPayload => write!(f, "Ether type payload"),
            VlanHeader => write!(f, "VLAN header"),
            MacsecHeader => write!(f, "MACsec header"),
            MacsecPacket => write!(f, "MACsec packet"),
            IpHeader => write!(f, "IP header"),
            Ipv4Header => write!(f, "IPv4 header"),
            Ipv4Packet => write!(f, "IPv4 packet"),
            IpAuthHeader => write!(f, "IP Authentication header"),
            Ipv6Header => write!(f, "IPv6 header"),
            Ipv6Packet => write!(f, "IPv6 packet"),
            Ipv6ExtHeader => write!(f, "IPv6 extension header"),
            Ipv6HopByHopHeader => write!(f, "IPv6 hop-by-hop option header"),
            Ipv6DestOptionsHeader => write!(f, "IPv6 destination options header"),
            Ipv6RouteHeader => write!(f, "IPv6 routing header"),
            Ipv6FragHeader => write!(f, "IPv6 fragment header"),
            UdpHeader => write!(f, "UDP header"),
            UdpPayload => write!(f, "UDP payload"),
            TcpHeader => write!(f, "TCP header"),
            Icmpv4 => write!(f, "ICMP packet"),
            Icmpv4Timestamp => write!(f, "ICMP timestamp message"),
            Icmpv4TimestampReply => write!(f, "ICMP timestamp reply message"),
            Icmpv6 => write!(f, "ICMPv6 packet"),
            Arp => write!(f, "Address Resolution Protocol packet"),
        }
    }
}

#[cfg(test)]
mod test {
    use super::Layer::*;
    use alloc::format;
    use std::{
        cmp::Ordering,
        collections::hash_map::DefaultHasher,
        hash::{Hash, Hasher},
    };

    #[test]
    fn debug() {
        assert_eq!("Ethernet2Header", format!("{:?}", Ethernet2Header));
    }

    #[test]
    fn clone_eq_hash_ord() {
        let layer = Ethernet2Header;
        assert_eq!(layer, layer.clone());
        let hash_a = {
            let mut hasher = DefaultHasher::new();
            layer.hash(&mut hasher);
            hasher.finish()
        };
        let hash_b = {
            let mut hasher = DefaultHasher::new();
            layer.clone().hash(&mut hasher);
            hasher.finish()
        };
        assert_eq!(hash_a, hash_b);
        assert_eq!(Ordering::Equal, layer.cmp(&layer));
        assert_eq!(Some(Ordering::Equal), layer.partial_cmp(&layer));
    }

    #[test]
    fn error_title() {
        let tests = [
            (LinuxSllHeader, "Linux Cooked Capture v1 Error"),
            (Ethernet2Header, "Ethernet 2 Header Error"),
            (EtherPayload, "Payload with Ether Type Error"),
            (VlanHeader, "VLAN Header Error"),
            (MacsecHeader, "MACsec Header Error"),
            (MacsecPacket, "MACsec Packet Error"),
            (IpHeader, "IP Header Error"),
            (Ipv4Header, "IPv4 Header Error"),
            (Ipv4Packet, "IPv4 Packet Error"),
            (IpAuthHeader, "IP Authentication Header Error"),
            (Ipv6Header, "IPv6 Header Error"),
            (Ipv6Packet, "IPv6 Packet Error"),
            (Ipv6ExtHeader, "IPv6 Extension Header Error"),
            (Ipv6HopByHopHeader, "IPv6 Hop-by-Hop Option Header Error"),
            (
                Ipv6DestOptionsHeader,
                "IPv6 Destination Options Header Error",
            ),
            (Ipv6RouteHeader, "IPv6 Routing Header Error"),
            (Ipv6FragHeader, "IPv6 Fragment Header Error"),
            (UdpHeader, "UDP Header Error"),
            (UdpPayload, "UDP Payload Error"),
            (TcpHeader, "TCP Header Error"),
            (Icmpv4, "ICMP Packet Error"),
            (Icmpv4Timestamp, "ICMP Timestamp Error"),
            (Icmpv4TimestampReply, "ICMP Timestamp Reply Error"),
            (Icmpv6, "ICMPv6 Packet Error"),
            (Arp, "Address Resolution Protocol Packet Error"),
        ];
        for test in tests {
            assert_eq!(test.0.error_title(), test.1);
        }
    }

    #[test]
    fn fmt() {
        let tests = [
            (LinuxSllHeader, "Linux Cooked Capture v1 header"),
            (Ethernet2Header, "Ethernet 2 header"),
            (EtherPayload, "Ether type payload"),
            (VlanHeader, "VLAN header"),
            (MacsecHeader, "MACsec header"),
            (MacsecPacket, "MACsec packet"),
            (IpHeader, "IP header"),
            (Ipv4Header, "IPv4 header"),
            (Ipv4Packet, "IPv4 packet"),
            (IpAuthHeader, "IP Authentication header"),
            (Ipv6Header, "IPv6 header"),
            (Ipv6Packet, "IPv6 packet"),
            (Ipv6ExtHeader, "IPv6 extension header"),
            (Ipv6HopByHopHeader, "IPv6 hop-by-hop option header"),
            (Ipv6DestOptionsHeader, "IPv6 destination options header"),
            (Ipv6RouteHeader, "IPv6 routing header"),
            (Ipv6FragHeader, "IPv6 fragment header"),
            (UdpHeader, "UDP header"),
            (UdpPayload, "UDP payload"),
            (TcpHeader, "TCP header"),
            (Icmpv4, "ICMP packet"),
            (Icmpv4Timestamp, "ICMP timestamp message"),
            (Icmpv4TimestampReply, "ICMP timestamp reply message"),
            (Icmpv6, "ICMPv6 packet"),
            (Arp, "Address Resolution Protocol packet"),
        ];
        for test in tests {
            assert_eq!(format!("{}", test.0), test.1);
        }
    }
}
