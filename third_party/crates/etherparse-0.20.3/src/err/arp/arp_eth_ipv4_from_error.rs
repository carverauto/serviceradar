use crate::*;

/// Error while converting an [`crate::ArpPacket`] to an [`crate::ArpEthIpv4Packet`].
#[derive(Debug, Clone, Eq, PartialEq, Hash)]
pub enum ArpEthIpv4FromError {
    /// Error if `hw_addr_type` is not [`crate::ArpHardwareId::ETHERNET`].
    NonMatchingHwType(ArpHardwareId),

    /// Error if `proto_addr_type` is not [`crate::EtherType::IPV4`].
    NonMatchingProtocolType(EtherType),

    /// Error if `hw_addr_size` is not `6`
    NonMatchingHwAddrSize(u8),

    /// Error if `hw_addr_size` is not `6`
    NonMatchingProtoAddrSize(u8),
}

impl core::fmt::Display for ArpEthIpv4FromError {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        match self {
            ArpEthIpv4FromError::NonMatchingHwType(t) =>
                write!(f, "Hardware address type is expected to have the type '1 (Ethernet)' but is '{t:?}'"),
            ArpEthIpv4FromError::NonMatchingProtocolType(t) =>
                write!(f, "Protocol address type is expected to have the type '0x0800 (Internet Protocol version 4 (IPv4))' but is '{t:?}'"),
            ArpEthIpv4FromError::NonMatchingHwAddrSize(len) =>
                write!(f, "Hardware address size is expected to be 6 but is {len}"),
            ArpEthIpv4FromError::NonMatchingProtoAddrSize(len) =>
                write!(f, "Protocol address size is expected to be 4 but is {len}"),
        }
    }
}

impl core::error::Error for ArpEthIpv4FromError {
    fn source(&self) -> Option<&(dyn core::error::Error + 'static)> {
        None
    }
}

#[cfg(test)]
mod tests {
    use super::{ArpEthIpv4FromError::*, ArpHardwareId, EtherType};
    use alloc::format;
    use std::{
        collections::hash_map::DefaultHasher,
        error::Error,
        hash::{Hash, Hasher},
    };

    #[test]
    fn debug() {
        assert_eq!(
            "NonMatchingProtoAddrSize(3)",
            format!("{:?}", NonMatchingProtoAddrSize(3))
        );
    }

    #[test]
    fn clone_eq_hash() {
        let err = NonMatchingProtoAddrSize(3);
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
            (NonMatchingHwType(ArpHardwareId::CHAOS), "Hardware address type is expected to have the type '1 (Ethernet)' but is '5 (Chaosnet)'"),
            (NonMatchingProtocolType(EtherType::IPV6), "Protocol address type is expected to have the type '0x0800 (Internet Protocol version 4 (IPv4))' but is '0x86DD (Internet Protocol Version 6 (IPV6))'"),
            (NonMatchingHwAddrSize(21), "Hardware address size is expected to be 6 but is 21"),
            (NonMatchingProtoAddrSize(22), "Protocol address size is expected to be 4 but is 22")
        ];
        for test in tests {
            assert_eq!(format!("{}", test.0), test.1);
        }
    }

    #[cfg(feature = "std")]
    #[test]
    fn source() {
        assert!(NonMatchingProtoAddrSize(3).source().is_none());
    }
}
