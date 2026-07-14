use crate::{
    err::{ipv4::SliceError, Layer, LenError},
    *,
};

/// Slice containing the IPv4 headers & payload.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Ipv4Slice<'a> {
    pub(crate) header: Ipv4HeaderSlice<'a>,
    pub(crate) exts: Ipv4ExtensionsSlice<'a>,
    pub(crate) payload: IpPayloadSlice<'a>,
}

impl<'a> Ipv4Slice<'a> {
    /// Separates and validates IPv4 headers (including extension headers)
    /// in the given slice and determine the sub-slice containing the payload
    /// of the IPv4 packet.
    ///
    /// Note that his function returns an [`crate::err::LenError`] if the given slice
    /// contains less data then the `total_len` field in the IPv4 header indicates
    /// should be present.
    ///
    /// If you want to ignore these kind of length errors based on the length
    /// fields in the IP headers use [`crate::LaxIpv4Slice::from_slice`] instead.
    pub fn from_slice(slice: &[u8]) -> Result<Ipv4Slice<'_>, SliceError> {
        use crate::ip_number::AUTH;

        // decode the header
        let header = Ipv4HeaderSlice::from_slice(slice).map_err(|err| {
            use crate::err::ipv4::HeaderSliceError::*;
            match err {
                Len(err) => SliceError::Len(err),
                Content(err) => SliceError::Header(err),
            }
        })?;

        // validate total_len at least contains the header
        let header_total_len: usize = header.total_len().into();
        if header_total_len < header.slice().len() {
            return Err(SliceError::Len(LenError {
                required_len: header.slice().len(),
                len: header_total_len,
                len_source: LenSource::Ipv4HeaderTotalLen,
                layer: Layer::Ipv4Packet,
                layer_start_offset: 0,
            }));
        }

        // check slice length based on the total length
        let header_payload = if slice.len() < header_total_len {
            return Err(SliceError::Len(LenError {
                required_len: header_total_len,
                len: slice.len(),
                len_source: LenSource::Slice,
                layer: Layer::Ipv4Packet,
                layer_start_offset: 0,
            }));
        } else {
            unsafe {
                core::slice::from_raw_parts(
                    slice.as_ptr().add(header.slice().len()),
                    header_total_len - header.slice().len(),
                )
            }
        };

