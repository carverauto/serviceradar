use crate::{err::*, *};

/// Slice containing a VLAN header & payload.
#[derive(Clone, Eq, PartialEq)]
pub struct SingleVlanSlice<'a> {
    pub(crate) slice: &'a [u8],
}

impl<'a> SingleVlanSlice<'a> {
    /// Try creating a [`SingleVlanSlice`] from a slice containing the
    /// VLAN header & payload.
    pub fn from_slice(slice: &'a [u8]) -> Result<SingleVlanSlice<'a>, LenError> {
        // check length
        if slice.len() < SingleVlanHeader::LEN {
            return Err(err::LenError {
                required_len: SingleVlanHeader::LEN,
                len: slice.len(),
                len_source: LenSource::Slice,
                layer: err::Layer::VlanHeader,
                layer_start_offset: 0,
            });
        }

        Ok(SingleVlanSlice { slice })
    }

    /// Returns the slice containing the VLAN header and payload.
    #[inline]
    pub fn slice(&self) -> &'a [u8] {
        self.slice
    }

    /// Read the "priority_code_point" field of the VLAN header.
    ///
    /// This is a 3 bit number which refers to the IEEE 802.1p class
    /// of service and maps to the frame priority level.
    #[inline]
    pub fn priority_code_point(&self) -> VlanPcp {
        unsafe {
            // SAFETY: Safe as slice len checked in constructor to be at least 4 &
            // the bit mask guarantees values does not exceed 0b0000_0111.
            VlanPcp::new_unchecked((*self.slice.get_unchecked(0) >> 5) & 0b0000_0111)
        }
    }

    /// Read the "drop_eligible_indicator" flag of the VLAN header.
    ///
    /// Indicates that the frame may be dropped under the presence
    /// of congestion.
    #[inline]
    pub fn drop_eligible_indicator(&self) -> bool {
        // SAFETY:
        // Slice len checked in constructor to be at least 4.
        unsafe { 0 != (*self.slice.get_unchecked(0) & 0x10) }
    }

    /// Reads the 12 bits "vlan identifier" field from the VLAN header.
    #[inline]
    pub fn vlan_identifier(&self) -> VlanId {
        // SAFETY:
        // Slice len checked in constructor to be at least 4 &
        // value and the value is guaranteed not to exceed
        // 0b0000_1111_1111_1111 as the upper bits have been
        // bit-masked out.
        unsafe {
            VlanId::new_unchecked(u16::from_be_bytes([
                *self.slice.get_unchecked(0) & 0b0000_1111,
                *self.slice.get_unchecked(1),
            ]))
        }
    }

    /// Read the "Tag protocol identifier" field from the VLAN header.
    ///
    /// Refer to the "EtherType" for a list of possible supported values.
    #[inline]
    pub fn ether_type(&self) -> EtherType {
        // SAFETY:
        // Slice len checked in constructor to be at least 4.
        EtherType(unsafe { get_unchecked_be_u16(self.slice.as_ptr().add(2)) })
    }

    /// Decode all the fields and copy the results to a SingleVlanHeader struct
    #[inline]
    pub fn to_header(&self) -> SingleVlanHeader {
        SingleVlanHeader {
            pcp: self.priority_code_point(),
            drop_eligible_indicator: self.drop_eligible_indicator(),
            vlan_id: self.vlan_identifier(),
            ether_type: self.ether_type(),
        }
    }

    /// Slice containing the Ethernet 2 header.
    pub fn header_slice(&self) -> &[u8] {
        unsafe {
            // SAFETY:
            // Safe as the constructor checks that the slice has
            // at least the length of SingleVlanHeader::LEN (4).
            core::slice::from_raw_parts(self.slice.as_ptr(), SingleVlanHeader::LEN)
        }
    }

