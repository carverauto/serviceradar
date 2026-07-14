/// Error when decoding a MACsec header.
#[derive(Clone, Debug, Eq, PartialEq, Hash)]
pub enum HeaderError {
    /// Error when the MACsec header version field is not equal 0.
    UnexpectedVersion,

    /// Error if the short len is 1 when it should be at least 2
    /// (for the next ether type).
    InvalidUnmodifiedShortLen,
}

impl core::fmt::Display for HeaderError {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        use HeaderError::*;
        match self {
            UnexpectedVersion => write!(f, "MACsec Header Error: Encountered '1' as MACsec version in the MACsec SecTag header (must be '0')."),
            InvalidUnmodifiedShortLen => write!(f, "MACsec Header Error: Encountered '1' as MACsec short len in an unmodified packet (must be '0' or '2' or greater)."),
        }
    }
}

impl core::error::Error for HeaderError {
    fn source(&self) -> Option<&(dyn core::error::Error + 'static)> {
        None
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
        assert_eq!("UnexpectedVersion", format!("{:?}", UnexpectedVersion));
    }

    #[test]
    fn clone_eq_hash() {
        let err = HeaderError::UnexpectedVersion;
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
            "MACsec Header Error: Encountered '1' as MACsec version in the MACsec SecTag header (must be '0').",
            format!("{}", UnexpectedVersion)
        );
        assert_eq!(
            "MACsec Header Error: Encountered '1' as MACsec short len in an unmodified packet (must be '0' or '2' or greater).",
            format!("{}", InvalidUnmodifiedShortLen)
        );
    }

    #[cfg(feature = "std")]
    #[test]
    fn source() {
        let values = [UnexpectedVersion, InvalidUnmodifiedShortLen];
        for v in values {
            assert!(v.source().is_none());
        }
    }
}
