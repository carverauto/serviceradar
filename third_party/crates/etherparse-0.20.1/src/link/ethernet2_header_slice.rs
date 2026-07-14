use crate::*;
use core::slice::from_raw_parts;

///A slice containing an ethernet 2 header of a network package.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Ethernet2HeaderSlice<'a> {
    pub(crate) slice: &'a [u8],
}

impl<'a> Ethernet2HeaderSlice<'a> {
    /// Creates a ethernet slice from an other slice.
    pub fn from_slice(slice: &'a [u8]) -> Result<Ethernet2HeaderSlice<'a>, err::LenError> {
        //check length
        if slice.len() < Ethernet2Header::LEN {
            return Err(err::LenError {
                required_len: Ethernet2Header::LEN,
                len: slice.len(),
                len_source: LenSource::Slice,
                layer: err::Layer::Ethernet2Header,
                layer_start_offset: 0,
            });
        }

        //all done
        Ok(Ethernet2HeaderSlice {
            // SAFETY:
            // Safe as slice length is checked to be at least
            // Ethernet2Header::LEN (14) before this.
            slice: unsafe { from_raw_parts(slice.as_ptr(), Ethernet2Header::LEN) },
        })
    }

    /// Converts the given slice into a ethernet 2 header slice WITHOUT any
    /// checks to ensure that the data present is an ethernet 2 header or that the
    /// slice length is matching the header length.
    ///
    /// If you are not sure what this means, use [`Ethernet2HeaderSlice::from_slice`]
    /// instead.
    ///
    /// # Safety
    ///
    /// The caller must ensured that the given slice has the length of
    /// [`Ethernet2Header::LEN`]
    #[inline]
    #[cfg(feature = "std")]
    pub(crate) unsafe fn from_slice_unchecked(slice: &[u8]) -> Ethernet2HeaderSlice<'_> {
        debug_assert!(slice.len() == Ethernet2Header::LEN);
        Ethernet2HeaderSlice { slice }
    }

    /// Returns the slice containing the ethernet 2 header
    #[inline]
    pub fn slice(&self) -> &'a [u8] {
        self.slice
    }

    /// Read the destination MAC address
    #[inline]
    pub fn destination(&self) -> [u8; 6] {
        // SAFETY:
        // Safe as the contructor checks that the slice has
        // at least the length of Ethernet2Header::LEN (14).
        unsafe { get_unchecked_6_byte_array(self.slice.as_ptr()) }
    }

    /// Read the source MAC address
    #[inline]
    pub fn source(&self) -> [u8; 6] {
        // SAFETY:
        // Safe as the contructor checks that the slice has
        // at least the length of Ethernet2Header::LEN (14).
        unsafe { get_unchecked_6_byte_array(self.slice.as_ptr().add(6)) }
    }

    /// Read the ether_type field of the header indicating the protocol
    /// after the header.
    #[inline]
    pub fn ether_type(&self) -> EtherType {
        // SAFETY:
        // Safe as the contructor checks that the slice has
        // at least the length of Ethernet2Header::LEN (14).
        EtherType(unsafe { get_unchecked_be_u16(self.slice.as_ptr().add(12)) })
    }

    /// Decode all the fields and copy the results to a [`Ethernet2Header`] struct
    pub fn to_header(&self) -> Ethernet2Header {
        Ethernet2Header {
            source: self.source(),
            destination: self.destination(),
            ether_type: self.ether_type(),
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
            input in ethernet_2_any(),
            dummy_data in proptest::collection::vec(any::<u8>(), 0..20)
        ) {
            // serialize
            let mut buffer: Vec<u8> = Vec::with_capacity(14 + dummy_data.len());
            input.write(&mut buffer).unwrap();
            buffer.extend(&dummy_data[..]);

            // calls with a valid result
            {
                let result = Ethernet2HeaderSlice::from_slice(&buffer[..]).unwrap();
                assert_eq!(&buffer[..14], result.slice());
            }

            // call with not enough data in the slice
            for len in 0..=13 {
                assert_eq!(
                    Ethernet2HeaderSlice::from_slice(&buffer[..len]),
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
        fn getters(input in ethernet_2_any()) {
            let buffer = input.to_bytes();
            let slice = Ethernet2HeaderSlice::from_slice(&buffer).unwrap();
            assert_eq!(input.destination, slice.destination());
            assert_eq!(input.source, slice.source());
            assert_eq!(input.ether_type, slice.ether_type());
        }
    }

    proptest! {
        #[test]
        fn to_header(input in ethernet_2_any()) {
            let buffer = input.to_bytes();
            let slice = Ethernet2HeaderSlice::from_slice(&buffer).unwrap();
            assert_eq!(input, slice.to_header());
        }
    }

    proptest! {
        #[test]
        fn clone_eq(input in ethernet_2_any()) {
            let buffer = input.to_bytes();
            let slice = Ethernet2HeaderSlice::from_slice(&buffer).unwrap();
            assert_eq!(slice, slice.clone());
        }
    }

    proptest! {
        #[test]
        fn dbg(input in ethernet_2_any()) {
            let buffer = input.to_bytes();
            let slice = Ethernet2HeaderSlice::from_slice(&buffer).unwrap();
            assert_eq!(
                &format!(
                    "Ethernet2HeaderSlice {{ slice: {:?} }}",
                    slice.slice()
                ),
                &format!("{:?}", slice)
            );
        }
    }
}
