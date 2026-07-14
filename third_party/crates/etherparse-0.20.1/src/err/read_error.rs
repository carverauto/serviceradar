use crate::err::*;

/// "Catch all" error for all `from_slice` or `read` errors (supports automatic conversion from all
/// other slice errors).
///
/// This type aggregates all errors that can be caused by decoding from a slice or reading
/// from an io stream.
///
/// This type can be used as a "catch all" type for errors caused by `from_slice` or
/// `read` functions as all errors from these functions can be converted into this type.
#[derive(Debug)]
#[cfg_attr(docsrs, doc(cfg(feature = "std")))]
pub enum ReadError {
    /// IO error was encountered while reading header or expected packet contents.
    Io(std::io::Error),

    /// Error when parsing had to be aborted because of a length error (usually
    /// not enough data being available).
    Len(LenError),

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

    /// Error while parsing a Linux Cooked Capture v1 (SLL)
    LinuxSll(linux_sll::HeaderError),

    /// Error while parsing a TCP extension header.
    Tcp(tcp::HeaderError),
}

#[cfg_attr(docsrs, doc(cfg(feature = "std")))]
impl ReadError {
    pub fn io(&self) -> Option<&std::io::Error> {
        match self {
            ReadError::Io(err) => Some(err),
            _ => None,
        }
    }
    pub fn len(&self) -> Option<&LenError> {
        match self {
            ReadError::Len(err) => Some(err),
            _ => None,
        }
    }
    pub fn macsec(&self) -> Option<&macsec::HeaderError> {
        match self {
            ReadError::Macsec(err) => Some(err),
            _ => None,
        }
    }
    pub fn ip(&self) -> Option<&ip::HeaderError> {
        match self {
            ReadError::Ip(err) => Some(err),
            _ => None,
        }
    }
    pub fn ip_auth(&self) -> Option<&ip_auth::HeaderError> {
        match self {
            ReadError::IpAuth(err) => Some(err),
            _ => None,
        }
    }
    pub fn ipv4(&self) -> Option<&ipv4::HeaderError> {
        match self {
            ReadError::Ipv4(err) => Some(err),
            _ => None,
        }
    }
    pub fn ipv6(&self) -> Option<&ipv6::HeaderError> {
        match self {
            ReadError::Ipv6(err) => Some(err),
            _ => None,
        }
    }
    pub fn ipv6_exts(&self) -> Option<&ipv6_exts::HeaderError> {
        match self {
            ReadError::Ipv6Exts(err) => Some(err),
            _ => None,
        }
    }
    pub fn linux_sll(&self) -> Option<&linux_sll::HeaderError> {
        match self {
            ReadError::LinuxSll(err) => Some(err),
            _ => None,
        }
    }
    pub fn tcp(&self) -> Option<&tcp::HeaderError> {
        match self {
            ReadError::Tcp(err) => Some(err),
            _ => None,
        }
    }
}

impl core::fmt::Display for ReadError {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        use crate::err::ReadError::*;
        match self {
            Io(err) => err.fmt(f),
            Len(err) => err.fmt(f),
            Macsec(err) => err.fmt(f),
            Ip(err) => err.fmt(f),
            IpAuth(err) => err.fmt(f),
            Ipv4(err) => err.fmt(f),
            Ipv6(err) => err.fmt(f),
            Ipv6Exts(err) => err.fmt(f),
            LinuxSll(err) => err.fmt(f),
            Tcp(err) => err.fmt(f),
        }
    }
}

impl core::error::Error for ReadError {
    fn source(&self) -> Option<&(dyn core::error::Error + 'static)> {
        use ReadError::*;
        match self {
            Io(err) => Some(err),
            Len(err) => Some(err),
            Macsec(err) => Some(err),
            Ip(err) => Some(err),
            IpAuth(err) => Some(err),
            Ipv4(err) => Some(err),
            Ipv6(err) => Some(err),
            Ipv6Exts(err) => Some(err),
            LinuxSll(err) => Some(err),
            Tcp(err) => Some(err),
        }
    }
}

