use crate::*;

/// Slice containing laxly parsed the network headers & payloads (e.g. IPv4, IPv6, ARP).
///
/// Compared to the normal [`NetSlice`] this slice allows the
/// payload to be incomplete/cut off and errors to be present in
/// the IpPayload.
///
/// The main usecases for "laxly" parsed slices are are:
///
/// * Parsing packets that have been cut off. This is, for example, useful to
///   parse packets returned via ICMP as these usually only contain the start.
/// * Parsing packets where the `total_len` (for IPv4) or `payload_len` (for IPv6)
///   have not yet been set. This can be useful when parsing packets which have
///   been recorded in a layer before the length field was set (e.g. before the
///   operating system set the length fields).
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum LaxNetSlice<'a> {
    /// IPv4 header & the decoded extension headers.
    Ipv4(LaxIpv4Slice<'a>),
    /// IPv6 header & the decoded extension headers.
    Ipv6(LaxIpv6Slice<'a>),
    /// "Address Resolution Protocol" Packet,
    Arp(ArpPacketSlice<'a>),
}

impl<'a> LaxNetSlice<'a> {
    /// Returns a reference to ip payload if the net slice contains
    /// an ipv4 or ipv6 slice.
    #[inline]
    pub fn ip_payload_ref(&self) -> Option<&LaxIpPayloadSlice<'a>> {
        match self {
            LaxNetSlice::Ipv4(s) => Some(&s.payload),
            LaxNetSlice::Ipv6(s) => Some(&s.payload),
            LaxNetSlice::Arp(_) => None,
        }
    }
}

impl<'a> From<LaxIpSlice<'a>> for LaxNetSlice<'a> {
    #[inline]
    fn from(value: LaxIpSlice<'a>) -> LaxNetSlice<'a> {
        match value {
            LaxIpSlice::Ipv4(ipv4) => LaxNetSlice::Ipv4(ipv4),
            LaxIpSlice::Ipv6(ipv6) => LaxNetSlice::Ipv6(ipv6),
        }
    }
}

impl<'a> From<LaxIpv4Slice<'a>> for LaxNetSlice<'a> {
    #[inline]
    fn from(value: LaxIpv4Slice<'a>) -> LaxNetSlice<'a> {
        LaxNetSlice::Ipv4(value)
    }
}

impl<'a> From<LaxIpv6Slice<'a>> for LaxNetSlice<'a> {
    #[inline]
    fn from(value: LaxIpv6Slice<'a>) -> LaxNetSlice<'a> {
        LaxNetSlice::Ipv6(value)
    }
}

#[cfg(test)]
mod tests {
    use crate::*;
    use alloc::{format, vec::Vec};

    #[test]
    fn debug() {
        let bytes = Ipv6Header {
            next_header: IpNumber::UDP,
            ..Default::default()
        }
        .to_bytes();
        let s = LaxIpv6Slice::from_slice(&bytes).unwrap().0;
        let n = LaxNetSlice::Ipv6(s.clone());
        assert_eq!(format!("{n:?}"), format!("Ipv6({s:?})"));
    }

    #[test]
    fn clone_eq() {
        let bytes = Ipv6Header {
            next_header: IpNumber::UDP,
            ..Default::default()
        }
        .to_bytes();
        let s = LaxNetSlice::Ipv6(LaxIpv6Slice::from_slice(&bytes).unwrap().0);
        assert_eq!(s, s.clone())
    }

    #[test]
    fn ip_payload_ref() {
        // ipv4
        {
            let payload = [1, 2, 3, 4];
            let bytes = {
                let mut bytes = Vec::with_capacity(Ipv4Header::MIN_LEN + 4);
                bytes.extend_from_slice(
                    &(Ipv4Header {
                        total_len: Ipv4Header::MIN_LEN_U16 + 4,
                        protocol: IpNumber::UDP,
                        ..Default::default()
                    })
                    .to_bytes(),
                );
                bytes.extend_from_slice(&payload);
                bytes
            };
            let s = LaxNetSlice::Ipv4(LaxIpv4Slice::from_slice(&bytes).unwrap().0);
            assert_eq!(
                s.ip_payload_ref(),
                Some(&LaxIpPayloadSlice {
                    ip_number: IpNumber::UDP,
                    fragmented: false,
                    len_source: LenSource::Ipv4HeaderTotalLen,
                    payload: &payload,
                    incomplete: false,
                })
            );
        }
        // ipv6
        {
            let payload = [1, 2, 3, 4];
            let bytes = {
                let mut bytes = Vec::with_capacity(Ipv6Header::LEN + 4);
                bytes.extend_from_slice(
                    &(Ipv6Header {
                        next_header: IpNumber::UDP,
                        payload_length: 4,
                        ..Default::default()
                    })
                    .to_bytes(),
                );
                bytes.extend_from_slice(&payload);
                bytes
            };
            let s = LaxNetSlice::Ipv6(LaxIpv6Slice::from_slice(&bytes).unwrap().0);
            assert_eq!(
                s.ip_payload_ref(),
                Some(&LaxIpPayloadSlice {
                    ip_number: IpNumber::UDP,
                    fragmented: false,
                    len_source: LenSource::Ipv6HeaderPayloadLen,
                    payload: &payload,
                    incomplete: false,
                })
            );
        }
    }

    #[test]
    fn from() {
        // IpSlice::Ipv4
        {
            let payload = [1, 2, 3, 4];
            let bytes = {
                let mut bytes = Vec::with_capacity(Ipv4Header::MIN_LEN + 4);
                bytes.extend_from_slice(
                    &(Ipv4Header {
                        total_len: Ipv4Header::MIN_LEN_U16 + 4,
                        protocol: IpNumber::UDP,
                        ..Default::default()
                    })
                    .to_bytes(),
                );
                bytes.extend_from_slice(&payload);
                bytes
            };
            let i = LaxIpv4Slice::from_slice(&bytes).unwrap().0;
            let actual: LaxNetSlice = LaxIpSlice::Ipv4(i.clone()).into();
            assert_eq!(LaxNetSlice::Ipv4(i.clone()), actual);
        }
        // LaxIpv4Slice
        {
            let payload = [1, 2, 3, 4];
            let bytes = {
                let mut bytes = Vec::with_capacity(Ipv4Header::MIN_LEN + 4);
                bytes.extend_from_slice(
                    &(Ipv4Header {
                        total_len: Ipv4Header::MIN_LEN_U16 + 4,
                        protocol: IpNumber::UDP,
                        ..Default::default()
                    })
                    .to_bytes(),
                );
                bytes.extend_from_slice(&payload);
                bytes
            };
            let i = LaxIpv4Slice::from_slice(&bytes).unwrap().0;
            let actual: LaxNetSlice = i.clone().into();
            assert_eq!(LaxNetSlice::Ipv4(i.clone()), actual);
        }
        // IpSlice::Ipv6
        {
            let payload = [1, 2, 3, 4];
            let bytes = {
                let mut bytes = Vec::with_capacity(Ipv6Header::LEN + 4);
                bytes.extend_from_slice(
                    &(Ipv6Header {
                        next_header: IpNumber::UDP,
                        payload_length: 4,
                        ..Default::default()
                    })
                    .to_bytes(),
                );
                bytes.extend_from_slice(&payload);
                bytes
            };
            let i = LaxIpv6Slice::from_slice(&bytes).unwrap().0;
            let actual: LaxNetSlice = i.clone().into();
            assert_eq!(LaxNetSlice::Ipv6(i.clone()), actual);
        }
    }
}
