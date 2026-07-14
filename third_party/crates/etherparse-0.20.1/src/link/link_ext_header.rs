use super::*;

/// The possible headers on the link layer
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum LinkExtHeader {
    /// VLAN header.
    Vlan(SingleVlanHeader),

    /// MACsec header (SecTag + next ether type if available).
    Macsec(MacsecHeader),
}

impl LinkExtHeader {
    /// Returns the header length of the link extension.
    pub fn header_len(&self) -> usize {
        match self {
            LinkExtHeader::Vlan(s) => s.header_len(),
            LinkExtHeader::Macsec(m) => m.header_len(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::test_gens::*;
    use alloc::format;
    use proptest::prelude::*;

    proptest! {
        #[test]
        fn debug_clone_eq(ref vlan in vlan_single_any()) {
            let header = LinkExtHeader::Vlan(vlan.clone());

            // clone & eq
            assert_eq!(header.clone(), header);

            // debug
            assert_eq!(
                format!("{:?}", header),
                format!("Vlan({:?})", vlan),
            );
        }
    }

    proptest! {
        #[test]
        fn header_len(
            vlan in vlan_single_any(),
            macsec in macsec_any()
        ) {
            // vlan
            {
                let header = LinkExtHeader::Vlan(vlan.clone());
                assert_eq!(header.header_len(), vlan.header_len());
            }

            // macsec
            {
                let header = LinkExtHeader::Macsec(macsec.clone());
                assert_eq!(header.header_len(), macsec.header_len());
            }
        }
    }
}
