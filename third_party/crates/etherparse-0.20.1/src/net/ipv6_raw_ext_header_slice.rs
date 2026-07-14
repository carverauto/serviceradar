use crate::*;
use core::slice::from_raw_parts;

/// Deprecated. Use [Ipv6RawExtHeaderSlice] instead.
#[deprecated(
    since = "0.14.0",
    note = "Please use the type Ipv6RawExtHeaderSlice instead"
)]
pub type Ipv6RawExtensionHeaderSlice<'a> = Ipv6RawExtHeaderSlice<'a>;

/// Slice containing an IPv6 extension header without specific decoding methods (fallback in case no specific implementation is available).
///
/// Slice containing an IPv6 extension header with only minimal data interpretation. NOTE only ipv6 header
/// extensions with the first two bytes representing the next header and the header length
/// in 8-octets (- 8 octets) can be represented with this struct. This excludes the "Authentication
/// Header" (AH) and "Encapsulating Security Payload" (ESP).
///
/// The following headers can be represented in a Ipv6ExtensionHeaderSlice:
/// * HopbyHop
/// * Destination Options
/// * Routing
/// * Mobility
/// * Host Identity Protocol
/// * Shim6 Protocol
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Ipv6RawExtHeaderSlice<'a> {
    /// Slice containing the packet data.
    slice: &'a [u8],
}

impl<'a> Ipv6RawExtHeaderSlice<'a> {
    /// Returns true if the given header type ip number can be represented in an `Ipv6ExtensionHeaderSlice`.
    pub fn header_type_supported(next_header: IpNumber) -> bool {
        Ipv6RawExtHeader::header_type_supported(next_header)
    }

    /// Creates a generic ipv6 extension header slice from a slice.
    pub fn from_slice(slice: &'a [u8]) -> Result<Ipv6RawExtHeaderSlice<'a>, err::LenError> {
        //check length
        if slice.len() < 8 {
            return Err(err::LenError {
                required_len: 8,
                len: slice.len(),
                len_source: LenSource::Slice,
                layer: err::Layer::Ipv6ExtHeader,
                layer_start_offset: 0,
            });
        }

        //check length
        let len = ((slice[1] as usize) + 1) * 8;

        //check the length again now that the expected length is known
        if slice.len() < len {
            return Err(err::LenError {
                required_len: len,
                len: slice.len(),
                len_source: LenSource::Slice,
                layer: err::Layer::Ipv6ExtHeader,
                layer_start_offset: 0,
            });
        }

        //all good
        Ok(Ipv6RawExtHeaderSlice {
            // SAFETY:
            // Safe as the slice has been checked in the previous if
            // to have at least the the length of the variable len.
            slice: unsafe { from_raw_parts(slice.as_ptr(), len) },
        })
    }

    /// Creates a raw ipv6 extension header slice from a slice (assumes slice
    /// size & content was validated before).
    ///
    /// # Safety
    ///
    /// This method assumes that the slice was previously validated to contain
    /// a valid & supported raw ipv6 extension header. This means the slice length
    /// must at least be at least 8 and `(slice[1] + 1)*8`. The data that the
    /// slice points must also be valid (meaning no nullptr or alike allowed).
    ///
    /// If these preconditions are not fulfilled the behavior of this function
    /// and the methods of the return [`IpAuthHeaderSlice`] will be undefined.
    pub unsafe fn from_slice_unchecked(slice: &'a [u8]) -> Ipv6RawExtHeaderSlice<'a> {
        Ipv6RawExtHeaderSlice {
            slice: from_raw_parts(slice.as_ptr(), ((*slice.get_unchecked(1) as usize) + 1) * 8),
        }
    }

    /// Returns the slice containing the ipv6 extension header
    #[inline]
    pub fn slice(&self) -> &'a [u8] {
        self.slice
    }

    /// Returns the IP protocol number of the next header or transport layer protocol.
    ///
    /// See [IpNumber] or [ip_number] for a definition of the known values.
    #[inline]
    pub fn next_header(&self) -> IpNumber {
        IpNumber(unsafe { *self.slice.get_unchecked(0) })
    }

    /// Returns a slice containing the payload data of the header.
    ///
    /// This contains all the data after the header length field
    /// until the end of the header (length specified by the
    /// hdr ext length field).
    #[inline]
    pub fn payload(&self) -> &'a [u8] {
        unsafe { from_raw_parts(self.slice.as_ptr().add(2), self.slice.len() - 2) }
    }

