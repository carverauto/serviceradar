use super::*;

/// "Catch all" error for all `from_slice` errors (supports automatic conversion from all
/// other slice errors).
///
/// This type aggregates all errors that can be caused by decoding from a slice.
///
/// This type can be used as a "catch all" type for errors caused by `from_slice` functions
/// as all errors from these functions can be converted into this type.
#[derive(Clone, Debug, Eq, PartialEq, Hash)]
pub enum FromSliceError {
    /// Error when parsing had to be aborted because of a length error (usually
    /// not enough data being available).
    Len(LenError),

    /// Error when decoding an Linux SLL header.
    LinuxSll(linux_sll::HeaderError),

    /// Error when decoding MACsec header.
    Macsec(macsec::HeaderError),

    /// Error while parsing a IP header.
    Ip(ip::HeaderError),

    /// Error while parsing a IP authentication header.
    IpAuth(ip_auth::HeaderError),

    /// Error while parsing a IPv4 header.
    Ipv4(ipv4::HeaderError),

    /// Error while parsing a IPv6 header.
    Ipv6(ipv6::HeaderError),

    /// Error while parsing a IPv6 extension header.
    Ipv6Exts(ipv6_exts::HeaderError),

    /// Error while parsing a TCP extension header.
    Tcp(tcp::HeaderError),
}

impl FromSliceError {
    pub fn len(&self) -> Option<&LenError> {
        match self {
            FromSliceError::Len(err) => Some(err),
            _ => None,
        }
    }
    pub fn linux_sll(&self) -> Option<&linux_sll::HeaderError> {
        match self {
            FromSliceError::LinuxSll(err) => Some(err),
            _ => None,
        }
    }
    pub fn macsec(&self) -> Option<&macsec::HeaderError> {
        match self {
            FromSliceError::Macsec(err) => Some(err),
            _ => None,
        }
    }
    pub fn ip(&self) -> Option<&ip::HeaderError> {
        match self {
            FromSliceError::Ip(err) => Some(err),
            _ => None,
        }
    }
    pub fn ip_auth(&self) -> Option<&ip_auth::HeaderError> {
        match self {
            FromSliceError::IpAuth(err) => Some(err),
            _ => None,
        }
    }
    pub fn ipv4(&self) -> Option<&ipv4::HeaderError> {
        match self {
            FromSliceError::Ipv4(err) => Some(err),
            _ => None,
        }
    }
    pub fn ipv6(&self) -> Option<&ipv6::HeaderError> {
        match self {
            FromSliceError::Ipv6(err) => Some(err),
            _ => None,
        }
    }
    pub fn ipv6_exts(&self) -> Option<&ipv6_exts::HeaderError> {
        match self {
            FromSliceError::Ipv6Exts(err) => Some(err),
            _ => None,
        }
    }
    pub fn tcp(&self) -> Option<&tcp::HeaderError> {
        match self {
            FromSliceError::Tcp(err) => Some(err),
            _ => None,
        }
    }
}

impl core::fmt::Display for FromSliceError {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        use FromSliceError::*;
        match self {
            Len(err) => err.fmt(f),
            LinuxSll(err) => err.fmt(f),
            Macsec(err) => err.fmt(f),
            Ip(err) => err.fmt(f),
            IpAuth(err) => err.fmt(f),
            Ipv4(err) => err.fmt(f),
            Ipv6(err) => err.fmt(f),
            Ipv6Exts(err) => err.fmt(f),
            Tcp(err) => err.fmt(f),
        }
    }
}

impl core::error::Error for FromSliceError {
    fn source(&self) -> Option<&(dyn core::error::Error + 'static)> {
        use FromSliceError::*;
        match self {
            Len(err) => Some(err),
            LinuxSll(err) => Some(err),
            Macsec(err) => Some(err),
            Ip(err) => Some(err),
            IpAuth(err) => Some(err),
            Ipv4(err) => Some(err),
            Ipv6(err) => Some(err),
            Ipv6Exts(err) => Some(err),
            Tcp(err) => Some(err),
        }
    }
}

