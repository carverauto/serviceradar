use crate::*;
use core::{cmp::min, slice::from_raw_parts};

///A slice containing an Linux Cooked Capture (SLL) header of a network package.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct LinuxSllHeaderSlice<'a> {
    slice: &'a [u8],
}

impl<'a> LinuxSllHeaderSlice<'a> {
    /// Creates a SLL header slice from an other slice.
    pub fn from_slice(
        slice: &'a [u8],
    ) -> Result<LinuxSllHeaderSlice<'a>, err::linux_sll::HeaderSliceError> {
        //check length
        if slice.len() < LinuxSllHeader::LEN {
            return Err(err::linux_sll::HeaderSliceError::Len(err::LenError {
                required_len: LinuxSllHeader::LEN,
                len: slice.len(),
                len_source: LenSource::Slice,
                layer: err::Layer::LinuxSllHeader,
                layer_start_offset: 0,
            }));
        }

        // check valid packet type

        // SAFETY:
        // Safe as it is checked at the start of the function that the
        // length of the slice is at least LinuxSllHeader::LEN (16).
        let packet_type_val = unsafe { get_unchecked_be_u16(slice.as_ptr()) };
        if let Err(err) = LinuxSllPacketType::try_from(packet_type_val) {
            return Err(err::linux_sll::HeaderSliceError::Content(err));
        }

        // check supported ArpHardwareId

        // SAFETY:
        // Safe as it is checked at the start of the function that the
        // length of the slice is at least LinuxSllHeader::LEN (16).
        let arp_hardware_id = unsafe { get_unchecked_be_u16(slice.as_ptr().add(2)) };
        let arp_hardware_id = ArpHardwareId::from(arp_hardware_id);

        // SAFETY:
        // Safe as it is checked at the start of the function that the
        // length of the slice is at least LinuxSllHeader::LEN (16).
        let protocol_type = unsafe { get_unchecked_be_u16(slice.as_ptr().add(14)) };

        if let Err(err) = LinuxSllProtocolType::try_from((arp_hardware_id, protocol_type)) {
            return Err(err::linux_sll::HeaderSliceError::Content(err));
        }

