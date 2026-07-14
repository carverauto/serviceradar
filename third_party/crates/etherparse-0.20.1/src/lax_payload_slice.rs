use crate::*;

/// Laxly parsed payload together with an identifier the type of content & the
/// information if the payload is incomplete.
#[derive(Debug, Clone, Eq, PartialEq, Hash, PartialOrd, Ord)]
pub enum LaxPayloadSlice<'a> {
    /// No specific payload (e.g. ARP packet).
    Empty,

    /// Payload with it's type identified by an ether type number
    /// (e.g. after an ethernet II or vlan header).
    Ether(LaxEtherPayloadSlice<'a>),

    /// MACsec modified payload (either by encryption or other algorithm).
    MacsecModified {
        payload: &'a [u8],
        /// True if the payload has been cut off.
        incomplete: bool,
    },

    /// Payload with is's type identified by an ip number (e.g.
    /// after an IP header or after an)
    Ip(LaxIpPayloadSlice<'a>),

    /// UDP payload.
    Udp {
        payload: &'a [u8],
        /// True if the payload has been cut off.
        incomplete: bool,
    },

    /// TCP payload.
    Tcp {
        payload: &'a [u8],
        /// True if the payload has been cut off.
        incomplete: bool,
    },

    /// Payload part of an ICMP V4 message. Check [`crate::Icmpv4Type`]
    /// for a description what will be part of the payload.
    Icmpv4 {
        payload: &'a [u8],
        /// True if the payload has been cut off.
        incomplete: bool,
    },

    /// Payload part of an ICMP V4 message. Check [`crate::Icmpv6Type`]
    /// for a description what will be part of the payload.
    Icmpv6 {
        payload: &'a [u8],
        /// True if the payload has been cut off.
        incomplete: bool,
    },

    /// Linux SLL payload.
    LinuxSll(LinuxSllPayloadSlice<'a>),
}

impl<'a> LaxPayloadSlice<'a> {
    pub fn slice(&self) -> &'a [u8] {
        match self {
            LaxPayloadSlice::Empty => &[],
            LaxPayloadSlice::Ether(e) => e.payload,
            LaxPayloadSlice::MacsecModified {
                payload,
                incomplete: _,
            } => payload,
            LaxPayloadSlice::Ip(i) => i.payload,
            LaxPayloadSlice::Udp {
                payload,
                incomplete: _,
            } => payload,
            LaxPayloadSlice::Tcp {
                payload,
                incomplete: _,
            } => payload,
            LaxPayloadSlice::Icmpv4 {
                payload,
                incomplete: _,
            } => payload,
            LaxPayloadSlice::Icmpv6 {
                payload,
                incomplete: _,
            } => payload,
            LaxPayloadSlice::LinuxSll(linux_sll) => linux_sll.payload,
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
            format!("Udp {{ payload: {:?}, incomplete: {} }}", &[0u8; 0], false),
            format!(
                "{:?}",
                LaxPayloadSlice::Udp {
                    payload: &[],
                    incomplete: false
                }
            )
        );
    }

    #[test]
    fn clone_eq_hash_ord() {
        let s = LaxPayloadSlice::Udp {
            payload: &[],
            incomplete: false,
        };
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

        use LaxPayloadSlice::*;
        assert_eq!(
            Ether(LaxEtherPayloadSlice {
                incomplete: false,
                ether_type: EtherType::IPV4,
                len_source: LenSource::Slice,
                payload: &payload,
            })
            .slice(),
            &payload
        );
        assert_eq!(
            MacsecModified {
                payload: &payload,
                incomplete: false,
            }
            .slice(),
            &payload
        );
        assert_eq!(
            Ip(LaxIpPayloadSlice {
                ip_number: IpNumber::IPV4,
                fragmented: false,
                len_source: LenSource::Slice,
                payload: &payload,
                incomplete: true,
            })
            .slice(),
            &payload
        );
        assert_eq!(
            Udp {
                payload: &payload,
                incomplete: false
            }
            .slice(),
            &payload
        );
        assert_eq!(
            Tcp {
                payload: &payload,
                incomplete: false
            }
            .slice(),
            &payload
        );
        assert_eq!(
            Icmpv4 {
                payload: &payload,
                incomplete: false
            }
            .slice(),
            &payload
        );
        assert_eq!(
            Icmpv6 {
                payload: &payload,
                incomplete: false
            }
            .slice(),
            &payload
        );
        assert_eq!(
            LinuxSll(LinuxSllPayloadSlice {
                protocol_type: LinuxSllProtocolType::Ignored(0),
                payload: &payload,
            })
            .slice(),
            &payload
        );
    }
}
