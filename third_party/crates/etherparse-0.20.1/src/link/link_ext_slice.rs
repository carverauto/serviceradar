use crate::*;

/// A slice containing the link layer extension header (currently only Ethernet II and
/// SLL are supported).
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum LinkExtSlice<'a> {
    /// Slice containing a VLAN header & payload.
    Vlan(SingleVlanSlice<'a>),

    /// Slice containing MACsec header & payload.
    Macsec(MacsecSlice<'a>),
}

impl<'a> LinkExtSlice<'a> {
    /// Returns the header length of the link extension.
    pub fn header_len(&self) -> usize {
        match self {
            LinkExtSlice::Vlan(s) => s.header_len(),
            LinkExtSlice::Macsec(m) => m.header.header_len(),
        }
    }

    /// Convert the header part of the link extension into a [`LinkExtHeader`].
    pub fn to_header(&self) -> LinkExtHeader {
        match self {
            LinkExtSlice::Vlan(s) => LinkExtHeader::Vlan(s.to_header()),
            LinkExtSlice::Macsec(m) => LinkExtHeader::Macsec(m.header.to_header()),
        }
    }

    /// Return the payload of the link extensions.
    pub fn ether_payload(&self) -> Option<EtherPayloadSlice<'a>> {
        match self {
            LinkExtSlice::Vlan(s) => Some(s.payload()),
            LinkExtSlice::Macsec(m) => {
                if let MacsecPayloadSlice::Unmodified(p) = &m.payload {
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
    use arrayvec::ArrayVec;
    use proptest::prelude::*;

    proptest! {
        #[test]
        fn debug_clone_eq(ref vlan in vlan_single_any()) {
            let bytes = vlan.to_bytes();
            let e = SingleVlanSlice::from_slice(&bytes).unwrap();
            let slice = LinkExtSlice::Vlan(
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
            macsec in macsec_any()
        ) {
            // vlan
            {
                let bytes = vlan.to_bytes();
                let e = SingleVlanSlice::from_slice(&bytes).unwrap();
                let slice = LinkExtSlice::Vlan(
                    e.clone()
                );
                assert_eq!(slice.header_len(), e.header_len());
            }
            // macsec
            {
                let mut macsec = macsec.clone();
                macsec.short_len = MacsecShortLen::ZERO;
                let mut bytes = ArrayVec::<u8, {MacsecHeader::MAX_LEN}>::new();
                bytes.try_extend_from_slice(&macsec.to_bytes()).unwrap();
                let e = MacsecSlice::from_slice(&bytes).unwrap();
                let slice = LinkExtSlice::Macsec(
                    e.clone()
                );
                assert_eq!(slice.header_len(), macsec.header_len());
            }
        }
    }

    proptest! {
        #[test]
        fn to_header(
            vlan in vlan_single_any(),
            macsec in macsec_any()
        ) {
            // vlan
            {
                let bytes = vlan.to_bytes();
                let e = SingleVlanSlice::from_slice(&bytes).unwrap();
                let slice = LinkExtSlice::Vlan(
                    e.clone()
                );
                assert_eq!(slice.to_header(), LinkExtHeader::Vlan(e.to_header()));
            }
            // macsec
            {
                let mut macsec = macsec.clone();
                macsec.short_len = MacsecShortLen::ZERO;
                let mut bytes = ArrayVec::<u8, {MacsecHeader::MAX_LEN}>::new();
                bytes.try_extend_from_slice(&macsec.to_bytes()).unwrap();
                let e = MacsecSlice::from_slice(&bytes).unwrap();
                let slice = LinkExtSlice::Macsec(
                    e.clone()
                );
                assert_eq!(slice.to_header(), LinkExtHeader::Macsec(macsec.clone()));
            }
        }
    }

    proptest! {
        #[test]
        fn ether_payload(
            vlan in vlan_single_any(),
            macsec in macsec_any(),
            ether_type in ether_type_any(),
        ) {
            // vlan
            {
                let payload = [1,2,3,4];
                let mut bytes = Vec::with_capacity(SingleVlanHeader::LEN + 4);
                bytes.extend_from_slice(&vlan.to_bytes());
                bytes.extend_from_slice(&payload);
                let e = SingleVlanSlice::from_slice(&bytes).unwrap();
                let slice = LinkExtSlice::Vlan(
                    e.clone()
                );
                assert_eq!(
                    slice.ether_payload(),
                    Some(EtherPayloadSlice{
                        ether_type: vlan.ether_type,
                        len_source: LenSource::Slice,
                        payload: &payload
                    })
                );
            }
            // macsec (unmodified)
            {
                let mut macsec = macsec.clone();
                macsec.ptype = MacsecPType::Unmodified(ether_type);
                macsec.short_len = MacsecShortLen::ZERO;
                let payload = [1,2,3,4];
                let mut bytes = ArrayVec::<u8, {MacsecHeader::MAX_LEN + 4}>::new();
                bytes.try_extend_from_slice(&macsec.to_bytes()).unwrap();
                bytes.try_extend_from_slice(&payload).unwrap();
                let e = MacsecSlice::from_slice(&bytes).unwrap();
                let slice = LinkExtSlice::Macsec(
                    e.clone()
                );
                assert_eq!(
                    slice.ether_payload(),
                    Some(EtherPayloadSlice{
                        ether_type,
                        len_source: LenSource::Slice,
                        payload: &payload,
                    })
                );
            }
            // macsec (modified)
            for ptype in [MacsecPType::Modified, MacsecPType::Encrypted, MacsecPType::EncryptedUnmodified] {
                let mut macsec = macsec.clone();
                macsec.ptype = ptype;
                macsec.short_len = MacsecShortLen::ZERO;
                let payload = [1,2,3,4];
                let mut bytes = ArrayVec::<u8, {MacsecHeader::MAX_LEN + 4}>::new();
                bytes.try_extend_from_slice(&macsec.to_bytes()).unwrap();
                bytes.try_extend_from_slice(&payload).unwrap();
                let e = MacsecSlice::from_slice(&bytes).unwrap();
                let slice = LinkExtSlice::Macsec(
                    e.clone()
                );
                assert_eq!(slice.ether_payload(), None);
            }
        }
    }
}