        //all done
        Ok(LinuxSllHeaderSlice {
            // SAFETY:
            // Safe as slice length is checked to be at least
            // LinuxSllHeader::LEN (16) before this.
            slice: unsafe { from_raw_parts(slice.as_ptr(), LinuxSllHeader::LEN) },
        })
    }

    /// Converts the given slice into a SLL header slice WITHOUT any checks to
    /// ensure that the data present is an sll header or that the slice length
    /// is matching the header length.
    ///
    /// If you are not sure what this means, use [`LinuxSllHeaderSlice::from_slice`]
    /// instead.
    ///
    /// # Safety
    ///
    /// The caller must ensured that the given slice has the length of
    /// [`LinuxSllHeader::LEN`] and the fields are valid
    #[inline]
    #[cfg(feature = "std")]
    pub(crate) unsafe fn from_slice_unchecked(slice: &[u8]) -> LinuxSllHeaderSlice<'_> {
        debug_assert!(slice.len() == LinuxSllHeader::LEN);
        LinuxSllHeaderSlice { slice }
    }

    /// Returns the slice containing the SLL header
    #[inline]
    pub fn slice(&self) -> &'a [u8] {
        self.slice
    }

    /// Read the packet type field.
    #[inline]
    pub fn packet_type(&self) -> LinuxSllPacketType {
        // SAFETY:
        // Safe as the constructor checks that the slice has
        // at least the length of LinuxSllHeader::LEN (16).
        let packet_type_raw = unsafe { get_unchecked_be_u16(self.slice.as_ptr()) };

        // SAFETY:
        // Safe as the constructor checks that the packet type is valid
        unsafe { LinuxSllPacketType::try_from(packet_type_raw).unwrap_unchecked() }
    }

    /// Read the arp hardware type field
    #[inline]
    pub fn arp_hardware_type(&self) -> ArpHardwareId {
        // SAFETY:
        // Safe as the constructor checks that the slice has
        // at least the length of LinuxSllHeader::LEN (16).
        let arp_hardware_type_raw = unsafe { get_unchecked_be_u16(self.slice.as_ptr().add(2)) };

        ArpHardwareId::from(arp_hardware_type_raw)
    }

    /// Read the link layer address length field.
    #[inline]
    pub fn sender_address_valid_length(&self) -> u16 {
        // SAFETY:
        // Safe as the constructor checks that the slice has
        // at least the length of LinuxSllHeader::LEN (16).
        unsafe { get_unchecked_be_u16(self.slice.as_ptr().add(4)) }
    }

    /// Read the link layer address field. Only the first
    /// `LinuxSllHeaderSlice::link_layer_address_length` bytes are meaningful
    #[inline]
    pub fn sender_address_full(&self) -> [u8; 8] {
        // SAFETY:
        // Safe as the constructor checks that the slice has
        // at least the length of LinuxSllHeader::LEN (16).
        unsafe { get_unchecked_8_byte_array(self.slice.as_ptr().add(6)) }
    }

    /// Get the meaningful bytes of the slice of the link layer address
    #[inline]
    pub fn sender_address(&self) -> &'a [u8] {
        let length = self.sender_address_valid_length() as usize;
        &self.slice[6..min(6 + length, 6 + 8)]
    }

    /// Read the protocol type field
    #[inline]
    pub fn protocol_type(&self) -> LinuxSllProtocolType {
        let arp_hardware_type = self.arp_hardware_type();
        // SAFETY:
        // Safe as the constructor checks that the slice has
        // at least the length of LinuxSllHeader::LEN (16).
        let protocol_type_raw = unsafe { get_unchecked_be_u16(self.slice.as_ptr().add(14)) };

        // SAFETY:
        // Safe as the constructor checks that the arphw + protocol are supported
        unsafe {
            LinuxSllProtocolType::try_from((arp_hardware_type, protocol_type_raw))
                .unwrap_unchecked()
        }
    }

    /// Decode all the fields and copy the results to a [`LinuxSllHeader`] struct
    pub fn to_header(&self) -> LinuxSllHeader {
        LinuxSllHeader {
            packet_type: self.packet_type(),
            arp_hrd_type: self.arp_hardware_type(),
            sender_address_valid_length: self.sender_address_valid_length(),
            sender_address: self.sender_address_full(),
            protocol_type: self.protocol_type(),
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
        fn from_slice(
            input in linux_sll_any(),
            dummy_data in proptest::collection::vec(any::<u8>(), 0..20),
            bad_packet_type in LinuxSllPacketType::MAX_VAL + 1..=u16::MAX,
            bad_hw_type in any::<u16>().prop_filter(
                "hw id must be unknown",
                |v| ![
                    ArpHardwareId::NETLINK,
                    ArpHardwareId::IPGRE,
                    ArpHardwareId::IEEE80211_RADIOTAP,
                    ArpHardwareId::FRAD,
                    ArpHardwareId::ETHERNET,
                ].iter().any(|&x| *v == x.0)
            )
        ) {
            // serialize
            let buffer = {
                let mut buffer: Vec<u8> = Vec::with_capacity(LinuxSllHeader::LEN + dummy_data.len());
                input.write(&mut buffer).unwrap();
                buffer.extend(&dummy_data[..]);
                buffer
            };

            // calls with a valid result
            {
                let result = LinuxSllHeaderSlice::from_slice(&buffer[..]).unwrap();
                assert_eq!(&buffer[..LinuxSllHeader::LEN], result.slice());
            }

            // call with not enough data in the slice
            for len in 0..=13 {
                assert_eq!(
                    LinuxSllHeaderSlice::from_slice(&buffer[..len]),
                    Err(err::linux_sll::HeaderSliceError::Len(err::LenError{
                        required_len: LinuxSllHeader::LEN,
                        len: len,
                        len_source: LenSource::Slice,
                        layer: err::Layer::LinuxSllHeader,
                        layer_start_offset: 0,
                    }))
                );
            }

            // packet_type_val error
            {
                let mut modbuf = buffer.clone();
                let p_be = bad_packet_type.to_be_bytes();
                modbuf[0] = p_be[0];
                modbuf[1] = p_be[1];
                assert_eq!(
                    LinuxSllHeaderSlice::from_slice(&modbuf),
                    Err(err::linux_sll::HeaderSliceError::Content(
                        err::linux_sll::HeaderError::UnsupportedPacketTypeField { packet_type: bad_packet_type }
                    ))
                );
            }

            // hardware_id error
            {
                let mut modbuf = buffer.clone();
                let p_be = bad_hw_type.to_be_bytes();
                modbuf[2] = p_be[0];
                modbuf[3] = p_be[1];
                assert_eq!(
                    LinuxSllHeaderSlice::from_slice(&modbuf),
                    Err(err::linux_sll::HeaderSliceError::Content(
                        err::linux_sll::HeaderError::UnsupportedArpHardwareId { arp_hardware_type: ArpHardwareId(bad_hw_type) }
                    ))
                );
            }
        }
    }

    proptest! {
        #[test]
        fn getters(input in linux_sll_any()) {
            let buffer = input.to_bytes();
            let slice = LinuxSllHeaderSlice::from_slice(&buffer).unwrap();
            assert_eq!(input.packet_type, slice.packet_type());
            assert_eq!(input.arp_hrd_type, slice.arp_hardware_type());
            assert_eq!(input.sender_address_valid_length, slice.sender_address_valid_length());
            assert_eq!(input.sender_address, slice.sender_address_full());
            assert_eq!(&input.sender_address[..usize::from(input.sender_address_valid_length)], slice.sender_address());
            assert_eq!(input.protocol_type, slice.protocol_type());
        }
    }

    proptest! {
        #[test]
        fn to_header(input in linux_sll_any()) {
            let buffer = input.to_bytes();
            let slice = LinuxSllHeaderSlice::from_slice(&buffer).unwrap();
            assert_eq!(input, slice.to_header());
        }
    }

    proptest! {
        #[test]
        fn clone_eq(input in linux_sll_any()) {
            let buffer = input.to_bytes();
            let slice = LinuxSllHeaderSlice::from_slice(&buffer).unwrap();
            assert_eq!(slice, slice.clone());
        }
    }

    proptest! {
        #[test]
        fn dbg(input in linux_sll_any()) {
            let buffer = input.to_bytes();
            let slice = LinuxSllHeaderSlice::from_slice(&buffer).unwrap();
            assert_eq!(
                &format!(
                    "LinuxSllHeaderSlice {{ slice: {:?} }}",
                    slice.slice()
                ),
                &format!("{:?}", slice)
            );
        }
    }
}
