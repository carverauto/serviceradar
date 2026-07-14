use crate::{err::*, *};

/// Slice containing an Ethernet 2 headers & payload.
#[derive(Clone, Eq, PartialEq)]
pub struct Ethernet2Slice<'a> {
    fcs_len: usize,
    slice: &'a [u8],
}

impl<'a> Ethernet2Slice<'a> {
    /// Try creating a [`Ethernet2Slice`] from a slice containing the
    /// Ethernet 2 header & payload WITHOUT an FCS (frame check sequence)
    /// at the end.
    pub fn from_slice_without_fcs(slice: &'a [u8]) -> Result<Ethernet2Slice<'a>, LenError> {
        // check length
        if slice.len() < Ethernet2Header::LEN {
            return Err(LenError {
                required_len: Ethernet2Header::LEN,
                len: slice.len(),
                len_source: LenSource::Slice,
                layer: Layer::Ethernet2Header,
                layer_start_offset: 0,
            });
        }

        Ok(Ethernet2Slice { fcs_len: 0, slice })
    }

    /// Try creating a [`Ethernet2Slice`] from a slice containing the
    /// Ethernet 2 header & payload with a CRC 32 bit FCS (frame
    /// check sequence) at the end.
    ///
    /// In case you are not sure if your ethernet2 frame has a FCS or not
    /// use [`Ethernet2Slice::from_slice_without_fcs`] instead and rely on the
    /// lower layers (e.g. IP) to determine the correct payload length.
    pub fn from_slice_with_crc32_fcs(slice: &'a [u8]) -> Result<Ethernet2Slice<'a>, LenError> {
        // check length
        let fcs_len = 4;
        if slice.len() < Ethernet2Header::LEN + fcs_len {
            return Err(LenError {
                required_len: Ethernet2Header::LEN + 4,
                len: slice.len(),
                len_source: LenSource::Slice,
                layer: Layer::Ethernet2Header,
                layer_start_offset: 0,
            });
        }

        Ok(Ethernet2Slice { fcs_len, slice })
    }

    /// Returns the slice containing the ethernet 2 header
    /// payload and FCS if present.
    #[inline]
    pub fn slice(&self) -> &'a [u8] {
        self.slice
    }

    /// Read the destination MAC address
    #[inline]
    pub fn destination(&self) -> [u8; 6] {
        // SAFETY:
        // Safe as the constructor checks that the slice has
        // at least the length of Ethernet2Header::LEN (14).
        unsafe { get_unchecked_6_byte_array(self.slice.as_ptr()) }
    }

    /// Read the source MAC address
    #[inline]
    pub fn source(&self) -> [u8; 6] {
        // SAFETY:
        // Safe as the constructor checks that the slice has
        // at least the length of Ethernet2Header::LEN (14).
        unsafe { get_unchecked_6_byte_array(self.slice.as_ptr().add(6)) }
    }

    /// Read the ether_type field of the header indicating the protocol
    /// after the header.
    #[inline]
    pub fn ether_type(&self) -> EtherType {
        // SAFETY:
        // Safe as the constructor checks that the slice has
        // at least the length of Ethernet2Header::LEN (14).
        EtherType(unsafe { get_unchecked_be_u16(self.slice.as_ptr().add(12)) })
    }

    /// Returns the frame check sequence if present.
    #[inline]
    pub fn fcs(&self) -> Option<[u8; 4]> {
        if self.fcs_len == 4 {
            // SAFETY: Safe as the slice length was verified
            // to be at least Ethernet2Header::LEN + fcs_len by
            // "from_slice_without_fcs" & "from_slice_with_crc32_fcs".
            Some(unsafe {
                [
                    *self.slice.as_ptr().add(self.slice.len() - 4),
                    *self.slice.as_ptr().add(self.slice.len() - 3),
                    *self.slice.as_ptr().add(self.slice.len() - 2),
                    *self.slice.as_ptr().add(self.slice.len() - 1),
                ]
            })
        } else {
            None
        }
    }

    /// Decode all the fields and copy the results to a [`Ethernet2Header`] struct
    pub fn to_header(&self) -> Ethernet2Header {
        Ethernet2Header {
            source: self.source(),
            destination: self.destination(),
            ether_type: self.ether_type(),
        }
    }

    /// Slice containing the Ethernet 2 header.
    pub fn header_slice(&self) -> &[u8] {
        unsafe {
            // SAFETY:
            // Safe as the constructor checks that the slice has
            // at least the length of Ethernet2Header::LEN (14).
            core::slice::from_raw_parts(self.slice.as_ptr(), Ethernet2Header::LEN)
        }
    }

    /// Returns the slice containing the Ethernet II payload & ether type
    /// identifying it's content type.
    #[inline]
    pub fn payload(&self) -> EtherPayloadSlice<'a> {
        EtherPayloadSlice {
            ether_type: self.ether_type(),
            len_source: LenSource::Slice,
            payload: self.payload_slice(),
        }
    }

