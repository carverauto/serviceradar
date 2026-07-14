#[cfg(feature = "std")]
use crate::err::{ipv4_exts, ipv6_exts, ValueTooBigError};

/// Error while writing packet
#[cfg(feature = "std")]
#[cfg_attr(docsrs, doc(cfg(feature = "std")))]
#[derive(Debug)]
pub enum BuildWriteError {
    /// IO error while writing packet.
    Io(std::io::Error),

    /// Error if the length of the payload is too
    /// big to be representable by the length fields.
    PayloadLen(ValueTooBigError<usize>),

    /// Error if the IPv4 extensions can not be serialized
    /// because of internal consistency errors.
    Ipv4Exts(ipv4_exts::ExtsWalkError),

    /// Error if the IPv6 extensions can not be serialized
    /// because of internal consistency errors.
    Ipv6Exts(ipv6_exts::ExtsWalkError),

    /// Error if ICMPv6 is packaged in an IPv4 packet (it is undefined
    /// how to calculate the checksum).
    Icmpv6InIpv4,

    /// address size defined in the ARP header does not match the actual size
    ArpHeaderNotMatch,
}

#[cfg(feature = "std")]
#[cfg_attr(docsrs, doc(cfg(feature = "std")))]
impl BuildWriteError {
    /// Returns the [`std::io::Error`] value if the `BuildWriteError` is an `Io`.
    /// Otherwise `None` is returned.
    pub fn io(&self) -> Option<&std::io::Error> {
        match self {
            BuildWriteError::Io(err) => Some(err),
            _ => None,
        }
    }

    /// Returns the [`crate::err::ValueTooBigError`] value if the
    /// `BuildWriteError` is a `PayloadLen`. Otherwise `None` is returned.
    pub fn payload_len(&self) -> Option<&ValueTooBigError<usize>> {
        match self {
            BuildWriteError::PayloadLen(err) => Some(err),
            _ => None,
        }
    }

    /// Returns the [`crate::err::ipv4_exts::ExtsWalkError`] value if the
    /// `BuildWriteError` is a `Ipv4Exts`. Otherwise `None` is returned.
    pub fn ipv4_exts(&self) -> Option<&ipv4_exts::ExtsWalkError> {
        match self {
            BuildWriteError::Ipv4Exts(err) => Some(err),
            _ => None,
        }
    }

    /// Returns the [`crate::err::ipv6_exts::ExtsWalkError`] value if the
    /// `BuildWriteError` is a `Ipv6Exts`. Otherwise `None` is returned.
    pub fn ipv6_exts(&self) -> Option<&ipv6_exts::ExtsWalkError> {
        match self {
            BuildWriteError::Ipv6Exts(err) => Some(err),
            _ => None,
        }
    }

    /// Returns true if the `BuildWriteError` is a `Icmpv6InIpv4`.
    pub fn is_icmpv6_in_ipv4(&self) -> bool {
        matches!(self, BuildWriteError::Icmpv6InIpv4)
    }
}

#[cfg(feature = "std")]
#[cfg_attr(docsrs, doc(cfg(feature = "std")))]
impl core::fmt::Display for BuildWriteError {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        use BuildWriteError::*;
        match self {
            Io(err) => err.fmt(f),
            PayloadLen(err) => err.fmt(f),
            Ipv4Exts(err) => err.fmt(f),
            Ipv6Exts(err) => err.fmt(f),
            ArpHeaderNotMatch => write!(f, "address size defined in the ARP header does not match the actual size"),
            Icmpv6InIpv4 => write!(f, "Error: ICMPv6 can not be combined with an IPv4 headers (checksum can not be calculated)."),
        }
    }
}

impl core::error::Error for BuildWriteError {
    fn source(&self) -> Option<&(dyn core::error::Error + 'static)> {
        use BuildWriteError::*;
        match self {
            Io(ref err) => Some(err),
            PayloadLen(ref err) => Some(err),
            Ipv4Exts(err) => Some(err),
            Ipv6Exts(err) => Some(err),
            Icmpv6InIpv4 => None,
            ArpHeaderNotMatch => None,
        }
    }
}

#[cfg(feature = "std")]
impl From<std::io::Error> for BuildWriteError {
    fn from(value: std::io::Error) -> Self {
        BuildWriteError::Io(value)
    }
}

#[cfg(feature = "std")]
impl From<ValueTooBigError<usize>> for BuildWriteError {
    fn from(value: ValueTooBigError<usize>) -> Self {
        BuildWriteError::PayloadLen(value)
    }
}

#[cfg(feature = "std")]
impl From<super::TransportChecksumError> for BuildWriteError {
    fn from(value: super::TransportChecksumError) -> Self {
        match value {
            super::TransportChecksumError::PayloadLen(err) => BuildWriteError::PayloadLen(err),
            super::TransportChecksumError::Icmpv6InIpv4 => BuildWriteError::Icmpv6InIpv4,
        }
    }
}

#[cfg(feature = "std")]
impl From<crate::WriteError<std::io::Error, ipv4_exts::ExtsWalkError>> for BuildWriteError {
    fn from(value: crate::WriteError<std::io::Error, ipv4_exts::ExtsWalkError>) -> Self {
        match value {
            crate::WriteError::Io(err) => BuildWriteError::Io(err),
            crate::WriteError::Content(err) => BuildWriteError::Ipv4Exts(err),
        }
    }
}

