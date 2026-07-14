use crate::*;

/// IEEE 802.1Q VLAN Tagging Header (can be single or double tagged).
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum VlanHeader {
    /// IEEE 802.1Q VLAN Tagging Header
    Single(SingleVlanHeader),
    /// IEEE 802.1Q double VLAN Tagging Header
    Double(DoubleVlanHeader),
}

impl VlanHeader {
    /// All ether types that identify a vlan header.
    pub const VLAN_ETHER_TYPES: [EtherType; 3] = [
        ether_type::VLAN_TAGGED_FRAME,
        ether_type::PROVIDER_BRIDGING,
        ether_type::VLAN_DOUBLE_TAGGED_FRAME,
    ];

    /// Returns the ether type of the next header after the vlan header(s).
    #[inline]
    pub fn next_header(&self) -> EtherType {
        match self {
            VlanHeader::Single(s) => s.ether_type,
            VlanHeader::Double(d) => d.inner.ether_type,
        }
    }
}

#[cfg(test)]
mod test {
    use super::*;
    use crate::test_gens::*;
    use alloc::format;
    use proptest::prelude::*;

    #[test]
    fn constants() {
        use ether_type::*;
        use VlanHeader as V;

        assert_eq!(3, V::VLAN_ETHER_TYPES.len());
        assert_eq!(VLAN_TAGGED_FRAME, V::VLAN_ETHER_TYPES[0]);
        assert_eq!(PROVIDER_BRIDGING, V::VLAN_ETHER_TYPES[1]);
        assert_eq!(VLAN_DOUBLE_TAGGED_FRAME, V::VLAN_ETHER_TYPES[2]);
    }

    proptest! {
        #[test]
        fn clone_eq(
            single in vlan_single_any(),
            double in vlan_double_any(),
        ) {
            // single eq
            {
                let value = VlanHeader::Single(single.clone());
                assert_eq!(value, value.clone());
            }
            // double
            {
                let value = VlanHeader::Double(double);
                assert_eq!(value, value.clone());
            }
        }
    }

    proptest! {
        #[test]
        fn dbg(
            single in vlan_single_any(),
            double in vlan_double_any(),
        ) {
            // single
            {
                let value = VlanHeader::Single(single.clone());
                assert_eq!(
                    &format!(
                        "Single({:?})",
                        single
                    ),
                    &format!("{:?}", value)
                );
            }
            // double
            {
                let value = VlanHeader::Double(double.clone());
                assert_eq!(
                    &format!(
                        "Double({:?})",
                        double
                    ),
                    &format!("{:?}", value)
                );
            }
        }
    }

    proptest! {
        #[test]
        fn next_header(
            single in vlan_single_any(),
            double in vlan_double_any(),
        ) {
            // single
            {
                let value = VlanHeader::Single(single.clone());
                assert_eq!(value.next_header(), single.ether_type);
            }
            // double
            {
                let value = VlanHeader::Double(double.clone());
                assert_eq!(value.next_header(), double.inner.ether_type);
            }
        }
    }
}
