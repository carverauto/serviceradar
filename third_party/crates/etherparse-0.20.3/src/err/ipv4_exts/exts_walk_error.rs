use crate::IpNumber;

/// Errors in content of IPv4 header extensions that prevent serialization
/// or determining the next header.
#[derive(Clone, Debug, Eq, PartialEq, Hash)]
pub enum ExtsWalkError {
    /// Error when a header in [`crate::Ipv4Extensions`] is never referenced even
    /// though it is present in the [`crate::Ipv4Extensions`].
    ///
    /// This can occur when calculating the "next header" value or when
    /// trying to write [crate::Ipv4Extensions`].
    ExtNotReferenced {
        /// IpNumber of the header which was not referenced.
        missing_ext: IpNumber,
    },
}

impl core::fmt::Display for ExtsWalkError {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        use ExtsWalkError::*;
        match self {
            ExtNotReferenced{ missing_ext } => write!(
                f,
                "IPv4 extensions '{missing_ext:?}' is defined but is not referenced by the 'protocol' the IPv4 header."
            ),
        }
    }
}

impl core::error::Error for ExtsWalkError {
    fn source(&self) -> Option<&(dyn core::error::Error + 'static)> {
        use ExtsWalkError::*;
        match self {
            ExtNotReferenced { missing_ext: _ } => None,
        }
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
        assert_eq!(
            format!(
                "ExtNotReferenced {{ missing_ext: {:?} }}",
                IpNumber::AUTHENTICATION_HEADER,
            ),
            format!(
                "{:?}",
                ExtNotReferenced {
                    missing_ext: IpNumber::AUTHENTICATION_HEADER
                }
            )
        );
    }

    #[test]
    fn clone_eq_hash() {
        let err = ExtNotReferenced {
            missing_ext: IpNumber::AUTHENTICATION_HEADER,
        };
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
            "IPv4 extensions '51 (AH - Authentication Header)' is defined but is not referenced by the 'protocol' the IPv4 header.",
            format!("{}", ExtNotReferenced{
                missing_ext: IpNumber::AUTHENTICATION_HEADER,
            })
        );
    }

    #[cfg(feature = "std")]
    #[test]
    fn source() {
        assert!(ExtNotReferenced {
            missing_ext: IpNumber::IPV6_FRAGMENTATION_HEADER
        }
        .source()
        .is_none());
    }
}
