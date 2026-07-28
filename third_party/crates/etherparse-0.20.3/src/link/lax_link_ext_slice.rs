use crate::*;

/// A slice containing the link layer extension header (currently only Ethernet II and
/// SLL are supported).
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum LaxLinkExtSlice<'a> {
    /// Slice containing a VLAN header & payload.
    Vlan(SingleVlanSlice<'a>),

    /// Slice containing MACsec header & payload.
    Macsec(LaxMacsecSlice<'a>),
}

impl<'a> LaxLinkExtSlice<'a> {
    /// Returns the header length of the link extension.
    pub fn header_len(&self) -> usize {
        match self {
            LaxLinkExtSlice::Vlan(s) => s.header_len(),
            LaxLinkExtSlice::Macsec(m) => m.header.header_len(),
        }
    }

    /// Convert the header part of the link extension into a [`LinkExtHeader`].
    pub fn to_header(&self) -> LinkExtHeader {
        match self {
            LaxLinkExtSlice::Vlan(s) => LinkExtHeader::Vlan(s.to_header()),
            LaxLinkExtSlice::Macsec(m) => LinkExtHeader::Macsec(m.header.to_header()),
        }
    }

    /// Return the payload of the link extensions.
    pub fn payload(&self) -> Option<LaxEtherPayloadSlice<'a>> {
        match self {
            LaxLinkExtSlice::Vlan(s) => {
                let p = s.payload();
                Some(LaxEtherPayloadSlice {
                    incomplete: false,
                    ether_type: p.ether_type,
                    len_source: p.len_source,
                    payload: p.payload,
                })
            }
            LaxLinkExtSlice::Macsec(m) => {
                if let LaxMacsecPayloadSlice::Unmodified(p) = &m.payload {
                    Some(p.clone())
                } else {
                    None
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::test_gens::*;
    use alloc::{format, vec::Vec};
    use proptest::prelude::*;

    proptest! {
        #[test]
        fn debug_clone_eq(ref vlan in vlan_single_any()) {
            let bytes = vlan.to_bytes();
            let e = SingleVlanSlice::from_slice(&bytes).unwrap();
            let slice = LaxLinkExtSlice::Vlan(
                e.clone()
            );

            // clone & eq
            assert_eq!(slice.clone(), slice);

            // debug
            assert_eq!(
                format!("{:?}", slice),
                format!("Vlan({:?})", e),
            );
        }
    }

    proptest! {
        #[test]
        fn header_len(
            vlan in vlan_single_any(),
            macsec in macsec_any(),
        ) {
            // vlan
            {
                let bytes = vlan.to_bytes();
                let e = SingleVlanSlice::from_slice(&bytes).unwrap();
                let slice = LaxLinkExtSlice::Vlan(
                    e.clone()
                );
                assert_eq!(slice.header_len(), e.header_len());
            }
            // macsec
            {
                let mut macsec = macsec.clone();
                macsec.short_len = MacsecShortLen::ZERO;
                let bytes = macsec.to_bytes();
                let m = LaxMacsecSlice::from_slice(&bytes).unwrap();
                let slice = LaxLinkExtSlice::Macsec(m.clone());
                assert_eq!(slice.header_len(), macsec.header_len());
            }
        }
    }

    proptest! {
        #[test]
        fn to_header(
            vlan in vlan_single_any(),
            macsec in macsec_any(),
        ) {
            // vlan
            {
                let bytes = vlan.to_bytes();
                let e = SingleVlanSlice::from_slice(&bytes).unwrap();
                let slice = LaxLinkExtSlice::Vlan(
                    e.clone()
                );
                assert_eq!(slice.to_header(), LinkExtHeader::Vlan(e.to_header()));
            }
            // macsec
            {
                let mut macsec = macsec.clone();
                macsec.short_len = MacsecShortLen::ZERO;
                let bytes = macsec.to_bytes();
                let m = LaxMacsecSlice::from_slice(&bytes).unwrap();
                let slice = LaxLinkExtSlice::Macsec(m.clone());
                assert_eq!(slice.to_header(), LinkExtHeader::Macsec(macsec.clone()));
            }
        }
    }

    proptest! {
        #[test]
        fn payload(
            vlan in vlan_single_any(),
            macsec in macsec_any(),
            ethertype in ether_type_any(),
        ) {
            // vlan
            {
                let payload = [1,2,3,4];
                let mut bytes = Vec::with_capacity(SingleVlanHeader::LEN + 4);
                bytes.extend_from_slice(&vlan.to_bytes());
                bytes.extend_from_slice(&payload);
                let e = SingleVlanSlice::from_slice(&bytes).unwrap();
                let slice = LaxLinkExtSlice::Vlan(
                    e.clone()
                );
                assert_eq!(
                    slice.payload(),
                    Some(LaxEtherPayloadSlice{
                        incomplete: false,
                        ether_type: vlan.ether_type,
                        len_source: LenSource::Slice,
                        payload: &payload
                    })
                );
            }
            // macsec (unmodified, complete)
            {
                let mut macsec = macsec.clone();
                macsec.ptype = MacsecPType::Unmodified(ethertype);
                macsec.short_len = MacsecShortLen::try_from(8 + 2).unwrap();
                let payload = [1,2,3,4,5,6,7,8];
                let mut bytes = Vec::with_capacity(macsec.header_len() + 8);
                bytes.extend_from_slice(&macsec.to_bytes());
                bytes.extend_from_slice(&payload);
                let m = LaxMacsecSlice::from_slice(&bytes).unwrap();
                let slice = LaxLinkExtSlice::Macsec(
                    m.clone()
                );
                prop_assert_eq!(
                    slice.payload(),
                    Some(LaxEtherPayloadSlice{
                        incomplete: false,
                        ether_type: ethertype,
                        len_source: LenSource::MacsecShortLength,
                        payload: &payload
                    })
                );
            }
            // macsec (unmodified, incomplete)
            {
                let payload = [1,2,3,4,5,6,7];
                let mut macsec = macsec.clone();
                macsec.ptype = MacsecPType::Unmodified(ethertype);
                macsec.set_payload_len(payload.len() + 1);
                let mut bytes = Vec::with_capacity(macsec.header_len() + payload.len());
                bytes.extend_from_slice(&macsec.to_bytes());
                bytes.extend_from_slice(&payload);
                let m = LaxMacsecSlice::from_slice(&bytes).unwrap();
                let slice = LaxLinkExtSlice::Macsec(
                    m.clone()
                );
                prop_assert_eq!(
                    slice.payload(),
                    Some(LaxEtherPayloadSlice{
                        incomplete: true,
                        ether_type: ethertype,
                        len_source: LenSource::Slice,
                        payload: &payload
                    })
                );
            }
            // macsec (modified)
            {
                let mut macsec = macsec.clone();
                macsec.ptype = MacsecPType::Modified;
                macsec.short_len = MacsecShortLen::try_from(1).unwrap();
                let payload = [1,2,3,4,5,6,7,8];
                let mut bytes = Vec::with_capacity(macsec.header_len() + 8);
                bytes.extend_from_slice(&macsec.to_bytes());
                bytes.extend_from_slice(&payload);
                let m = LaxMacsecSlice::from_slice(&bytes).unwrap();
                let slice = LaxLinkExtSlice::Macsec(
                    m.clone()
                );
                prop_assert_eq!(
                    slice.payload(),
                    None
                );
            }
        }
    }
}
