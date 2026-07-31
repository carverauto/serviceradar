use crate::err::ValueTooBigError;

/// Error while calculating the checksum in a transport header.
#[derive(Clone, Debug, Eq, PartialEq, Hash)]
pub enum TransportChecksumError {
    /// Error if the length of the payload is too
    /// big to be representable by the length fields.
    PayloadLen(ValueTooBigError<usize>),

    /// Error when an Icmpv6 payload is found in an IPv4 packet.
    Icmpv6InIpv4,
}

impl core::fmt::Display for TransportChecksumError {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        use TransportChecksumError::*;
        match self {
            PayloadLen(err) => err.fmt(f),
            Icmpv6InIpv4 => write!(f, "Error: ICMPv6 can not be combined with an IPv4 headers (checksum can not be calculated)."),
        }
    }
}

impl core::error::Error for TransportChecksumError {
    fn source(&self) -> Option<&(dyn core::error::Error + 'static)> {
        use TransportChecksumError::*;
        match self {
            PayloadLen(err) => Some(err),
            Icmpv6InIpv4 => None,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{TransportChecksumError::*, *};
    use crate::err::ValueType;
    use alloc::format;
    use std::{
        collections::hash_map::DefaultHasher,
        error::Error,
        hash::{Hash, Hasher},
    };

    #[test]
    fn debug() {
        assert_eq!("Icmpv6InIpv4", format!("{:?}", Icmpv6InIpv4));
    }

    #[test]
    fn clone_eq_hash() {
        let err = Icmpv6InIpv4;
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
        // PayloadLen
        {
            let err = ValueTooBigError {
                actual: 1,
                max_allowed: 2,
                value_type: ValueType::TcpPayloadLengthIpv6,
            };
            assert_eq!(format!("{}", &err), format!("{}", PayloadLen(err)));
        }

        // Icmpv6InIpv4
        assert_eq!(
            format!("{}", Icmpv6InIpv4),
            "Error: ICMPv6 can not be combined with an IPv4 headers (checksum can not be calculated)."
        );
    }

    #[cfg(feature = "std")]
    #[test]
    fn source() {
        // Len
        {
            let err = ValueTooBigError {
                actual: 1,
                max_allowed: 2,
                value_type: ValueType::TcpPayloadLengthIpv6,
            };
            assert!(PayloadLen(err).source().is_some());
        }

        // IpHeader
        assert!(Icmpv6InIpv4.source().is_none());
    }
}
