use crate::*;

/// IEEE 802.1Q double VLAN Tagging Header (helper struct to
/// check vlan tagging values in a [crate::`PacketHeaders`]).
///
/// Note that it is NOT guranteed that the two VLAN headers
/// will directly follow each other. In the original packet
/// there could be another LinkExt header present in between
/// them (e.g. MacSec Security Tag).
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct DoubleVlanHeader {
    /// The outer vlan tagging header
    pub outer: SingleVlanHeader,
    /// The inner vlan tagging header
    pub inner: SingleVlanHeader,
}

impl Default for DoubleVlanHeader {
    fn default() -> Self {
        DoubleVlanHeader {
            outer: SingleVlanHeader {
                pcp: VlanPcp::ZERO,
                drop_eligible_indicator: false,
                vlan_id: Default::default(),
                ether_type: ether_type::VLAN_TAGGED_FRAME,
            },
            inner: Default::default(),
        }
    }
}

#[cfg(test)]
mod test {
    use crate::{test_gens::*, *};
    use alloc::format;
    use proptest::prelude::*;

    #[test]
    fn default() {
        let actual: DoubleVlanHeader = Default::default();
        assert_eq!(actual.outer, {
            let mut outer: SingleVlanHeader = Default::default();
            outer.ether_type = ether_type::VLAN_TAGGED_FRAME;
            outer
        });
        assert_eq!(actual.inner, Default::default());
    }

    proptest! {
        #[test]
        fn clone_eq(input in vlan_double_any()) {
            assert_eq!(input, input.clone());
        }
    }

    proptest! {
        #[test]
        fn dbg(input in vlan_double_any()) {
            assert_eq!(
                &format!(
                    "DoubleVlanHeader {{ outer: {:?}, inner: {:?} }}",
                    input.outer,
                    input.inner,
                ),
                &format!("{:?}", input)
            );
        }
    }
}
