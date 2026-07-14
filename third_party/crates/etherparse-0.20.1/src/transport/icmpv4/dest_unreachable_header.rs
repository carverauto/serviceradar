/// "Destination Unreachable" ICMP header for IPv4 (without the invoking packet).
///
/// # Description in RFC 792:
///
/// If, according to the information in the gateway's routing tables,
/// the network specified in the internet destination field of a
/// datagram is unreachable, e.g., the distance to the network is
/// infinity, the gateway may send a destination unreachable message
/// to the internet source host of the datagram.  In addition, in some
/// networks, the gateway may be able to determine if the internet
/// destination host is unreachable.  Gateways in these networks may
/// send destination unreachable messages to the source host when the
/// destination host is unreachable.
///
/// If, in the destination host, the IP module cannot deliver the
/// datagram  because the indicated protocol module or process port is
/// not active, the destination host may send a destination
/// unreachable message to the source host.
///
/// Another case is when a datagram must be fragmented to be forwarded
/// by a gateway yet the Don't Fragment flag is on.  In this case the
/// gateway must discard the datagram and may return a destination
/// unreachable message.
///
/// Codes 0, 1, 4, and 5 may be received from a gateway.  Codes 2 and
/// 3 may be received from a host.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum DestUnreachableHeader {
    /// Network unreachable error.
    Network,
    /// Host unreachable error.
    Host,
    /// Transport protocol not supported error.
    Protocol,
    /// Port unreachable error.
    Port,
    /// Fragmentation would be needed but the don't fragment bit is set.
    FragmentationNeeded { next_hop_mtu: u16 },
    /// Source Route Failed
    SourceRouteFailed,
    /// Destination Network Unknown (from [RFC 1122](https://tools.ietf.org/html/rfc1122))
    NetworkUnknown,
    /// Destination Host Unknown (no route to host known) (from [RFC 1122](https://tools.ietf.org/html/rfc1122))
    HostUnknown,
    /// Source Host Isolated - obsolete (from [RFC 1122](https://tools.ietf.org/html/rfc1122))
    Isolated,
    /// Communication with Destination Network is Administratively Prohibited (from [RFC 1122](https://tools.ietf.org/html/rfc1122))
    NetworkProhibited,
    /// Communication with Destination Host is Administratively Prohibited (from [RFC 1122](https://tools.ietf.org/html/rfc1122))
    HostProhibited,
    /// Destination Network Unreachable for Type of Service (from [RFC 1122](https://tools.ietf.org/html/rfc1122))
    TosNetwork,
    /// Destination Host Unreachable for Type of Service (from [RFC 1122](https://tools.ietf.org/html/rfc1122))
    TosHost,
    /// Cannot forward because packet administratively filtered (from [RFC 1812](https://tools.ietf.org/html/rfc1812))
    FilterProhibited,
    /// Required level of precidence not supported (from [RFC 1812](https://tools.ietf.org/html/rfc1812))
    HostPrecedenceViolation,
    /// Packet was below minimum precidence (from [RFC 1812](https://tools.ietf.org/html/rfc1812))
    PrecedenceCutoff,
}

impl DestUnreachableHeader {
    /// Tries to convert the code [`u8`] value and next_hop_mtu to a [`DestUnreachableHeader`] value.
    ///
    /// Returns [`None`] in case the code value is not known as a destination unreachable code.
    pub fn from_values(code_u8: u8, next_hop_mtu: u16) -> Option<DestUnreachableHeader> {
        use crate::icmpv4::{DestUnreachableHeader::*, *};
        match code_u8 {
            CODE_DST_UNREACH_NET => Some(Network),
            CODE_DST_UNREACH_HOST => Some(Host),
            CODE_DST_UNREACH_PROTOCOL => Some(Protocol),
            CODE_DST_UNREACH_PORT => Some(Port),
            CODE_DST_UNREACH_NEED_FRAG => Some(FragmentationNeeded { next_hop_mtu }),
            CODE_DST_UNREACH_SOURCE_ROUTE_FAILED => Some(SourceRouteFailed),
            CODE_DST_UNREACH_NET_UNKNOWN => Some(NetworkUnknown),
            CODE_DST_UNREACH_HOST_UNKNOWN => Some(HostUnknown),
            CODE_DST_UNREACH_ISOLATED => Some(Isolated),
            CODE_DST_UNREACH_NET_PROHIB => Some(NetworkProhibited),
            CODE_DST_UNREACH_HOST_PROHIB => Some(HostProhibited),
            CODE_DST_UNREACH_TOS_NET => Some(TosNetwork),
            CODE_DST_UNREACH_TOS_HOST => Some(TosHost),
            CODE_DST_UNREACH_FILTER_PROHIB => Some(FilterProhibited),
            CODE_DST_UNREACH_HOST_PRECEDENCE_VIOLATION => Some(HostPrecedenceViolation),
            CODE_DST_UNREACH_PRECEDENCE_CUTOFF => Some(PrecedenceCutoff),
            _ => None,
        }
    }

