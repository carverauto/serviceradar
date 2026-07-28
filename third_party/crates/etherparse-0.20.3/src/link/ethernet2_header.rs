use crate::{err::Layer, err::SliceWriteSpaceError, *};

/// Ethernet II header.
#[derive(Clone, Debug, Eq, PartialEq, Default)]
pub struct Ethernet2Header {
    /// Source MAC Address
    pub source: [u8; 6],
    /// Destination MAC Address
    pub destination: [u8; 6],
    /// Protocol present after the ethernet2 header.
    pub ether_type: EtherType,
}

impl Ethernet2Header {
    /// Serialized size of an Ethernet2 header in bytes/octets.
    pub const LEN: usize = 14;

    /// Deprecated use [`Ethernet2Header::LEN`] instead.
    #[deprecated(since = "0.14.0", note = "Use `Ethernet2Header::LEN` instead")]
    pub const SERIALIZED_SIZE: usize = Ethernet2Header::LEN;

    /// Deprecated use [`Ethernet2Header::from_slice`] instead.
    #[deprecated(since = "0.10.1", note = "Use Ethernet2Header::from_slice instead.")]
    #[inline]
    pub fn read_from_slice(slice: &[u8]) -> Result<(Ethernet2Header, &[u8]), err::LenError> {
        Ethernet2Header::from_slice(slice)
    }

    /// Read an Ethernet2Header from a slice and return the header & unused parts of the slice.
    #[inline]
    pub fn from_slice(slice: &[u8]) -> Result<(Ethernet2Header, &[u8]), err::LenError> {
        Ok((
            Ethernet2HeaderSlice::from_slice(slice)?.to_header(),
            &slice[Ethernet2Header::LEN..],
        ))
    }

    /// Read an Ethernet2Header from a static sized byte array.
    #[inline]
    pub fn from_bytes(bytes: [u8; 14]) -> Ethernet2Header {
        Ethernet2Header {
            destination: [bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5]],
            source: [bytes[6], bytes[7], bytes[8], bytes[9], bytes[10], bytes[11]],
            ether_type: EtherType(u16::from_be_bytes([bytes[12], bytes[13]])),
        }
    }

    /// Reads an Ethernet-II header from the current position of the read argument.
    #[cfg(feature = "std")]
    #[cfg_attr(docsrs, doc(cfg(feature = "std")))]
    pub fn read<T: std::io::Read + std::io::Seek + Sized>(
        reader: &mut T,
    ) -> Result<Ethernet2Header, std::io::Error> {
        let buffer = {
            let mut buffer = [0; Ethernet2Header::LEN];
            reader.read_exact(&mut buffer)?;
            buffer
        };

        Ok(
            // SAFETY: Safe as the buffer contains exactly the needed Ethernet2Header::LEN bytes.
            unsafe { Ethernet2HeaderSlice::from_slice_unchecked(&buffer) }.to_header(),
        )
    }

    /// Serialize the header to a given slice. Returns the unused part of the slice.
    pub fn write_to_slice<'a>(
        &self,
        slice: &'a mut [u8],
    ) -> Result<&'a mut [u8], SliceWriteSpaceError> {
        // length check
        if slice.len() < Ethernet2Header::LEN {
            Err(SliceWriteSpaceError {
                required_len: Ethernet2Header::LEN,
                len: slice.len(),
                layer: Layer::Ethernet2Header,
                layer_start_offset: 0,
            })
        } else {
            slice[..Ethernet2Header::LEN].copy_from_slice(&self.to_bytes());
            Ok(&mut slice[Ethernet2Header::LEN..])
        }
    }

    /// Writes a given Ethernet-II header to the current position of the write argument.
    #[cfg(feature = "std")]
    #[cfg_attr(docsrs, doc(cfg(feature = "std")))]
    #[inline]
    pub fn write<T: std::io::Write + Sized>(&self, writer: &mut T) -> Result<(), std::io::Error> {
        writer.write_all(&self.to_bytes())
    }

    /// Length of the serialized header in bytes.
    #[inline]
    pub fn header_len(&self) -> usize {
        14
    }

    /// Returns the serialized form of the header as a statically
    /// sized byte array.
    #[inline]
    pub fn to_bytes(&self) -> [u8; 14] {
        let ether_type_be = self.ether_type.0.to_be_bytes();
        [
            self.destination[0],
            self.destination[1],
            self.destination[2],
            self.destination[3],
            self.destination[4],
            self.destination[5],
            self.source[0],
            self.source[1],
            self.source[2],
            self.source[3],
            self.source[4],
            self.source[5],
            ether_type_be[0],
            ether_type_be[1],
        ]
    }
}

#[cfg(test)]
mod test {
    use super::*;
    use crate::test_gens::*;
    use alloc::{format, vec::Vec};
    use proptest::prelude::*;
    use std::io::{Cursor, ErrorKind};