// len error conversions

impl From<LenError> for FromSliceError {
    fn from(value: LenError) -> Self {
        FromSliceError::Len(value)
    }
}

// linux sll conversions

impl From<linux_sll::HeaderError> for FromSliceError {
    fn from(value: linux_sll::HeaderError) -> Self {
        FromSliceError::LinuxSll(value)
    }
}

impl From<linux_sll::HeaderSliceError> for FromSliceError {
    fn from(value: linux_sll::HeaderSliceError) -> Self {
        use linux_sll::HeaderSliceError::*;
        match value {
            Len(err) => FromSliceError::Len(err),
            Content(err) => FromSliceError::LinuxSll(err),
        }
    }
}

// ip error conversions

impl From<ip::HeaderError> for FromSliceError {
    fn from(value: ip::HeaderError) -> Self {
        FromSliceError::Ip(value)
    }
}

impl From<ip::HeadersError> for FromSliceError {
    fn from(value: ip::HeadersError) -> Self {
        match value {
            ip::HeadersError::Ip(err) => FromSliceError::Ip(err),
            ip::HeadersError::Ipv4Ext(err) => FromSliceError::IpAuth(err),
            ip::HeadersError::Ipv6Ext(err) => FromSliceError::Ipv6Exts(err),
        }
    }
}

impl From<ip::HeadersSliceError> for FromSliceError {
    fn from(value: ip::HeadersSliceError) -> Self {
        use ip::HeadersSliceError::*;
        match value {
            Len(err) => FromSliceError::Len(err),
            Content(err) => err.into(),
        }
    }
}

impl From<ip::SliceError> for FromSliceError {
    fn from(value: ip::SliceError) -> Self {
        use ip::SliceError::*;
        match value {
            Len(err) => FromSliceError::Len(err),
            IpHeaders(err) => err.into(),
        }
    }
}

// ip auth error conversions

impl From<ip_auth::HeaderError> for FromSliceError {
    fn from(value: ip_auth::HeaderError) -> Self {
        FromSliceError::IpAuth(value)
    }
}

impl From<ip_auth::HeaderSliceError> for FromSliceError {
    fn from(value: ip_auth::HeaderSliceError) -> Self {
        use ip_auth::HeaderSliceError::*;
        match value {
            Len(err) => FromSliceError::Len(err),
            Content(err) => FromSliceError::IpAuth(err),
        }
    }
}

// ipv4 error conversions

impl From<ipv4::HeaderError> for FromSliceError {
    fn from(value: ipv4::HeaderError) -> Self {
        FromSliceError::Ipv4(value)
    }
}

impl From<ipv4::HeaderSliceError> for FromSliceError {
    fn from(value: ipv4::HeaderSliceError) -> Self {
        use ipv4::HeaderSliceError::*;
        match value {
            Len(err) => FromSliceError::Len(err),
            Content(err) => FromSliceError::Ipv4(err),
        }
    }
}

impl From<ipv4::SliceError> for FromSliceError {
    fn from(value: ipv4::SliceError) -> Self {
        use ipv4::SliceError::*;
        match value {
            Len(err) => FromSliceError::Len(err),
            Header(err) => FromSliceError::Ipv4(err),
            Exts(err) => FromSliceError::IpAuth(err),
        }
    }
}

// ipv6 error conversions

impl From<ipv6::HeaderError> for FromSliceError {
    fn from(value: ipv6::HeaderError) -> Self {
        FromSliceError::Ipv6(value)
    }
}

impl From<ipv6::HeaderSliceError> for FromSliceError {
    fn from(value: ipv6::HeaderSliceError) -> Self {
        use ipv6::HeaderSliceError::*;
        match value {
            Len(err) => FromSliceError::Len(err),
            Content(err) => FromSliceError::Ipv6(err),
        }
    }
}

