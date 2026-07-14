/// Represents an "ether type" present in a Ethernet II header.
///
/// You can access the underlying `u16` value by using `.0` and any `u16`
/// can be converted to an `EtherType`:
///
/// ```
/// use etherparse::EtherType;
///
/// assert_eq!(EtherType::IPV4.0, 0x0800);
/// assert_eq!(EtherType::IPV4, EtherType(0x0800));
///
/// // convert to EtherType using the from & into trait
/// let ether_type: EtherType = 0x0800.into();
/// assert_eq!(EtherType::IPV4, ether_type);
///
/// // convert to u16 using the from & into trait
/// let num: u16 = EtherType::IPV4.into();
/// assert_eq!(0x0800, num);
/// ```
///
/// The constants are also defined in the `ether_type` module so they can
/// be used without the need to write `EtherType::` in front of them:
///
/// ```
/// use etherparse::{ether_type::IPV4, EtherType};
///
/// assert_eq!(IPV4, EtherType::IPV4);
/// ```
///
#[derive(Default, PartialEq, Eq, Clone, Copy, Hash, Ord, PartialOrd)]
pub struct EtherType(pub u16);

impl EtherType {
    pub const IPV4: EtherType = Self(0x0800);
    pub const IPV6: EtherType = Self(0x86dd);
    pub const ARP: EtherType = Self(0x0806);
    pub const WAKE_ON_LAN: EtherType = Self(0x0842);
    pub const VLAN_TAGGED_FRAME: EtherType = Self(0x8100);
    pub const PROVIDER_BRIDGING: EtherType = Self(0x88A8);

    /// IEEE Std 802.1AE - Media Access Control Security
    pub const MACSEC: EtherType = Self(0x88E5);
    pub const VLAN_DOUBLE_TAGGED_FRAME: EtherType = Self(0x9100);
}

impl From<u16> for EtherType {
    #[inline]
    fn from(val: u16) -> Self {
        EtherType(val)
    }
}

impl From<EtherType> for u16 {
    #[inline]
    fn from(val: EtherType) -> Self {
        val.0
    }
}

impl core::fmt::Debug for EtherType {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        match *self {
            Self::IPV4 => write!(f, "{:#06X} (Internet Protocol version 4 (IPv4))", self.0),
            Self::IPV6 => write!(f, "{:#06X} (Internet Protocol Version 6 (IPV6))", self.0),
            Self::ARP => write!(f, "{:#06X} (Address Resolution Protocol (ARP))", self.0),
            Self::WAKE_ON_LAN => write!(f, "{:#06X} (Wake on LAN)", self.0),
            Self::VLAN_TAGGED_FRAME => write!(
                f,
                "{:#06X} (Customer VLAN Tag (C-TAG) as defined in IEEE Std 802.1Q)",
                self.0
            ),
            Self::PROVIDER_BRIDGING => write!(
                f,
                "{:#06X} (IEEE Std 802.1Q - Service VLAN tag identifier (S-Tag))",
                self.0
            ),
            Self::MACSEC => write!(
                f,
                "{:#06X} (IEEE Std 802.1AE - Media Access Control Security)",
                self.0
            ),
            Self::VLAN_DOUBLE_TAGGED_FRAME => {
                write!(f, "{:#06X} (VLAN Double Tagged Frame)", self.0)
            }
            _ => write!(f, "{:#06X}", self.0),
        }
    }
}

/// Constants for the ethertype values for easy importing (e.g. `use ether_type::*;`).
///
/// The constants only exist for convenience so you can import them
/// (`use ether_type::*`) without a need to write `EtherType::` in front
/// of every constant.
///
/// You can access the underlying `u16` value by using `.0` and any `u16`
/// can be converted to an `EtherType`:
///
/// ```
/// use etherparse::{ether_type::IPV4, EtherType};
///
/// assert_eq!(IPV4.0, 0x0800);
/// assert_eq!(IPV4, EtherType(0x0800));
/// let num: EtherType = 0x0800.into();
/// assert_eq!(IPV4, num);
/// ```
pub mod ether_type {
    use super::EtherType;

    pub const IPV4: EtherType = EtherType::IPV4;
    pub const IPV6: EtherType = EtherType::IPV6;
    pub const ARP: EtherType = EtherType::ARP;
    pub const WAKE_ON_LAN: EtherType = EtherType::WAKE_ON_LAN;
    pub const VLAN_TAGGED_FRAME: EtherType = EtherType::VLAN_TAGGED_FRAME;
    pub const PROVIDER_BRIDGING: EtherType = EtherType::PROVIDER_BRIDGING;

    /// IEEE Std 802.1AE - Media Access Control Security
    pub const MACSEC: EtherType = EtherType::MACSEC;
    pub const VLAN_DOUBLE_TAGGED_FRAME: EtherType = EtherType::VLAN_DOUBLE_TAGGED_FRAME;
}

#[cfg(test)]
mod test {
    use crate::{ether_type, EtherType};
    use alloc::format;