// io & len error conversions
#[cfg_attr(docsrs, doc(cfg(feature = "std")))]
impl From<std::io::Error> for ReadError {
    fn from(value: std::io::Error) -> Self {
        ReadError::Io(value)
    }
}

#[cfg_attr(docsrs, doc(cfg(feature = "std")))]
impl From<LenError> for ReadError {
    fn from(value: LenError) -> Self {
        ReadError::Len(value)
    }
}

// ip error conversions
#[cfg_attr(docsrs, doc(cfg(feature = "std")))]
impl From<ip::HeaderError> for ReadError {
    fn from(value: ip::HeaderError) -> Self {
        ReadError::Ip(value)
    }
}

#[cfg_attr(docsrs, doc(cfg(feature = "std")))]
impl From<ip::HeadersError> for ReadError {
    fn from(value: ip::HeadersError) -> Self {
        match value {
            ip::HeadersError::Ip(err) => ReadError::Ip(err),
            ip::HeadersError::Ipv4Ext(err) => ReadError::IpAuth(err),
            ip::HeadersError::Ipv6Ext(err) => ReadError::Ipv6Exts(err),
        }
    }
}

#[cfg_attr(docsrs, doc(cfg(feature = "std")))]
impl From<ip::HeaderReadError> for ReadError {
    fn from(value: ip::HeaderReadError) -> Self {
        use ip::HeaderReadError::*;
        match value {
            Io(err) => ReadError::Io(err),
            Len(err) => ReadError::Len(err),
            Content(err) => err.into(),
        }
    }
}

#[cfg_attr(docsrs, doc(cfg(feature = "std")))]
impl From<ip::HeadersSliceError> for ReadError {
    fn from(value: ip::HeadersSliceError) -> Self {
        use ip::HeadersSliceError::*;
        match value {
            Len(err) => ReadError::Len(err),
            Content(err) => err.into(),
        }
    }
}

#[cfg_attr(docsrs, doc(cfg(feature = "std")))]
impl From<ip::SliceError> for ReadError {
    fn from(value: ip::SliceError) -> Self {
        use ip::SliceError::*;
        match value {
            Len(err) => ReadError::Len(err),
            IpHeaders(err) => err.into(),
        }
    }
}

// ip auth error conversions
#[cfg_attr(docsrs, doc(cfg(feature = "std")))]
impl From<ip_auth::HeaderError> for ReadError {
    fn from(value: ip_auth::HeaderError) -> Self {
        ReadError::IpAuth(value)
    }
}

#[cfg_attr(docsrs, doc(cfg(feature = "std")))]
impl From<ip_auth::HeaderReadError> for ReadError {
    fn from(value: ip_auth::HeaderReadError) -> Self {
        use ip_auth::HeaderReadError::*;
        match value {
            Io(err) => ReadError::Io(err),
            Content(err) => ReadError::IpAuth(err),
        }
    }
}

#[cfg_attr(docsrs, doc(cfg(feature = "std")))]
impl From<ip_auth::HeaderSliceError> for ReadError {
    fn from(value: ip_auth::HeaderSliceError) -> Self {
        use ip_auth::HeaderSliceError::*;
        match value {
            Len(err) => ReadError::Len(err),
            Content(err) => ReadError::IpAuth(err),
        }
    }
}

// ipv4 error conversions
#[cfg_attr(docsrs, doc(cfg(feature = "std")))]
impl From<ipv4::HeaderError> for ReadError {
    fn from(value: ipv4::HeaderError) -> Self {
        ReadError::Ipv4(value)
    }
}

#[cfg_attr(docsrs, doc(cfg(feature = "std")))]
impl From<ipv4::HeaderReadError> for ReadError {
    fn from(value: ipv4::HeaderReadError) -> Self {
        use ipv4::HeaderReadError::*;
        match value {
            Io(err) => ReadError::Io(err),
            Content(err) => ReadError::Ipv4(err),
        }
    }
}

