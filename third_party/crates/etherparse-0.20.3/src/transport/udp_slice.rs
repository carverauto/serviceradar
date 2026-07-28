use crate::{err::*, *};

/// Slice containing the UDP headers & payload.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct UdpSlice<'a> {
    slice: &'a [u8],
}

impl<'a> UdpSlice<'a> {
    /// Decode length from UDP header and restrict slice to the length
    /// of the header including the payload.
    ///
    /// Note that this method fall backs to the length of the slice
    /// in the case the length field in the UDP header is set to zero.
    pub fn from_slice(slice: &'a [u8]) -> Result<UdpSlice<'a>, LenError> {
        // slice header
        let header = UdpHeaderSlice::from_slice(slice)?;

        // validate the length of the slice
        let len: usize = header.length().into();
        if slice.len() < len {
            return Err(LenError {
                required_len: len,
                len: slice.len(),
                len_source: LenSource::Slice,
                layer: Layer::UdpPayload,
                layer_start_offset: 0,
            });
        }

        // fallback to the slice length in case length is set to 0
        if len == 0 {
            Ok(UdpSlice { slice })
        } else {
            // validate the length
            if len < UdpHeader::LEN {
                // TODO: Should this replaced with a custom error?
                Err(LenError {
                    required_len: UdpHeader::LEN,
                    len,
                    len_source: LenSource::UdpHeaderLen,
                    layer: Layer::UdpHeader,
                    layer_start_offset: 0,
                })
            } else {
                Ok(UdpSlice {
                    // SAFETY: Safe as slice.len() was validated before to
                    // be at least as big as "len".
                    slice: unsafe { core::slice::from_raw_parts(slice.as_ptr(), len) },
                })
            }
        }
    }

    /// Try decoding length from UDP header and restrict slice to the length
    /// of the header including the payload if possible. If not the slice length
    /// is used as a fallback value.
    ///
    /// Note that this method fall also backs to the length of the slice
    /// in the case the length field in the UDP header is set to zero or smaller
    /// then the minimum header length.
    pub fn from_slice_lax(slice: &'a [u8]) -> Result<UdpSlice<'a>, LenError> {
        // slice header
        let header = UdpHeaderSlice::from_slice(slice)?;

        // validate the length of the slice and fallback to the slice
        // length if the slice is smaller then expected or zero.
        let len: usize = header.length().into();
        if slice.len() < len || len < UdpHeader::LEN {
            Ok(UdpSlice { slice })
        } else {
            Ok(UdpSlice {
                // SAFETY: Safe as slice.len() was validated before to
                // be at least as big as "len".
                slice: unsafe { core::slice::from_raw_parts(slice.as_ptr(), len) },
            })
        }
    }

    /// Return the slice containing the UDP header & payload.
    #[inline]
    pub fn slice(&self) -> &'a [u8] {
        self.slice
    }

    /// Return the slice containing the UDP header.
    #[inline]
    pub fn header_slice(&self) -> &'a [u8] {
        unsafe {
            // SAFETY: Safe as the slice length was verified
            // to be at least UdpHeader::LEN by "from_slice".
            core::slice::from_raw_parts(self.slice.as_ptr(), UdpHeader::LEN)
        }
    }

