use crate::*;

/// Two IEEE 802.1Q VLAN Tagging headers & payload slices (helper
/// struct to check vlan tagging values in a [crate::`SlicedPacket`]).
///
/// Note that it is NOT guaranteed that the two VLAN headers directly
/// followed each other in the original packet. In the original packet
/// there could be another LinkExt header present in between them (e.g.
/// a MacSec Security Tag).
#[derive(Clone, Eq, PartialEq)]
pub struct DoubleVlanSlice<'a> {
    /// Outer VLAN header & payload (should include the header of inner vlan header
    /// and potentially additional link extension headers (e.g. MacSec) in between).
    pub outer: SingleVlanSlice<'a>,
    /// Inner VLAN header & payload.
    pub inner: SingleVlanSlice<'a>,
}

impl<'a> DoubleVlanSlice<'a> {
    /// Decode all the fields and copy the results to a DoubleVlanHeader struct
    #[inline]
    pub fn to_header(&self) -> DoubleVlanHeader {
        DoubleVlanHeader {
            outer: self.outer.to_header(),
            inner: self.inner.to_header(),
        }
    }

    /// Returns the slice containing the payload & ether type
    /// identifying it's content type after bother VLAN headers.
    #[inline]
    pub fn payload(&self) -> EtherPayloadSlice<'a> {
        self.inner.payload()
    }

    /// Returns the slice containing the payload after both
    /// VLAN headers.
    pub fn payload_slice(&self) -> &'a [u8] {
        self.inner.payload_slice()
    }
}

impl core::fmt::Debug for DoubleVlanSlice<'_> {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        f.debug_struct("DoubleVlanSlice")
            .field("outer", &self.outer.to_header())
            .field("inner", &self.inner.to_header())
            .field("payload", &self.payload())
            .finish()
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
        fn debug_clone_eq(
            vlan in vlan_double_any()
        ) {
            let payload: [u8;8] = [1,2,3,4,5,6,7,8];
            let mut data = Vec::with_capacity(
                vlan.outer.header_len() +
                vlan.inner.header_len() +
                payload.len()
            );
            data.extend_from_slice(&vlan.outer.to_bytes());
            data.extend_from_slice(&vlan.inner.to_bytes());
            data.extend_from_slice(&payload);

            // decode packet
            let slice = DoubleVlanSlice{
                outer: SingleVlanSlice::from_slice(&data).unwrap(),
                inner: SingleVlanSlice::from_slice(&data[SingleVlanHeader::LEN..]).unwrap(),
            };

            // check debug output
            prop_assert_eq!(
                format!("{:?}", slice),
                format!(
                    "DoubleVlanSlice {{ outer: {:?}, inner: {:?}, payload: {:?} }}",
                    slice.outer.to_header(),
                    slice.inner.to_header(),
                    slice.payload(),
                )
            );
            prop_assert_eq!(slice.clone(), slice);
        }
    }

    proptest! {
        #[test]
        fn getters(vlan in vlan_double_any()) {
            let payload: [u8;8] = [1,2,3,4,5,6,7,8];
            let mut data = Vec::with_capacity(
                vlan.outer.header_len() +
                vlan.inner.header_len() +
                payload.len()
            );
            data.extend_from_slice(&vlan.outer.to_bytes());
            data.extend_from_slice(&vlan.inner.to_bytes());
            data.extend_from_slice(&payload);

            let slice = DoubleVlanSlice{
                outer: SingleVlanSlice::from_slice(&data).unwrap(),
                inner: SingleVlanSlice::from_slice(&data[SingleVlanHeader::LEN..]).unwrap(),
            };
            assert_eq!(&data, slice.outer.slice());
            assert_eq!(vlan.outer, slice.outer.to_header());
            assert_eq!(&data[SingleVlanHeader::LEN..], slice.inner.slice());
            assert_eq!(vlan.inner, slice.inner.to_header());
            assert_eq!(vlan, slice.to_header());
            assert_eq!(
                EtherPayloadSlice{
                    ether_type: vlan.inner.ether_type,
                    len_source: LenSource::Slice,
                    payload: &payload,
                },
                slice.payload()
            );
            assert_eq!(&payload, slice.payload_slice());
        }
    }
}