#[cfg_attr(docsrs, doc(cfg(feature = "std")))]
impl From<ipv4::HeaderSliceError> for ReadError {
    fn from(value: ipv4::HeaderSliceError) -> Self {
        use ipv4::HeaderSliceError::*;
        match value {
            Len(err) => ReadError::Len(err),
            Content(err) => ReadError::Ipv4(err),
        }
    }
}

#[cfg_attr(docsrs, doc(cfg(feature = "std")))]
impl From<ipv4::SliceError> for ReadError {
    fn from(value: ipv4::SliceError) -> Self {
        use ipv4::SliceError::*;
        match value {
            Len(err) => ReadError::Len(err),
            Header(err) => ReadError::Ipv4(err),
            Exts(err) => ReadError::IpAuth(err),
        }
    }
}

// ipv6 error conversions
#[cfg_attr(docsrs, doc(cfg(feature = "std")))]
impl From<ipv6::HeaderError> for ReadError {
    fn from(value: ipv6::HeaderError) -> Self {
        ReadError::Ipv6(value)
    }
}

#[cfg_attr(docsrs, doc(cfg(feature = "std")))]
impl From<ipv6::HeaderReadError> for ReadError {
    fn from(value: ipv6::HeaderReadError) -> Self {
        use ipv6::HeaderReadError::*;
        match value {
            Io(err) => ReadError::Io(err),
            Content(err) => ReadError::Ipv6(err),
        }
    }
}

#[cfg_attr(docsrs, doc(cfg(feature = "std")))]
impl From<ipv6::HeaderSliceError> for ReadError {
    fn from(value: ipv6::HeaderSliceError) -> Self {
        use ipv6::HeaderSliceError::*;
        match value {
            Len(err) => ReadError::Len(err),
            Content(err) => ReadError::Ipv6(err),
        }
    }
}

#[cfg_attr(docsrs, doc(cfg(feature = "std")))]
impl From<ipv6::SliceError> for ReadError {
    fn from(value: ipv6::SliceError) -> Self {
        use ipv6::SliceError::*;
        match value {
            Len(err) => ReadError::Len(err),
            Header(err) => ReadError::Ipv6(err),
            Exts(err) => ReadError::Ipv6Exts(err),
        }
    }
}

// ipv6 exts error conversions
#[cfg_attr(docsrs, doc(cfg(feature = "std")))]
impl From<ipv6_exts::HeaderError> for ReadError {
    fn from(value: ipv6_exts::HeaderError) -> Self {
        ReadError::Ipv6Exts(value)
    }
}

#[cfg_attr(docsrs, doc(cfg(feature = "std")))]
impl From<ipv6_exts::HeaderReadError> for ReadError {
    fn from(value: ipv6_exts::HeaderReadError) -> Self {
        use ipv6_exts::HeaderReadError::*;
        match value {
            Io(err) => ReadError::Io(err),
            Content(err) => ReadError::Ipv6Exts(err),
        }
    }
}

#[cfg_attr(docsrs, doc(cfg(feature = "std")))]
impl From<ipv6_exts::HeaderSliceError> for ReadError {
    fn from(value: ipv6_exts::HeaderSliceError) -> Self {
        use ipv6_exts::HeaderSliceError::*;
        match value {
            Len(err) => ReadError::Len(err),
            Content(err) => ReadError::Ipv6Exts(err),
        }
    }
}

// linux sll error conversions
#[cfg_attr(docsrs, doc(cfg(feature = "std")))]
impl From<linux_sll::HeaderError> for ReadError {
    fn from(value: linux_sll::HeaderError) -> Self {
        ReadError::LinuxSll(value)
    }
}

#[cfg_attr(docsrs, doc(cfg(feature = "std")))]
impl From<linux_sll::HeaderReadError> for ReadError {
    fn from(value: linux_sll::HeaderReadError) -> Self {
        use linux_sll::HeaderReadError::*;
        match value {
            Io(err) => ReadError::Io(err),
            Content(err) => ReadError::LinuxSll(err),
        }
    }
}

