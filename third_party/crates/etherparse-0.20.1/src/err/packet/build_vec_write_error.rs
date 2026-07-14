use crate::err::{ipv4_exts, ipv6_exts, ValueTooBigError};
use core::convert::Infallible;

/// Error while serializing a packet into a [`alloc::vec::Vec`].
#[cfg_attr(docsrs, doc(cfg(feature = "alloc")))]
#[derive(Clone, Debug, Eq, PartialEq, Hash)]
pub enum BuildVecWriteError {
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

    /// Address size defined in the ARP header does not match the actual size.
    ArpHeaderNotMatch,
}

impl From<Infallible> for BuildVecWriteError {
    fn from(value: Infallible) -> Self {
        match value {}
    }
}

impl From<ValueTooBigError<usize>> for BuildVecWriteError {
    fn from(value: ValueTooBigError<usize>) -> Self {
        BuildVecWriteError::PayloadLen(value)
    }
}

impl From<super::TransportChecksumError> for BuildVecWriteError {
    fn from(value: super::TransportChecksumError) -> Self {
        match value {
            super::TransportChecksumError::PayloadLen(err) => BuildVecWriteError::PayloadLen(err),
            super::TransportChecksumError::Icmpv6InIpv4 => BuildVecWriteError::Icmpv6InIpv4,
        }
    }
}

impl From<crate::WriteError<Infallible, ipv4_exts::ExtsWalkError>> for BuildVecWriteError {
    fn from(value: crate::WriteError<Infallible, ipv4_exts::ExtsWalkError>) -> Self {
        match value {
            crate::WriteError::Io(err) => match err {},
            crate::WriteError::Content(err) => BuildVecWriteError::Ipv4Exts(err),
        }
    }
}

impl From<crate::WriteError<Infallible, ipv6_exts::ExtsWalkError>> for BuildVecWriteError {
    fn from(value: crate::WriteError<Infallible, ipv6_exts::ExtsWalkError>) -> Self {
        match value {
            crate::WriteError::Io(err) => match err {},
            crate::WriteError::Content(err) => BuildVecWriteError::Ipv6Exts(err),
        }
    }
}

impl core::fmt::Display for BuildVecWriteError {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        use BuildVecWriteError::*;
        match self {
            PayloadLen(err) => err.fmt(f),
            Ipv4Exts(err) => err.fmt(f),
            Ipv6Exts(err) => err.fmt(f),
            ArpHeaderNotMatch => write!(
                f,
                "address size defined in the ARP header does not match the actual size"
            ),
            Icmpv6InIpv4 => write!(
                f,
                "Error: ICMPv6 can not be combined with an IPv4 headers (checksum can not be calculated)."
            ),
        }
    }
}

impl core::error::Error for BuildVecWriteError {
    fn source(&self) -> Option<&(dyn core::error::Error + 'static)> {
        use BuildVecWriteError::*;
        match self {
            PayloadLen(err) => Some(err),
            Ipv4Exts(err) => Some(err),
            Ipv6Exts(err) => Some(err),
            Icmpv6InIpv4 => None,
            ArpHeaderNotMatch => None,
        }
    }
}
