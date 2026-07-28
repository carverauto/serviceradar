/// Error if a slice can not be used as options data in
/// [`crate::Ipv4Options`] as then length is non compatible.
///
/// The length for options in an IPv4 header
#[derive(Clone, Debug, Eq, PartialEq, Hash)]
pub struct BadOptionsLen {
    /// Invalid length.
    pub bad_len: usize,
}

impl core::fmt::Display for BadOptionsLen {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        write!(f, "Slice of length {} cannot be set as IPv4 header options. The length must be a multiple of 4 and at maximum 40.", self.bad_len)
    }
}

impl core::error::Error for BadOptionsLen {
    fn source(&self) -> Option<&(dyn core::error::Error + 'static)> {
        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use alloc::format;
    use std::{
        collections::hash_map::DefaultHasher,
        error::Error,
        hash::{Hash, Hasher},
    };

    #[test]
    fn debug() {
        assert_eq!(
            "BadOptionsLen { bad_len: 123 }",
            format!("{:?}", BadOptionsLen { bad_len: 123 })
        );
    }

    #[test]
    fn clone_eq_hash() {
        let err = BadOptionsLen { bad_len: 123 };
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
        let err = BadOptionsLen { bad_len: 123 };
        assert_eq!(
            format!("{}", err),
            "Slice of length 123 cannot be set as IPv4 header options. The length must be a multiple of 4 and at maximum 40."
        );
    }

    #[cfg(feature = "std")]
    #[test]
    fn source() {
        assert!(BadOptionsLen { bad_len: 123 }.source().is_none());
    }
}
