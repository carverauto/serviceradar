use crate::*;
use core::slice::from_raw_parts;

/// Deprecated use [IpAuthHeaderSlice] instead.
#[deprecated(
    since = "0.14.0",
    note = "Please use the type IpAuthHeaderSlice instead"
)]
pub type IpAuthenticationHeaderSlice<'a> = IpAuthHeaderSlice<'a>;

/// A slice containing an IP Authentication Header (rfc4302)
#[derive(Copy, Clone, Debug, Eq, PartialEq)]
pub struct IpAuthHeaderSlice<'a> {
    slice: &'a [u8],
}

impl<'a> IpAuthHeaderSlice<'a> {
    /// Creates a ip authentication header slice from a slice.
    pub fn from_slice(
        slice: &'a [u8],
    ) -> Result<IpAuthHeaderSlice<'a>, err::ip_auth::HeaderSliceError> {
        use err::ip_auth::{HeaderError::*, HeaderSliceError::*};

        // check slice length
        if slice.len() < IpAuthHeader::MIN_LEN {
            return Err(Len(err::LenError {
                required_len: IpAuthHeader::MIN_LEN,
                len: slice.len(),
                len_source: LenSource::Slice,
                layer: err::Layer::IpAuthHeader,
                layer_start_offset: 0,
            }));
        }

        // SAFETY:
        // Safe the slice length gets checked to be at least 12 beforehand.
        let payload_len_enc = unsafe { *slice.get_unchecked(1) };

        // check header length minimum size
        if payload_len_enc < 1 {
            return Err(Content(ZeroPayloadLen));
        }

        // check length
        // note: The unit is different then all other ipv6 extension headers.
        //       In the other headers the length is in 8 octets, but for authentication
        //       headers the length is in 4 octets.
        let len = ((payload_len_enc as usize) + 2) * 4;
        if slice.len() < len {
            return Err(Len(err::LenError {
                required_len: len,
                len: slice.len(),
                len_source: LenSource::Slice,
                layer: err::Layer::IpAuthHeader,
                layer_start_offset: 0,
            }));
        }

        // all good
        Ok(IpAuthHeaderSlice {
            // SAFETY:
            // Safe as slice len is checked to be at last len above.
            slice: unsafe { from_raw_parts(slice.as_ptr(), len) },
        })
    }

    /// Creates a ip authentication header slice from a slice (assumes slice size & content was validated before).
    ///
    /// # Safety
    ///
    /// This method assumes that the slice was previously validated to contain
    /// a valid authentication header. This means the slice length must at
    /// least be at least 8 and `(slice[1] + 2)*4`. The data that the
    /// slice points must also be valid (meaning no nullptr or alike allowed).
    ///
    /// If these preconditions are not fulfilled the behavior of this function
    /// and the methods of the return IpAuthHeaderSlice will be undefined.
    pub unsafe fn from_slice_unchecked(slice: &'a [u8]) -> IpAuthHeaderSlice<'a> {
        IpAuthHeaderSlice {
            slice: from_raw_parts(slice.as_ptr(), ((*slice.get_unchecked(1) as usize) + 2) * 4),
        }
    }

    /// Returns the slice containing the authentication header.
    #[inline]
    pub fn slice(&self) -> &'a [u8] {
        self.slice
    }

    /// Returns the IP protocol number of the next header or transport layer protocol.
    ///
    /// See [IpNumber] or [ip_number] for a definition of the known values.
    #[inline]
    pub fn next_header(&self) -> IpNumber {
        // SAFETY:
        // Safe as slice length is checked in the constructor
        // to be at least 12.
        IpNumber(unsafe { *self.slice.get_unchecked(0) })
    }

    /// Read the security parameters index from the slice
    #[inline]
    pub fn spi(&self) -> u32 {
        // SAFETY:
        // Safe as slice length is checked in the constructor
        // to be at least 12.
        unsafe { get_unchecked_be_u32(self.slice.as_ptr().add(4)) }
    }

    /// This unsigned 32-bit field contains a counter value that
    /// increases by one for each packet sent.
    #[inline]
    pub fn sequence_number(&self) -> u32 {
        // SAFETY:
        // Safe as slice length is checked in the constructor
        // to be at least 12.
        unsafe { get_unchecked_be_u32(self.slice.as_ptr().add(8)) }
    }

    /// Return a slice with the raw integrity check value
    pub fn raw_icv(&self) -> &'a [u8] {
        &self.slice[12..]
    }

    /// Decode some of the fields and copy the results to a
    /// Ipv6ExtensionHeader struct together with a slice pointing
    /// to the non decoded parts.
    pub fn to_header(&self) -> IpAuthHeader {
        IpAuthHeader::new(
            self.next_header(),
            self.spi(),
            self.sequence_number(),
            self.raw_icv(),
        )
        .unwrap()
    }
}