        // decode the authentication header if needed
        let fragmented = header.is_fragmenting_payload();
        match header.protocol() {
            AUTH => {
                use crate::err::ip_auth::HeaderSliceError as E;

                // parse extension headers
                let auth = match IpAuthHeaderSlice::from_slice(header_payload) {
                    Ok(s) => s,
                    Err(err) => match err {
                        E::Len(mut l) => {
                            // change the length source to the ipv4 header
                            l.len_source = LenSource::Ipv4HeaderTotalLen;
                            l.layer_start_offset += header.slice().len();
                            return Err(SliceError::Len(l));
                        }
                        E::Content(err) => return Err(SliceError::Exts(err)),
                    },
                };

                // remove the extension header from the payload
                let payload = unsafe {
                    core::slice::from_raw_parts(
                        header_payload.as_ptr().add(auth.slice().len()),
                        header_payload.len() - auth.slice().len(),
                    )
                };
                let ip_number = auth.next_header();
                Ok(Ipv4Slice {
                    header,
                    exts: Ipv4ExtensionsSlice { auth: Some(auth) },
                    payload: IpPayloadSlice {
                        ip_number,
                        fragmented,
                        len_source: LenSource::Ipv4HeaderTotalLen,
                        payload,
                    },
                })
            }
            ip_number => Ok(Ipv4Slice {
                header,
                exts: Ipv4ExtensionsSlice { auth: None },
                payload: IpPayloadSlice {
                    ip_number,
                    fragmented,
                    len_source: LenSource::Ipv4HeaderTotalLen,
                    payload: header_payload,
                },
            }),
        }
    }

    /// Returns a slice containing the IPv4 header.
    #[inline]
    pub fn header(&self) -> Ipv4HeaderSlice<'_> {
        self.header
    }

    /// Returns a slice containing the IPv4 extension headers.
    #[inline]
    pub fn extensions(&self) -> Ipv4ExtensionsSlice<'_> {
        self.exts
    }

    /// Returns a slice containing the data after the IPv4 header
    /// and IPv4 extensions headers.
    #[inline]
    pub fn payload(&self) -> &IpPayloadSlice<'a> {
        &self.payload
    }

    /// Returns the ip number the type of payload of the IPv4 packet.
    ///
    /// This function returns the ip number stored in the last
    /// IPv4 header or extension header.
    #[inline]
    pub fn payload_ip_number(&self) -> IpNumber {
        self.payload.ip_number
    }

    /// Returns true if the payload is flagged as being fragmented.
    #[inline]
    pub fn is_payload_fragmented(&self) -> bool {
        self.header.is_fragmenting_payload()
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
            ipv4_base in ipv4_any(),
            auth in ip_auth_any()
        ) {
            let payload: [u8;4] = [1,2,3,4];
            let mut data = Vec::with_capacity(
                ipv4_base.header_len() +
                auth.header_len() +
                payload.len()
            );
            let mut ipv4 = ipv4_base.clone();
            ipv4.protocol = crate::ip_number::AUTH;
            ipv4.set_payload_len(auth.header_len() + payload.len()).unwrap();
            data.extend_from_slice(&ipv4.to_bytes());
            data.extend_from_slice(&auth.to_bytes());
            data.extend_from_slice(&payload);

            // decode packet
            let slice = Ipv4Slice::from_slice(&data).unwrap();

            // check debug output
            prop_assert_eq!(
                format!("{:?}", slice),
                format!(
                    "Ipv4Slice {{ header: {:?}, exts: {:?}, payload: {:?} }}",
                    slice.header(),
                    slice.extensions(),
                    slice.payload()
                )
            );
            prop_assert_eq!(slice.clone(), slice);
        }
    }

    proptest! {
        #[test]
        fn from_slice(
            ipv4_base in ipv4_any(),
            auth in ip_auth_any()
        ) {
            let payload: [u8;6] = [1,2,3,4,5,6];

            // build packets
            let data_without_ext = {
                let mut data = Vec::with_capacity(
                    ipv4_base.header_len() +
                    payload.len() +
                    4
                );
                let mut ipv4 = ipv4_base.clone();
                ipv4.set_payload_len(payload.len()).unwrap();
                ipv4.protocol = crate::ip_number::UDP;
                data.extend_from_slice(&ipv4.to_bytes());
                data.extend_from_slice(&payload);
                data.extend_from_slice(&[0,0,0,0]);
                data
            };
            let data_with_ext = {
                let payload: [u8;6] = [1,2,3,4,5,6];
                let mut data = Vec::with_capacity(
                    ipv4_base.header_len() +
                    auth.header_len() +
                    payload.len() +
                    4
                );
                let mut ipv4 = ipv4_base.clone();
                ipv4.set_payload_len(auth.header_len() + payload.len()).unwrap();
                ipv4.protocol = crate::ip_number::AUTH;
                data.extend_from_slice(&ipv4.to_bytes());
                data.extend_from_slice(&auth.to_bytes());
                data.extend_from_slice(&payload);
                data.extend_from_slice(&[0,0,0,0]);
                data
            };

            // parsing without extensions
            {
                let actual = Ipv4Slice::from_slice(&data_without_ext).unwrap();
                prop_assert_eq!(actual.header().slice(), &data_without_ext[..ipv4_base.header_len()]);
                prop_assert!(actual.extensions().auth.is_none());
                prop_assert_eq!(
                    &actual.payload,
                    &IpPayloadSlice{
                        ip_number: ip_number::UDP.into(),
                        fragmented: ipv4_base.is_fragmenting_payload(),
                        len_source: LenSource::Ipv4HeaderTotalLen,
                        payload: &payload
                    }
                );
                prop_assert_eq!(actual.payload_ip_number(), ip_number::UDP.into());
            }

            // parsing with extensions
            {
                let actual = Ipv4Slice::from_slice(&data_with_ext).unwrap();
                prop_assert_eq!(actual.header().slice(), &data_with_ext[..ipv4_base.header_len()]);
                prop_assert_eq!(
                    actual.extensions().auth.unwrap(),
                    IpAuthHeaderSlice::from_slice(&data_with_ext[ipv4_base.header_len()..]).unwrap()
                );
                prop_assert_eq!(
                    &actual.payload,
                    &IpPayloadSlice{
                        ip_number: auth.next_header.into(),
                        fragmented: ipv4_base.is_fragmenting_payload(),
                        len_source: LenSource::Ipv4HeaderTotalLen,
                        payload: &payload
                    }
                );
                prop_assert_eq!(actual.payload_ip_number(), auth.next_header.into());
            }

            // header length error
            for len in 0..Ipv4Header::MIN_LEN {
                prop_assert_eq!(
                    Ipv4Slice::from_slice(&data_without_ext[..len]).unwrap_err(),
                    SliceError::Len(
                        LenError{
                            required_len: Ipv4Header::MIN_LEN,
                            len,
                            len_source: LenSource::Slice,
                            layer: Layer::Ipv4Header,
                            layer_start_offset: 0,
                        }
                    )
                );
            }

            // header content error
            {
                use crate::err::ipv4::HeaderError;
                // inject invalid icv
                let mut data = data_without_ext.clone();
                data[0] = data[0] & 0xf0; // icv 0
                prop_assert_eq!(
                    Ipv4Slice::from_slice(&data).unwrap_err(),
                    SliceError::Header(
                        HeaderError::HeaderLengthSmallerThanHeader { ihl: 0 }
                    )
                );
            }

            // payload length error without auth header
            {
                use crate::err::{LenError, Layer};

                let required_len = ipv4_base.header_len() + payload.len();
                prop_assert_eq!(
                    Ipv4Slice::from_slice(&data_without_ext[..required_len - 1]).unwrap_err(),
                    SliceError::Len(LenError{
                        required_len: required_len,
                        len: required_len - 1,
                        len_source: LenSource::Slice,
                        layer: Layer::Ipv4Packet,
                        layer_start_offset: 0,
                    })
                );
            }

            // payload length error auth header
            {
                use crate::err::{LenError, Layer};

                let required_len = ipv4_base.header_len() + auth.header_len() + payload.len();
                prop_assert_eq!(
                    Ipv4Slice::from_slice(&data_with_ext[..required_len - 1]).unwrap_err(),
                    SliceError::Len(LenError{
                        required_len: required_len,
                        len: required_len - 1,
                        len_source: LenSource::Slice,
                        layer: Layer::Ipv4Packet,
                        layer_start_offset: 0,
                    })
                );
            }

            // auth length error
            {
                use crate::err::{LenError, Layer};

                // inject a total_length that is smaller then the auth header
                let mut data = data_with_ext.clone();
                let total_len_too_small = ipv4_base.header_len() + auth.header_len() - 1;
                {
                    let tltsm = (total_len_too_small as u16).to_be_bytes();
                    data[2] = tltsm[0];
                    data[3] = tltsm[1];
                }

                prop_assert_eq!(
                    Ipv4Slice::from_slice(&data).unwrap_err(),
                    SliceError::Len(
                        LenError{
                            required_len: auth.header_len(),
                            len: auth.header_len() - 1,
                            len_source: LenSource::Ipv4HeaderTotalLen,
                            layer: Layer::IpAuthHeader,
                            layer_start_offset: ipv4_base.header_len(),
                        }
                    )
                );
            }

            // auth content error
            {
                use crate::err::ip_auth::HeaderError;

                // inject zero as auth header length
                let mut data = data_with_ext.clone();
                data[ipv4_base.header_len() + 1] = 0;

                prop_assert_eq!(
                    Ipv4Slice::from_slice(&data).unwrap_err(),
                    SliceError::Exts(
                        HeaderError::ZeroPayloadLen
                    )
                );
            }
        }
    }

    #[test]
    fn is_payload_fragmented() {
        use crate::ip_number::UDP;
        // non-fragmented
        {
            let payload: [u8; 6] = [1, 2, 3, 4, 5, 6];
            let ipv4 =
                Ipv4Header::new(payload.len() as u16, 1, UDP, [3, 4, 5, 6], [7, 8, 9, 10]).unwrap();
            let data = {
                let mut data = Vec::with_capacity(ipv4.header_len() + payload.len());
                data.extend_from_slice(&ipv4.to_bytes());
                data.extend_from_slice(&payload);
                data
            };

            let slice = Ipv4Slice::from_slice(&data).unwrap();
            assert!(false == slice.is_payload_fragmented());
        }
        // fragmented
        {
            let payload: [u8; 6] = [1, 2, 3, 4, 5, 6];
            let mut ipv4 =
                Ipv4Header::new(payload.len() as u16, 1, UDP, [3, 4, 5, 6], [7, 8, 9, 10]).unwrap();
            ipv4.fragment_offset = 123.try_into().unwrap();
            let data = {
                let mut data = Vec::with_capacity(ipv4.header_len() + payload.len());
                data.extend_from_slice(&ipv4.to_bytes());
                data.extend_from_slice(&payload);
                data
            };

            let slice = Ipv4Slice::from_slice(&data).unwrap();
            assert!(slice.is_payload_fragmented());
        }
    }
}
