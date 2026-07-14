use crate::*;

/// A slice containing the link layer header (currently only Ethernet II and
/// SLL are supported).
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum LinkSlice<'a> {
    /// A slice containing an Ethernet II header.
    Ethernet2(Ethernet2Slice<'a>),

    /// A slice containing a Linux Cooked Capture v1 (SLL) header.
    LinuxSll(LinuxSllSlice<'a>),

    /// Ether payload without header.
    EtherPayload(EtherPayloadSlice<'a>),

    /// Sll payload without header.
    LinuxSllPayload(LinuxSllPayloadSlice<'a>),
}

impl<'a> LinkSlice<'a> {
    /// Convert the link slice to a header
    pub fn to_header(&self) -> Option<LinkHeader> {
        use LinkSlice::*;
        match self {
            Ethernet2(slice) => Some(LinkHeader::Ethernet2(slice.to_header())),
            LinuxSll(slice) => Some(LinkHeader::LinuxSll(slice.to_header())),
            EtherPayload(_) => None,
            LinuxSllPayload(_) => None,
        }
    }

    /// Returns the link layer ether payload (slice + ether type number).
    pub fn ether_payload(&self) -> Option<EtherPayloadSlice<'a>> {
        use LinkSlice::*;
        match self {
            Ethernet2(s) => Some(s.payload().clone()),
            LinuxSll(s) => Some(EtherPayloadSlice::try_from(s.payload()).ok()?.clone()),
            EtherPayload(p) => Some(p.clone()),
            LinuxSllPayload(p) => Some(EtherPayloadSlice::try_from(p.clone()).ok()?),
        }
    }

    /// Returns the link layer sll payload (slice + link layer protocol type).
    pub fn sll_payload(&self) -> LinuxSllPayloadSlice<'a> {
        use LinkSlice::*;
        match self {
            Ethernet2(s) => LinuxSllPayloadSlice::from(s.payload().clone()),
            LinuxSll(s) => s.payload().clone(),
            EtherPayload(p) => LinuxSllPayloadSlice::from(p.clone()),
            LinuxSllPayload(p) => p.clone(),
        }
    }
}

#[cfg(test)]
mod test {
    use super::*;
    use crate::test_gens::*;
    use alloc::{format, vec::Vec};
    use proptest::prelude::*;

    proptest! {
        #[test]
        fn debug_clone_eq(ref eth in ethernet_2_unknown()) {
            let bytes = eth.to_bytes();
            let e = Ethernet2Slice::from_slice_without_fcs(&bytes).unwrap();
            let slice = LinkSlice::Ethernet2(
                e.clone()
            );

            // clone & eq
            assert_eq!(slice.clone(), slice);

            // debug
            assert_eq!(
                format!("{:?}", slice),
                format!("Ethernet2({:?})", e),
            );
        }
    }

    proptest! {
        #[test]
        fn to_header(
            ref eth in ethernet_2_unknown(),
            ref linux_sll in linux_sll_any()
        ) {
            {
                let bytes = eth.to_bytes();
                let slice = LinkSlice::Ethernet2(
                    Ethernet2Slice::from_slice_without_fcs(&bytes).unwrap()
                );
                assert_eq!(
                    slice.to_header(),
                    Some(LinkHeader::Ethernet2(eth.clone()))
                );
            }
            {
                let bytes = linux_sll.to_bytes();
                let slice = LinkSlice::LinuxSll(
                    LinuxSllSlice::from_slice(&bytes).unwrap()
                );
                assert_eq!(
                    slice.to_header(),
                    Some(LinkHeader::LinuxSll(linux_sll.clone()))
                );
            }
            {
                let slice = LinkSlice::EtherPayload(EtherPayloadSlice {
                    ether_type: ether_type::IPV4,
                    len_source: LenSource::Slice,
                    payload: &[]
                });
                assert_eq!(
                    slice.to_header(),
                    None
                );
            }
            {
                let slice = LinkSlice::LinuxSllPayload(LinuxSllPayloadSlice {
                    protocol_type: LinuxSllProtocolType::EtherType(ether_type::IPV4),
                    payload: &[]
                });
                assert_eq!(
                    slice.to_header(),
                    None
                );
            }
        }
    }

    proptest! {
        #[test]
        fn ether_payload(
            ref eth in ethernet_2_unknown(),
            ref linux_sll in linux_sll_any()
        ) {
            let p = [1,2,3,4];
            {
                let mut bytes = Vec::with_capacity(Ethernet2Header::LEN + p.len());
                bytes.extend_from_slice(&eth.to_bytes());
                bytes.extend_from_slice(&p);
                let slice = LinkSlice::Ethernet2(
                    Ethernet2Slice::from_slice_without_fcs(&bytes).unwrap()
                );
                assert_eq!(
                    slice.ether_payload().unwrap(),
                    EtherPayloadSlice{
                        ether_type: eth.ether_type,
                        len_source: LenSource::Slice,
                        payload: &p
                    }
                );
            }
            {
                let slice = LinkSlice::EtherPayload(EtherPayloadSlice {
                    ether_type: eth.ether_type,
                    len_source: LenSource::Slice,
                    payload: &p
                });
                assert_eq!(
                    slice.ether_payload().unwrap(),
                    EtherPayloadSlice{
                        ether_type: eth.ether_type,
                        len_source: LenSource::Slice,
                        payload: &p
                    }
                );
            }
            {
                let mut bytes = Vec::with_capacity(LinuxSllHeader::LEN + p.len());
                bytes.extend_from_slice(&linux_sll.to_bytes());
                bytes.extend_from_slice(&p);
                let slice = LinkSlice::LinuxSll(
                    LinuxSllSlice::from_slice(&bytes).unwrap()
                );
                match linux_sll.protocol_type {
                    LinuxSllProtocolType::EtherType(EtherType(v)) | LinuxSllProtocolType::LinuxNonstandardEtherType(LinuxNonstandardEtherType(v)) => { assert_eq!(
                            slice.ether_payload().unwrap(),
                            EtherPayloadSlice{
                                ether_type: EtherType(v),
                                len_source: LenSource::Slice,
                                payload: &p,
                            }
                    );}
                    _ => { assert!(slice.ether_payload().is_none());}
                }
            }
            {
                let slice = LinkSlice::LinuxSllPayload(LinuxSllPayloadSlice {
                    protocol_type: linux_sll.protocol_type,
                    payload: &p
                });
                match linux_sll.protocol_type {
                    LinuxSllProtocolType::EtherType(EtherType(v)) | LinuxSllProtocolType::LinuxNonstandardEtherType(LinuxNonstandardEtherType(v)) => { assert_eq!(
                        slice.ether_payload().unwrap(),
                            EtherPayloadSlice{
                                ether_type: EtherType(v),
                                len_source: LenSource::Slice,
                                payload: &p,
                            }
                    );}
                    _ => { assert!(slice.ether_payload().is_none());}
                }
            }
        }
    }

    proptest! {
        #[test]
        fn sll_payload(
            ref eth in ethernet_2_unknown(),
            ref linux_sll in linux_sll_any()
        ) {
            let p = [1,2,3,4];
            {
                let mut bytes = Vec::with_capacity(Ethernet2Header::LEN + p.len());
                bytes.extend_from_slice(&eth.to_bytes());
                bytes.extend_from_slice(&p);
                let slice = LinkSlice::Ethernet2(
                    Ethernet2Slice::from_slice_without_fcs(&bytes).unwrap()
                );
                assert_eq!(
                    slice.sll_payload(),
                    LinuxSllPayloadSlice{
                        protocol_type: LinuxSllProtocolType::EtherType(eth.ether_type),
                        payload: &p
                    }
                );
            }
            {
                let slice = LinkSlice::EtherPayload(EtherPayloadSlice {
                    ether_type: eth.ether_type,
                    len_source: LenSource::Slice,
                    payload: &p
                });
                assert_eq!(
                    slice.sll_payload(),
                    LinuxSllPayloadSlice{
                        protocol_type: LinuxSllProtocolType::EtherType(eth.ether_type),
                        payload: &p
                    }
                );
            }
            {
                let mut bytes = Vec::with_capacity(LinuxSllHeader::LEN + p.len());
                bytes.extend_from_slice(&linux_sll.to_bytes());
                bytes.extend_from_slice(&p);
                let slice = LinkSlice::LinuxSll(
                    LinuxSllSlice::from_slice(&bytes).unwrap()
                );
                assert_eq!(
                    slice.sll_payload(),
                    LinuxSllPayloadSlice{
                        protocol_type: linux_sll.protocol_type,
                        payload: &p
                    }
                );
            }
            {
                let slice = LinkSlice::LinuxSllPayload(LinuxSllPayloadSlice {
                    protocol_type: linux_sll.protocol_type,
                    payload: &p
                });
                assert_eq!(
                    slice.sll_payload(),
                    LinuxSllPayloadSlice{
                        protocol_type: linux_sll.protocol_type,
                        payload: &p
                    }
                );
            }
        }
    }
}
