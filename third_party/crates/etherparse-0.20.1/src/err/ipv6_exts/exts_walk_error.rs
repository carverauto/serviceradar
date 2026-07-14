use crate::IpNumber;

/// Errors in content of IPv6 header extensions that prevent serialization.
#[derive(Clone, Debug, Eq, PartialEq, Hash)]
pub enum ExtsWalkError {
    /// Error when a hop-by-hop header is not referenced as the
    /// first header after the ipv6 header but as a later extension
    /// header.
    HopByHopNotAtStart,

    /// Error when a header in [`crate::Ipv6Extensions`] is never written
    /// as it is never referenced by any of the other `next_header`
    /// fields or the initial ip number.
    ExtNotReferenced {
        /// IpNumber of the header which was not referenced.
        missing_ext: IpNumber,
    },
}

impl core::fmt::Display for ExtsWalkError {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        match self {
            ExtsWalkError::HopByHopNotAtStart =>
                write!(f, "IPv6 extensions hop-by-hop is not located directly after the IPv6 header (required by IPv6)."),
            ExtsWalkError::ExtNotReferenced{ missing_ext } =>
                write!(f, "IPv6 extensions '{missing_ext:?}' is defined but is not referenced by any of the 'next_header' of the other extension headers or the IPv6 header."),
        }
    }
}

impl core::error::Error for ExtsWalkError {
    fn source(&self) -> Option<&(dyn core::error::Error + 'static)> {
        None
    }
}

#[cfg(test)]
mod tests {
    use super::ExtsWalkError::*;
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
            "IPv6 extensions hop-by-hop is not located directly after the IPv6 header (required by IPv6).",
            format!("{}", HopByHopNotAtStart)
        );
        assert_eq!(
            "IPv6 extensions '44 (IPv6-Frag - Fragment Header for IPv6)' is defined but is not referenced by any of the 'next_header' of the other extension headers or the IPv6 header.",
            format!("{}", ExtNotReferenced{ missing_ext: IpNumber::IPV6_FRAGMENTATION_HEADER })
        );
    }

    #[cfg(feature = "std")]
    #[test]
    fn source() {
        assert!(HopByHopNotAtStart.source().is_none());
        assert!(ExtNotReferenced {
            missing_ext: IpNumber::IPV6_FRAGMENTATION_HEADER
        }
        .source()
        .is_none());
    }
}
