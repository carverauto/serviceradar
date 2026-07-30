use crate::*;

/// Error when decoding the IP extension header.
#[derive(Clone, Debug, Eq, PartialEq, Hash)]
pub enum HeaderError {
    /// Error in the IPv4 extension headers (only authentication header).
    Ipv4Ext(err::ip_auth::HeaderError),

    /// Error in the IPv6 extension headers.
    Ipv6Ext(err::ipv6_exts::HeaderError),
}

impl core::fmt::Display for HeaderError {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        use HeaderError::*;
        match self {
            Ipv4Ext(err) => err.fmt(f),
            Ipv6Ext(err) => err.fmt(f),
        }
    }
}

impl core::error::Error for HeaderError {
    fn source(&self) -> Option<&(dyn core::error::Error + 'static)> {
        use HeaderError::*;
        match self {
            Ipv4Ext(err) => Some(err),
            Ipv6Ext(err) => Some(err),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{super::HeaderError::*, *};
    use alloc::format;
    use std::{
        collections::hash_map::DefaultHasher,
        error::Error,
        hash::{Hash, Hasher},
    };

    #[test]
    fn debug() {
        assert_eq!(
            "Ipv4Ext(ZeroPayloadLen)",
            format!("{:?}", Ipv4Ext(err::ip_auth::HeaderError::ZeroPayloadLen))
        );
    }

    #[test]
    fn clone_eq_hash() {
        let err = Ipv4Ext(err::ip_auth::HeaderError::ZeroPayloadLen);
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
        let values = [
            Ipv4Ext(err::ip_auth::HeaderError::ZeroPayloadLen),
            Ipv6Ext(err::ipv6_exts::HeaderError::HopByHopNotAtStart),
        ];
        for v in values {
            assert!(v.source().is_some());
        }
    }
}