    /// Returns the icmp code value of the destination unreachable packet.
    #[inline]
    pub fn code_u8(&self) -> u8 {
        use crate::icmpv4::{DestUnreachableHeader::*, *};
        match self {
            Network => CODE_DST_UNREACH_NET,
            Host => CODE_DST_UNREACH_HOST,
            Protocol => CODE_DST_UNREACH_PROTOCOL,
            Port => CODE_DST_UNREACH_PORT,
            FragmentationNeeded { next_hop_mtu: _ } => CODE_DST_UNREACH_NEED_FRAG,
            SourceRouteFailed => CODE_DST_UNREACH_SOURCE_ROUTE_FAILED,
            NetworkUnknown => CODE_DST_UNREACH_NET_UNKNOWN,
            HostUnknown => CODE_DST_UNREACH_HOST_UNKNOWN,
            Isolated => CODE_DST_UNREACH_ISOLATED,
            NetworkProhibited => CODE_DST_UNREACH_NET_PROHIB,
            HostProhibited => CODE_DST_UNREACH_HOST_PROHIB,
            TosNetwork => CODE_DST_UNREACH_TOS_NET,
            TosHost => CODE_DST_UNREACH_TOS_HOST,
            FilterProhibited => CODE_DST_UNREACH_FILTER_PROHIB,
            HostPrecedenceViolation => CODE_DST_UNREACH_HOST_PRECEDENCE_VIOLATION,
            PrecedenceCutoff => CODE_DST_UNREACH_PRECEDENCE_CUTOFF,
        }
    }
}

#[cfg(test)]
mod test {
    use crate::icmpv4::*;
    use alloc::format;
    use proptest::prelude::*;

    fn conversion_values(next_hop_mtu: u16) -> [(u8, DestUnreachableHeader); 16] {
        use DestUnreachableHeader::*;
        [
            (CODE_DST_UNREACH_NET, Network),
            (CODE_DST_UNREACH_HOST, Host),
            (CODE_DST_UNREACH_PROTOCOL, Protocol),
            (CODE_DST_UNREACH_PORT, Port),
            (
                CODE_DST_UNREACH_NEED_FRAG,
                FragmentationNeeded { next_hop_mtu },
            ),
            (CODE_DST_UNREACH_SOURCE_ROUTE_FAILED, SourceRouteFailed),
            (CODE_DST_UNREACH_NET_UNKNOWN, NetworkUnknown),
            (CODE_DST_UNREACH_HOST_UNKNOWN, HostUnknown),
            (CODE_DST_UNREACH_ISOLATED, Isolated),
            (CODE_DST_UNREACH_NET_PROHIB, NetworkProhibited),
            (CODE_DST_UNREACH_HOST_PROHIB, HostProhibited),
            (CODE_DST_UNREACH_TOS_NET, TosNetwork),
            (CODE_DST_UNREACH_TOS_HOST, TosHost),
            (CODE_DST_UNREACH_FILTER_PROHIB, FilterProhibited),
            (
                CODE_DST_UNREACH_HOST_PRECEDENCE_VIOLATION,
                HostPrecedenceViolation,
            ),
            (CODE_DST_UNREACH_PRECEDENCE_CUTOFF, PrecedenceCutoff),
        ]
    }

    proptest! {
        #[test]
        fn from_values(
            next_hop_mtu in any::<u16>(),
        ) {
            // valid values
            {
                let valid_values = conversion_values(next_hop_mtu);
                for t in valid_values {
                    assert_eq!(Some(t.1), DestUnreachableHeader::from_values(t.0, next_hop_mtu));
                }
            }
            // invalid values
            for code_u8 in 16u8..=u8::MAX {
                assert_eq!(None, DestUnreachableHeader::from_values(code_u8, next_hop_mtu));
            }
        }
    }

    proptest! {
        #[test]
        fn code_u8(
            next_hop_mtu in any::<u16>(),
        ) {
            let valid_values = conversion_values(next_hop_mtu);
            for t in valid_values {
                assert_eq!(t.0, t.1.code_u8());
            }
        }
    }

    #[test]
    fn clone_eq() {
        use DestUnreachableHeader::*;
        let values = [
            Network,
            Host,
            Protocol,
            Port,
            FragmentationNeeded { next_hop_mtu: 0 },
            SourceRouteFailed,
            NetworkUnknown,
            HostUnknown,
            Isolated,
            NetworkProhibited,
            HostProhibited,
            TosNetwork,
            TosHost,
            FilterProhibited,
            HostPrecedenceViolation,
            PrecedenceCutoff,
        ];
        for value in values {
            assert_eq!(value.clone(), value);
        }
    }

    #[test]
    fn debug() {
        use DestUnreachableHeader::*;
        let tests = [
            ("Network", Network),
            ("Host", Host),
            ("Protocol", Protocol),
            ("Port", Port),
            (
                "FragmentationNeeded { next_hop_mtu: 0 }",
                FragmentationNeeded { next_hop_mtu: 0 },
            ),
            ("SourceRouteFailed", SourceRouteFailed),
            ("NetworkUnknown", NetworkUnknown),
            ("HostUnknown", HostUnknown),
            ("Isolated", Isolated),
            ("NetworkProhibited", NetworkProhibited),
            ("HostProhibited", HostProhibited),
            ("TosNetwork", TosNetwork),
            ("TosHost", TosHost),
            ("FilterProhibited", FilterProhibited),
            ("HostPrecedenceViolation", HostPrecedenceViolation),
            ("PrecedenceCutoff", PrecedenceCutoff),
        ];
        for t in tests {
            assert_eq!(t.0, format!("{:?}", t.1));
        }
    }
}
