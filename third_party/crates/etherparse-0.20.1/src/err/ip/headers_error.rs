use crate::*;

/// Error when decoding the IP header part of a message.
#[derive(Clone, Debug, Eq, PartialEq, Hash)]
pub enum HeadersError {
    /// Error in the IPv4 or IPv6 header.
    Ip(err::ip::HeaderError),

    /// Error in the IPv4 extension headers (only authentication header).
    Ipv4Ext(err::ip_auth::HeaderError),

    /// Error in the IPv6 extension headers.
    Ipv6Ext(err::ipv6_exts::HeaderError),
}

impl core::fmt::Display for HeadersError {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        use HeadersError::*;
        match self {
            Ip(err) => err.fmt(f),
            Ipv4Ext(err) => err.fmt(f),
            Ipv6Ext(err) => err.fmt(f),
        }
    }
}

impl core::error::Error for HeadersError {
    fn source(&self) -> Option<&(dyn core::error::Error + 'static)> {
        use HeadersError::*;
        match self {
            Ip(err) => Some(err),
            Ipv4Ext(err) => Some(err),
            Ipv6Ext(err) => Some(err),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{super::HeaderError::*, HeadersError::*, *};
    use alloc::format;
    use std::{
        collections::hash_map::DefaultHasher,
        error::Error,
        hash::{Hash, Hasher},
    };

    #[test]
    fn debug() {
        assert_eq!(
            "Ip(UnsupportedIpVersion { version_number: 6 })",
            format!("{:?}", Ip(UnsupportedIpVersion { version_number: 6 }))
        );
    }

    #[test]
    fn clone_eq_hash() {
        let err = Ip(UnsupportedIpVersion { version_number: 6 });
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
        assert_eq!(
            "IP Header Error: Encountered '1' as IP version number in the IP header (only '4' or '6' are supported).",
            format!("{}", UnsupportedIpVersion{ version_number: 1 })
        );
        assert_eq!(
            "IPv4 Header Error: The 'internet header length' value '2' present in the IPv4 header is smaller than the minimum size of an IPv4 header. The minimum allowed value is '5'.",
            format!("{}", Ipv4HeaderLengthSmallerThanHeader{ ihl: 2 })
        );
        {
            let err = err::ip_auth::HeaderError::ZeroPayloadLen;
            assert_eq!(format!("{}", Ipv4Ext(err.clone())), format!("{}", err));
        }
        {
            let err = err::ipv6_exts::HeaderError::HopByHopNotAtStart;
            assert_eq!(format!("{}", Ipv6Ext(err.clone())), format!("{}", err));
        }
    }

    #[cfg(feature = "std")]
    #[test]
    fn source() {
        {
            let values = [
                UnsupportedIpVersion { version_number: 0 },
                Ipv4HeaderLengthSmallerThanHeader { ihl: 0 },
            ];
            for v in values {
                assert!(v.source().is_none());
            }
        }
        {
            let values = [
                Ipv4Ext(err::ip_auth::HeaderError::ZeroPayloadLen),
                Ipv6Ext(err::ipv6_exts::HeaderError::HopByHopNotAtStart),
            ];
            for v in values {
                assert!(v.source().is_some());
            }
        }
    }
}
