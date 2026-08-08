use crate::{err, ArpHardwareId, LinuxSllHeaderSlice, LinuxSllPacketType, LinuxSllProtocolType};

/// Linux Cooked Capture v1 (SLL) Header
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct LinuxSllHeader {
    /// Type of the captured packet
    pub packet_type: LinuxSllPacketType,
    /// ARPHRD_ value for the link-layer device type
    pub arp_hrd_type: ArpHardwareId,
    /// The size of the address that is valid
    pub sender_address_valid_length: u16,
    /// The link-layer address of the sender of the packet, with the meaningful
    /// bytes specified by `sender_address_valid_length`. If the original is
    /// larger, the value on the packet is truncated to the first 8 bytes. If
    /// the original is smaller, the remaining bytes will be filled with 0s.
    pub sender_address: [u8; 8],
    /// The protocol type of the encapsulated packet
    pub protocol_type: LinuxSllProtocolType,
}

impl LinuxSllHeader {
    /// Serialized size of an SLL header in bytes/octets.
    pub const LEN: usize = 16;

    /// Read an SLL header from a slice and return the header & unused parts of the slice.
    #[inline]
    pub fn from_slice(
        slice: &[u8],
    ) -> Result<(LinuxSllHeader, &[u8]), err::linux_sll::HeaderSliceError> {
        Ok((
            LinuxSllHeaderSlice::from_slice(slice)?.to_header(),
            &slice[LinuxSllHeader::LEN..],
        ))
    }

    /// Read an SLL header from a static sized byte array.
    #[inline]
    pub fn from_bytes(bytes: [u8; 16]) -> Result<LinuxSllHeader, err::linux_sll::HeaderError> {
        let packet_type = LinuxSllPacketType::try_from(u16::from_be_bytes([bytes[0], bytes[1]]))?;
        let arp_hrd_type = ArpHardwareId::from(u16::from_be_bytes([bytes[2], bytes[3]]));
        let sender_address_valid_length = u16::from_be_bytes([bytes[4], bytes[5]]);
        let sender_address = [
            bytes[6], bytes[7], bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13],
        ];
        let protocol_type = LinuxSllProtocolType::try_from((
            arp_hrd_type,
            u16::from_be_bytes([bytes[14], bytes[15]]),
        ))?;

        Ok(LinuxSllHeader {
            packet_type,
            arp_hrd_type,
            sender_address_valid_length,
            sender_address,
            protocol_type,
        })
    }

    /// Reads an SLL header from the current position of the read argument.
    #[cfg(feature = "std")]
    #[cfg_attr(docsrs, doc(cfg(feature = "std")))]
    pub fn read<T: std::io::Read + std::io::Seek + Sized>(
        reader: &mut T,
    ) -> Result<LinuxSllHeader, err::ReadError> {
        let buffer = {
            let mut buffer = [0; LinuxSllHeader::LEN];
            reader.read_exact(&mut buffer)?;
            buffer
        };

        Ok(
            // SAFETY: Safe as the buffer contains exactly the needed LinuxSllHeader::LEN bytes.
            unsafe { LinuxSllHeaderSlice::from_slice_unchecked(&buffer) }.to_header(),
        )
    }

    /// Serialize the header to a given slice. Returns the unused part of the slice.
    pub fn write_to_slice<'a>(
        &self,
        slice: &'a mut [u8],
    ) -> Result<&'a mut [u8], err::SliceWriteSpaceError> {
        // length check
        if slice.len() < LinuxSllHeader::LEN {
            Err(err::SliceWriteSpaceError {
                required_len: LinuxSllHeader::LEN,
                len: slice.len(),
                layer: err::Layer::LinuxSllHeader,
                layer_start_offset: 0,
            })
        } else {
            slice[..LinuxSllHeader::LEN].copy_from_slice(&self.to_bytes());
            Ok(&mut slice[LinuxSllHeader::LEN..])
        }
    }

    /// Writes a given Sll header to the current position of the write argument.
    #[cfg(feature = "std")]
    #[cfg_attr(docsrs, doc(cfg(feature = "std")))]
    #[inline]
    pub fn write<T: std::io::Write + Sized>(&self, writer: &mut T) -> Result<(), std::io::Error> {
        writer.write_all(&self.to_bytes())
    }

    /// Length of the serialized header in bytes.
    #[inline]
    pub fn header_len(&self) -> usize {
        Self::LEN
    }

    /// Returns the serialized form of the header as a statically
    /// sized byte array.
    #[inline]
    pub fn to_bytes(&self) -> [u8; Self::LEN] {
        let packet_type_be = u16::from(self.packet_type).to_be_bytes();
        let arp_hrd_type_be = u16::from(self.arp_hrd_type).to_be_bytes();
        let sender_address_valid_length_be = self.sender_address_valid_length.to_be_bytes();
        let sender_address_be = self.sender_address;
        let protocol_type_be = u16::from(self.protocol_type).to_be_bytes();

        [
            packet_type_be[0],
            packet_type_be[1],
            arp_hrd_type_be[0],
            arp_hrd_type_be[1],
            sender_address_valid_length_be[0],
            sender_address_valid_length_be[1],
            sender_address_be[0],
            sender_address_be[1],
            sender_address_be[2],
            sender_address_be[3],
            sender_address_be[4],
            sender_address_be[5],
            sender_address_be[6],
            sender_address_be[7],
            protocol_type_be[0],
            protocol_type_be[1],
        ]
    }
}

#[cfg(test)]
mod test {
    use super::*;
    use crate::{test_gens::*, LenSource};
    use alloc::{format, vec::Vec};
    use proptest::prelude::*;
    use std::io::{Cursor, ErrorKind};