#[cfg(feature = "std")]
impl From<crate::WriteError<std::io::Error, ipv6_exts::ExtsWalkError>> for BuildWriteError {
    fn from(value: crate::WriteError<std::io::Error, ipv6_exts::ExtsWalkError>) -> Self {
        match value {
            crate::WriteError::Io(err) => BuildWriteError::Io(err),
            crate::WriteError::Content(err) => BuildWriteError::Ipv6Exts(err),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{BuildWriteError::*, *};
    use crate::{err::ValueType, *};
    use alloc::format;
    use core::error::Error;

    #[test]
    fn io() {
        assert!(Io(std::io::Error::new(
            std::io::ErrorKind::UnexpectedEof,
            "failed to fill whole buffer",
        ))
        .io()
        .is_some());
        assert!(Ipv4Exts(ipv4_exts::ExtsWalkError::ExtNotReferenced {
            missing_ext: IpNumber::AUTHENTICATION_HEADER,
        })
        .io()
        .is_none());
    }

    #[test]
    fn payload_len() {
        {
            let err = ValueTooBigError {
                actual: 3,
                max_allowed: 2,
                value_type: ValueType::Ipv4PayloadLength,
            };
            assert_eq!(Some(&err), PayloadLen(err.clone()).payload_len());
        }
        {
            let err = ipv4_exts::ExtsWalkError::ExtNotReferenced {
                missing_ext: IpNumber::AUTHENTICATION_HEADER,
            };
            assert_eq!(None, Ipv4Exts(err.clone()).payload_len());
        }
    }

    #[test]
    fn ipv4_exts() {
        assert!(Io(std::io::Error::new(
            std::io::ErrorKind::UnexpectedEof,
            "failed to fill whole buffer",
        ))
        .ipv4_exts()
        .is_none());
        {
            let err = ipv4_exts::ExtsWalkError::ExtNotReferenced {
                missing_ext: IpNumber::AUTHENTICATION_HEADER,
            };
            assert_eq!(Some(&err), Ipv4Exts(err.clone()).ipv4_exts());
        }
    }

    #[test]
    fn ipv6_exts() {
        assert!(Io(std::io::Error::new(
            std::io::ErrorKind::UnexpectedEof,
            "failed to fill whole buffer",
        ))
        .ipv6_exts()
        .is_none());
        {
            let err = ipv6_exts::ExtsWalkError::ExtNotReferenced {
                missing_ext: IpNumber::AUTHENTICATION_HEADER,
            };
            assert_eq!(Some(&err), Ipv6Exts(err.clone()).ipv6_exts());
        }
    }

    #[test]
    fn is_icmpv6_in_ipv4() {
        assert_eq!(
            false,
            Io(std::io::Error::new(
                std::io::ErrorKind::UnexpectedEof,
                "failed to fill whole buffer",
            ))
            .is_icmpv6_in_ipv4()
        );
        assert!(Icmpv6InIpv4.is_icmpv6_in_ipv4());
    }

    #[test]
    fn debug() {
        let err = ipv4_exts::ExtsWalkError::ExtNotReferenced {
            missing_ext: IpNumber::AUTHENTICATION_HEADER,
        };
        assert_eq!(
            format!("Ipv4Exts({:?})", err.clone()),
            format!("{:?}", Ipv4Exts(err))
        );
    }

    #[test]
    fn fmt() {
        {
            let err = std::io::Error::new(
                std::io::ErrorKind::UnexpectedEof,
                "failed to fill whole buffer",
            );
            assert_eq!(format!("{}", err), format!("{}", Io(err)));
        }
        {
            let err = ValueTooBigError {
                actual: 3,
                max_allowed: 2,
                value_type: ValueType::Ipv4PayloadLength,
            };
            assert_eq!(format!("{}", err), format!("{}", PayloadLen(err.clone())));
        }
        {
            let err = ipv4_exts::ExtsWalkError::ExtNotReferenced {
                missing_ext: IpNumber::AUTHENTICATION_HEADER,
            };
            assert_eq!(format!("{}", err), format!("{}", Ipv4Exts(err.clone())));
        }
        {
            let err = ipv6_exts::ExtsWalkError::ExtNotReferenced {
                missing_ext: IpNumber::AUTHENTICATION_HEADER,
            };
            assert_eq!(format!("{}", err), format!("{}", Ipv6Exts(err.clone())));
        }
        assert_eq!(
            "Error: ICMPv6 can not be combined with an IPv4 headers (checksum can not be calculated).",
            format!("{}", Icmpv6InIpv4)
        );
    }

    #[cfg(feature = "std")]
    #[test]
    fn source() {
        assert!(Io(std::io::Error::new(
            std::io::ErrorKind::UnexpectedEof,
            "failed to fill whole buffer",
        ))
        .source()
        .is_some());
        assert!(PayloadLen(ValueTooBigError {
            actual: 3,
            max_allowed: 2,
            value_type: ValueType::Ipv4PayloadLength,
        })
        .source()
        .is_some());
        assert!(Ipv4Exts(ipv4_exts::ExtsWalkError::ExtNotReferenced {
            missing_ext: IpNumber::AUTHENTICATION_HEADER,
        })
        .source()
        .is_some());
        assert!(Ipv6Exts(ipv6_exts::ExtsWalkError::ExtNotReferenced {
            missing_ext: IpNumber::AUTHENTICATION_HEADER,
        })
        .source()
        .is_some());
        assert!(Icmpv6InIpv4.source().is_none());
    }
}
