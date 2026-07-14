use crate::*;

/// IEEE 802.1Q VLAN Tagging Header
#[derive(Clone, Debug, Eq, PartialEq, Default)]
pub struct SingleVlanHeader {
    /// A 3 bit number which refers to the IEEE 802.1p class of service and maps to the frame priority level.
    pub pcp: VlanPcp,
    /// Indicate that the frame may be dropped under the presence of congestion.
    pub drop_eligible_indicator: bool,
    /// 12 bits vland identifier.
    pub vlan_id: VlanId,
    /// "Tag protocol identifier": Type id of content after this header. Refer to the "EtherType" for a list of possible supported values.
    pub ether_type: EtherType,
}

impl SingleVlanHeader {
    /// Serialized size of an VLAN header in bytes/octets.
    pub const LEN: usize = 4;

    #[deprecated(since = "0.14.0", note = "Use `SingleVlanHeader::LEN` instead")]
    pub const SERIALIZED_SIZE: usize = SingleVlanHeader::LEN;

    /// Read an SingleVlanHeader from a slice and return the header & unused parts of the slice.
    #[deprecated(since = "0.10.1", note = "Use SingleVlanHeader::from_slice instead.")]
    #[inline]
    pub fn read_from_slice(slice: &[u8]) -> Result<(SingleVlanHeader, &[u8]), err::LenError> {
        SingleVlanHeader::from_slice(slice)
    }

    /// Read an SingleVlanHeader from a slice and return the header & unused parts of the slice.
    #[inline]
    pub fn from_slice(slice: &[u8]) -> Result<(SingleVlanHeader, &[u8]), err::LenError> {
        Ok((
            SingleVlanHeaderSlice::from_slice(slice)?.to_header(),
            &slice[SingleVlanHeader::LEN..],
        ))
    }

    /// Read an SingleVlanHeader from a static sized byte array.
    #[inline]
    pub fn from_bytes(bytes: [u8; 4]) -> SingleVlanHeader {
        SingleVlanHeader {
            pcp: unsafe {
                // SAFETY: Safe as bitmasks guarantee that value does not exceed
                //         0b0000_0111.
                VlanPcp::new_unchecked((bytes[0] >> 5) & 0b0000_0111u8)
            },
            drop_eligible_indicator: 0 != (bytes[0] & 0b0001_0000u8),
            vlan_id: unsafe {
                // SAFETY: Safe as bitmasks guarantee that value does not exceed
                //         0b0000_1111_1111_1111.
                VlanId::new_unchecked(u16::from_be_bytes([bytes[0] & 0b0000_1111u8, bytes[1]]))
            },
            ether_type: EtherType(u16::from_be_bytes([bytes[2], bytes[3]])),
        }
    }

    /// Read a IEEE 802.1Q VLAN tagging header
    #[cfg(feature = "std")]
    #[cfg_attr(docsrs, doc(cfg(feature = "std")))]
    pub fn read<T: std::io::Read + std::io::Seek + Sized>(
        reader: &mut T,
    ) -> Result<SingleVlanHeader, std::io::Error> {
        let buffer = {
            let mut buffer: [u8; SingleVlanHeader::LEN] = [0; SingleVlanHeader::LEN];
            reader.read_exact(&mut buffer)?;
            buffer
        };

        Ok(
            // SAFETY: Safe as the buffer has the exact size of an vlan header.
            unsafe { SingleVlanHeaderSlice::from_slice_unchecked(&buffer) }.to_header(),
        )
    }

    /// Write the IEEE 802.1Q VLAN tagging header
    #[inline]
    #[cfg(feature = "std")]
    #[cfg_attr(docsrs, doc(cfg(feature = "std")))]
    pub fn write<T: std::io::Write + Sized>(&self, writer: &mut T) -> Result<(), std::io::Error> {
        writer.write_all(&self.to_bytes())
    }

    /// Length of the serialized header in bytes.
    #[inline]
    pub fn header_len(&self) -> usize {
        4
    }

    /// Returns the serialized form of the header or an value error in case
    /// the header values are outside of range.
    #[inline]
    pub fn to_bytes(&self) -> [u8; 4] {
        let id_be = self.vlan_id.value().to_be_bytes();
        let eth_type_be = self.ether_type.0.to_be_bytes();
        [
            (if self.drop_eligible_indicator {
                id_be[0] | 0x10
            } else {
                id_be[0]
            } | (self.pcp.value() << 5)),
            id_be[1],
            eth_type_be[0],
            eth_type_be[1],
        ]
    }
}

#[cfg(test)]
mod test {
    use crate::{test_gens::*, *};
    use alloc::{format, vec::Vec};
    use proptest::prelude::*;
    use std::io::{Cursor, ErrorKind};

