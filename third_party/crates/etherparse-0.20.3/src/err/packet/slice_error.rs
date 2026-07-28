use crate::*;

/// Error when slicing an packet from downwards (both
/// starting from ethernet or ip layer downwards).
#[derive(Clone, Debug, Eq, PartialEq, Hash)]
pub enum SliceError {
    /// Length related errors (e.g. not enough data in slice).
    Len(err::LenError),
    /// Error when decoding an Linux SLL header.
    LinuxSll(err::linux_sll::HeaderError),
    /// Error when decoding MACsec header.
    Macsec(err::macsec::HeaderError),
    /// Error when decoding starting at an IP header (v4 or v6).
    Ip(err::ip::HeaderError),
    /// Error when decoding an IPv4 header.
    Ipv4(err::ipv4::HeaderError),
    /// Error when decoding an IPv6 header.
    Ipv6(err::ipv6::HeaderError),
    /// Error when decoding an IPv4 extension header.
    Ipv4Exts(err::ip_auth::HeaderError),
    /// Error when decoding an IPv6 extension header.
    Ipv6Exts(err::ipv6_exts::HeaderError),
    /// Error when decoding a TCP header.
    Tcp(err::tcp::HeaderError),
}

impl core::fmt::Display for SliceError {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        use SliceError::*;

        match self {
            Len(err) => err.fmt(f),
            LinuxSll(err) => err.fmt(f),
            Macsec(err) => err.fmt(f),
            Ip(err) => err.fmt(f),
            Ipv4(err) => err.fmt(f),
            Ipv6(err) => err.fmt(f),
            Ipv4Exts(err) => err.fmt(f),
            Ipv6Exts(err) => err.fmt(f),
            Tcp(err) => err.fmt(f),
        }
    }
}

impl core::error::Error for SliceError {
    fn source(&self) -> Option<&(dyn core::error::Error + 'static)> {
        use SliceError::*;
        match self {
            Len(err) => Some(err),
            LinuxSll(err) => Some(err),
            Macsec(err) => Some(err),
            Ip(err) => Some(err),
            Ipv4(err) => Some(err),
            Ipv6(err) => Some(err),
            Ipv4Exts(err) => Some(err),
            Ipv6Exts(err) => Some(err),
            Tcp(err) => Some(err),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{SliceError::*, *};
    use crate::err::Layer;
    use alloc::format;
    use std::{
        collections::hash_map::DefaultHasher,
        error::Error,
        hash::{Hash, Hasher},
    };

    #[test]
    fn debug() {
        let err = err::ipv4::HeaderError::UnexpectedVersion { version_number: 1 };
        assert_eq!(
            format!("Ipv4({:?})", err.clone()),
            format!("{:?}", Ipv4(err))
        );
    }

    #[test]
    fn clone_eq_hash() {
        let err = Ipv4(err::ipv4::HeaderError::UnexpectedVersion { version_number: 1 });
        assert_eq!(err, err.clone());
        let hash_a = {
            let mut hasher = DefaultHasher::new();
            err.hash(&mut hasher);
            hasher.finish()
        };
        let hash_b = {
            let mut hasher = DefaultHasher::new();
            err.clone().hash(&mut hasher);
            hasher.finish()
        };
        assert_eq!(hash_a, hash_b);
    }

    #[test]
    fn fmt() {
        // Len
        {
            let err = err::LenError {
                required_len: 2,
                len: 1,
                len_source: LenSource::Slice,
                layer: Layer::TcpHeader,
                layer_start_offset: 3,
            };
            assert_eq!(format!("{}", err), format!("{}", Len(err)));
        }

        // Linux SLL Header
        {
            let err = err::linux_sll::HeaderError::UnsupportedArpHardwareId {
                arp_hardware_type: ArpHardwareId::ADAPT,
            };
            assert_eq!(
                format!("{}", err),
                format!("{}", err::packet::SliceError::LinuxSll(err))
            );
        }

        // Macsec Header
        {
            let err = err::macsec::HeaderError::UnexpectedVersion;
            assert_eq!(
                format!("{}", err),
                format!("{}", err::packet::SliceError::Macsec(err))
            );
        }

        // IpHeader
        {
            let err = err::ip::HeaderError::UnsupportedIpVersion { version_number: 1 };
            assert_eq!(
                format!("{}", err),
                format!("{}", err::packet::SliceError::Ip(err))
            );
        }

        // Ipv4Header
        {
            let err = err::ipv4::HeaderError::UnexpectedVersion { version_number: 1 };
            assert_eq!(format!("{}", err), format!("{}", Ipv4(err)));
        }

        // Ipv6Header
        {
            let err = err::ipv6::HeaderError::UnexpectedVersion { version_number: 1 };
            assert_eq!(format!("{}", err), format!("{}", Ipv6(err)));
        }

        // Ipv4ExtHeader
        {
            let err = err::ip_auth::HeaderError::ZeroPayloadLen;
            assert_eq!(format!("{}", err), format!("{}", Ipv4Exts(err)));
        }

        // Ipv6ExtHeader
        {
            let err = err::ipv6_exts::HeaderError::HopByHopNotAtStart;
            assert_eq!(format!("{}", err), format!("{}", Ipv6Exts(err)));
        };

        // TcpHeader
        {
            let err = err::tcp::HeaderError::DataOffsetTooSmall { data_offset: 1 };
            assert_eq!(format!("{}", err), format!("{}", Tcp(err)));
        }
    }

    #[cfg(feature = "std")]
    #[test]
    fn source() {
        // Len
        {
            let err = err::LenError {
                required_len: 2,
                len: 1,
                len_source: LenSource::Slice,
                layer: Layer::TcpHeader,
                layer_start_offset: 3,
            };
            assert!(Len(err).source().is_some());
        }

        // Linux SLL Header
        {
            let err = err::linux_sll::HeaderError::UnsupportedArpHardwareId {
                arp_hardware_type: ArpHardwareId::ADAPT,
            };
            assert!(err::packet::SliceError::LinuxSll(err.clone())
                .source()
                .is_some());
        }

        // Macsec Header
        {
            let err = err::macsec::HeaderError::UnexpectedVersion;
            assert!(err::packet::SliceError::Macsec(err).source().is_some());
        }

        // IpHeaders
        {
            let err = err::linux_sll::HeaderError::UnsupportedArpHardwareId {
                arp_hardware_type: ArpHardwareId::ETHERNET,
            };
            assert!(LinuxSll(err).source().is_some());
        }

        // IpHeaders
        {
            let err = err::ip::HeaderError::UnsupportedIpVersion { version_number: 1 };
            assert!(Ip(err).source().is_some());
        }

        // Ipv4Header
        {
            let err = err::ipv4::HeaderError::UnexpectedVersion { version_number: 1 };
            assert!(Ipv4(err).source().is_some());
        }

        // Ipv6Header
        {
            let err = err::ipv6::HeaderError::UnexpectedVersion { version_number: 1 };
            assert!(Ipv6(err).source().is_some());
        }

        // Ipv4ExtHeader
        {
            let err = err::ip_auth::HeaderError::ZeroPayloadLen;
            assert!(Ipv4Exts(err).source().is_some());
        }

        // Ipv6ExtHeader
        {
            let err = err::ipv6_exts::HeaderError::HopByHopNotAtStart;
            assert!(Ipv6Exts(err).source().is_some());
        };

        // TcpHeader
        {
            let err = err::tcp::HeaderError::DataOffsetTooSmall { data_offset: 1 };
            assert!(Tcp(err).source().is_some());
        }
    }
}
