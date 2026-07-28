use crate::*;

/// Slice containing UDP, TCP, ICMP or ICMPv4 header & payload.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum TransportSlice<'a> {
    /// A slice containing an Icmp4 header & payload.
    Icmpv4(Icmpv4Slice<'a>),

    /// A slice containing an Icmp6 header & payload.
    Icmpv6(Icmpv6Slice<'a>),

    /// A slice containing an UDP header & payload.
    Udp(UdpSlice<'a>),

    /// A slice containing a TCP header & payload.
    Tcp(TcpSlice<'a>),
}

#[cfg(test)]
mod test {
    use super::*;
    use alloc::{format, vec::Vec};

    #[test]
    fn debug_clone_eq() {
        // udp
        {
            let header: UdpHeader = Default::default();
            let raw = header.to_bytes();
            let u = UdpSlice::from_slice(&raw).unwrap();
            let slice = TransportSlice::Udp(u.clone());

            // clone & eq
            assert_eq!(slice.clone(), slice);

            // debug
            assert_eq!(format!("{:?}", slice), format!("Udp({:?})", u));
        }
        // tcp
        {
            let header: TcpHeader = Default::default();
            let buffer = {
                let mut buffer = Vec::with_capacity(header.header_len() as usize);
                header.write(&mut buffer).unwrap();
                buffer
            };
            let t = TcpSlice::from_slice(&buffer).unwrap();
            let slice = TransportSlice::Tcp(t.clone());

            // clone & eq
            assert_eq!(slice.clone(), slice);

            // debug
            assert_eq!(format!("{:?}", slice), format!("Tcp({:?})", t));
        }
    }
}
