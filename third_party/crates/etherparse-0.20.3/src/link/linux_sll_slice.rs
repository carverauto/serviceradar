use crate::{
    err::{self, Layer},
    ArpHardwareId, LenSource, LinuxSllHeader, LinuxSllHeaderSlice, LinuxSllPacketType,
    LinuxSllPayloadSlice, LinuxSllProtocolType,
};

/// Slice containing a Linux Cooked Capture v1 (SLL) header & payload.
#[derive(Clone, Eq, PartialEq)]
pub struct LinuxSllSlice<'a> {
    header_slice: LinuxSllHeaderSlice<'a>,
    header_and_payload_slice: &'a [u8],
}

impl<'a> LinuxSllSlice<'a> {
    /// Try creating a [`LinuxSllSlice`] from a slice containing the
    /// header & payload
    pub fn from_slice(
        slice: &'a [u8],
    ) -> Result<LinuxSllSlice<'a>, err::linux_sll::HeaderSliceError> {
        // check length
        if slice.len() < LinuxSllHeader::LEN {
            return Err(err::linux_sll::HeaderSliceError::Len(err::LenError {
                required_len: LinuxSllHeader::LEN,
                len: slice.len(),
                len_source: LenSource::Slice,
                layer: Layer::LinuxSllHeader,
                layer_start_offset: 0,
            }));
        }

        // extract header
        match LinuxSllHeaderSlice::from_slice(&slice[0..LinuxSllHeader::LEN]) {
            Err(err) => Err(err),
            Ok(header_slice) => Ok(LinuxSllSlice {
                header_slice,
                header_and_payload_slice: slice,
            }),
        }
    }

    /// Returns the slice containing the Linux Cooked Capture v1 (SLL) header &
    /// payload.
    #[inline]
    pub fn slice(&self) -> &'a [u8] {
        self.header_and_payload_slice
    }

    /// Read the packet type field from the header
    #[inline]
    pub fn packet_type(&self) -> LinuxSllPacketType {
        self.header_slice.packet_type()
    }

    /// Read the arp hardware type field from the header
    #[inline]
    pub fn arp_hardware_type(&self) -> ArpHardwareId {
        self.header_slice.arp_hardware_type()
    }

    /// Read the link layer address length field from the header
    #[inline]
    pub fn sender_address_valid_length(&self) -> u16 {
        self.header_slice.sender_address_valid_length()
    }

    /// Read the link layer address field from the header. Only the first
    /// `LinuxSllSlice::link_layer_address_length` bytes are meaningful
    #[inline]
    pub fn sender_address_full(&self) -> [u8; 8] {
        self.header_slice.sender_address_full()
    }

    /// Get the meaningful bytes of the slice of the link layer address from
    /// the header
    #[inline]
    pub fn sender_address(&self) -> &'a [u8] {
        self.header_slice.sender_address()
    }

    /// Read the protocol type field from the header
    #[inline]
    pub fn protocol_type(&self) -> LinuxSllProtocolType {
        self.header_slice.protocol_type()
    }

    /// Decode all the header fields and copy the results to a
    /// [`LinuxSllHeader`] struct
    pub fn to_header(&self) -> LinuxSllHeader {
        LinuxSllHeader {
            packet_type: self.packet_type(),
            arp_hrd_type: self.arp_hardware_type(),
            sender_address_valid_length: self.sender_address_valid_length(),
            sender_address: self.sender_address_full(),
            protocol_type: self.protocol_type(),
        }
    }

    /// Slice only containing the header
    pub fn header_slice(&self) -> &[u8] {
        self.header_slice.slice()
    }

    /// Returns the slice containing the Ethernet II payload & ether type
    /// identifying it's content type.
    #[inline]
    pub fn payload(&self) -> LinuxSllPayloadSlice<'a> {
        LinuxSllPayloadSlice {
            protocol_type: self.protocol_type(),
            payload: self.payload_slice(),
        }
    }

    /// Slice only containing the payload
    #[inline]
    pub fn payload_slice(&self) -> &'a [u8] {
        // SAFETY: Safe as the slice length was verified to be at least
        // LinuxSllHeader::LEN by "from_slice".
        unsafe {
            core::slice::from_raw_parts(
                self.header_and_payload_slice
                    .as_ptr()
                    .add(LinuxSllHeader::LEN),
                self.header_and_payload_slice.len() - LinuxSllHeader::LEN,
            )
        }
    }

    /// Length of the header in bytes (equal to [`crate::LinuxSllHeader::LEN`])
    #[inline]
    pub const fn header_len(&self) -> usize {
        LinuxSllHeader::LEN
    }
}

