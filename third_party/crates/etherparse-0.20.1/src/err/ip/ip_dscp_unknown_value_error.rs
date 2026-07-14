use core::{cmp::Eq, cmp::PartialEq, fmt::Debug, hash::Hash};

/// Error if an unknown value is passed to [`crate::IpDscpKnown::try_from_ip_dscp`].
#[derive(Clone, Debug, Eq, PartialEq, Hash)]
pub struct IpDscpUnknownValueError {
    /// Unknown DSCP value that caused the error.
    pub value: u8,
}

impl core::fmt::Display for IpDscpUnknownValueError {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        write!(f, "Error DSCP value '{}' is not known.", self.value)
    }
}

impl core::error::Error for IpDscpUnknownValueError {
    fn source(&self) -> Option<&(dyn core::error::Error + 'static)> {
        None
    }
}

#[cfg(test)]
mod test {
    use super::*;
    use std::{collections::hash_map::DefaultHasher, error::Error, format, hash::Hasher};

    #[test]
    fn fmt() {
        assert_eq!(
            format!("{}", IpDscpUnknownValueError { value: 3 }),
            "Error DSCP value '3' is not known."
        );
    }

    #[test]
    fn dbg() {
        assert_eq!(
            format!("{:?}", IpDscpUnknownValueError { value: 3 }),
            format!("IpDscpUnknownValueError {{ value: {} }}", 3)
        );
    }

    #[test]
    fn clone_eq_hash() {
        let err = IpDscpUnknownValueError { value: 3 };
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

    #[cfg(feature = "std")]
    #[test]
    fn source() {
        assert!(IpDscpUnknownValueError { value: 3 }.source().is_none());
    }
}
