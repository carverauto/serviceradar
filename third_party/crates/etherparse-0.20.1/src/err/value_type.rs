/// Types of values that have a limited allowed value range
/// and can cause an [`crate::err::ValueTooBigError`].
#[derive(Copy, Clone, Debug, Eq, PartialEq, Ord, PartialOrd, Hash)]
pub enum ValueType {
    /// VLAN identifier field present in a [`crate::SingleVlanHeader`].
    VlanId,
    /// VLAN PCP (Priority Code Point) field in a [`crate::SingleVlanHeader`].
    VlanPcp,
    /// MACsec association number (present in the [`crate::MacsecHeader`]).
    MacsecAn,
    /// MACsec short length (present in the [`crate::MacsecHeader`]).
    MacsecShortLen,
    /// IP Fragment offset present in the IPv4 header and
    /// IPv6 fragmentation header.
    IpFragmentOffset,
    /// IPv4 & IPv6 Header DSCP (Differentiated Services Code Point) field
    /// present in an [`crate::Ipv4Header`] or [`crate::Ipv6Header`].
    IpDscp,
    /// IPv6 & IPv6 Header ECN (Explicit Congestion Notification) field
    /// present in an [`crate::Ipv4Header`] or [`crate::Ipv6Header`].
    IpEcn,
    /// IPv6 Header Flow Label field present in [`crate::Ipv6Header`].
    Ipv6FlowLabel,
    /// IPv4 Header "total length" field based on the payload
    /// length after the header.
    Ipv4PayloadLength,
    /// IPv6 Header "payload length" field present in an
    /// [`crate::Ipv6Header`].
    Ipv6PayloadLength,
    /// Payload length used when calculating the checksum of a
    /// [`crate::UdpHeader`] for IPv4.
    UdpPayloadLengthIpv4,
    /// Payload length used when calculating the checksum of a
    /// [`crate::UdpHeader`] for IPv6.
    UdpPayloadLengthIpv6,
    /// Payload length used when calculating the checksum of a
    /// [`crate::TcpHeader`] for IPv4.
    TcpPayloadLengthIpv4,
    /// Payload length used when calculating the checksum of a
    /// [`crate::TcpHeader`] for IPv6.
    TcpPayloadLengthIpv6,
    /// Variable length data of an ICMPv6 packet.
    Icmpv6PayloadLength,
    /// Packet type of a Linux Cooked Capture v1 (SLL)
    LinuxSllType,
}

impl core::fmt::Display for ValueType {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        use ValueType::*;
        match self {
            VlanId => write!(f, "VLAN ID"),
            VlanPcp => write!(f, "VLAN PCP (Priority Code Point)"),
            MacsecAn => write!(f, "MACsec AN (Association Number)"),
            MacsecShortLen => write!(f, "MACsec SL (Short Length)"),
            IpFragmentOffset => write!(f, "IP Fragment Offset"),
            IpDscp => write!(f, "IPv4 DSCP (Differentiated Services Code Point)"),
            IpEcn => write!(f, "IPv4 ECN (Explicit Congestion Notification)"),
            Ipv6FlowLabel => write!(f, "IPv6 Flow Label"),
            Ipv4PayloadLength => write!(f, "IPv4 Header 'Payload Length' (sets 'Total Length')"),
            Ipv6PayloadLength => write!(f, "IPv6 Header 'Payload Length'"),
            UdpPayloadLengthIpv4 => write!(f, "UDP Payload Length (in IPv4 checksum calculation)"),
            UdpPayloadLengthIpv6 => write!(f, "UDP Payload Length (in IPv6 checksum calculation)"),
            TcpPayloadLengthIpv4 => write!(f, "TCP Payload Length (in IPv4 checksum calculation)"),
            TcpPayloadLengthIpv6 => write!(f, "TCP Payload Length (in IPv6 checksum calculation)"),
            Icmpv6PayloadLength => write!(f, "ICMPv6 Payload Length"),
            LinuxSllType => write!(f, "Linux Cooked Capture v1 (SLL)"),
        }
    }
}

#[cfg(test)]
mod test {
    use super::*;
    use std::format;

    #[test]
    fn debug() {
        assert_eq!(
            format!("{:?}", ValueType::IpFragmentOffset),
            "IpFragmentOffset"
        );
    }

    #[test]
    fn cmp_partial_cmp() {
        use core::cmp::Ordering;
        let a = ValueType::IpFragmentOffset;
        let b = a;
        assert_eq!(a.cmp(&b), Ordering::Equal);
        assert_eq!(a.partial_cmp(&b), Some(Ordering::Equal));
    }

    #[test]
    fn display() {
        use ValueType::*;

        assert_eq!("VLAN ID", &format!("{}", VlanId));
        assert_eq!("VLAN PCP (Priority Code Point)", &format!("{}", VlanPcp));
        assert_eq!("MACsec AN (Association Number)", &format!("{}", MacsecAn));
        assert_eq!("MACsec SL (Short Length)", &format!("{}", MacsecShortLen));
        assert_eq!("IP Fragment Offset", &format!("{}", IpFragmentOffset));
        assert_eq!(
            "IPv4 DSCP (Differentiated Services Code Point)",
            &format!("{}", IpDscp)
        );
        assert_eq!(
            "IPv4 ECN (Explicit Congestion Notification)",
            &format!("{}", IpEcn)
        );
        assert_eq!("IPv6 Flow Label", &format!("{}", Ipv6FlowLabel));
        assert_eq!(
            "IPv4 Header 'Payload Length' (sets 'Total Length')",
            &format!("{}", Ipv4PayloadLength)
        );
        assert_eq!(
            "IPv6 Header 'Payload Length'",
            &format!("{}", Ipv6PayloadLength)
        );
        assert_eq!(
            "UDP Payload Length (in IPv4 checksum calculation)",
            &format!("{}", UdpPayloadLengthIpv4)
        );
        assert_eq!(
            "UDP Payload Length (in IPv6 checksum calculation)",
            &format!("{}", UdpPayloadLengthIpv6)
        );
        assert_eq!(
            "TCP Payload Length (in IPv4 checksum calculation)",
            &format!("{}", TcpPayloadLengthIpv4)
        );
        assert_eq!(
            "TCP Payload Length (in IPv6 checksum calculation)",
            &format!("{}", TcpPayloadLengthIpv6)
        );
        assert_eq!("ICMPv6 Payload Length", &format!("{}", Icmpv6PayloadLength));
    }
}