    /// Convert the slice to an [Ipv6RawExtHeader].
    ///
    /// Decode some of the fields and copy the results to a
    /// [Ipv6RawExtHeader] struct together with a slice pointing
    /// to the non decoded parts.
    pub fn to_header(&self) -> Ipv6RawExtHeader {
        Ipv6RawExtHeader::new_raw(self.next_header(), self.payload()).unwrap()
    }
}

#[cfg(test)]
mod test {
    use crate::{test_gens::*, *};
    use alloc::{format, vec::Vec};
    use proptest::prelude::*;

    proptest! {
        #[test]
        fn debug(header in ipv6_raw_ext_any()) {
            let bytes = header.to_bytes();
            let slice = Ipv6RawExtHeaderSlice::from_slice(&bytes).unwrap();
            assert_eq!(
                format!("{:?}", slice),
                format!("Ipv6RawExtHeaderSlice {{ slice: {:?} }}", slice.slice())
            );
        }
    }

    proptest! {
        #[test]
        fn clone_eq(header in ipv6_raw_ext_any()) {
            let bytes = header.to_bytes();
            let slice = Ipv6RawExtHeaderSlice::from_slice(&bytes).unwrap();
            assert_eq!(slice.clone(), slice);
        }
    }

    #[test]
    fn header_type_supported() {
        use ip_number::*;
        for value in 0..=u8::MAX {
            let expected_supported = match IpNumber(value) {
                IPV6_HOP_BY_HOP | IPV6_DEST_OPTIONS | IPV6_ROUTE | MOBILITY | HIP | SHIM6 => true,
                _ => false,
            };
            assert_eq!(
                expected_supported,
                Ipv6RawExtHeaderSlice::header_type_supported(IpNumber(value))
            );
        }
    }

    proptest! {
        #[test]
        fn from_slice(header in ipv6_raw_ext_any()) {
            // ok
            {
                let mut bytes = Vec::with_capacity(header.header_len() + 2);
                bytes.extend_from_slice(&header.to_bytes());
                bytes.push(1);
                bytes.push(2);

                let (actual_header, actual_rest) = Ipv6RawExtHeader::from_slice(&bytes).unwrap();
                assert_eq!(actual_header, header);
                assert_eq!(actual_rest, &[1, 2]);
            }

            // length error
            {
                let bytes = header.to_bytes();
                for len in 0..bytes.len() {
                    assert_eq!(
                        Ipv6RawExtHeader::from_slice(&bytes[..len]).unwrap_err(),
                        err::LenError{
                            required_len: if len < Ipv6RawExtHeader::MIN_LEN {
                                Ipv6RawExtHeader::MIN_LEN
                            } else {
                                header.header_len()
                            },
                            len: len,
                            len_source: LenSource::Slice,
                            layer: err::Layer::Ipv6ExtHeader,
                            layer_start_offset: 0,
                        }
                    );
                }
            }
        }
    }

    proptest! {
        #[test]
        fn from_slice_unchecked(header in ipv6_raw_ext_any()) {
            let bytes = header.to_bytes();
            let slice = unsafe {
                Ipv6RawExtHeaderSlice::from_slice_unchecked(&bytes)
            };
            assert_eq!(&bytes[..], slice.slice());
        }
    }

    proptest! {
        #[test]
        fn getters(header in ipv6_raw_ext_any()) {
            let bytes = header.to_bytes();
            let slice = Ipv6RawExtHeaderSlice::from_slice(&bytes).unwrap();
            assert_eq!(slice.next_header(), header.next_header);
            assert_eq!(slice.payload(), header.payload());
        }
    }

    proptest! {
        #[test]
        fn to_header(header in ipv6_raw_ext_any()) {
            let bytes = header.to_bytes();
            let slice = Ipv6RawExtHeaderSlice::from_slice(&bytes).unwrap();
            assert_eq!(header, slice.to_header());
        }
    }
}