#[cfg_attr(docsrs, doc(cfg(feature = "std")))]
impl From<linux_sll::HeaderSliceError> for ReadError {
    fn from(value: linux_sll::HeaderSliceError) -> Self {
        use linux_sll::HeaderSliceError::*;
        match value {
            Len(err) => ReadError::Len(err),
            Content(err) => ReadError::LinuxSll(err),
        }
    }
}

// macsec error conversions
#[cfg_attr(docsrs, doc(cfg(feature = "std")))]
impl From<macsec::HeaderError> for ReadError {
    fn from(value: macsec::HeaderError) -> Self {
        ReadError::Macsec(value)
    }
}

#[cfg_attr(docsrs, doc(cfg(feature = "std")))]
impl From<macsec::HeaderReadError> for ReadError {
    fn from(value: macsec::HeaderReadError) -> Self {
        use macsec::HeaderReadError::*;
        match value {
            Io(err) => ReadError::Io(err),
            Content(err) => ReadError::Macsec(err),
        }
    }
}

#[cfg_attr(docsrs, doc(cfg(feature = "std")))]
impl From<macsec::HeaderSliceError> for ReadError {
    fn from(value: macsec::HeaderSliceError) -> Self {
        use macsec::HeaderSliceError::*;
        match value {
            Len(err) => ReadError::Len(err),
            Content(err) => ReadError::Macsec(err),
        }
    }
}

// packet error conversions
#[cfg_attr(docsrs, doc(cfg(feature = "std")))]
impl From<packet::SliceError> for ReadError {
    fn from(value: packet::SliceError) -> Self {
        use packet::SliceError::*;
        match value {
            Len(err) => ReadError::Len(err),
            LinuxSll(err) => ReadError::LinuxSll(err),
            Macsec(err) => ReadError::Macsec(err),
            Ip(err) => ReadError::Ip(err),
            Ipv4(err) => ReadError::Ipv4(err),
            Ipv6(err) => ReadError::Ipv6(err),
            Ipv4Exts(err) => ReadError::IpAuth(err),
            Ipv6Exts(err) => ReadError::Ipv6Exts(err),
            Tcp(err) => ReadError::Tcp(err),
        }
    }
}

// tcp error conversions
#[cfg_attr(docsrs, doc(cfg(feature = "std")))]
impl From<tcp::HeaderError> for ReadError {
    fn from(value: tcp::HeaderError) -> Self {
        ReadError::Tcp(value)
    }
}

#[cfg_attr(docsrs, doc(cfg(feature = "std")))]
impl From<tcp::HeaderReadError> for ReadError {
    fn from(value: tcp::HeaderReadError) -> Self {
        use tcp::HeaderReadError::*;
        match value {
            Io(err) => ReadError::Io(err),
            Content(err) => ReadError::Tcp(err),
        }
    }
}

#[cfg_attr(docsrs, doc(cfg(feature = "std")))]
impl From<tcp::HeaderSliceError> for ReadError {
    fn from(value: tcp::HeaderSliceError) -> Self {
        use tcp::HeaderSliceError::*;
        match value {
            Len(err) => ReadError::Len(err),
            Content(err) => ReadError::Tcp(err),
        }
    }
}

#[cfg(test)]
mod tests {
    use crate::ArpHardwareId;
    use crate::{
        err::{ReadError::*, *},
        LenSource,
    };
    use core::error::Error;
    use std::format;

