use crate::*;

/// Slice containing an IPv4 or IPv6 base header plus extension headers.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum IpHeadersSlice<'a> {
    /// IPv4 base header and extension headers.
    Ipv4(Ipv4HeaderSlice<'a>, Ipv4ExtensionsSlice<'a>),
    /// IPv6 base header and extension headers.
    Ipv6(Ipv6HeaderSlice<'a>, Ipv6ExtensionsSlice<'a>),
}

impl<'a> IpHeadersSlice<'a> {
    /// Returns true if the slice contains an IPv4 header.
    #[inline]
    pub fn is_ipv4(&self) -> bool {
        matches!(self, IpHeadersSlice::Ipv4(_, _))
    }

    /// Returns true if the slice contains an IPv6 header.
    #[inline]
    pub fn is_ipv6(&self) -> bool {
        matches!(self, IpHeadersSlice::Ipv6(_, _))
    }

    /// Returns the IPv4 header slice if `self` contains one.
    #[inline]
    pub fn ipv4(&self) -> Option<Ipv4HeaderSlice<'a>> {
        if let IpHeadersSlice::Ipv4(v, _) = self {
            Some(*v)
        } else {
            None
        }
    }

    /// Returns the IPv4 extension header slices if `self` contains one.
    #[inline]
    pub fn ipv4_exts(&self) -> Option<Ipv4ExtensionsSlice<'a>> {
        if let IpHeadersSlice::Ipv4(_, v) = self {
            Some(*v)
        } else {
            None
        }
    }

    /// Returns the IPv6 header slice if `self` contains one.
    #[inline]
    pub fn ipv6(&self) -> Option<Ipv6HeaderSlice<'a>> {
        if let IpHeadersSlice::Ipv6(v, _) = self {
            Some(*v)
        } else {
            None
        }
    }

    /// Returns the IPv6 extension header slices if `self` contains one.
    #[inline]
    pub fn ipv6_exts(&self) -> Option<&Ipv6ExtensionsSlice<'a>> {
        if let IpHeadersSlice::Ipv6(_, v) = self {
            Some(v)
        } else {
            None
        }
    }

    /// Returns the underlying base-header slice.
    #[inline]
    pub fn slice(&self) -> &'a [u8] {
        match self {
            IpHeadersSlice::Ipv4(v, _) => v.slice(),
            IpHeadersSlice::Ipv6(v, _) => v.slice(),
        }
    }

    /// Returns the source IP address.
    #[inline]
    pub fn source_addr(&self) -> core::net::IpAddr {
        match self {
            IpHeadersSlice::Ipv4(v, _) => v.source_addr().into(),
            IpHeadersSlice::Ipv6(v, _) => v.source_addr().into(),
        }
    }

    /// Returns the destination IP address.
    #[inline]
    pub fn destination_addr(&self) -> core::net::IpAddr {
        match self {
            IpHeadersSlice::Ipv4(v, _) => v.destination_addr().into(),
            IpHeadersSlice::Ipv6(v, _) => v.destination_addr().into(),
        }
    }

    /// Returns the protocol number stored in the base header.
    ///
    /// For IPv4 this is the `protocol` field and for IPv6 this is
    /// the `next_header` field.
    #[inline]
    pub fn next_header(&self) -> IpNumber {
        match self {
            IpHeadersSlice::Ipv4(v, _) => v.protocol(),
            IpHeadersSlice::Ipv6(v, _) => v.next_header(),
        }
    }

    /// Returns the payload IP number after extension headers.
    #[inline]
    pub fn payload_ip_number(&self) -> IpNumber {
        match self {
            IpHeadersSlice::Ipv4(v, exts) => {
                exts.auth.map(|a| a.next_header()).unwrap_or(v.protocol())
            }
            IpHeadersSlice::Ipv6(v, exts) => {
                let (_, payload_ip_number, _, _) =
                    Ipv6Extensions::from_slice_lax(v.next_header(), exts.slice());
                payload_ip_number
            }
        }
    }

    /// Returns the IP version (4 or 6).
    #[inline]
    pub fn version(&self) -> u8 {
        match self {
            IpHeadersSlice::Ipv4(v, _) => v.version(),
            IpHeadersSlice::Ipv6(v, _) => v.version(),
        }
    }

    /// Returns the serialized header length in bytes, including extensions.
    #[inline]
    pub fn header_len(&self) -> usize {
        match self {
            IpHeadersSlice::Ipv4(v, exts) => {
                v.slice().len() + exts.auth.map(|v| v.slice().len()).unwrap_or(0)
            }
            IpHeadersSlice::Ipv6(v, exts) => v.slice().len() + exts.slice().len(),
        }
    }

    /// Converts this sliced header representation into [`IpHeaders`].
    ///
    /// For IPv6 this conversion uses [`Ipv6Extensions::from_slice`].
    ///
    /// Note that [`Ipv6Extensions`] can only represent a subset of valid IPv6
    /// extension chains. If more extension headers are present than can be
    /// represented, only the representable subset is converted.
    #[inline]
    pub fn try_to_header(&self) -> Result<IpHeaders, err::ipv6_exts::HeaderSliceError> {
        match self {
            IpHeadersSlice::Ipv4(v, exts) => Ok(IpHeaders::Ipv4(v.to_header(), exts.to_header())),
            IpHeadersSlice::Ipv6(v, exts) => {
                let (exts, _, _) = Ipv6Extensions::from_slice(v.next_header(), exts.slice())?;
                Ok(IpHeaders::Ipv6(v.to_header(), exts))
            }
        }
    }
}