    /// Returns the slice containing the VLAN payload & ether type
    /// identifying it's content type.
    #[inline]
    pub fn payload(&self) -> EtherPayloadSlice<'a> {
        EtherPayloadSlice {
            ether_type: self.ether_type(),
            len_source: LenSource::Slice,
            payload: self.payload_slice(),
        }
    }

    /// Returns the slice containing the VLAN payload.
    #[inline]
    pub fn payload_slice(&self) -> &'a [u8] {
        unsafe {
            // SAFETY:
            // Safe as the constructor checks that the slice has
            // at least the length of SingleVlanHeader::LEN (4).
            core::slice::from_raw_parts(
                self.slice.as_ptr().add(SingleVlanHeader::LEN),
                self.slice.len() - SingleVlanHeader::LEN,
            )
        }
    }

    /// Length of the VLAN header in bytes (equal to
    /// [`crate::SingleVlanHeader::LEN`]).
    #[inline]
    pub const fn header_len(&self) -> usize {
        SingleVlanHeader::LEN
    }
}

impl core::fmt::Debug for SingleVlanSlice<'_> {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        f.debug_struct("SingleVlanSlice")
            .field("header", &self.to_header())
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
            vlan in vlan_single_any()
        ) {
            let payload: [u8;8] = [1,2,3,4,5,6,7,8];
            let mut data = Vec::with_capacity(
                vlan.header_len() +
                payload.len()
            );
            data.extend_from_slice(&vlan.to_bytes());
            data.extend_from_slice(&payload);

            // decode packet
            let slice = SingleVlanSlice::from_slice(&data).unwrap();

            // check debug output
            prop_assert_eq!(
                format!("{:?}", slice),
                format!(
                    "SingleVlanSlice {{ header: {:?}, payload: {:?} }}",
                    slice.to_header(),
                    slice.payload(),
                )
            );
            prop_assert_eq!(slice.clone(), slice);
        }
    }

    proptest! {
        #[test]
        fn getters(vlan in vlan_single_any()) {
            let payload: [u8;8] = [1,2,3,4,5,6,7,8];
            let mut data = Vec::with_capacity(
                vlan.header_len() +
                payload.len()
            );
            data.extend_from_slice(&vlan.to_bytes());
            data.extend_from_slice(&payload);

            let slice = SingleVlanSlice::from_slice(&data).unwrap();
            assert_eq!(&data, slice.slice());
            assert_eq!(vlan.pcp, slice.priority_code_point());
            assert_eq!(vlan.drop_eligible_indicator, slice.drop_eligible_indicator());
            assert_eq!(vlan.vlan_id, slice.vlan_identifier());
            assert_eq!(vlan.ether_type, slice.ether_type());
            assert_eq!(vlan, slice.to_header());
            assert_eq!(&data[..SingleVlanHeader::LEN], slice.header_slice());

            assert_eq!(
                EtherPayloadSlice {
                    ether_type: vlan.ether_type,
                    len_source: LenSource::Slice,
                    payload: &data[SingleVlanHeader::LEN..],
                },
                slice.payload()
            );
            assert_eq!(&data[SingleVlanHeader::LEN..], slice.payload_slice());
            assert_eq!(SingleVlanHeader::LEN, slice.header_len());
        }
    }

    proptest! {
        #[test]
        fn from_slice(vlan in vlan_single_any()) {

            let payload: [u8;10] = [1,2,3,4,5,6,7,8,9,10];
            let data = {
                let mut data = Vec::with_capacity(
                    vlan.header_len() +
                    payload.len()
                );
                data.extend_from_slice(&vlan.to_bytes());
                data.extend_from_slice(&payload);
                data
            };

            // normal decode
            {
                let slice = SingleVlanSlice::from_slice(&data).unwrap();
                assert_eq!(slice.to_header(), vlan);
                assert_eq!(slice.payload_slice(), &payload);
            }

            // length error
            for len in 0..SingleVlanHeader::LEN {
                assert_eq!(
                    SingleVlanSlice::from_slice(&data[..len]).unwrap_err(),
                    LenError{
                        required_len: SingleVlanHeader::LEN,
                        len,
                        len_source: LenSource::Slice,
                        layer: Layer::VlanHeader,
                        layer_start_offset: 0
                    }
                );
            }
        }
    }
}