    /// Returns the slice containing the UDP payload.
    #[inline]
    pub fn payload(&self) -> &'a [u8] {
        unsafe {
            // SAFETY: Safe as the slice length was verified
            // to be at least UdpHeader::LEN by "from_slice".
            core::slice::from_raw_parts(
                self.slice.as_ptr().add(UdpHeader::LEN),
                self.slice.len() - UdpHeader::LEN,
            )
        }
    }

    /// Value that was used to determine the length of the payload.
    #[inline]
    pub fn payload_len_source(&self) -> LenSource {
        if usize::from(self.length()) == self.slice.len() {
            LenSource::UdpHeaderLen
        } else {
            LenSource::Slice
        }
    }

    /// Reads the "udp source port" in the UDP header.
    #[inline]
    pub fn source_port(&self) -> u16 {
        // SAFETY:
        // Safe as the contructor checks that the slice has
        // at least the length of UdpHeader::LEN (8).
        unsafe { get_unchecked_be_u16(self.slice.as_ptr()) }
    }

    /// Reads the "udp destination port" in the UDP header.
    #[inline]
    pub fn destination_port(&self) -> u16 {
        // SAFETY:
        // Safe as the contructor checks that the slice has
        // at least the length of UdpHeader::LEN (8).
        unsafe { get_unchecked_be_u16(self.slice.as_ptr().add(2)) }
    }

    /// Reads the "length" field in the UDP header.
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

    /// Length of the UDP header (equal to [`crate::UdpHeader::LEN`]).
    #[inline]
    pub const fn header_len(&self) -> usize {
        UdpHeader::LEN
    }

    /// Length of the UDP header in an [`u16`] (equal to [`crate::UdpHeader::LEN_U16`]).
    #[inline]
    pub const fn header_len_u16(&self) -> u16 {
        UdpHeader::LEN_U16
    }

    /// Decode all the fields of the UDP header and copy the results
    /// to a UdpHeader struct.
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
    use super::*;
    use crate::test_gens::*;
    use alloc::{format, vec::Vec};
    use proptest::prelude::*;

    proptest! {
        #[test]
        fn debug_clone_eq(
            udp_base in udp_any()
        ) {
            let payload: [u8;4] = [1,2,3,4];
            let mut data = Vec::with_capacity(
                udp_base.header_len() +
                payload.len()
            );
            let mut udp = udp_base.clone();
            udp.length = (UdpHeader::LEN + payload.len()) as u16;
            data.extend_from_slice(&udp.to_bytes());
            data.extend_from_slice(&payload);

            // decode packet
            let slice = UdpSlice::from_slice(&data).unwrap();

            // check debug output
            prop_assert_eq!(
                format!("{:?}", slice),
                format!(
                    "UdpSlice {{ slice: {:?} }}",
                    &data[..]
                )
            );
            prop_assert_eq!(slice.clone(), slice);
        }
    }

    proptest! {
        #[test]
        fn getters(
            udp_base in udp_any()
        ) {
            let udp = {
                let mut udp = udp_base.clone();
                udp.length = UdpHeader::LEN as u16;
                udp
            };
            let data = {
                let mut data = Vec::with_capacity(
                    udp.header_len()
                );
                data.extend_from_slice(&udp.to_bytes());
                data
            };

            // normal decode
            {
                let slice = UdpSlice::from_slice(&data).unwrap();
                assert_eq!(slice.slice(), &data);
                assert_eq!(slice.header_slice(), &data);
                assert_eq!(slice.payload(), &[]);
                assert_eq!(slice.source_port(), udp.source_port);
                assert_eq!(slice.destination_port(), udp.destination_port);
                assert_eq!(slice.length(), udp.length);
                assert_eq!(slice.checksum(), udp.checksum);
                assert_eq!(slice.to_header(), udp);
            }
        }
    }

    proptest! {
        #[test]
        fn from_slice(
            udp_base in udp_any()
        ) {
            let payload: [u8;4] = [1,2,3,4];
            let udp = {
                let mut udp = udp_base.clone();
                udp.length = (UdpHeader::LEN + payload.len()) as u16;
                udp
            };
            let data = {
                let mut data = Vec::with_capacity(
                    udp.header_len() +
                    payload.len()
                );
                data.extend_from_slice(&udp.to_bytes());
                data.extend_from_slice(&payload);
                data
            };

            // normal decode
            {
                let slice = UdpSlice::from_slice(&data).unwrap();
                assert_eq!(udp, slice.to_header());
                assert_eq!(payload, slice.payload());
            }

            // decode a payload smaller then the given slice
            {
                let mut mod_data = data.clone();
                let reduced_len = (UdpHeader::LEN + payload.len() - 1) as u16;
                // inject the reduced length
                {
                    let rl_be = reduced_len.to_be_bytes();
                    mod_data[4] = rl_be[0];
                    mod_data[5] = rl_be[1];
                }

                let slice = UdpSlice::from_slice(&mod_data).unwrap();
                assert_eq!(
                    slice.to_header(),
                    {
                        let mut expected = slice.to_header();
                        expected.length = reduced_len;
                        expected
                    }
                );
                assert_eq!(&payload[..payload.len() - 1], slice.payload());
            }

            // if length is zero the length given by the slice should be used
            {
                // inject zero as length
                let mut mod_data = data.clone();
                mod_data[4] = 0;
                mod_data[5] = 0;

                let slice = UdpSlice::from_slice(&mod_data).unwrap();

                assert_eq!(slice.source_port(), udp_base.source_port);
                assert_eq!(slice.destination_port(), udp_base.destination_port);
                assert_eq!(slice.checksum(), udp_base.checksum);
                assert_eq!(slice.length(), 0);
                assert_eq!(&payload, slice.payload());
            }

            // too little data to even decode the header
            for len in 0..UdpHeader::LEN {
                assert_eq!(
                    UdpSlice::from_slice(&data[..len]).unwrap_err(),
                    LenError {
                        required_len: UdpHeader::LEN,
                        len,
                        len_source: LenSource::Slice,
                        layer: Layer::UdpHeader,
                        layer_start_offset: 0,
                    }
                );
            }

            // slice length smaller then the length described in the header
            assert_eq!(
                UdpSlice::from_slice(&data[..data.len() - 1]).unwrap_err(),
                LenError {
                    required_len: data.len(),
                    len: data.len() - 1,
                    len_source: LenSource::Slice,
                    layer: Layer::UdpPayload,
                    layer_start_offset: 0,
                }
            );

            // length in header smaller than the header itself
            {
                let mut mod_data = data.clone();
                // inject the reduced length
                {
                    let len_be = ((UdpHeader::LEN - 1) as u16).to_be_bytes();
                    mod_data[4] = len_be[0];
                    mod_data[5] = len_be[1];
                }
                assert_eq!(
                    UdpSlice::from_slice(&mod_data).unwrap_err(),
                    LenError {
                        required_len: UdpHeader::LEN,
                        len: UdpHeader::LEN - 1,
                        len_source: LenSource::UdpHeaderLen,
                        layer: Layer::UdpHeader,
                        layer_start_offset: 0
                    }
                );
            }
        }
    }

    proptest! {
        #[test]
        fn from_slice_lax(
            udp_base in udp_any()
        ) {
            let payload: [u8;4] = [1,2,3,4];
            let udp = {
                let mut udp = udp_base.clone();
                udp.length = (UdpHeader::LEN + payload.len()) as u16;
                udp
            };
            let data = {
                let mut data = Vec::with_capacity(
                    udp.header_len() +
                    payload.len()
                );
                data.extend_from_slice(&udp.to_bytes());
                data.extend_from_slice(&payload);
                data
            };

            // normal decode
            {
                let slice = UdpSlice::from_slice_lax(&data).unwrap();
                assert_eq!(udp, slice.to_header());
                assert_eq!(payload, slice.payload());
                assert_eq!(slice.payload_len_source(), LenSource::UdpHeaderLen);
            }

            // decode a payload smaller then the given slice
            {
                let mut mod_data = data.clone();
                let reduced_len = (UdpHeader::LEN + payload.len() - 1) as u16;
                // inject the reduced length
                {
                    let rl_be = reduced_len.to_be_bytes();
                    mod_data[4] = rl_be[0];
                    mod_data[5] = rl_be[1];
                }

                let slice = UdpSlice::from_slice_lax(&mod_data).unwrap();
                assert_eq!(
                    slice.to_header(),
                    {
                        let mut expected = slice.to_header();
                        expected.length = reduced_len;
                        expected
                    }
                );
                assert_eq!(&payload[..payload.len() - 1], slice.payload());
                assert_eq!(slice.payload_len_source(), LenSource::UdpHeaderLen);
            }

            // if length is zero the length given by the slice should be used
            for len in 0..UdpHeader::LEN_U16{
                // inject zero as length
                let mut mod_data = data.clone();
                mod_data[4] = len.to_be_bytes()[0];
                mod_data[5] = len.to_be_bytes()[1];

                let slice = UdpSlice::from_slice_lax(&mod_data).unwrap();

                assert_eq!(slice.source_port(), udp_base.source_port);
                assert_eq!(slice.destination_port(), udp_base.destination_port);
                assert_eq!(slice.checksum(), udp_base.checksum);
                assert_eq!(slice.length(), len);
                assert_eq!(&payload, slice.payload());
                assert_eq!(slice.payload_len_source(), LenSource::Slice);
            }

            // too little data to even decode the header
            for len in 0..UdpHeader::LEN {
                assert_eq!(
                    UdpSlice::from_slice_lax(&data[..len]).unwrap_err(),
                    LenError {
                        required_len: UdpHeader::LEN,
                        len,
                        len_source: LenSource::Slice,
                        layer: Layer::UdpHeader,
                        layer_start_offset: 0,
                    }
                );
            }

            // slice length smaller then the length described in the header
            {
                let slice = UdpSlice::from_slice_lax(&data[..data.len() - 1]).unwrap();
                assert_eq!(udp, slice.to_header());
                assert_eq!(&payload[..payload.len() - 1], slice.payload());
                assert_eq!(slice.payload_len_source(), LenSource::Slice);
            }
        }
    }

    proptest! {
        #[test]
        fn header_len(
            udp in udp_any()
        ) {
            let mut udp = udp.clone();
            udp.length = UdpHeader::LEN_U16;
            let bytes = udp.to_bytes();
            let slice = UdpSlice::from_slice(&bytes).unwrap();
            assert_eq!(UdpHeader::LEN, slice.header_len());
        }
    }

    proptest! {
        #[test]
        fn header_len_u16(
            udp in udp_any()
        ) {
            let mut udp = udp.clone();
            udp.length = UdpHeader::LEN_U16;
            let bytes = udp.to_bytes();
            let slice = UdpSlice::from_slice(&bytes).unwrap();
            assert_eq!(UdpHeader::LEN_U16, slice.header_len_u16());
        }
    }
}
