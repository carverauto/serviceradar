/// Errors when setting the next header IP number.
#[derive(Clone, Debug, Eq, PartialEq, Hash)]
pub enum NetSetNextHeaderError {
    /// It is possible to set the ip_number in an ARP header.
    ArpHeader,
}

impl core::fmt::Display for NetSetNextHeaderError {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        use NetSetNextHeaderError::*;
        match self {
            ArpHeader => write!(
                f,
                "It is not possible to set the payload 'IP number' for an ARP header."
            ),
        }
    }
}

impl core::error::Error for NetSetNextHeaderError {
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
            "ArpHeader",
            format!("{:?}", NetSetNextHeaderError::ArpHeader)
        );
    }

    #[test]
    fn clone_eq_hash() {
        let err = NetSetNextHeaderError::ArpHeader;
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
            "It is not possible to set the payload 'IP number' for an ARP header.",
            format!("{}", NetSetNextHeaderError::ArpHeader)
        );
    }

    #[cfg(feature = "std")]
    #[test]
    fn source() {
        let values = [NetSetNextHeaderError::ArpHeader];
        for v in values {
            assert!(v.source().is_none());
        }
    }
}
