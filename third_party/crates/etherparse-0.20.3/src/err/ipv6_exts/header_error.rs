use crate::*;

/// Error when decoding IPv6 extension headers.
#[derive(Clone, Debug, Eq, PartialEq, Hash)]
pub enum HeaderError {
    /// Error if the ipv6 hop by hop header does not occur directly after the ipv6 header (see rfc8200 chapter 4.1.)
    HopByHopNotAtStart,

    /// Error in the ip authentication header.
    IpAuth(err::ip_auth::HeaderError),
}

impl core::fmt::Display for HeaderError {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        use HeaderError::*;
        match self {
            HopByHopNotAtStart => write!(f, "IPv6 Extension Header Error: Encountered an IPv6 hop-by-hop header not directly after the IPv6 header. This is not allowed according to RFC 8200."),
            IpAuth(err) => err.fmt(f),
        }
    }
}

impl core::error::Error for HeaderError {
    fn source(&self) -> Option<&(dyn core::error::Error + 'static)> {
        use HeaderError::*;
        match self {
            HopByHopNotAtStart => None,
            IpAuth(err) => Some(err),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::HeaderError::*;
    use crate::*;
    use alloc::format;
    use std::{
        collections::hash_map::DefaultHasher,
        error::Error,
        hash::{Hash, Hasher},
    };

    #[test]
    fn debug() {
        assert_eq!("HopByHopNotAtStart", format!("{:?}", HopByHopNotAtStart));
    }

    #[test]
    fn clone_eq_hash() {
        let err = HopByHopNotAtStart;
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
            "IPv6 Extension Header Error: Encountered an IPv6 hop-by-hop header not directly after the IPv6 header. This is not allowed according to RFC 8200.",
            format!("{}", HopByHopNotAtStart)
        );
        {
            let err = err::ip_auth::HeaderError::ZeroPayloadLen;
            assert_eq!(format!("{}", err), format!("{}", IpAuth(err)));
        }
    }

    #[cfg(feature = "std")]
    #[test]
    fn source() {
        use err::ip_auth::HeaderError::ZeroPayloadLen;

        assert!(HopByHopNotAtStart.source().is_none());
        assert!(IpAuth(ZeroPayloadLen).source().is_some());
    }
}