    proptest! {
        #[test]
        fn from_slice(
            input in linux_sll_any(),
            dummy_data in proptest::collection::vec(any::<u8>(), 0..20)
        ) {
            // serialize
            let mut buffer: Vec<u8> = Vec::with_capacity(LinuxSllHeader::LEN + dummy_data.len());
            input.write(&mut buffer).unwrap();
            buffer.extend(&dummy_data[..]);

            // calls with a valid result
            {
                let (result, rest) = LinuxSllHeader::from_slice(&buffer[..]).unwrap();
                assert_eq!(input, result);
                assert_eq!(&buffer[16..], rest);
            }

            // call with not enough data in the slice
            for len in 0..=13 {
                assert_eq!(
                    LinuxSllHeader::from_slice(&buffer[..len]).unwrap_err(),
                    err::linux_sll::HeaderSliceError::Len(err::LenError{
                        required_len: LinuxSllHeader::LEN,
                        len: len,
                        len_source: LenSource::Slice,
                        layer: err::Layer::LinuxSllHeader,
                        layer_start_offset: 0,
                    })
                );
            }
        }
    }

    proptest! {
        #[test]
        fn from_bytes(input in linux_sll_any()) {
            assert_eq!(
                input,
                LinuxSllHeader::from_bytes(input.to_bytes()).unwrap()
            );
        }
    }

    proptest! {
        #[test]
        fn read(
            input in linux_sll_any(),
            dummy_data in proptest::collection::vec(any::<u8>(), 0..20)
        ) {
            // normal read
            let mut buffer = Vec::with_capacity(LinuxSllHeader::LEN + dummy_data.len());
            input.write(&mut buffer).unwrap();
            buffer.extend(&dummy_data[..]);

            // calls with a valid result
            {
                let mut cursor = Cursor::new(&buffer);
                let result = LinuxSllHeader::read(&mut cursor).unwrap();
                assert_eq!(input, result);
                assert_eq!(cursor.position(), u64::try_from(LinuxSllHeader::LEN).unwrap());
            }

            // unexpected eof
            for len in 0..=13 {
                let mut cursor = Cursor::new(&buffer[0..len]);
                assert_eq!(
                    LinuxSllHeader::read(&mut cursor)
                    .unwrap_err()
                    .io().unwrap()
                    .kind(),
                    ErrorKind::UnexpectedEof
                );
            }
        }
    }

    proptest! {
        #[test]
        fn write_to_slice(input in linux_sll_any()) {
            // normal write
            {
                let mut buffer: [u8;LinuxSllHeader::LEN] = [0;LinuxSllHeader::LEN];
                input.write_to_slice(&mut buffer).unwrap();
                assert_eq!(buffer, input.to_bytes());
            }
            // len to small
            for len in 0..14 {
                let mut buffer: [u8;LinuxSllHeader::LEN] = [0;LinuxSllHeader::LEN];
                assert_eq!(
                    err::SliceWriteSpaceError {
                        required_len: LinuxSllHeader::LEN,
                        len,
                        layer: err::Layer::LinuxSllHeader,
                        layer_start_offset: 0,
                    },
                    input.write_to_slice(&mut buffer[..len]).unwrap_err()
                );
            }
        }
    }

    proptest! {
        #[test]
        fn write(input in linux_sll_any()) {
            // successful write
            {
                let mut buffer: Vec<u8> = Vec::with_capacity(LinuxSllHeader::LEN);
                input.write(&mut buffer).unwrap();
                assert_eq!(&buffer[..], &input.to_bytes());
            }

            // not enough memory for write (unexpected eof)
            for len in 0..8 {
                let mut buffer = [0u8;8];
                let mut writer = Cursor::new(&mut buffer[..len]);
                assert!(input.write(&mut writer).is_err());
            }
        }
    }

    proptest! {
        #[test]
        fn header_len(input in linux_sll_any()) {
            assert_eq!(input.header_len(), LinuxSllHeader::LEN);
        }
    }

    proptest! {
        #[test]
        fn to_bytes(input in linux_sll_any()) {
            let packet_type_be = u16::from(input.packet_type).to_be_bytes();
            let arp_hrd_type_be = u16::from(input.arp_hrd_type).to_be_bytes();
            let sender_address_valid_length_be = input.sender_address_valid_length.to_be_bytes();
            let sender_address_be = input.sender_address;
            let protocol_type_be = u16::from(input.protocol_type).to_be_bytes();

            assert_eq!(
                input.to_bytes(),
                [
                    packet_type_be[0],
                    packet_type_be[1],
                    arp_hrd_type_be[0],
                    arp_hrd_type_be[1],
                    sender_address_valid_length_be[0],
                    sender_address_valid_length_be[1],
                    sender_address_be[0],
                    sender_address_be[1],
                    sender_address_be[2],
                    sender_address_be[3],
                    sender_address_be[4],
                    sender_address_be[5],
                    sender_address_be[6],
                    sender_address_be[7],
                    protocol_type_be[0],
                    protocol_type_be[1],
                ]
            );
        }
    }

    proptest! {
        #[test]
        fn clone_eq(input in linux_sll_any()) {
            assert_eq!(input, input.clone());
        }
    }

    proptest! {
        #[test]
        fn dbg(input in linux_sll_any()) {
            assert_eq!(
                &format!(
                    "LinuxSllHeader {{ packet_type: {:?}, arp_hrd_type: {:?}, sender_address_valid_length: {:?}, sender_address: {:?}, protocol_type: {:?} }}",
                    input.packet_type,
                    input.arp_hrd_type,
                    input.sender_address_valid_length,
                    input.sender_address,
                    input.protocol_type,
                ),
                &format!("{:?}", input)
            );
        }
    }
}
