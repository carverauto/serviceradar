use crate::err::{ipv4_exts, ipv6_exts};

/// Errors while serializing or determining the next_header of
/// an [`crate::IpHeaders`].
#[derive(Clone, Debug, Eq, PartialEq, Hash)]
pub enum ExtsWalkError {
    /// Error within the IPv4 extensions headers.
    Ipv4Exts(ipv4_exts::ExtsWalkError),

    /// Error within the IPv6 extensions headers.
    Ipv6Exts(ipv6_exts::ExtsWalkError),
}

impl core::fmt::Display for ExtsWalkError {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        use ExtsWalkError::*;
        match self {
            Ipv4Exts(err) => err.fmt(f),
            Ipv6Exts(err) => err.fmt(f),
        }
    }
}

impl core::error::Error for ExtsWalkError {
    fn source(&self) -> Option<&(dyn core::error::Error + 'static)> {
        use ExtsWalkError::*;
        match self {
            Ipv4Exts(err) => Some(err),
            Ipv6Exts(err) => Some(err),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{ExtsWalkError::*, *};
    use crate::IpNumber;
    use alloc::format;
    use std::{
        collections::hash_map::DefaultHasher,
        error::Error,
        hash::{Hash, Hasher},
    };

    #[test]
    fn debug() {
        let err = ipv6_exts::ExtsWalkError::HopByHopNotAtStart;
        assert_eq!(
            format!("Ipv6Exts({:?})", err.clone()),
            format!("{:?}", Ipv6Exts(err))
        );
    }

    #[test]
    fn clone_eq_hash() {
        let err = Ipv6Exts(ipv6_exts::ExtsWalkError::HopByHopNotAtStart);
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
        // Ipv4Exts
        {
            let err = ipv4_exts::ExtsWalkError::ExtNotReferenced {
                missing_ext: IpNumber::AUTHENTICATION_HEADER,
            };
            assert_eq!(format!("{}", &err), format!("{}", Ipv4Exts(err)));
        }
        // Ipv6Exts
        {
            let err = ipv6_exts::ExtsWalkError::HopByHopNotAtStart;
            assert_eq!(format!("{}", &err), format!("{}", Ipv6Exts(err.clone())));
        }
    }

    #[cfg(feature = "std")]
    #[test]
    fn source() {
        assert!(Ipv4Exts(ipv4_exts::ExtsWalkError::ExtNotReferenced {
            missing_ext: IpNumber::AUTHENTICATION_HEADER
        })
        .source()
        .is_some());
        assert!(Ipv6Exts(ipv6_exts::ExtsWalkError::HopByHopNotAtStart)
            .source()
            .is_some());
    }
}