impl From<ipv6::SliceError> for FromSliceError {
    fn from(value: ipv6::SliceError) -> Self {
        use ipv6::SliceError::*;
        match value {
            Len(err) => FromSliceError::Len(err),
            Header(err) => FromSliceError::Ipv6(err),
            Exts(err) => FromSliceError::Ipv6Exts(err),
        }
    }
}

// ipv6 exts error conversions

impl From<ipv6_exts::HeaderError> for FromSliceError {
    fn from(value: ipv6_exts::HeaderError) -> Self {
        FromSliceError::Ipv6Exts(value)
    }
}

impl From<ipv6_exts::HeaderSliceError> for FromSliceError {
    fn from(value: ipv6_exts::HeaderSliceError) -> Self {
        use ipv6_exts::HeaderSliceError::*;
        match value {
            Len(err) => FromSliceError::Len(err),
            Content(err) => FromSliceError::Ipv6Exts(err),
        }
    }
}

// packet error conversions

impl From<packet::SliceError> for FromSliceError {
    fn from(value: packet::SliceError) -> Self {
        use packet::SliceError::*;
        match value {
            Len(err) => FromSliceError::Len(err),
            LinuxSll(err) => FromSliceError::LinuxSll(err),
            Macsec(err) => FromSliceError::Macsec(err),
            Ip(err) => FromSliceError::Ip(err),
            Ipv4(err) => FromSliceError::Ipv4(err),
            Ipv6(err) => FromSliceError::Ipv6(err),
            Ipv4Exts(err) => FromSliceError::IpAuth(err),
            Ipv6Exts(err) => FromSliceError::Ipv6Exts(err),
            Tcp(err) => FromSliceError::Tcp(err),
        }
    }
}

// tcp error conversions

impl From<tcp::HeaderError> for FromSliceError {
    fn from(value: tcp::HeaderError) -> Self {
        FromSliceError::Tcp(value)
    }
}

impl From<tcp::HeaderSliceError> for FromSliceError {
    fn from(value: tcp::HeaderSliceError) -> Self {
        use tcp::HeaderSliceError::*;
        match value {
            Len(err) => FromSliceError::Len(err),
            Content(err) => FromSliceError::Tcp(err),
        }
    }
}

#[cfg(test)]
mod tests {
    use crate::{ArpHardwareId, LenSource};

    use super::{FromSliceError::*, *};
    use core::error::Error;
    use core::hash::{Hash, Hasher};
    use std::collections::hash_map::DefaultHasher;
    use std::format;

    #[test]
    fn clone_eq_hash() {
        let value = Len(LenError {
            required_len: 0,
            len: 0,
            len_source: LenSource::Slice,
            layer: Layer::Icmpv4,
            layer_start_offset: 0,
        });
        assert_eq!(value, value.clone());
        let h1 = {
            let mut h = DefaultHasher::new();
            value.hash(&mut h);
            h.finish()
        };
        let h2 = {
            let mut h = DefaultHasher::new();
            value.clone().hash(&mut h);
            h.finish()
        };
        assert_eq!(h1, h2);
    }