    #[test]
    fn debug_source() {
        let test_values: [(&str, ReadError); 10] = [
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
                    arp_hardware_type: ArpHardwareId::ETHERNET,
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
                "LinuxSll",
                LinuxSll(linux_sll::HeaderError::UnsupportedPacketTypeField { packet_type: 123 }),
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
        // io handled separately as source points to the underlying type
        {
            let io_error = || std::io::Error::new(std::io::ErrorKind::Other, "some error");
            assert_eq!(
                format!("Io({:?})", io_error()),
                format!("{:?}", Io(io_error()))
            );
        }
    }

    #[test]
    fn display_source() {
        let test_values: [ReadError; 10] = [
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
            LinuxSll(linux_sll::HeaderError::UnsupportedPacketTypeField { packet_type: 123 }),
            Tcp(tcp::HeaderError::DataOffsetTooSmall { data_offset: 1 }),
        ];
        for value in &test_values {
            // display
            assert_eq!(format!("{}", value), format!("{}", value.source().unwrap()));
        }
        // io handled separately as source points to the underlying type
        {
            let io_error = || std::io::Error::new(std::io::ErrorKind::Other, "some error");
            assert_eq!(format!("{}", io_error()), format!("{}", Io(io_error())));
            assert!(Io(io_error()).source().is_some());
        }
    }

    #[test]
    fn accessors() {
        use ReadError::*;
        let io_error = || std::io::Error::new(std::io::ErrorKind::Other, "some error");
        let len_error = || LenError {
            required_len: 0,
            len: 0,
            len_source: LenSource::Slice,
            layer: Layer::Icmpv4,
            layer_start_offset: 0,
        };
        let macsec_error = || macsec::HeaderError::UnexpectedVersion;
        let ip_error = || ip::HeaderError::UnsupportedIpVersion { version_number: 0 };
        let ipv4_error = || ipv4::HeaderError::UnexpectedVersion { version_number: 1 };
        let ipv6_error = || ipv6::HeaderError::UnexpectedVersion { version_number: 1 };
        let ip_auth_error = || ip_auth::HeaderError::ZeroPayloadLen;
        let ipv6_exts_error = || ipv6_exts::HeaderError::HopByHopNotAtStart;
        let linux_sll_error =
            || linux_sll::HeaderError::UnsupportedPacketTypeField { packet_type: 123 };
        let tcp_error = || tcp::HeaderError::DataOffsetTooSmall { data_offset: 1 };

        // io
        assert!(Io(io_error()).io().is_some());
        assert!(Ipv4(ipv4_error()).io().is_none());

        // len
        assert_eq!(Len(len_error()).len(), Some(&len_error()));
        assert_eq!(Ipv4(ipv4_error()).len(), None);

        // linux sll
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

        // linux_sll
        assert_eq!(
            LinuxSll(linux_sll_error()).linux_sll(),
            Some(&linux_sll_error())
        );
        assert_eq!(IpAuth(ip_auth_error()).linux_sll(), None);

        // tcp
        assert_eq!(Tcp(tcp_error()).tcp(), Some(&tcp_error()));
        assert_eq!(IpAuth(ip_auth_error()).tcp(), None);
    }

    #[test]
    fn from() {
        let io_error =
            || -> std::io::Error { std::io::Error::new(std::io::ErrorKind::Other, "some error") };
        let len_error = || -> LenError {
            LenError {
                required_len: 0,
                len: 0,
                len_source: LenSource::Slice,
                layer: Layer::Icmpv4,
                layer_start_offset: 0,
            }
        };

        // io & len
        assert!(ReadError::from(io_error()).io().is_some());
        assert_eq!(&len_error(), ReadError::from(len_error()).len().unwrap());

        // linux sll
        {
            let header_error = || linux_sll::HeaderError::UnsupportedArpHardwareId {
                arp_hardware_type: ArpHardwareId::ETHERNET,
            };
            assert_eq!(
                &header_error(),
                ReadError::from(header_error()).linux_sll().unwrap()
            );
            assert_eq!(
                &header_error(),
                ReadError::from(linux_sll::HeaderReadError::Content(header_error()))
                    .linux_sll()
                    .unwrap()
            );
            assert!(ReadError::from(linux_sll::HeaderReadError::Io(io_error()))
                .io()
                .is_some());
            assert_eq!(
                &header_error(),
                ReadError::from(linux_sll::HeaderSliceError::Content(header_error()))
                    .linux_sll()
                    .unwrap()
            );
            assert_eq!(
                &len_error(),
                ReadError::from(linux_sll::HeaderSliceError::Len(len_error()))
                    .len()
                    .unwrap()
            );
            assert_eq!(
                &header_error(),
                ReadError::from(linux_sll::HeaderSliceError::Content(header_error()))
                    .linux_sll()
                    .unwrap()
            );
        }

        // linux_sll errors
        {
            let header_error =
                || linux_sll::HeaderError::UnsupportedPacketTypeField { packet_type: 123 };
            assert_eq!(
                &header_error(),
                ReadError::from(header_error()).linux_sll().unwrap()
            );
            assert_eq!(
                &header_error(),
                ReadError::from(linux_sll::HeaderReadError::Content(header_error()))
                    .linux_sll()
                    .unwrap()
            );
            assert!(ReadError::from(linux_sll::HeaderReadError::Io(io_error()))
                .io()
                .is_some());
            assert_eq!(
                &header_error(),
                ReadError::from(linux_sll::HeaderSliceError::Content(header_error()))
                    .linux_sll()
                    .unwrap()
            );
            assert_eq!(
                &len_error(),
                ReadError::from(linux_sll::HeaderSliceError::Len(len_error()))
                    .len()
                    .unwrap()
            );
            assert_eq!(
                &header_error(),
                ReadError::from(linux_sll::HeaderSliceError::Content(header_error()))
                    .linux_sll()
                    .unwrap()
            );
        }

        // macsec errors
        {
            let header_error = || macsec::HeaderError::UnexpectedVersion;
            assert_eq!(
                &header_error(),
                ReadError::from(header_error()).macsec().unwrap()
            );
            assert_eq!(
                &header_error(),
                ReadError::from(macsec::HeaderReadError::Content(header_error()))
                    .macsec()
                    .unwrap()
            );
            assert!(ReadError::from(macsec::HeaderReadError::Io(io_error()))
                .io()
                .is_some());
            assert_eq!(
                &header_error(),
                ReadError::from(macsec::HeaderSliceError::Content(header_error()))
                    .macsec()
                    .unwrap()
            );
            assert_eq!(
                &len_error(),
                ReadError::from(macsec::HeaderSliceError::Len(len_error()))
                    .len()
                    .unwrap()
            );
            assert_eq!(
                &header_error(),
                ReadError::from(macsec::HeaderSliceError::Content(header_error()))
                    .macsec()
                    .unwrap()
            );
        }

        // ip errors
        {
            let header_error = || ip::HeaderError::UnsupportedIpVersion {
                version_number: 123,
            };
            let ip_auth_error = || ip_auth::HeaderError::ZeroPayloadLen;
            let ipv6_ext_error = || ipv6_exts::HeaderError::HopByHopNotAtStart;

            assert_eq!(
                &header_error(),
                ReadError::from(header_error()).ip().unwrap()
            );
            assert_eq!(
                &header_error(),
                ReadError::from(ip::HeaderReadError::Content(ip::HeadersError::Ip(
                    header_error()
                )))
                .ip()
                .unwrap()
            );
            assert_eq!(
                &ip_auth_error(),
                ReadError::from(ip::HeaderReadError::Content(ip::HeadersError::Ipv4Ext(
                    ip_auth_error()
                )))
                .ip_auth()
                .unwrap()
            );
            assert_eq!(
                &ipv6_ext_error(),
                ReadError::from(ip::HeaderReadError::Content(ip::HeadersError::Ipv6Ext(
                    ipv6_ext_error()
                )))
                .ipv6_exts()
                .unwrap()
            );
            assert_eq!(
                &len_error(),
                ReadError::from(ip::HeaderReadError::Len(len_error()))
                    .len()
                    .unwrap()
            );
            assert!(ReadError::from(ip::HeaderReadError::Io(io_error()))
                .io()
                .is_some());
            assert_eq!(
                &header_error(),
                ReadError::from(ip::HeadersSliceError::Content(ip::HeadersError::Ip(
                    header_error()
                )))
                .ip()
                .unwrap()
            );
            assert_eq!(
                &len_error(),
                ReadError::from(ip::HeadersSliceError::Len(len_error()))
                    .len()
                    .unwrap()
            );
            assert_eq!(
                &header_error(),
                ReadError::from(ip::HeadersSliceError::Content(ip::HeadersError::Ip(
                    header_error()
                )))
                .ip()
                .unwrap()
            );
            assert_eq!(
                &len_error(),
                ReadError::from(ip::SliceError::Len(len_error()))
                    .len()
                    .unwrap()
            );
            assert_eq!(
                &header_error(),
                ReadError::from(ip::SliceError::IpHeaders(ip::HeadersError::Ip(
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
                ReadError::from(header_error()).ip_auth().unwrap()
            );
            assert_eq!(
                &header_error(),
                ReadError::from(ip_auth::HeaderReadError::Content(header_error()))
                    .ip_auth()
                    .unwrap()
            );
            assert!(ReadError::from(ip_auth::HeaderReadError::Io(io_error()))
                .io()
                .is_some());
            assert_eq!(
                &header_error(),
                ReadError::from(ip_auth::HeaderSliceError::Content(header_error()))
                    .ip_auth()
                    .unwrap()
            );
            assert_eq!(
                &len_error(),
                ReadError::from(ip_auth::HeaderSliceError::Len(len_error()))
                    .len()
                    .unwrap()
            );
            assert_eq!(
                &header_error(),
                ReadError::from(ip_auth::HeaderSliceError::Content(header_error()))
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
                ReadError::from(header_error()).ipv4().unwrap()
            );
            assert_eq!(
                &header_error(),
                ReadError::from(ipv4::HeaderReadError::Content(header_error()))
                    .ipv4()
                    .unwrap()
            );
            assert!(ReadError::from(ipv4::HeaderReadError::Io(io_error()))
                .io()
                .is_some());
            assert_eq!(
                &header_error(),
                ReadError::from(ipv4::HeaderSliceError::Content(header_error()))
                    .ipv4()
                    .unwrap()
            );
            assert_eq!(
                &len_error(),
                ReadError::from(ipv4::HeaderSliceError::Len(len_error()))
                    .len()
                    .unwrap()
            );
            assert_eq!(
                &header_error(),
                ReadError::from(ipv4::HeaderSliceError::Content(header_error()))
                    .ipv4()
                    .unwrap()
            );
            assert_eq!(
                &len_error(),
                ReadError::from(ipv4::SliceError::Len(len_error()))
                    .len()
                    .unwrap()
            );
            assert_eq!(
                &header_error(),
                ReadError::from(ipv4::SliceError::Header(header_error()))
                    .ipv4()
                    .unwrap()
            );
            assert_eq!(
                &exts_error(),
                ReadError::from(ipv4::SliceError::Exts(exts_error()))
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
                ReadError::from(header_error()).ipv6().unwrap()
            );
            assert_eq!(
                &header_error(),
                ReadError::from(ipv6::HeaderReadError::Content(header_error()))
                    .ipv6()
                    .unwrap()
            );
            assert!(ReadError::from(ipv6::HeaderReadError::Io(io_error()))
                .io()
                .is_some());
            assert_eq!(
                &header_error(),
                ReadError::from(ipv6::HeaderSliceError::Content(header_error()))
                    .ipv6()
                    .unwrap()
            );
            assert_eq!(
                &len_error(),
                ReadError::from(ipv6::HeaderSliceError::Len(len_error()))
                    .len()
                    .unwrap()
            );
            assert_eq!(
                &header_error(),
                ReadError::from(ipv6::HeaderSliceError::Content(header_error()))
                    .ipv6()
                    .unwrap()
            );
            assert_eq!(
                &len_error(),
                ReadError::from(ipv6::SliceError::Len(len_error()))
                    .len()
                    .unwrap()
            );
            assert_eq!(
                &header_error(),
                ReadError::from(ipv6::SliceError::Header(header_error()))
                    .ipv6()
                    .unwrap()
            );
            assert_eq!(
                &exts_error(),
                ReadError::from(ipv6::SliceError::Exts(exts_error()))
                    .ipv6_exts()
                    .unwrap()
            );
        }

        // ipv6 exts errors
        {
            let header_error = || ipv6_exts::HeaderError::HopByHopNotAtStart;
            assert_eq!(
                &header_error(),
                ReadError::from(header_error()).ipv6_exts().unwrap()
            );
            assert_eq!(
                &header_error(),
                ReadError::from(ipv6_exts::HeaderReadError::Content(header_error()))
                    .ipv6_exts()
                    .unwrap()
            );
            assert!(ReadError::from(ipv6_exts::HeaderReadError::Io(io_error()))
                .io()
                .is_some());
            assert_eq!(
                &header_error(),
                ReadError::from(ipv6_exts::HeaderSliceError::Content(header_error()))
                    .ipv6_exts()
                    .unwrap()
            );
            assert_eq!(
                &len_error(),
                ReadError::from(ipv6_exts::HeaderSliceError::Len(len_error()))
                    .len()
                    .unwrap()
            );
            assert_eq!(
                &header_error(),
                ReadError::from(ipv6_exts::HeaderSliceError::Content(header_error()))
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

            // IpSliceError
            assert_eq!(
                &len_error(),
                ReadError::from(packet::SliceError::Len(len_error()))
                    .len()
                    .unwrap()
            );
            assert_eq!(
                &linux_sll_error(),
                ReadError::from(packet::SliceError::LinuxSll(linux_sll_error()))
                    .linux_sll()
                    .unwrap()
            );
            assert_eq!(
                &macsec_error(),
                ReadError::from(packet::SliceError::Macsec(macsec_error()))
                    .macsec()
                    .unwrap()
            );
            assert_eq!(
                &ip_error(),
                ReadError::from(packet::SliceError::Ip(ip_error()))
                    .ip()
                    .unwrap()
            );
            assert_eq!(
                &ipv4_error(),
                ReadError::from(packet::SliceError::Ipv4(ipv4_error()))
                    .ipv4()
                    .unwrap()
            );
            assert_eq!(
                &ipv6_error(),
                ReadError::from(packet::SliceError::Ipv6(ipv6_error()))
                    .ipv6()
                    .unwrap()
            );
            assert_eq!(
                &ip_auth_error(),
                ReadError::from(packet::SliceError::Ipv4Exts(ip_auth_error()))
                    .ip_auth()
                    .unwrap()
            );
            assert_eq!(
                &ipv6_exts_error(),
                ReadError::from(packet::SliceError::Ipv6Exts(ipv6_exts_error()))
                    .ipv6_exts()
                    .unwrap()
            );
            assert_eq!(
                &tcp_error(),
                ReadError::from(packet::SliceError::Tcp(tcp_error()))
                    .tcp()
                    .unwrap()
            );
        }

        // tcp errors
        {
            let header_error = || tcp::HeaderError::DataOffsetTooSmall { data_offset: 1 };
            assert_eq!(
                &header_error(),
                ReadError::from(header_error()).tcp().unwrap()
            );
            assert_eq!(
                &header_error(),
                ReadError::from(tcp::HeaderReadError::Content(header_error()))
                    .tcp()
                    .unwrap()
            );
            assert!(ReadError::from(tcp::HeaderReadError::Io(io_error()))
                .io()
                .is_some());
            assert_eq!(
                &header_error(),
                ReadError::from(tcp::HeaderSliceError::Content(header_error()))
                    .tcp()
                    .unwrap()
            );
            assert_eq!(
                &len_error(),
                ReadError::from(tcp::HeaderSliceError::Len(len_error()))
                    .len()
                    .unwrap()
            );
            assert_eq!(
                &header_error(),
                ReadError::from(tcp::HeaderSliceError::Content(header_error()))
                    .tcp()
                    .unwrap()
            );
        }
    }
} // mod tests
