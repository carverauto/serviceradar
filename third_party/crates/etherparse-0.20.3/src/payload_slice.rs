use crate::*;

/// Payload together with an identifier the type of content.
#[derive(Debug, Clone, Eq, PartialEq, Hash, PartialOrd, Ord)]
pub enum PayloadSlice<'a> {
    /// No specific payload (e.g. ARP packet).
    Empty,

    /// Payload with it's type identified by an ether type number
    /// (e.g. after an ethernet II or vlan header).
    Ether(EtherPayloadSlice<'a>),

    /// MACsec encrypted or modified payload.
    MacsecMod(&'a [u8]),

    /// Payload with is's type identified by an ip number (e.g.
    /// after an IP header or after an)
    Ip(IpPayloadSlice<'a>),

    /// UDP payload.
    Udp(&'a [u8]),

    /// TCP payload.
    Tcp(&'a [u8]),

    /// Payload part of an ICMP V4 message. Check [`crate::Icmpv4Type`]
    /// for a description what will be part of the payload.
    Icmpv4(&'a [u8]),

    /// Payload part of an ICMP V4 message. Check [`crate::Icmpv6Type`]
    /// for a description what will be part of the payload.
    Icmpv6(&'a [u8]),
}

impl<'a> PayloadSlice<'a> {
    pub fn slice(&self) -> &'a [u8] {
        match self {
            PayloadSlice::Empty => &[],
            PayloadSlice::Ether(s) => s.payload,
            PayloadSlice::MacsecMod(s) => s,
            PayloadSlice::Ip(s) => s.payload,
            PayloadSlice::Udp(s) => s,
            PayloadSlice::Tcp(s) => s,
            PayloadSlice::Icmpv4(s) => s,
            PayloadSlice::Icmpv6(s) => s,
        }
    }
}

#[cfg(test)]
mod test {
    use super::*;
    use alloc::format;

    #[test]
    fn debug() {
        assert_eq!(
            format!("Udp({:?})", &[0u8; 0]),
            format!("{:?}", PayloadSlice::Udp(&[]))
        );
    }

    #[test]
    fn clone_eq_hash_ord() {
        let s = PayloadSlice::Udp(&[]);
        assert_eq!(s.clone(), s);

        use std::collections::hash_map::DefaultHasher;
        use std::hash::{Hash, Hasher};

        let a_hash = {
            let mut hasher = DefaultHasher::new();
            s.hash(&mut hasher);
            hasher.finish()
        };
        let b_hash = {
            let mut hasher = DefaultHasher::new();
            s.clone().hash(&mut hasher);
            hasher.finish()
        };
        assert_eq!(a_hash, b_hash);

        use std::cmp::Ordering;
        assert_eq!(s.clone().cmp(&s), Ordering::Equal);
        assert_eq!(s.clone().partial_cmp(&s), Some(Ordering::Equal));
    }

    #[test]
    fn slice() {
        let payload = [1, 2, 3, 4];

        use PayloadSlice::*;
        assert_eq!(
            Ether(EtherPayloadSlice {
                ether_type: EtherType::IPV4,
                len_source: LenSource::Slice,
                payload: &payload
            })
            .slice(),
            &payload
        );
        assert_eq!(
            Ip(IpPayloadSlice {
                ip_number: IpNumber::IPV4,
                fragmented: false,
                len_source: LenSource::Slice,
                payload: &payload
            })
            .slice(),
            &payload
        );
        assert_eq!(Udp(&payload).slice(), &payload);
        assert_eq!(Tcp(&payload).slice(), &payload);
        assert_eq!(Icmpv4(&payload).slice(), &payload);
        assert_eq!(Icmpv6(&payload).slice(), &payload);
    }
}