    #[test]
    fn debug_source() {
        let test_values: [(&str, FromSliceError); 9] = [
            (
                "Len",
                Len(LenError {
                    required_len: 0,
                    len: 0,
                    len_source: LenSource::Slice,
                    layer: Layer::Icmpv4,
                    layer_start_offset: 0,
                }),
            ),
            (
                "LinuxSll",
                LinuxSll(linux_sll::HeaderError::UnsupportedArpHardwareId {
                    arp_hardware_type: ArpHardwareId(0),
                }),
            ),
            ("Macsec", Macsec(macsec::HeaderError::UnexpectedVersion)),
            (
                "Ip",
                Ip(ip::HeaderError::UnsupportedIpVersion {
                    version_number: 123,
                }),
            ),
            ("IpAuth", IpAuth(ip_auth::HeaderError::ZeroPayloadLen)),
            (
                "Ipv4",
                Ipv4(ipv4::HeaderError::UnexpectedVersion { version_number: 1 }),
            ),
            (
                "Ipv6",
                Ipv6(ipv6::HeaderError::UnexpectedVersion { version_number: 1 }),
            ),
            (
                "Ipv6Exts",
                Ipv6Exts(ipv6_exts::HeaderError::HopByHopNotAtStart),
            ),
            (
                "Tcp",
                Tcp(tcp::HeaderError::DataOffsetTooSmall { data_offset: 1 }),
            ),
        ];
        for (prefix, value) in &test_values {
            // display
            assert_eq!(
                format!("{:?}", value),
                format!("{}({:?})", prefix, value.source().unwrap())
            );
        }
    }

    #[test]
    fn display_source() {
        let test_values: [FromSliceError; 9] = [
            Len(LenError {
                required_len: 0,
                len: 0,
                len_source: LenSource::Slice,
                layer: Layer::Icmpv4,
                layer_start_offset: 0,
            }),
            LinuxSll(linux_sll::HeaderError::UnsupportedArpHardwareId {
                arp_hardware_type: ArpHardwareId::ETHERNET,
            }),
            Macsec(macsec::HeaderError::UnexpectedVersion),
            Ip(ip::HeaderError::UnsupportedIpVersion {
                version_number: 123,
            }),
            IpAuth(ip_auth::HeaderError::ZeroPayloadLen),
            Ipv4(ipv4::HeaderError::UnexpectedVersion { version_number: 1 }),
            Ipv6(ipv6::HeaderError::UnexpectedVersion { version_number: 1 }),
            Ipv6Exts(ipv6_exts::HeaderError::HopByHopNotAtStart),
            Tcp(tcp::HeaderError::DataOffsetTooSmall { data_offset: 1 }),
        ];
        for value in &test_values {
            // display
            assert_eq!(format!("{}", value), format!("{}", value.source().unwrap()));
        }
    }

    #[test]
    fn accessors() {
        use FromSliceError::*;
        let len_error = || LenError {
            required_len: 0,
            len: 0,
            len_source: LenSource::Slice,
            layer: Layer::Icmpv4,
            layer_start_offset: 0,
        };
        let linux_sll_error = || linux_sll::HeaderError::UnsupportedArpHardwareId {
            arp_hardware_type: ArpHardwareId::ETHERNET,
        };
        let macsec_error = || macsec::HeaderError::UnexpectedVersion;
        let ip_error = || ip::HeaderError::UnsupportedIpVersion { version_number: 0 };
        let ipv4_error = || ipv4::HeaderError::UnexpectedVersion { version_number: 1 };
        let ipv6_error = || ipv6::HeaderError::UnexpectedVersion { version_number: 1 };
        let ip_auth_error = || ip_auth::HeaderError::ZeroPayloadLen;
        let ipv6_exts_error = || ipv6_exts::HeaderError::HopByHopNotAtStart;
        let tcp_error = || tcp::HeaderError::DataOffsetTooSmall { data_offset: 1 };

        // len
        assert_eq!(Len(len_error()).len(), Some(&len_error()));
        assert_eq!(Ipv4(ipv4_error()).len(), None);

        // linux_sll
        assert_eq!(
            LinuxSll(linux_sll_error()).linux_sll(),
            Some(&linux_sll_error())
        );
        assert_eq!(Ipv4(ipv4_error()).linux_sll(), None);

        // macsec
        assert_eq!(Macsec(macsec_error()).macsec(), Some(&macsec_error()));
        assert_eq!(Ipv4(ipv4_error()).macsec(), None);

        // ip
        assert_eq!(Ip(ip_error()).ip(), Some(&ip_error()));
        assert_eq!(Ipv4(ipv4_error()).ip(), None);

        // ip_auth
        assert_eq!(IpAuth(ip_auth_error()).ip_auth(), Some(&ip_auth_error()));
        assert_eq!(Ipv4(ipv4_error()).ip_auth(), None);

        // ipv4
        assert_eq!(Ipv4(ipv4_error()).ipv4(), Some(&ipv4_error()));
        assert_eq!(IpAuth(ip_auth_error()).ipv4(), None);

        // ipv6
        assert_eq!(Ipv6(ipv6_error()).ipv6(), Some(&ipv6_error()));
        assert_eq!(IpAuth(ip_auth_error()).ipv6(), None);

        // ipv6_exts
        assert_eq!(
            Ipv6Exts(ipv6_exts_error()).ipv6_exts(),
            Some(&ipv6_exts_error())
        );
        assert_eq!(IpAuth(ip_auth_error()).ipv6_exts(), None);

        // tcp
        assert_eq!(Tcp(tcp_error()).tcp(), Some(&tcp_error()));
        assert_eq!(IpAuth(ip_auth_error()).tcp(), None);
    }