    #[test]
    fn constants() {
        assert_eq!(4, SingleVlanHeader::LEN);
    }

    proptest! {
        #[test]
        fn from_slice(
            input in vlan_single_any(),
            dummy_data in proptest::collection::vec(any::<u8>(), 0..20)
        ) {
            // serialize
            let mut buffer: Vec<u8> = Vec::with_capacity(input.header_len() + dummy_data.len());
            input.write(&mut buffer).unwrap();
            buffer.extend(&dummy_data[..]);

            // normal
            {
                let (result, rest) = SingleVlanHeader::from_slice(&buffer).unwrap();
                assert_eq!(result, input);
                assert_eq!(rest, &buffer[4..]);
            }
            #[allow(deprecated)]
            {
                let (result, rest) = SingleVlanHeader::read_from_slice(&buffer).unwrap();
                assert_eq!(result, input);
                assert_eq!(rest, &buffer[4..]);
            }

            // slice length to small
            for len in 0..4 {
                assert_eq!(
                    SingleVlanHeader::from_slice(&buffer[..len])
                        .unwrap_err(),
                    err::LenError{
                        required_len: 4,
                        len: len,
                        len_source: LenSource::Slice,
                        layer:  err::Layer::VlanHeader,
                        layer_start_offset: 0,
                    }
                );
            }
        }
    }

    proptest! {
        #[test]
        fn from_bytes(input in vlan_single_any()) {
            let actual = SingleVlanHeader::from_bytes(
                input.to_bytes()
            );
            assert_eq!(actual, input);
        }
    }

    proptest! {
        #[test]
        fn read(
            input in vlan_single_any(),
            dummy_data in proptest::collection::vec(any::<u8>(), 0..20)
        ) {
            // serialize
            let mut buffer: Vec<u8> = Vec::with_capacity(input.header_len() + dummy_data.len());
            input.write(&mut buffer).unwrap();
            buffer.extend(&dummy_data[..]);

            // normal
            {
                let mut cursor = Cursor::new(&buffer);
                let result = SingleVlanHeader::read(&mut cursor).unwrap();
                assert_eq!(result, input);
                assert_eq!(4, cursor.position());
            }

            // unexpexted eof
            for len in 0..4 {
                let mut cursor = Cursor::new(&buffer[0..len]);
                assert_eq!(
                    SingleVlanHeader::read(&mut cursor)
                    .unwrap_err()
                    .kind(),
                    ErrorKind::UnexpectedEof
                );
            }
        }
    }

    proptest! {
        #[test]
        fn write_and_to_bytes(input in vlan_single_any()) {
            // normal write
            {
                let mut buffer: Vec<u8> = Vec::with_capacity(input.header_len());
                input.write(&mut buffer).unwrap();
                assert_eq!(&buffer[..], &input.to_bytes());
                {
                    let id_be = input.vlan_id.value().to_be_bytes();
                    let eth_type_be = input.ether_type.0.to_be_bytes();
                    assert_eq!(
                        input.to_bytes(),
                        [
                            (
                                id_be[0] | if input.drop_eligible_indicator {
                                    0x10
                                } else {
                                    0
                                } | (input.pcp.value() << 5)
                            ),
                            id_be[1],
                            eth_type_be[0],
                            eth_type_be[1]
                        ]
                    );
                }
            }

            // unexpected eof
            for len in 0..4 {
                let mut buffer = [0u8;4];
                let mut cursor = Cursor::new(&mut buffer[..len]);
                assert!(input.write(&mut cursor).is_err());
            }
        }
    }

    proptest! {
        #[test]
        fn header_len(input in vlan_single_any()) {
            assert_eq!(4, input.header_len());
        }
    }

    #[test]
    fn default() {
        let actual: SingleVlanHeader = Default::default();
        assert_eq!(0, actual.pcp.value());
        assert_eq!(false, actual.drop_eligible_indicator);
        assert_eq!(0, actual.vlan_id.value());
        assert_eq!(0, actual.ether_type.0);
    }

    proptest! {
        #[test]
        fn clone_eq(input in vlan_single_any()) {
            assert_eq!(input, input.clone());
        }
    }

    proptest! {
        #[test]
        fn dbg(input in vlan_single_any()) {
            assert_eq!(
                &format!(
                    "SingleVlanHeader {{ pcp: {:?}, drop_eligible_indicator: {}, vlan_id: {:?}, ether_type: {:?} }}",
                    input.pcp,
                    input.drop_eligible_indicator,
                    input.vlan_id,
                    input.ether_type,
                ),
                &format!("{:?}", input)
            );
        }
    }
}