#[cfg(test)]
mod test {
    use super::*;
    use crate::test_gens::*;
    use alloc::format;
    use arrayvec::ArrayVec;
    use err::ip_auth::{HeaderError::*, HeaderSliceError::*};
    use proptest::prelude::*;

    proptest! {
        #[test]
        fn debug(input in ip_auth_any()) {
            let buffer = input.to_bytes();
            let slice = IpAuthHeaderSlice::from_slice(&buffer).unwrap();
            assert_eq!(
                &format!(
                    "IpAuthHeaderSlice {{ slice: {:?} }}",
                    slice.slice()
                ),
                &format!("{:?}", slice)
            );
        }
    }

    #[test]
    fn clone_eq() {
        let buffer = IpAuthHeader::new(0.into(), 0, 0, &[0; 4])
            .unwrap()
            .to_bytes();
        let slice = IpAuthHeaderSlice::from_slice(&buffer).unwrap();
        assert_eq!(slice.clone(), slice);
    }

    proptest! {
        #[test]
        fn from_slice(header in ip_auth_any()) {

            // ok
            {
                let mut bytes = ArrayVec::<u8, {IpAuthHeader::MAX_LEN + 2}>::new();
                bytes.extend(header.to_bytes());
                bytes.push(1);
                bytes.push(2);

                let slice = IpAuthHeaderSlice::from_slice(&bytes).unwrap();
                assert_eq!(slice.slice(), &bytes[..bytes.len() - 2]);
            }

            // length error
            {
                let bytes = header.to_bytes();
                for len in 0..header.header_len() {
                    assert_eq!(
                        IpAuthHeaderSlice::from_slice(&bytes[..len]).unwrap_err(),
                        Len(err::LenError{
                            required_len: if len < IpAuthHeader::MIN_LEN {
                                IpAuthHeader::MIN_LEN
                            } else {
                                header.header_len()
                            },
                            len: len,
                            len_source: LenSource::Slice,
                            layer: err::Layer::IpAuthHeader,
                            layer_start_offset: 0,
                        })
                    );
                }
            }

            // payload length error
            {
                let mut bytes = header.to_bytes();
                // set payload length to 0
                bytes[1] = 0;
                assert_eq!(
                    IpAuthHeaderSlice::from_slice(&bytes).unwrap_err(),
                    Content(ZeroPayloadLen)
                );
            }
        }
    }

    proptest! {
        #[test]
        fn from_slice_unchecked(header in ip_auth_any()) {
            let bytes = header.to_bytes();
            let slice = unsafe {
                IpAuthHeaderSlice::from_slice_unchecked(&bytes)
            };
            assert_eq!(slice.slice(), &bytes[..]);
        }
    }

    proptest! {
        #[test]
        fn getters(header in ip_auth_any()) {
            let bytes = header.to_bytes();
            let slice = IpAuthHeaderSlice::from_slice(&bytes).unwrap();
            assert_eq!(slice.slice(), &bytes[..]);
            assert_eq!(slice.next_header(), header.next_header);
            assert_eq!(slice.spi(), header.spi);
            assert_eq!(slice.sequence_number(), header.sequence_number);
            assert_eq!(slice.raw_icv(), header.raw_icv());
        }
    }

    proptest! {
        #[test]
        fn to_header(header in ip_auth_any()) {
            let bytes = header.to_bytes();
            assert_eq!(
                header,
                IpAuthHeaderSlice::from_slice(&bytes)
                    .unwrap()
                    .to_header()
            );
        }
    }
}