    #[test]
    fn from() {
        let len_error = || -> LenError {
            LenError {
                required_len: 0,
                len: 0,
                len_source: LenSource::Slice,
                layer: Layer::Icmpv4,
                layer_start_offset: 0,
            }
        };

        // len
        assert_eq!(
            &len_error(),
            FromSliceError::from(len_error()).len().unwrap()
        );

        // linux sll
        {
            let header_error = || linux_sll::HeaderError::UnsupportedArpHardwareId {
                arp_hardware_type: ArpHardwareId::ETHERNET,
            };
            assert_eq!(
                &header_error(),
                FromSliceError::from(header_error()).linux_sll().unwrap()
            );
            assert_eq!(
                &header_error(),
                FromSliceError::from(linux_sll::HeaderSliceError::Content(header_error()))
                    .linux_sll()
                    .unwrap()
            );
            assert_eq!(
                &len_error(),
                FromSliceError::from(linux_sll::HeaderSliceError::Len(len_error()))
                    .len()
                    .unwrap()
            );
            assert_eq!(
                &header_error(),
                FromSliceError::from(linux_sll::HeaderSliceError::Content(header_error()))
                    .linux_sll()
                    .unwrap()
            );
        }

        // ip errors
        {
            let header_error = || ip::HeaderError::UnsupportedIpVersion {
                version_number: 123,
            };

            let ip_auth_error = || ip_auth::HeaderError::ZeroPayloadLen;
            let ipv6_ext_header_error = || ipv6_exts::HeaderError::HopByHopNotAtStart;

            assert_eq!(
                &header_error(),
                FromSliceError::from(header_error()).ip().unwrap()
            );
            assert_eq!(
                &header_error(),
                FromSliceError::from(ip::HeadersSliceError::Content(ip::HeadersError::Ip(
                    header_error()
                )))
                .ip()
                .unwrap()
            );
            assert_eq!(
                &ip_auth_error(),
                FromSliceError::from(ip::HeadersSliceError::Content(ip::HeadersError::Ipv4Ext(
                    ip_auth_error()
                )))
                .ip_auth()
                .unwrap()
            );
            assert_eq!(
                &ipv6_ext_header_error(),
                FromSliceError::from(ip::HeadersSliceError::Content(ip::HeadersError::Ipv6Ext(
                    ipv6_ext_header_error()
                )))
                .ipv6_exts()
                .unwrap()
            );
            assert_eq!(
                &len_error(),
                FromSliceError::from(ip::HeadersSliceError::Len(len_error()))
                    .len()
                    .unwrap()
            );
            assert_eq!(
                &len_error(),
                FromSliceError::from(ip::SliceError::Len(len_error()))
                    .len()
                    .unwrap()
            );
            assert_eq!(
                &header_error(),
                FromSliceError::from(ip::SliceError::IpHeaders(ip::HeadersError::Ip(
                    header_error()
                )))
                .ip()
                .unwrap()
            );
        }

        // ip auth errors
        {
            let header_error = || ip_auth::HeaderError::ZeroPayloadLen;
            assert_eq!(
                &header_error(),
                FromSliceError::from(header_error()).ip_auth().unwrap()
            );
            assert_eq!(
                &header_error(),
                FromSliceError::from(ip_auth::HeaderSliceError::Content(header_error()))
                    .ip_auth()
                    .unwrap()
            );
            assert_eq!(
                &len_error(),
                FromSliceError::from(ip_auth::HeaderSliceError::Len(len_error()))
                    .len()
                    .unwrap()
            );
            assert_eq!(
                &header_error(),
                FromSliceError::from(ip_auth::HeaderSliceError::Content(header_error()))
                    .ip_auth()
                    .unwrap()
            );
        }

        // ipv4 errors
        {
            let header_error = || ipv4::HeaderError::UnexpectedVersion {
                version_number: 123,
            };
            let exts_error = || ip_auth::HeaderError::ZeroPayloadLen;
            assert_eq!(
                &header_error(),
                FromSliceError::from(header_error()).ipv4().unwrap()
            );
            assert_eq!(
                &header_error(),
                FromSliceError::from(ipv4::HeaderSliceError::Content(header_error()))
                    .ipv4()
                    .unwrap()
            );
            assert_eq!(
                &len_error(),
                FromSliceError::from(ipv4::HeaderSliceError::Len(len_error()))
                    .len()
                    .unwrap()
            );
            assert_eq!(
                &header_error(),
                FromSliceError::from(ipv4::HeaderSliceError::Content(header_error()))
                    .ipv4()
                    .unwrap()
            );
            assert_eq!(
                &len_error(),
                FromSliceError::from(ipv4::SliceError::Len(len_error()))
                    .len()
                    .unwrap()
            );
            assert_eq!(
                &header_error(),
                FromSliceError::from(ipv4::SliceError::Header(header_error()))
                    .ipv4()
                    .unwrap()
            );
            assert_eq!(
                &exts_error(),
                FromSliceError::from(ipv4::SliceError::Exts(exts_error()))
                    .ip_auth()
                    .unwrap()
            );
        }

        // ipv6 errors
        {
            let header_error = || ipv6::HeaderError::UnexpectedVersion {
                version_number: 123,
            };
            let exts_error = || ipv6_exts::HeaderError::HopByHopNotAtStart;
            assert_eq!(
                &header_error(),
                FromSliceError::from(header_error()).ipv6().unwrap()
            );
            assert_eq!(
                &header_error(),
                FromSliceError::from(ipv6::HeaderSliceError::Content(header_error()))
                    .ipv6()
                    .unwrap()
            );
            assert_eq!(
                &len_error(),
                FromSliceError::from(ipv6::HeaderSliceError::Len(len_error()))
                    .len()
                    .unwrap()
            );
            assert_eq!(
                &header_error(),
                FromSliceError::from(ipv6::HeaderSliceError::Content(header_error()))
                    .ipv6()
                    .unwrap()
            );
            assert_eq!(
                &len_error(),
                FromSliceError::from(ipv6::SliceError::Len(len_error()))
                    .len()
                    .unwrap()
            );
            assert_eq!(
                &header_error(),
                FromSliceError::from(ipv6::SliceError::Header(header_error()))
                    .ipv6()
                    .unwrap()
            );
            assert_eq!(
                &exts_error(),
                FromSliceError::from(ipv6::SliceError::Exts(exts_error()))
                    .ipv6_exts()
                    .unwrap()
            );
        }

        // ipv6 exts errors
        {
            let header_error = || ipv6_exts::HeaderError::HopByHopNotAtStart;
            assert_eq!(
                &header_error(),
                FromSliceError::from(header_error()).ipv6_exts().unwrap()
            );
            assert_eq!(
                &header_error(),
                FromSliceError::from(ipv6_exts::HeaderSliceError::Content(header_error()))
                    .ipv6_exts()
                    .unwrap()
            );
            assert_eq!(
                &len_error(),
                FromSliceError::from(ipv6_exts::HeaderSliceError::Len(len_error()))
                    .len()
                    .unwrap()
            );
            assert_eq!(
                &header_error(),
                FromSliceError::from(ipv6_exts::HeaderSliceError::Content(header_error()))
                    .ipv6_exts()
                    .unwrap()
            );
        }

        // packet error
        {
            let linux_sll_error = || linux_sll::HeaderError::UnsupportedArpHardwareId {
                arp_hardware_type: ArpHardwareId(0),
            };
            let macsec_error = || macsec::HeaderError::UnexpectedVersion;
            let ip_error = || ip::HeaderError::UnsupportedIpVersion { version_number: 0 };
            let ipv4_error = || ipv4::HeaderError::UnexpectedVersion { version_number: 1 };
            let ipv6_error = || ipv6::HeaderError::UnexpectedVersion { version_number: 1 };
            let ip_auth_error = || ip_auth::HeaderError::ZeroPayloadLen;
            let ipv6_exts_error = || ipv6_exts::HeaderError::HopByHopNotAtStart;
            let tcp_error = || tcp::HeaderError::DataOffsetTooSmall { data_offset: 1 };

            // SliceError
            assert_eq!(
                &len_error(),
                FromSliceError::from(packet::SliceError::Len(len_error()))
                    .len()
                    .unwrap()
            );
            assert_eq!(
                &linux_sll_error(),
                FromSliceError::from(packet::SliceError::LinuxSll(linux_sll_error()))
                    .linux_sll()
                    .unwrap()
            );
            assert_eq!(
                &macsec_error(),
                FromSliceError::from(packet::SliceError::Macsec(macsec_error()))
                    .macsec()
                    .unwrap()
            );
            assert_eq!(
                &ip_error(),
                FromSliceError::from(packet::SliceError::Ip(ip_error()))
                    .ip()
                    .unwrap()
            );
            assert_eq!(
                &ipv4_error(),
                FromSliceError::from(packet::SliceError::Ipv4(ipv4_error()))
                    .ipv4()
                    .unwrap()
            );
            assert_eq!(
                &ipv6_error(),
                FromSliceError::from(packet::SliceError::Ipv6(ipv6_error()))
                    .ipv6()
                    .unwrap()
            );
            assert_eq!(
                &ip_auth_error(),
                FromSliceError::from(packet::SliceError::Ipv4Exts(ip_auth_error()))
                    .ip_auth()
                    .unwrap()
            );
            assert_eq!(
                &ipv6_exts_error(),
                FromSliceError::from(packet::SliceError::Ipv6Exts(ipv6_exts_error()))
                    .ipv6_exts()
                    .unwrap()
            );
            assert_eq!(
                &tcp_error(),
                FromSliceError::from(packet::SliceError::Tcp(tcp_error()))
                    .tcp()
                    .unwrap()
            );
        }

        // tcp errors
        {
            let header_error = || tcp::HeaderError::DataOffsetTooSmall { data_offset: 1 };
            assert_eq!(
                &header_error(),
                FromSliceError::from(header_error()).tcp().unwrap()
            );
            assert_eq!(
                &header_error(),
                FromSliceError::from(tcp::HeaderSliceError::Content(header_error()))
                    .tcp()
                    .unwrap()
            );
            assert_eq!(
                &len_error(),
                FromSliceError::from(tcp::HeaderSliceError::Len(len_error()))
                    .len()
                    .unwrap()
            );
            assert_eq!(
                &header_error(),
                FromSliceError::from(tcp::HeaderSliceError::Content(header_error()))
                    .tcp()
                    .unwrap()
            );
        }
    }
} // mod tests
