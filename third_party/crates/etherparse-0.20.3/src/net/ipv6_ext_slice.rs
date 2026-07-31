use crate::*;

/// Enum containing a slice of a supported ipv6 extension header.
///
/// This enum is used as item type when iterating over a list of extension headers
/// with an [Ipv6ExtensionSliceIter].
///
/// Note the following extension headers are missing from
/// this enum and currently not supported (list taken on 2021-07-17
/// from <https://www.iana.org/assignments/ipv6-parameters/ipv6-parameters.xhtml>):
///
/// * Encapsulating Security Payload \[[RFC4303](https://datatracker.ietf.org/doc/html/rfc4303)\]
/// * Mobility Header \[[RFC6275](https://datatracker.ietf.org/doc/html/rfc6275)\]
/// * Host Identity Protocol \[[RFC7401](https://datatracker.ietf.org/doc/html/rfc7401)\]
/// * Shim6 Protocol \[[RFC5533](https://datatracker.ietf.org/doc/html/rfc5533)\]
/// * 253 Use for experimentation and testing \[[RFC3692](https://datatracker.ietf.org/doc/html/rfc3692)\]\[[RFC4727](https://datatracker.ietf.org/doc/html/rfc4727)\]
/// * 254 Use for experimentation and testing \[[RFC3692](https://datatracker.ietf.org/doc/html/rfc3692)\]\[[RFC4727](https://datatracker.ietf.org/doc/html/rfc4727)\]
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum Ipv6ExtensionSlice<'a> {
    /// IPv6 Hop-by-Hop Option \[[RFC8200](https://datatracker.ietf.org/doc/html/rfc8200)\]
    HopByHop(Ipv6RawExtHeaderSlice<'a>),
    /// Routing Header for IPv6 \[[RFC8200](https://datatracker.ietf.org/doc/html/rfc8200)\] \[[RFC5095](https://datatracker.ietf.org/doc/html/rfc5095)\]
    Routing(Ipv6RawExtHeaderSlice<'a>),
    /// Fragment Header for IPv6 \[[RFC8200](https://datatracker.ietf.org/doc/html/rfc8200)\]
    Fragment(Ipv6FragmentHeaderSlice<'a>),
    /// Destination Options for IPv6 \[[RFC8200](https://datatracker.ietf.org/doc/html/rfc8200)\]
    DestinationOptions(Ipv6RawExtHeaderSlice<'a>),
    /// Authentication Header \[[RFC4302](https://datatracker.ietf.org/doc/html/rfc4302)\]
    Authentication(IpAuthHeaderSlice<'a>),
}

#[cfg(test)]
mod test {
    use super::*;
    use crate::ip_number::*;

    #[test]
    fn debug() {
        use alloc::{format, vec::Vec};
        use Ipv6ExtensionSlice::*;
        {
            let header = Ipv6RawExtHeader::new_raw(UDP, &[1, 2, 3, 4, 5, 6]).unwrap();
            let mut buffer = Vec::with_capacity(header.header_len());
            header.write(&mut buffer).unwrap();
            let slice = Ipv6RawExtHeaderSlice::from_slice(&buffer).unwrap();
            assert_eq!(
                format!("HopByHop({:?})", slice),
                format!("{:?}", HopByHop(slice.clone()))
            );
            assert_eq!(
                format!("Routing({:?})", slice),
                format!("{:?}", Routing(slice.clone()))
            );
            assert_eq!(
                format!("DestinationOptions({:?})", slice),
                format!("{:?}", DestinationOptions(slice.clone()))
            );
        }
        {
            let header = Ipv6FragmentHeader::new(UDP, 1.try_into().unwrap(), true, 2);
            let mut buffer = Vec::with_capacity(header.header_len());
            header.write(&mut buffer).unwrap();
            let slice = Ipv6FragmentHeaderSlice::from_slice(&buffer).unwrap();
            assert_eq!(
                format!("Fragment({:?})", slice),
                format!("{:?}", Fragment(slice))
            );
        }
        {
            let header = IpAuthHeader::new(UDP, 1, 2, &[1, 2, 3, 4]).unwrap();
            let mut buffer = Vec::with_capacity(header.header_len());
            header.write(&mut buffer).unwrap();
            let slice = IpAuthHeaderSlice::from_slice(&buffer).unwrap();
            assert_eq!(
                format!("Authentication({:?})", slice),
                format!("{:?}", Authentication(slice.clone()))
            );
        }
    }

    #[test]
    fn clone_eq() {
        use alloc::vec::Vec;
        use Ipv6ExtensionSlice::*;

        let header = Ipv6RawExtHeader::new_raw(UDP, &[1, 2, 3, 4, 5, 6]).unwrap();
        let mut buffer = Vec::with_capacity(header.header_len());
        header.write(&mut buffer).unwrap();
        let slice = Ipv6RawExtHeaderSlice::from_slice(&buffer).unwrap();

        let hop = HopByHop(slice.clone());
        assert_eq!(hop.clone(), hop.clone());

        let route = Routing(slice.clone());
        assert_eq!(route.clone(), route.clone());

        assert_ne!(route, hop);
    }
}
