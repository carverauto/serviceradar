use crate::ArpHardwareId;

/// Errors in an Linux Cooked Capture header encountered while decoding it.
#[derive(Clone, Debug, Eq, PartialEq, Hash)]
pub enum HeaderError {
    /// Error when the "packet byte" field is not one of the known ones
    UnsupportedPacketTypeField {
        // The unexpected packet type number in the SLL header
        packet_type: u16,
    },
    /// Error when the arp hardware type field is not one of the known ones
    UnsupportedArpHardwareId { arp_hardware_type: ArpHardwareId },
}

impl core::fmt::Display for HeaderError {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        use HeaderError::*;
        match self {
            UnsupportedPacketTypeField { packet_type } => write!(f, "Linux cooked capture v1 (SLL) Header Error: Encountered '{packet_type}' as the packet type, but its not supported."),
            UnsupportedArpHardwareId { arp_hardware_type } => write!(f, "Linux cooked capture v1 (SLL)  Header Error:  Encountered '{arp_hardware_type:?}' as the ARP harware type, but its not supported."),
        }
    }
}

impl core::error::Error for HeaderError {
    fn source(&self) -> Option<&(dyn core::error::Error + 'static)> {
        use HeaderError::*;
        match self {
            UnsupportedPacketTypeField { packet_type: _ } => None,
            UnsupportedArpHardwareId {
                arp_hardware_type: _,
            } => None,
        }
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
        assert_eq!(
            "UnsupportedPacketTypeField { packet_type: 6 }",
            format!("{:?}", UnsupportedPacketTypeField { packet_type: 6 })
        );
    }

    #[test]
    fn clone_eq_hash() {
        let err = HeaderError::UnsupportedPacketTypeField { packet_type: 6 };
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
            "Linux cooked capture v1 (SLL) Header Error: Encountered '6' as the packet type, but its not supported.",
            format!("{}", UnsupportedPacketTypeField{ packet_type: 6 })
        );
        assert_eq!(
            "Linux cooked capture v1 (SLL)  Header Error:  Encountered '1 (Ethernet)' as the ARP harware type, but its not supported.",
            format!("{}", UnsupportedArpHardwareId{ arp_hardware_type: ArpHardwareId::ETHERNET })
        );
    }

    #[cfg(feature = "std")]
    #[test]
    fn source() {
        let values = [
            UnsupportedPacketTypeField { packet_type: 6 },
            UnsupportedArpHardwareId {
                arp_hardware_type: ArpHardwareId::ETHERNET,
            },
        ];
        for v in values {
            assert!(v.source().is_none());
        }
    }
}