    #[test]
    fn default() {
        let e: Ethernet2Header = Default::default();
        assert_eq!([0u8; 6], e.source);
        assert_eq!([0u8; 6], e.destination);
        assert_eq!(EtherType(0), e.ether_type);
    }

    proptest! {
        #[test]
        fn from_slice(
            input in ethernet_2_any(),
            dummy_data in proptest::collection::vec(any::<u8>(), 0..20)
        ) {
            // serialize
            let mut buffer: Vec<u8> = Vec::with_capacity(14 + dummy_data.len());
            input.write(&mut buffer).unwrap();
            buffer.extend(&dummy_data[..]);

            // calls with a valid result
            {
                let (result, rest) = Ethernet2Header::from_slice(&buffer[..]).unwrap();
                assert_eq!(input, result);
                assert_eq!(&buffer[14..], rest);
            }
            #[allow(deprecated)]
            {
                let (result, rest) = Ethernet2Header::read_from_slice(&buffer[..]).unwrap();
                assert_eq!(input, result);
                assert_eq!(&buffer[14..], rest);
            }

            // call with not enough data in the slice
            for len in 0..=13 {
                assert_eq!(
                    Ethernet2Header::from_slice(&buffer[..len]),
                    Err(err::LenError{
                        required_len: Ethernet2Header::LEN,
                        len: len,
                        len_source: LenSource::Slice,
                        layer: err::Layer::Ethernet2Header,
                        layer_start_offset: 0,
                    })
                );
            }
        }
    }

    proptest! {
        #[test]
        fn from_bytes(input in ethernet_2_any()) {
            assert_eq!(
                input,
                Ethernet2Header::from_bytes(input.to_bytes())
            );
        }
    }

    proptest! {
        #[test]
        fn read(
            input in ethernet_2_any(),
            dummy_data in proptest::collection::vec(any::<u8>(), 0..20)
        ) {
            // normal read
            let mut buffer = Vec::with_capacity(14 + dummy_data.len());
            input.write(&mut buffer).unwrap();
            buffer.extend(&dummy_data[..]);

            // calls with a valid result
            {
                let mut cursor = Cursor::new(&buffer);
                let result = Ethernet2Header::read(&mut cursor).unwrap();
                assert_eq!(input, result);
                assert_eq!(cursor.position(), 14);
            }

            // unexpected eof
            for len in 0..=13 {
                let mut cursor = Cursor::new(&buffer[0..len]);
                assert_eq!(
                    Ethernet2Header::read(&mut cursor)
                    .unwrap_err()
                    .kind(),
                    ErrorKind::UnexpectedEof
                );
            }
        }
    }

    proptest! {
        #[test]
        fn write_to_slice(input in ethernet_2_any()) {
            // normal write
            {
                let mut buffer: [u8;14] = [0;14];
                input.write_to_slice(&mut buffer).unwrap();
                assert_eq!(buffer, input.to_bytes());
            }
            // len to small
            for len in 0..14 {
                let mut buffer: [u8;14] = [0;14];
                assert_eq!(
                    SliceWriteSpaceError {
                        required_len: Ethernet2Header::LEN,
                        len,
                        layer: Layer::Ethernet2Header,
                        layer_start_offset: 0,
                    },
                    input.write_to_slice(&mut buffer[..len]).unwrap_err()
                );
            }
        }
    }

    proptest! {
        #[test]
        fn write(input in ethernet_2_any()) {
            // successful write
            {
                let mut buffer: Vec<u8> = Vec::with_capacity(14);
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
        fn header_len(input in ethernet_2_any()) {
            assert_eq!(input.header_len(), 14);
        }
    }

    proptest! {
        #[test]
        fn to_bytes(input in ethernet_2_any()) {
            let ether_type_be = input.ether_type.0.to_be_bytes();
            assert_eq!(
                input.to_bytes(),
                [
                    input.destination[0],
                    input.destination[1],
                    input.destination[2],
                    input.destination[3],
                    input.destination[4],
                    input.destination[5],
                    input.source[0],
                    input.source[1],
                    input.source[2],
                    input.source[3],
                    input.source[4],
                    input.source[5],
                    ether_type_be[0],
                    ether_type_be[1],
                ]
            );
        }
    }

    proptest! {
        #[test]
        fn clone_eq(input in ethernet_2_any()) {
            assert_eq!(input, input.clone());
        }
    }

    proptest! {
        #[test]
        fn dbg(input in ethernet_2_any()) {
            assert_eq!(
                &format!(
                    "Ethernet2Header {{ source: {:?}, destination: {:?}, ether_type: {:?} }}",
                    input.source,
                    input.destination,
                    input.ether_type
                ),
                &format!("{:?}", input)
            );
        }
    }
}
