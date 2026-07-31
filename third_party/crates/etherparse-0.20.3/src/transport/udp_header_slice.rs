use crate::*;
use core::slice::from_raw_parts;

///A slice containing an udp header of a network package. Struct allows the selective read of fields in the header.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct UdpHeaderSlice<'a> {
    pub(crate) slice: &'a [u8],
}

impl<'a> UdpHeaderSlice<'a> {
    /// Creates a slice containing an udp header.
    #[inline]
    pub fn from_slice(slice: &'a [u8]) -> Result<UdpHeaderSlice<'a>, err::LenError> {
        //check length
        if slice.len() < UdpHeader::LEN {
            return Err(err::LenError {
                required_len: UdpHeader::LEN,
                len: slice.len(),
                len_source: LenSource::Slice,
                layer: err::Layer::UdpHeader,
                layer_start_offset: 0,
            });
        }

        //done
        Ok(UdpHeaderSlice {
            // SAFETY:
            // Safe as slice length is checked to be at least
            // UdpHeader::LEN (8) before this.
            slice: unsafe { from_raw_parts(slice.as_ptr(), UdpHeader::LEN) },
        })
    }

    /// Returns the slice containing the udp header
    #[inline]
    pub fn slice(&self) -> &'a [u8] {
        self.slice
    }

    /// Reads the "udp source port" from the slice.
    #[inline]
    pub fn source_port(&self) -> u16 {
        // SAFETY:
        // Safe as the contructor checks that the slice has
        // at least the length of UdpHeader::LEN (8).
        unsafe { get_unchecked_be_u16(self.slice.as_ptr()) }
    }

    /// Reads the "udp destination port" from the slice.
    #[inline]
    pub fn destination_port(&self) -> u16 {
        // SAFETY:
        // Safe as the contructor checks that the slice has
        // at least the length of UdpHeader::LEN (8).
        unsafe { get_unchecked_be_u16(self.slice.as_ptr().add(2)) }
    }

    /// Reads the "length" from the slice.
    #[inline]
    pub fn length(&self) -> u16 {
        // SAFETY:
        // Safe as the contructor checks that the slice has
        // at least the length of UdpHeader::LEN (8).
        unsafe { get_unchecked_be_u16(self.slice.as_ptr().add(4)) }
    }

    /// Reads the "checksum" from the slice.
    #[inline]
    pub fn checksum(&self) -> u16 {
        // SAFETY:
        // Safe as the contructor checks that the slice has
        // at least the length of UdpHeader::LEN (8).
        unsafe { get_unchecked_be_u16(self.slice.as_ptr().add(6)) }
    }

    /// Decode all the fields and copy the results to a UdpHeader struct
    #[inline]
    pub fn to_header(&self) -> UdpHeader {
        UdpHeader {
            source_port: self.source_port(),
            destination_port: self.destination_port(),
            length: self.length(),
            checksum: self.checksum(),
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
        fn from_slice(
            input in udp_any(),
            dummy_data in proptest::collection::vec(any::<u8>(), 0..20)
        ) {
            // serialize
            let mut buffer: Vec<u8> = Vec::with_capacity(8 + dummy_data.len());
            input.write(&mut buffer).unwrap();
            buffer.extend(&dummy_data[..]);

            // calls with a valid result
            {
                let result = UdpHeaderSlice::from_slice(&buffer[..]).unwrap();
                assert_eq!(&buffer[..8], result.slice());
            }

            // call with not enough data in the slice
            for len in 0..8 {
                assert_eq!(
                    UdpHeaderSlice::from_slice(&buffer[0..len]).unwrap_err(),
                    err::LenError{
                        required_len: UdpHeader::LEN,
                        len: len,
                        len_source: LenSource::Slice,
                        layer: err::Layer::UdpHeader,
                        layer_start_offset: 0,
                    }
                );
            }
        }
    }

    proptest! {
        #[test]
        fn getters(input in udp_any()) {
            let bytes = input.to_bytes();
            let slice = UdpHeaderSlice::from_slice(&bytes).unwrap();

            assert_eq!(slice.source_port(), input.source_port);
            assert_eq!(slice.destination_port(), input.destination_port);
            assert_eq!(slice.length(), input.length);
            assert_eq!(slice.checksum(), input.checksum);
        }
    }

    proptest! {
        #[test]
        fn to_header(input in udp_any()) {
            let bytes = input.to_bytes();
            let slice = UdpHeaderSlice::from_slice(&bytes).unwrap();
            assert_eq!(input, slice.to_header());
        }
    }

    proptest! {
        #[test]
        fn clone_eq(input in udp_any()) {
            let bytes = input.to_bytes();
            let slice = UdpHeaderSlice::from_slice(&bytes).unwrap();
            assert_eq!(slice, slice.clone());
        }
    }

    proptest! {
        #[test]
        fn dbg(input in udp_any()) {
            let bytes = input.to_bytes();
            let slice = UdpHeaderSlice::from_slice(&bytes).unwrap();
            assert_eq!(
                &format!(
                    "UdpHeaderSlice {{ slice: {:?} }}",
                    slice.slice()
                ),
                &format!("{:?}", slice)
            );
        }
    }
}