    /// Returns the slice containing the Ethernet II payload.
    #[inline]
    pub fn payload_slice(&self) -> &'a [u8] {
        unsafe {
            // SAFETY: Safe as the slice length was verified
            // to be at least Ethernet2Header::LEN + fcs_len by
            // "from_slice_without_fcs" & "from_slice_with_crc32_fcs".
            core::slice::from_raw_parts(
                self.slice.as_ptr().add(Ethernet2Header::LEN),
                self.slice.len() - Ethernet2Header::LEN - self.fcs_len,
            )
        }
    }

    /// Length of the Ethernet 2 header in bytes (equal to
    /// [`crate::Ethernet2Header::LEN`]).
    #[inline]
    pub const fn header_len(&self) -> usize {
        Ethernet2Header::LEN
    }
}

impl core::fmt::Debug for Ethernet2Slice<'_> {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        f.debug_struct("Ethernet2Slice")
            .field("header", &self.to_header())
            .field("payload", &self.payload())
            .field("fcs", &self.fcs())
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
            eth in ethernet_2_any(),
            has_fcs in any::<bool>()
        ) {
            let payload: [u8;8] = [1,2,3,4,5,6,7,8];
            let mut data = Vec::with_capacity(
                eth.header_len() +
                payload.len()
            );
            data.extend_from_slice(&eth.to_bytes());
            data.extend_from_slice(&payload);

            // decode packet
            let slice = if has_fcs {
                Ethernet2Slice::from_slice_with_crc32_fcs(&data).unwrap()
            } else {
                Ethernet2Slice::from_slice_without_fcs(&data).unwrap()
            };

            // check debug output
            prop_assert_eq!(
                format!("{:?}", slice),
                format!(
                    "Ethernet2Slice {{ header: {:?}, payload: {:?}, fcs: {:?} }}",
                    slice.to_header(),
                    slice.payload(),
                    slice.fcs()
                )
            );
            prop_assert_eq!(slice.clone(), slice);
        }
    }

    proptest! {
        #[test]
        fn getters(eth in ethernet_2_any()) {
            let payload: [u8;8] = [1,2,3,4,5,6,7,8];
            let mut data = Vec::with_capacity(
                eth.header_len() +
                payload.len()
            );
            data.extend_from_slice(&eth.to_bytes());
            data.extend_from_slice(&payload);

            // without fcs
            {
                let slice = Ethernet2Slice::from_slice_without_fcs(&data).unwrap();
                assert_eq!(eth.destination, slice.destination());
                assert_eq!(eth.source, slice.source());
                assert_eq!(eth.ether_type, slice.ether_type());
                assert_eq!(&payload, slice.payload_slice());
                assert_eq!(
                    EtherPayloadSlice{
                        payload: &payload,
                        len_source: LenSource::Slice,
                        ether_type: eth.ether_type,
                    },
                    slice.payload()
                );
                assert_eq!(None, slice.fcs());
                assert_eq!(eth, slice.to_header());
                assert_eq!(&data, slice.slice());
                assert_eq!(&data[..Ethernet2Header::LEN], slice.header_slice());
            }
            // with fcs
            {
                let slice = Ethernet2Slice::from_slice_with_crc32_fcs(&data).unwrap();
                assert_eq!(eth.destination, slice.destination());
                assert_eq!(eth.source, slice.source());
                assert_eq!(eth.ether_type, slice.ether_type());
                assert_eq!(&payload[..payload.len() - 4], slice.payload_slice());
                assert_eq!(
                    EtherPayloadSlice{
                        ether_type: eth.ether_type,
                        len_source: LenSource::Slice,
                        payload: &payload[..payload.len() - 4],
                    },
                    slice.payload()
                );
                assert_eq!(Some([5, 6, 7, 8]), slice.fcs());
                assert_eq!(eth, slice.to_header());
                assert_eq!(&data, slice.slice());
                assert_eq!(&data[..Ethernet2Header::LEN], slice.header_slice());
            }
        }
    }

    proptest! {
        #[test]
        fn from_slice_without_fcs(eth in ethernet_2_any()) {

            let payload: [u8;10] = [1,2,3,4,5,6,7,8,9,10];
            let data = {
                let mut data = Vec::with_capacity(
                    eth.header_len() +
                    payload.len()
                );
                data.extend_from_slice(&eth.to_bytes());
                data.extend_from_slice(&payload);
                data
            };

            // normal decode
            {
                let slice = Ethernet2Slice::from_slice_without_fcs(&data).unwrap();
                assert_eq!(slice.to_header(), eth);
                assert_eq!(slice.payload_slice(), &payload);
                assert_eq!(slice.fcs(), None);
            }

            // decode without payload
            {
                let slice = Ethernet2Slice::from_slice_without_fcs(&data[..Ethernet2Header::LEN]).unwrap();
                assert_eq!(slice.to_header(), eth);
                assert_eq!(slice.payload_slice(), &[]);
                assert_eq!(slice.fcs(), None);
            }

            // length error
            for len in 0..Ethernet2Header::LEN {
                assert_eq!(
                    Ethernet2Slice::from_slice_without_fcs(&data[..len]).unwrap_err(),
                    LenError{
                        required_len: Ethernet2Header::LEN,
                        len,
                        len_source: LenSource::Slice,
                        layer: Layer::Ethernet2Header,
                        layer_start_offset: 0
                    }
                );
            }
        }
    }

    proptest! {
        #[test]
        fn from_slice_with_crc32_fcs(
            eth in ethernet_2_any()
        ) {
            let payload: [u8;10] = [1,2,3,4,5,6,7,8,9,10];
            let fcs: [u8;4] = [11,12,13,14];
            let data = {
                let mut data = Vec::with_capacity(
                    eth.header_len() +
                    payload.len()
                );
                data.extend_from_slice(&eth.to_bytes());
                data.extend_from_slice(&payload);
                data.extend_from_slice(&fcs);
                data
            };

            // normal decode
            {
                let slice = Ethernet2Slice::from_slice_with_crc32_fcs(&data).unwrap();
                assert_eq!(slice.to_header(), eth);
                assert_eq!(slice.payload_slice(), &payload);
                assert_eq!(slice.fcs(), Some(fcs));
            }

            // decode without payload
            {
                let slice = Ethernet2Slice::from_slice_with_crc32_fcs(&data[..Ethernet2Header::LEN + 4]).unwrap();
                assert_eq!(slice.to_header(), eth);
                assert_eq!(slice.payload_slice(), &[]);
                assert_eq!(slice.fcs(), Some([1,2,3,4]));
            }

            // length error
            for len in 0..Ethernet2Header::LEN + 4 {
                assert_eq!(
                    Ethernet2Slice::from_slice_with_crc32_fcs(&data[..len]).unwrap_err(),
                    LenError{
                        required_len: Ethernet2Header::LEN + 4,
                        len,
                        len_source: LenSource::Slice,
                        layer: Layer::Ethernet2Header,
                        layer_start_offset: 0
                    }
                );
            }
        }
    }
}
