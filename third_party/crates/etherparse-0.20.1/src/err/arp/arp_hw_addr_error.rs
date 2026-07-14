/// Error in the hardware addresses when creating an [`crate::ArpPacket`] or
/// changing the hardware addresses in an [`crate::ArpPacket`].
#[derive(Debug, Clone, Eq, PartialEq, Hash)]
pub enum ArpHwAddrError {
    /// Error if the given hardware address is longer than
    /// the maximum of 255 bytes/octets.
    LenTooBig(usize),

    /// Hardware address lengths of sender and target differ.
    LenNonMatching(usize, usize),
}

impl core::fmt::Display for ArpHwAddrError {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        match self {
            ArpHwAddrError::LenTooBig(len) =>
                write!(f, "ARP Hardware Address Error: Given hardware address has a length of {len} which is greater then the maximum of 255."),
            ArpHwAddrError::LenNonMatching(len_sender, len_target) =>
                write!(f, "ARP Hardware Address Error: Given sender & target hardware addresses have differing lengths of {len_sender} & {len_target} (must be matching)."),
        }
    }
}

impl core::error::Error for ArpHwAddrError {
    fn source(&self) -> Option<&(dyn core::error::Error + 'static)> {
        None
    }
}

#[cfg(test)]
mod tests {
    use super::ArpHwAddrError::*;
    use alloc::format;
    use std::{
        collections::hash_map::DefaultHasher,
        error::Error,
        hash::{Hash, Hasher},
    };

    #[test]
    fn debug() {
        assert_eq!("LenTooBig(300)", format!("{:?}", LenTooBig(300)));
    }

    #[test]
    fn clone_eq_hash() {
        let err = LenTooBig(300);
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
        let tests = [
            (LenTooBig(300), "ARP Hardware Address Error: Given hardware address has a length of 300 which is greater then the maximum of 255."),
            (LenNonMatching(21, 22), "ARP Hardware Address Error: Given sender & target hardware addresses have differing lengths of 21 & 22 (must be matching)."),
        ];
        for test in tests {
            assert_eq!(format!("{}", test.0), test.1);
        }
    }

    #[cfg(feature = "std")]
    #[test]
    fn source() {
        assert!(LenTooBig(300).source().is_none());
    }
}
