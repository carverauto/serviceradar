use crate::*;

/// Slice containing laxly separated IPv4 headers & payload.
///
/// Compared to the normal [`Ipv4Slice`] this slice allows the
/// payload to be incomplete/cut off and errors to be present in
/// the IpPayload.
///
/// The main use cases for "laxly" parsed slices are are:
///
/// * Parsing packets that have been cut off. This is, for example, useful to
///   parse packets returned via ICMP as these usually only contain the start.
/// * Parsing packets where the `total_len` (for IPv4) have not yet been set.
///   This can be useful when parsing packets which have been recorded in a
///   layer before the length field was set (e.g. before the operating
///   system set the length fields).
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct LaxIpv4Slice<'a> {
    pub(crate) header: Ipv4HeaderSlice<'a>,
    pub(crate) exts: Ipv4ExtensionsSlice<'a>,
    pub(crate) payload: LaxIpPayloadSlice<'a>,
}

impl<'a> LaxIpv4Slice<'a> {
    /// Separates and validates IPv4 headers (including extension headers) &
    /// the payload from the given slice with less strict length checks
    /// (useful for cut off packet or for packets with unset length fields).
    ///
    /// If you want to only receive correct IpPayloads use [`Ipv4Slice::from_slice`]
    /// instead.
    ///
    /// The main use cases for this functions are:
    ///
    /// * Parsing packets that have been cut off. This is, for example, useful to
    ///   parse packets returned via ICMP as these usually only contain the start.
    /// * Parsing packets where the `total_len` (for IPv4) have not yet been set.
    ///   This can be useful when parsing packets which have been recorded in a
    ///   layer before the length field was set (e.g. before the operating
    ///   system set the length fields).
    ///
    /// # Differences to `Ipv4Slice::from_slice`:
    ///
    /// There are two main differences:
    ///
    /// * Errors in the expansion headers will only stop the parsing and return an `Ok`
    ///   with the successfully parsed parts and the error as optional. Only if an
    ///   unrecoverable error is encountered in the IP header itself an `Err` is returned.
    ///   In the normal `Ipv4Slice::from_slice` function an `Err` is returned if an error is
    ///   encountered in an extension header.
    /// * `LaxIpv4Slice::from_slice` ignores inconsistent `total_len` values. When the `total_len`
    ///   value in the IPv4 header are inconsistent the length of the given slice is
    ///   used as a substitute.
    ///
    /// ## What happens in the `total_len` value is inconsistent?
    ///
    /// When the total_length value in the IPv4 header is inconsistent the
    /// length of the given slice is used as a substitute. This can happen
    /// if the `total_length` field in the IPv4 header is:
    ///
    ///  * Bigger then the given slice (payload cannot fully be separated).
    ///  * Too small to contain at least the IPv4 header.
    ///
    /// Additionally you can check if more data was expected based on the
    /// `total_len` but the given slice was too small by checking if `incomplete`
    /// is set to `true` in the returned [`LaxIpPayloadSlice`].
    ///
    /// You can check if the slice length was used as a substitute by checking
    /// if the `len_source` value in the returned [`LaxIpPayloadSlice`] is set to
    /// [`LenSource::Slice`]. If a substitution was not needed `len_source`
    /// is set to [`LenSource::Ipv4HeaderTotalLen`].
    pub fn from_slice(
        slice: &[u8],
    ) -> Result<
        (LaxIpv4Slice<'_>, Option<err::ip_auth::HeaderSliceError>),
        err::ipv4::HeaderSliceError,
    > {
        use crate::ip_number::AUTH;

        // decode the header
        let header = Ipv4HeaderSlice::from_slice(slice)?;

        // validate total_len at least contains the header
        let header_total_len: usize = header.total_len().into();
        let (header_payload, len_source, incomplete) = if header_total_len < header.slice().len() {
            // total_length is smaller then the header itself
            // fall back to the slice for the length
            (
                unsafe {
                    core::slice::from_raw_parts(
                        slice.as_ptr().add(header.slice().len()),
                        slice.len() - header.slice().len(),
                    )
                },
                LenSource::Slice,
                // note that we have no indication that the packet is incomplete
                false,
            )
        } else if header_total_len > slice.len() {
            // more data was expected, fallback to slice and report payload as "incomplete"
            (
                unsafe {
                    core::slice::from_raw_parts(
                        slice.as_ptr().add(header.slice().len()),
                        slice.len() - header.slice().len(),
                    )
                },
                LenSource::Slice,
                true, // incomplete
            )
        } else {
            // all good the packet seems to be complete
            (
                unsafe {
                    core::slice::from_raw_parts(
                        slice.as_ptr().add(header.slice().len()),
                        header_total_len - header.slice().len(),
                    )
                },
                LenSource::Ipv4HeaderTotalLen,
                false,
            )
        };

        // decode the authentication header if needed
        let fragmented = header.is_fragmenting_payload();
        match header.protocol() {
            AUTH => {
                use crate::err::ip_auth::HeaderSliceError as E;

                // parse extension headers
                match IpAuthHeaderSlice::from_slice(header_payload) {
                    Ok(auth) => {
                        // remove the extension header from the payload
                        let payload = unsafe {
                            core::slice::from_raw_parts(
                                header_payload.as_ptr().add(auth.slice().len()),
                                header_payload.len() - auth.slice().len(),
                            )
                        };
                        let ip_number = auth.next_header();
                        Ok((
                            LaxIpv4Slice {
                                header,
                                exts: Ipv4ExtensionsSlice { auth: Some(auth) },
                                payload: LaxIpPayloadSlice {
                                    incomplete,
                                    ip_number,
                                    fragmented,
                                    len_source,
                                    payload,
                                },
                            },
                            None,
                        ))
                    }
                    Err(err) => {
                        let err = match err {
                            E::Len(mut l) => {
                                // change the length source to the ipv4 header
                                l.len_source = len_source;
                                l.layer_start_offset += header.slice().len();
                                E::Len(l)
                            }
                            E::Content(err) => E::Content(err),
                        };
                        Ok((
                            LaxIpv4Slice {
                                header,
                                exts: Ipv4ExtensionsSlice { auth: None },
                                payload: LaxIpPayloadSlice {
                                    incomplete,
                                    ip_number: AUTH,
                                    fragmented,
                                    len_source,
                                    payload: header_payload,
                                },
                            },
                            Some(err),
                        ))
                    }
                }
            }
            ip_number => Ok((
                LaxIpv4Slice {
                    header,
                    exts: Ipv4ExtensionsSlice { auth: None },
                    payload: LaxIpPayloadSlice {
                        incomplete,
                        ip_number,
                        fragmented,
                        len_source,
                        payload: header_payload,
                    },
                },
                None,
            )),
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
    pub fn payload(&self) -> &LaxIpPayloadSlice<'a> {
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
    use crate::{err::LenError, ip_number::AUTH, test_gens::*};
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
            let (slice, _) = LaxIpv4Slice::from_slice(&data).unwrap();

            // check debug output
            prop_assert_eq!(
                format!("{:?}", slice),
                format!(
                    "LaxIpv4Slice {{ header: {:?}, exts: {:?}, payload: {:?} }}",
                    slice.header(),
                    slice.extensions(),
                    slice.payload()
                )
            );
            prop_assert_eq!(slice.clone(), slice);
        }
    }

    fn combine_v4(
        v4: &Ipv4Header,
        ext: &crate::Ipv4Extensions,
        payload: &[u8],
    ) -> crate::IpHeaders {
        use crate::ip_number::UDP;
        crate::IpHeaders::Ipv4(
            {
                let mut v4 = v4.clone();
                v4.protocol = if ext.auth.is_some() { AUTH } else { UDP };
                v4.total_len = (v4.header_len() + ext.header_len() + payload.len()) as u16;
                v4.header_checksum = v4.calc_header_checksum();
                v4
            },
            ext.clone(),
        )
    }

    proptest! {
        #[test]
        fn from_slice(
            v4 in ipv4_any(),
            v4_exts in ipv4_extensions_any()
        ) {
            use crate::err::{self, ipv4::HeaderError::*};
            use crate::err::ipv4::HeaderSliceError as E;
            use err::ip_auth::HeaderSliceError as A;

            let payload = [1,2,3,4];

            // empty error
            assert_eq!(
                LaxIpv4Slice::from_slice(&[]),
                Err(E::Len(err::LenError {
                    required_len: 20,
                    len: 0,
                    len_source: LenSource::Slice,
                    layer: err::Layer::Ipv4Header,
                    layer_start_offset: 0,
                }))
            );

            // build a buffer with a valid packet
            let header = combine_v4(&v4, &v4_exts, &payload);
            let mut buffer = Vec::with_capacity(header.header_len() + payload.len() + 1);
            header.write(&mut buffer).unwrap();
            buffer.extend_from_slice(&payload);
            buffer.push(1); // add some value to check the return slice

            // normal read
            {
                let (actual, actual_stop_err) = LaxIpv4Slice::from_slice(&buffer).unwrap();
                assert_eq!(None, actual_stop_err);
                assert_eq!(&actual.header.to_header(), header.ipv4().unwrap().0);
                assert_eq!(&actual.extensions().to_header(), header.ipv4().unwrap().1);
                assert_eq!(
                    actual.payload,
                    LaxIpPayloadSlice{
                        incomplete: false,
                        ip_number: header.next_header().unwrap(),
                        fragmented: header.is_fragmenting_payload(),
                        len_source: LenSource::Ipv4HeaderTotalLen,
                        payload: &payload
                    }
                );
                assert_eq!(actual.payload_ip_number(), header.next_header().unwrap());
            }

            // error len smaller then min header len
            for len in 1..Ipv4Header::MIN_LEN {
                assert_eq!(
                    LaxIpv4Slice::from_slice(&buffer[..len]),
                    Err(E::Len(err::LenError {
                        required_len: Ipv4Header::MIN_LEN,
                        len,
                        len_source: LenSource::Slice,
                        layer: err::Layer::Ipv4Header,
                        layer_start_offset: 0,
                    }))
                );
            }

            // ihl value error
            {
                let mut bad_ihl_buffer = buffer.clone();
                for bad_ihl in 0..5 {
                    bad_ihl_buffer[0] = (bad_ihl_buffer[0] & 0xf0) | bad_ihl;
                    assert_eq!(
                        LaxIpv4Slice::from_slice(&bad_ihl_buffer),
                        Err(E::Content(HeaderLengthSmallerThanHeader { ihl: bad_ihl }))
                    );
                }
            }

            // ihl len error
            for short_ihl in 5..usize::from(v4.ihl()) {
                assert_eq!(
                    LaxIpv4Slice::from_slice(&buffer[..4*short_ihl]),
                    Err(E::Len(err::LenError {
                        required_len: usize::from(v4.ihl())*4,
                        len: 4*short_ihl,
                        len_source: LenSource::Slice,
                        layer: err::Layer::Ipv4Header,
                        layer_start_offset: 0,
                    }))
                );
            }

            // total_len bigger then slice len (fallback to slice len)
            for payload_len in 0..payload.len(){
                let (actual, stop_err) = LaxIpv4Slice::from_slice(&buffer[..v4.header_len() + v4_exts.header_len() + payload_len]).unwrap();
                assert_eq!(stop_err, None);
                assert_eq!(&actual.header().to_header(), header.ipv4().unwrap().0);
                assert_eq!(
                    actual.payload(),
                    &LaxIpPayloadSlice{
                        incomplete: true,
                        ip_number: header.next_header().unwrap(),
                        fragmented: header.is_fragmenting_payload(),
                        len_source: LenSource::Slice,
                        payload: &payload[..payload_len]
                    }
                );
            }

            // len error ipv4 extensions
            if v4_exts.header_len() > 0 {
                let (actual, stop_err) = LaxIpv4Slice::from_slice(&buffer[..v4.header_len() + 1]).unwrap();
                assert_eq!(&actual.header().to_header(), header.ipv4().unwrap().0);
                assert_eq!(
                    actual.payload(),
                    &LaxIpPayloadSlice{
                        incomplete: true,
                        ip_number: AUTH,
                        fragmented: header.is_fragmenting_payload(),
                        len_source: LenSource::Slice,
                        payload: &buffer[v4.header_len()..v4.header_len() + 1]
                    }
                );
                assert_eq!(stop_err, Some(A::Len(LenError{
                    required_len: IpAuthHeader::MIN_LEN,
                    len: 1,
                    len_source: LenSource::Slice,
                    layer: err::Layer::IpAuthHeader,
                    layer_start_offset: header.ipv4().unwrap().0.header_len()
                })));
            }

            // content error ipv4 extensions
            if v4_exts.auth.is_some() {
                use err::ip_auth::HeaderError::ZeroPayloadLen;


                // introduce a auth header zero payload error
                let mut errored_buffer = buffer.clone();
                // inject length zero into auth header (not valid, will
                // trigger a content error)
                errored_buffer[v4.header_len() + 1] = 0;

                let (actual, stop_err) = LaxIpv4Slice::from_slice(&errored_buffer).unwrap();
                assert_eq!(&actual.header().to_header(), header.ipv4().unwrap().0);
                assert!(actual.extensions().is_empty());
                let auth_offset = header.ipv4().unwrap().0.header_len();
                let payload_end = auth_offset + v4_exts.auth.map(|v| v.header_len()).unwrap() + payload.len();
                assert_eq!(
                    actual.payload(),
                    &LaxIpPayloadSlice{
                        incomplete: false,
                        ip_number: AUTH,
                        fragmented: header.is_fragmenting_payload(),
                        len_source: LenSource::Ipv4HeaderTotalLen,
                        payload: &errored_buffer[auth_offset..payload_end]
                    }
                );
                assert_eq!(stop_err, Some(A::Content(ZeroPayloadLen)));
            }

            // total length smaller the header (fallback to slice len)
            {
                let bad_total_len = (v4.header_len() - 1) as u16;

                let mut buffer = buffer.clone();
                // inject bad total_len
                let bad_total_len_be = bad_total_len.to_be_bytes();
                buffer[2] = bad_total_len_be[0];
                buffer[3] = bad_total_len_be[1];

                let (actual, actual_stop_error) = LaxIpv4Slice::from_slice(&buffer[..]).unwrap();
                assert_eq!(actual_stop_error, None);

                let (v4_header, v4_exts) = header.ipv4().unwrap();
                let expected_headers = IpHeaders::Ipv4(
                    {
                        let mut expected_v4 = v4_header.clone();
                        expected_v4.total_len = bad_total_len;
                        expected_v4
                    },
                    v4_exts.clone()
                );
                assert_eq!(expected_headers.ipv4().unwrap().0, &actual.header().to_header());
                assert_eq!(
                    actual.payload(),
                    &LaxIpPayloadSlice{
                        incomplete: false,
                        ip_number: header.next_header().unwrap(),
                        fragmented: header.is_fragmenting_payload(),
                        len_source: LenSource::Slice,
                        payload: &buffer[v4_header.header_len() + v4_exts.header_len()..],
                    }
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

            let (slice, stop_err) = LaxIpv4Slice::from_slice(&data).unwrap();
            assert_eq!(None, stop_err);
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

            let (slice, stop_err) = LaxIpv4Slice::from_slice(&data).unwrap();
            assert_eq!(None, stop_err);
            assert!(slice.is_payload_fragmented());
        }
    }
}
