use super::{ArpHwAddrError, ArpProtoAddrError};

/// Error while creating a new [`crate::ArpPacket`].
#[derive(Debug, Clone, Eq, PartialEq, Hash)]
pub enum ArpNewError {
    /// Error in the given hardware addresses.
    HwAddr(ArpHwAddrError),

    /// Error in the given protocol addresses.
    ProtoAddr(ArpProtoAddrError),
}

impl core::fmt::Display for ArpNewError {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        match self {
            ArpNewError::HwAddr(err) => err.fmt(f),
            ArpNewError::ProtoAddr(err) => err.fmt(f),
        }
    }
}

impl core::error::Error for ArpNewError {
    fn source(&self) -> Option<&(dyn core::error::Error + 'static)> {
        None
    }
}

#[cfg(test)]
mod tests {
    use crate::err::arp::{ArpHwAddrError, ArpProtoAddrError};

    use super::ArpNewError::*;
    use alloc::format;
    use std::{
        collections::hash_map::DefaultHasher,
        error::Error,
        hash::{Hash, Hasher},
    };

    #[test]
    fn debug() {
        assert_eq!(
            "HwAddr(LenTooBig(300))",
            format!("{:?}", HwAddr(ArpHwAddrError::LenTooBig(300)))
        );
    }

    #[test]
    fn clone_eq_hash() {
        let err = HwAddr(ArpHwAddrError::LenTooBig(300));
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
            (HwAddr(ArpHwAddrError::LenTooBig(300)), "ARP Hardware Address Error: Given hardware address has a length of 300 which is greater then the maximum of 255."),
            (ProtoAddr(ArpProtoAddrError::LenTooBig(301)), "ARP Protocol Address Error: Given protocol address has a length of 301 which is greater then the maximum of 255."),
            (HwAddr(ArpHwAddrError::LenNonMatching(21, 22)), "ARP Hardware Address Error: Given sender & target hardware addresses have differing lengths of 21 & 22 (must be matching)."),
            (ProtoAddr(ArpProtoAddrError::LenNonMatching(23, 24)), "ARP Protocol Address Error: Given sender & target protocol addresses have differing lengths of 23 & 24 (must be matching).")
        ];
        for test in tests {
            assert_eq!(format!("{}", test.0), test.1);
        }
    }

    #[cfg(feature = "std")]
    #[test]
    fn source() {
        assert!(HwAddr(ArpHwAddrError::LenTooBig(300)).source().is_none());
    }
}