    #[test]
    fn to_u16() {
        assert_eq!(0x0800, u16::from(EtherType::IPV4));
        assert_eq!(0x86dd, u16::from(EtherType::IPV6));
        assert_eq!(0x0806, u16::from(EtherType::ARP));
        assert_eq!(0x0842, u16::from(EtherType::WAKE_ON_LAN));
        assert_eq!(0x8100, u16::from(EtherType::VLAN_TAGGED_FRAME));
        assert_eq!(0x88A8, u16::from(EtherType::PROVIDER_BRIDGING));
        assert_eq!(0x9100, u16::from(EtherType::VLAN_DOUBLE_TAGGED_FRAME));
    }

    #[test]
    fn from_u16() {
        assert_eq!(EtherType::from(0x0800), EtherType::IPV4);
        assert_eq!(EtherType::from(0x86dd), EtherType::IPV6);
        assert_eq!(EtherType::from(0x0806), EtherType::ARP);
        assert_eq!(EtherType::from(0x0842), EtherType::WAKE_ON_LAN);
        assert_eq!(EtherType::from(0x8100), EtherType::VLAN_TAGGED_FRAME);
        assert_eq!(EtherType::from(0x88A8), EtherType::PROVIDER_BRIDGING);
        assert_eq!(EtherType::from(0x9100), EtherType::VLAN_DOUBLE_TAGGED_FRAME);
        assert_eq!(EtherType::from(0x1234), EtherType(0x1234));
    }

    #[test]
    fn constants() {
        use ether_type::*;
        let pairs = &[
            (EtherType::IPV4, IPV4),
            (EtherType::IPV6, IPV6),
            (EtherType::ARP, ARP),
            (EtherType::WAKE_ON_LAN, WAKE_ON_LAN),
            (EtherType::VLAN_TAGGED_FRAME, VLAN_TAGGED_FRAME),
            (EtherType::MACSEC, MACSEC),
            (EtherType::PROVIDER_BRIDGING, PROVIDER_BRIDGING),
            (
                EtherType::VLAN_DOUBLE_TAGGED_FRAME,
                VLAN_DOUBLE_TAGGED_FRAME,
            ),
        ];

        for (ether_type, constant) in pairs {
            assert_eq!(ether_type, constant);
        }
    }

    #[test]
    fn dbg() {
        let pairs = &[
            (
                EtherType::IPV4,
                "0x0800 (Internet Protocol version 4 (IPv4))",
            ),
            (
                EtherType::IPV6,
                "0x86DD (Internet Protocol Version 6 (IPV6))",
            ),
            (EtherType::ARP, "0x0806 (Address Resolution Protocol (ARP))"),
            (EtherType::WAKE_ON_LAN, "0x0842 (Wake on LAN)"),
            (
                EtherType::VLAN_TAGGED_FRAME,
                "0x8100 (Customer VLAN Tag (C-TAG) as defined in IEEE Std 802.1Q)",
            ),
            (
                EtherType::PROVIDER_BRIDGING,
                "0x88A8 (IEEE Std 802.1Q - Service VLAN tag identifier (S-Tag))",
            ),
            (
                EtherType::MACSEC,
                "0x88E5 (IEEE Std 802.1AE - Media Access Control Security)",
            ),
            (
                EtherType::VLAN_DOUBLE_TAGGED_FRAME,
                "0x9100 (VLAN Double Tagged Frame)",
            ),
            (EtherType(1), "0x0001"),
        ];

        for (ether_type, str_value) in pairs {
            assert_eq!(str_value, &format!("{:?}", ether_type));
        }
    }

    #[test]
    fn default() {
        let value: EtherType = Default::default();
        assert_eq!(EtherType(0), value);
    }

    #[test]
    fn clone_eq() {
        let values = &[
            EtherType::IPV4,
            EtherType::IPV6,
            EtherType::ARP,
            EtherType::WAKE_ON_LAN,
            EtherType::VLAN_TAGGED_FRAME,
            EtherType::PROVIDER_BRIDGING,
            EtherType::VLAN_DOUBLE_TAGGED_FRAME,
        ];

        // clone
        for v in values {
            assert_eq!(v, &v.clone());
        }

        // eq
        for (a_pos, a) in values.iter().enumerate() {
            for (b_pos, b) in values.iter().enumerate() {
                assert_eq!(a_pos == b_pos, a == b);
                assert_eq!(a_pos != b_pos, a != b);
            }
        }
    }

    #[test]
    fn hash_ord() {
        use core::cmp::Ordering;
        use core::hash::{Hash, Hasher};
        use std::collections::hash_map::DefaultHasher;

        // hash
        let a_hash = {
            let mut s = DefaultHasher::new();
            EtherType::IPV4.hash(&mut s);
            s.finish()
        };
        let b_hash = {
            let mut s = DefaultHasher::new();
            EtherType::IPV4.hash(&mut s);
            s.finish()
        };
        assert_eq!(a_hash, b_hash);

        // order
        assert_eq!(
            EtherType::IPV4.cmp(&EtherType::IPV4.clone()),
            Ordering::Equal
        );
        assert!(EtherType::IPV4.ge(&EtherType::IPV4.clone()));
    }
}
