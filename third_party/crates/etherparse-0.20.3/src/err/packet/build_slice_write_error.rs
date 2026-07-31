use crate::err::{ipv4_exts, ipv6_exts, SliceWriteSpaceError, ValueTooBigError};

/// Error while serializing a packet into a byte slice.
#[derive(Clone, Debug, Eq, PartialEq, Hash)]
pub enum BuildSliceWriteError {
    /// Not enough space is available in the target slice.
    /// Contains the minimum required length.
    Space(usize),

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

impl From<ValueTooBigError<usize>> for BuildSliceWriteError {
    fn from(value: ValueTooBigError<usize>) -> Self {
        BuildSliceWriteError::PayloadLen(value)
    }
}

impl From<SliceWriteSpaceError> for BuildSliceWriteError {
    fn from(value: SliceWriteSpaceError) -> Self {
        BuildSliceWriteError::Space(value.required_len)
    }
}

impl From<super::TransportChecksumError> for BuildSliceWriteError {
    fn from(value: super::TransportChecksumError) -> Self {
        match value {
            super::TransportChecksumError::PayloadLen(err) => BuildSliceWriteError::PayloadLen(err),
            super::TransportChecksumError::Icmpv6InIpv4 => BuildSliceWriteError::Icmpv6InIpv4,
        }
    }
}

impl From<crate::WriteError<SliceWriteSpaceError, ipv4_exts::ExtsWalkError>>
    for BuildSliceWriteError
{
    fn from(value: crate::WriteError<SliceWriteSpaceError, ipv4_exts::ExtsWalkError>) -> Self {
        match value {
            crate::WriteError::Io(err) => BuildSliceWriteError::Space(err.required_len),
            crate::WriteError::Content(err) => BuildSliceWriteError::Ipv4Exts(err),
        }
    }
}

impl From<crate::WriteError<SliceWriteSpaceError, ipv6_exts::ExtsWalkError>>
    for BuildSliceWriteError
{
    fn from(value: crate::WriteError<SliceWriteSpaceError, ipv6_exts::ExtsWalkError>) -> Self {
        match value {
            crate::WriteError::Io(err) => BuildSliceWriteError::Space(err.required_len),
            crate::WriteError::Content(err) => BuildSliceWriteError::Ipv6Exts(err),
        }
    }
}

impl core::fmt::Display for BuildSliceWriteError {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        use BuildSliceWriteError::*;
        match self {
            Space(required_len) => write!(
                f,
                "Not enough space to write packet to slice. Needed {} byte(s).",
                required_len
            ),
            PayloadLen(err) => err.fmt(f),
            Ipv4Exts(err) => err.fmt(f),
            Ipv6Exts(err) => err.fmt(f),
            ArpHeaderNotMatch => write!(
                f,
                "address size defined in the ARP header does not match the actual size"
            ),
            Icmpv6InIpv4 => write!(
                f,
                "Error: ICMPv6 can not be combined with an IPv4 header (checksum can not be calculated)."
            ),
        }
    }
}

impl core::error::Error for BuildSliceWriteError {
    fn source(&self) -> Option<&(dyn core::error::Error + 'static)> {
        use BuildSliceWriteError::*;
        match self {
            Space(_) => None,
            PayloadLen(err) => Some(err),
            Ipv4Exts(err) => Some(err),
            Ipv6Exts(err) => Some(err),
            Icmpv6InIpv4 => None,
            ArpHeaderNotMatch => None,
        }
    }
}