impl core::fmt::Debug for LinuxSllSlice<'_> {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        f.debug_struct("LinuxSllSlice")
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
            linux_sll in linux_sll_any()
        ) {
            let payload: [u8;8] = [1,2,3,4,5,6,7,8];
            let mut data = Vec::with_capacity(
                linux_sll.header_len() +
                payload.len()
            );
            data.extend_from_slice(&linux_sll.to_bytes());
            data.extend_from_slice(&payload);

            // decode packet
            let slice = LinuxSllSlice::from_slice(&data).unwrap();

            // check debug output
            prop_assert_eq!(
                format!("{:?}", slice),
                format!(
                    "LinuxSllSlice {{ header: {:?}, payload: {:?} }}",
                    slice.to_header(),
                    slice.payload(),
                )
            );
            prop_assert_eq!(slice.clone(), slice);
        }
    }

    proptest! {
        #[test]
        fn getters(linux_sll in linux_sll_any()) {
            let payload: [u8;8] = [1,2,3,4,5,6,7,8];
            let mut data = Vec::with_capacity(
                linux_sll.header_len() +
                payload.len()
            );
            data.extend_from_slice(&linux_sll.to_bytes());
            data.extend_from_slice(&payload);

            let slice = LinuxSllSlice::from_slice(&data).unwrap();
            assert_eq!(linux_sll.packet_type, slice.packet_type());
            assert_eq!(linux_sll.arp_hrd_type, slice.arp_hardware_type());
            assert_eq!(linux_sll.sender_address_valid_length, slice.sender_address_valid_length());
            assert_eq!(linux_sll.sender_address, slice.sender_address_full());
            assert_eq!(&linux_sll.sender_address[..usize::from(linux_sll.sender_address_valid_length)], slice.sender_address());
            assert_eq!(linux_sll.protocol_type, slice.protocol_type());
            assert_eq!(&payload, slice.payload_slice());
            assert_eq!(
                LinuxSllPayloadSlice{
                    payload: &payload,
                    protocol_type: linux_sll.protocol_type,
                },
                slice.payload()
            );
            assert_eq!(linux_sll, slice.to_header());
            assert_eq!(&data, slice.slice());
            assert_eq!(&data[..LinuxSllHeader::LEN], slice.header_slice());
        }
    }

    proptest! {
        #[test]
        fn from_slice(linux_sll in linux_sll_any()) {

            let payload: [u8;10] = [1,2,3,4,5,6,7,8,9,10];
            let data = {
                let mut data = Vec::with_capacity(
                    linux_sll.header_len() +
                    payload.len()
                );
                data.extend_from_slice(&linux_sll.to_bytes());
                data.extend_from_slice(&payload);
                data
            };

            // normal decode
            {
                let slice = LinuxSllSlice::from_slice(&data).unwrap();
                assert_eq!(slice.to_header(), linux_sll);
                assert_eq!(slice.payload_slice(), &payload);
            }

            // decode without payload
            {
                let slice = LinuxSllSlice::from_slice(&data[..LinuxSllHeader::LEN]).unwrap();
                assert_eq!(slice.to_header(), linux_sll);
                assert_eq!(slice.payload_slice(), &[]);
            }

            // length error
            for len in 0..LinuxSllHeader::LEN {
                assert_eq!(
                    LinuxSllSlice::from_slice(&data[..len]).unwrap_err(),
                    err::linux_sll::HeaderSliceError::Len(err::LenError{
                        required_len: LinuxSllHeader::LEN,
                        len,
                        len_source: LenSource::Slice,
                        layer: Layer::LinuxSllHeader,
                        layer_start_offset: 0
                    })
                );
            }
        }
    }
}
