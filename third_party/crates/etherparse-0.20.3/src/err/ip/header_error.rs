/// Error when decoding the IP header part of a message.
#[derive(Clone, Debug, Eq, PartialEq, Hash)]
pub enum HeaderError {
    /// Error when the IP header version field is not equal to 4 or 6.
    UnsupportedIpVersion {
        /// The unexpected version number in the IP header.
        version_number: u8,
    },

    /// Error when the ipv4 internet header length is smaller then the header itself (5).
    Ipv4HeaderLengthSmallerThanHeader {
        /// The internet header length that was too small.
        ihl: u8,
    },
}

impl core::fmt::Display for HeaderError {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        use HeaderError::*;
        match self {
            UnsupportedIpVersion { version_number } => write!(f, "IP Header Error: Encountered '{version_number}' as IP version number in the IP header (only '4' or '6' are supported)."),
            Ipv4HeaderLengthSmallerThanHeader { ihl } => write!(f, "IPv4 Header Error: The 'internet header length' value '{ihl}' present in the IPv4 header is smaller than the minimum size of an IPv4 header. The minimum allowed value is '5'."),
        }
    }
}

impl core::error::Error for HeaderError {
    fn source(&self) -> Option<&(dyn core::error::Error + 'static)> {
        use HeaderError::*;
        match self {
            UnsupportedIpVersion { version_number: _ } => None,
            Ipv4HeaderLengthSmallerThanHeader { ihl: _ } => None,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{HeaderError::*, *};
    use alloc::format;
    use std::{
        collections::hash_map::DefaultHasher,
        error::Error,
        hash::{Hash, Hasher},
    };

    #[test]
    fn debug() {
        assert_eq!(
            "UnsupportedIpVersion { version_number: 6 }",
            format!("{:?}", UnsupportedIpVersion { version_number: 6 })
        );
    }

    #[test]
    fn clone_eq_hash() {
        let err = HeaderError::UnsupportedIpVersion { version_number: 6 };
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
    }

    #[cfg(feature = "std")]
    #[test]
    fn source() {
        let values = [
            UnsupportedIpVersion { version_number: 0 },
            Ipv4HeaderLengthSmallerThanHeader { ihl: 0 },
        ];
        for v in values {
            assert!(v.source().is_none());
        }
    }
}