impl<'a> From<Ipv4HeaderSlice<'a>> for IpHeadersSlice<'a> {
    #[inline]
    fn from(value: Ipv4HeaderSlice<'a>) -> Self {
        Self::Ipv4(value, Default::default())
    }
}

impl<'a> From<Ipv6HeaderSlice<'a>> for IpHeadersSlice<'a> {
    #[inline]
    fn from(value: Ipv6HeaderSlice<'a>) -> Self {
        Self::Ipv6(value, Default::default())
    }
}

impl<'a> From<(Ipv4HeaderSlice<'a>, Ipv4ExtensionsSlice<'a>)> for IpHeadersSlice<'a> {
    #[inline]
    fn from(value: (Ipv4HeaderSlice<'a>, Ipv4ExtensionsSlice<'a>)) -> Self {
        Self::Ipv4(value.0, value.1)
    }
}

impl<'a> From<(Ipv6HeaderSlice<'a>, Ipv6ExtensionsSlice<'a>)> for IpHeadersSlice<'a> {
    #[inline]
    fn from(value: (Ipv6HeaderSlice<'a>, Ipv6ExtensionsSlice<'a>)) -> Self {
        Self::Ipv6(value.0, value.1)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use alloc::vec::Vec;
    use core::net::{IpAddr, Ipv4Addr, Ipv6Addr};

    #[test]
    fn is_ipv4_ipv6_and_accessors() {
        // ipv4 with auth extension
        {
            let h = Ipv4Header {
                protocol: ip_number::AUTH,
                source: [1, 2, 3, 4],
                destination: [5, 6, 7, 8],
                ..Default::default()
            };
            let header_bytes = h.to_bytes();
            let auth = IpAuthHeader::new(ip_number::UDP, 7, 9, &[1, 2, 3, 4]).unwrap();
            let auth_bytes = auth.to_bytes();
            let exts = Ipv4ExtensionsSlice::from_slice(ip_number::AUTH, &auth_bytes)
                .unwrap()
                .0;
            let s = IpHeadersSlice::Ipv4(Ipv4HeaderSlice::from_slice(&header_bytes).unwrap(), exts);
            assert!(s.is_ipv4());
            assert_eq!(false, s.is_ipv6());
            assert!(s.ipv4().is_some());
            assert!(s.ipv6().is_none());
            assert!(s.ipv4_exts().is_some());
            assert!(s.ipv6_exts().is_none());
            assert_eq!(s.slice(), header_bytes.as_slice());
            assert_eq!(
                s.ipv4_exts().unwrap().auth.unwrap().slice(),
                auth_bytes.as_slice()
            );
            assert_eq!(s.next_header(), ip_number::AUTH);
            assert_eq!(s.payload_ip_number(), ip_number::UDP);
            assert_eq!(s.version(), 4);
            assert_eq!(s.header_len(), Ipv4Header::MIN_LEN + auth.header_len());
            assert_eq!(s.source_addr(), IpAddr::V4(Ipv4Addr::new(1, 2, 3, 4)));
            assert_eq!(s.destination_addr(), IpAddr::V4(Ipv4Addr::new(5, 6, 7, 8)));
        }

        // ipv6 with fragment extension
        {
            let h = Ipv6Header {
                next_header: ip_number::IPV6_FRAG,
                source: [1; 16],
                destination: [2; 16],
                ..Default::default()
            };
            let header_bytes = h.to_bytes();
            let fragment = Ipv6FragmentHeader::new(ip_number::TCP, IpFragOffset::ZERO, false, 1234);
            let mut ext_bytes = Vec::new();
            ext_bytes.extend_from_slice(&fragment.to_bytes());
            let exts = Ipv6ExtensionsSlice::from_slice(ip_number::IPV6_FRAG, &ext_bytes)
                .unwrap()
                .0;

            let s = IpHeadersSlice::Ipv6(
                Ipv6HeaderSlice::from_slice(&header_bytes).unwrap(),
                exts.clone(),
            );
            assert_eq!(false, s.is_ipv4());
            assert!(s.is_ipv6());
            assert!(s.ipv4().is_none());
            assert!(s.ipv6().is_some());
            assert!(s.ipv4_exts().is_none());
            assert_eq!(s.ipv6_exts(), Some(&exts));
            assert_eq!(s.slice(), &header_bytes[..]);
            assert_eq!(s.ipv6_exts().unwrap().slice(), &ext_bytes[..]);
            assert_eq!(s.next_header(), ip_number::IPV6_FRAG);
            assert_eq!(s.payload_ip_number(), ip_number::TCP);
            assert_eq!(s.version(), 6);
            assert_eq!(s.header_len(), Ipv6Header::LEN + ext_bytes.len());
            assert_eq!(s.source_addr(), IpAddr::V6(Ipv6Addr::from([1; 16])));
            assert_eq!(s.destination_addr(), IpAddr::V6(Ipv6Addr::from([2; 16])));
        }
    }

    #[test]
    fn try_to_header() {
        // ipv4 with auth extension
        {
            let h = Ipv4Header {
                protocol: ip_number::AUTH,
                source: [1, 2, 3, 4],
                destination: [5, 6, 7, 8],
                ..Default::default()
            };
            let header_bytes = h.to_bytes();
            let auth = IpAuthHeader::new(ip_number::UDP, 7, 9, &[1, 2, 3, 4]).unwrap();
            let auth_bytes = auth.to_bytes();
            let exts = Ipv4ExtensionsSlice::from_slice(ip_number::AUTH, &auth_bytes)
                .unwrap()
                .0;
            let s = IpHeadersSlice::Ipv4(Ipv4HeaderSlice::from_slice(&header_bytes).unwrap(), exts);
            assert_eq!(
                s.try_to_header().unwrap(),
                IpHeaders::Ipv4(h, Ipv4Extensions { auth: Some(auth) })
            );
        }

        // ipv6 with fragment extension
        {
            let h = Ipv6Header {
                next_header: ip_number::IPV6_FRAG,
                source: [1; 16],
                destination: [2; 16],
                ..Default::default()
            };
            let header_bytes = h.to_bytes();
            let fragment = Ipv6FragmentHeader::new(ip_number::TCP, IpFragOffset::ZERO, false, 1234);
            let mut ext_bytes = Vec::new();
            ext_bytes.extend_from_slice(&fragment.to_bytes());
            let exts = Ipv6ExtensionsSlice::from_slice(ip_number::IPV6_FRAG, &ext_bytes)
                .unwrap()
                .0;

            let s = IpHeadersSlice::Ipv6(Ipv6HeaderSlice::from_slice(&header_bytes).unwrap(), exts);
            assert_eq!(
                s.try_to_header().unwrap(),
                IpHeaders::Ipv6(
                    h,
                    Ipv6Extensions {
                        fragment: Some(fragment),
                        ..Default::default()
                    }
                )
            );
        }

        // ipv6 parse error
        {
            let h = Ipv6Header {
                next_header: ip_number::IPV6_HOP_BY_HOP,
                ..Default::default()
            };
            let header_bytes = h.to_bytes();
            let s = IpHeadersSlice::Ipv6(
                Ipv6HeaderSlice::from_slice(&header_bytes).unwrap(),
                Ipv6ExtensionsSlice::default(),
            );
            assert!(s.try_to_header().is_err());
        }
    }
}
