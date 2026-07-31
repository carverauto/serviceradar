use crate::*;

/// A slice containing a single or double vlan header.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum VlanSlice<'a> {
    SingleVlan(SingleVlanSlice<'a>),
    DoubleVlan(DoubleVlanSlice<'a>),
}

impl<'a> VlanSlice<'a> {
    /// Decode all the fields and copy the results to a VlanHeader struct
    #[inline]
    pub fn to_header(&self) -> VlanHeader {
        use crate::VlanHeader::*;
        use crate::VlanSlice::*;
        match self {
            SingleVlan(value) => Single(value.to_header()),
            DoubleVlan(value) => Double(value.to_header()),
        }
    }

    #[inline]
    pub fn payload(&self) -> EtherPayloadSlice<'a> {
        match self {
            VlanSlice::SingleVlan(s) => s.payload(),
            VlanSlice::DoubleVlan(d) => d.payload(),
        }
    }
}

#[cfg(test)]
mod test {
    use crate::{test_gens::*, *};
    use alloc::{format, vec::Vec};
    use proptest::prelude::*;

    proptest! {
        #[test]
        fn to_header(
            single in vlan_single_any(),
            double in vlan_double_any(),
        ) {
            // single
            {
                let raw = single.to_bytes();
                let slice = VlanSlice::SingleVlan(
                    SingleVlanSlice::from_slice(&raw).unwrap()
                );
                assert_eq!(
                    slice.to_header(),
                    VlanHeader::Single(single)
                );
            }

            // double
            {
                let mut raw = Vec::with_capacity(
                    SingleVlanHeader::LEN*2
                );
                raw.extend_from_slice(&double.outer.to_bytes());
                raw.extend_from_slice(&double.inner.to_bytes());

                let slice = VlanSlice::DoubleVlan(
                    DoubleVlanSlice{
                        outer: SingleVlanSlice::from_slice(&raw[..]).unwrap(),
                        inner: SingleVlanSlice::from_slice(&raw[SingleVlanHeader::LEN..]).unwrap(),
                    }
                );
                assert_eq!(
                    slice.to_header(),
                    VlanHeader::Double(double)
                );
            }
        }
    }

    proptest! {
        #[test]
        fn payload(
            outer in vlan_single_any(),
            inner in vlan_single_any()
        ) {
            let payload = [1,2,3,4];

            // single
            {
                let mut bytes = Vec::with_capacity(SingleVlanHeader::LEN + 4);
                bytes.extend_from_slice(&outer.to_bytes());
                bytes.extend_from_slice(&payload);
                let slice = VlanSlice::SingleVlan(
                    SingleVlanSlice::from_slice(&bytes).unwrap()
                );
                assert_eq!(
                    slice.payload(),
                    EtherPayloadSlice{
                        ether_type: outer.ether_type,
                        len_source: LenSource::Slice,
                        payload: &payload,
                    }
                );
            }

            // double
            {
                let mut bytes = Vec::with_capacity(SingleVlanHeader::LEN + 4);
                bytes.extend_from_slice(&outer.to_bytes());
                bytes.extend_from_slice(&inner.to_bytes());
                bytes.extend_from_slice(&payload);
                let slice = VlanSlice::DoubleVlan(DoubleVlanSlice{
                    outer: SingleVlanSlice::from_slice(&bytes).unwrap(),
                    inner: SingleVlanSlice::from_slice(&bytes[SingleVlanHeader::LEN..]).unwrap()
                });
                assert_eq!(
                    slice.payload(),
                    EtherPayloadSlice{
                        ether_type: inner.ether_type,
                        len_source: LenSource::Slice,
                        payload: &payload,
                    }
                );
            }
        }
    }

    proptest! {
        #[test]
        fn debug(
            single in vlan_single_any(),
            double in vlan_double_any(),
        ) {
            // single
            {
                let raw = single.to_bytes();
                let s = SingleVlanSlice::from_slice(&raw).unwrap();
                assert_eq!(
                    format!("{:?}", VlanSlice::SingleVlan(s.clone())),
                    format!("SingleVlan({:?})", s)
                );
            }

            // double
            {
                let mut raw = Vec::with_capacity(
                    SingleVlanHeader::LEN*2
                );
                raw.extend_from_slice(&double.outer.to_bytes());
                raw.extend_from_slice(&double.inner.to_bytes());

                let inner = DoubleVlanSlice{
                    outer: SingleVlanSlice::from_slice(&raw[..]).unwrap(),
                    inner: SingleVlanSlice::from_slice(&raw[SingleVlanHeader::LEN..]).unwrap(),
                };
                let d = VlanSlice::DoubleVlan(inner.clone());
                assert_eq!(
                    format!("{:?}", d.clone()),
                    format!("DoubleVlan({:?})", inner)
                );
            }
        }
    }

    proptest! {
        #[test]
        fn clone_eq(
            single in vlan_single_any(),
            double in vlan_double_any(),
        ) {
            // single
            {
                let raw = single.to_bytes();
                let s = VlanSlice::SingleVlan(
                    SingleVlanSlice::from_slice(&raw).unwrap()
                );
                assert_eq!(s.clone(), s);
            }

            // double
            {
                let mut raw = Vec::with_capacity(
                    SingleVlanHeader::LEN*2
                );
                raw.extend_from_slice(&double.outer.to_bytes());
                raw.extend_from_slice(&double.inner.to_bytes());

                let d = VlanSlice::DoubleVlan(
                    DoubleVlanSlice{
                        outer: SingleVlanSlice::from_slice(&raw[..]).unwrap(),
                        inner: SingleVlanSlice::from_slice(&raw[SingleVlanHeader::LEN..]).unwrap(),
                    }
                );
                assert_eq!(d.clone(), d);
            }
        }
    }
}
