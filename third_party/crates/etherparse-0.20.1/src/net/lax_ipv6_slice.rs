use crate::{
    err::{ipv6, ipv6_exts},
    *,
};

/// Slice containing laxly separated IPv6 headers & payload.
///
/// Compared to the normal [`Ipv6Slice`] this slice allows the
/// payload to incomplete/cut off and errors to be present in
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
pub struct LaxIpv6Slice<'a> {
    pub(crate) header: Ipv6HeaderSlice<'a>,
    pub(crate) exts: Ipv6ExtensionsSlice<'a>,
    pub(crate) payload: LaxIpPayloadSlice<'a>,
}

impl<'a> LaxIpv6Slice<'a> {
    /// separate an IPv6 header (+ extensions) & the payload from the given slice with
    /// less strict length checks (useful for cut off packet or for packets with
    /// unset length fields).
    ///
    /// If you want to only receive correct IpPayloads use [`crate::Ipv4Slice::from_slice`]
    /// instead.
    ///
    /// The main use cases for this functions are:
    ///
    /// * Parsing packets that have been cut off. This is, for example, useful to
    ///   parse packets returned via ICMP as these usually only contain the start.
    /// * Parsing packets where the `payload_length` (in the IPv6 header) has not
    ///   yet been set. This can be useful when parsing packets which have been
    ///   recorded in a layer before the length field was set (e.g. before the operating
    ///   system set the length fields).
    ///
    /// # Differences to `from_slice`:
    ///
    /// There are two main differences:
    ///
    /// * Errors in the expansion headers will only stop the parsing and return an `Ok`
    ///   with the successfully parsed parts and the error as optional. Only if an
    ///   unrecoverable error is encountered in the IP header itself an `Err` is returned.
    ///   In the normal `Ipv4Slice::from_slice` function an `Err` is returned if an error is
    ///   encountered in an extension header.
    /// * `LaxIpv4Slice::from_slice` ignores inconsistent `payload_length` values. When the
    ///   `payload_length` value in the IPv6 header is inconsistent the length of
    ///   the given slice is used as a substitute.
    ///
    /// You can check if the slice length was used as a substitute by checking
    /// if the `len_source` value in the returned [`IpPayloadSlice`] is set to
    /// [`LenSource::Slice`]. If a substitution was not needed `len_source`
    /// is set to [`LenSource::Ipv6HeaderPayloadLen`].
    ///
    /// # When is the slice length used as a fallback?
    ///
    /// The slice length is used as a fallback/substitute if the `payload_length`
    /// field in the IPv6 header is
    ///
    /// * Bigger then the given slice (payload cannot fully be separated).
    /// * The value `0`.
    pub fn from_slice(
        slice: &'a [u8],
    ) -> Result<
        (
            LaxIpv6Slice<'a>,
            Option<(ipv6_exts::HeaderSliceError, err::Layer)>,
        ),
        ipv6::HeaderSliceError,
    > {
        // try reading the header
        let header = Ipv6HeaderSlice::from_slice(slice)?;

        // restrict slice by the length specified in the header
        let (header_payload, len_source, incomplete) =
            if 0 == header.payload_length() && slice.len() > Ipv6Header::LEN {
                // In case the payload_length is 0 assume that the entire
                // rest of the slice is part of the packet until the jumbogram
                // parameters can be parsed.

                // TODO: Add payload length parsing from the jumbogram
                (
                    unsafe {
                        core::slice::from_raw_parts(
                            slice.as_ptr().add(Ipv6Header::LEN),
                            slice.len() - Ipv6Header::LEN,
                        )
                    },
                    LenSource::Slice,
                    false,
                )
            } else {
                let payload_len = usize::from(header.payload_length());
                let expected_len = Ipv6Header::LEN + payload_len;
                if slice.len() < expected_len {
                    (
                        unsafe {
                            core::slice::from_raw_parts(
                                slice.as_ptr().add(Ipv6Header::LEN),
                                slice.len() - Ipv6Header::LEN,
                            )
                        },
                        LenSource::Slice,
                        true,
                    )
                } else {
                    (
                        unsafe {
                            core::slice::from_raw_parts(
                                slice.as_ptr().add(Ipv6Header::LEN),
                                payload_len,
                            )
                        },
                        LenSource::Ipv6HeaderPayloadLen,
                        false,
                    )
                }
            };

        // parse extension headers
        let (exts, payload_ip_number, payload, mut ext_stop_err) =
            Ipv6ExtensionsSlice::from_slice_lax(header.next_header(), header_payload);

        // modify length errors
        if let Some((ipv6_exts::HeaderSliceError::Len(err), _)) = &mut ext_stop_err {
            err.len_source = len_source;
            err.layer_start_offset += Ipv6Header::LEN;
        };

        let fragmented = exts.is_fragmenting_payload();
        Ok((
            LaxIpv6Slice {
                header,
                exts,
                payload: LaxIpPayloadSlice {
                    incomplete,
                    ip_number: payload_ip_number,
                    fragmented,
                    len_source,
                    payload,
                },
            },
            ext_stop_err,
        ))
    }

    /// Returns a slice containing the IPv6 header.
    #[inline]
    pub fn header(&self) -> Ipv6HeaderSlice<'a> {
        self.header
    }

    /// Returns a slice containing the IPv6 extension headers.
    #[inline]
    pub fn extensions(&self) -> &Ipv6ExtensionsSlice<'a> {
        &self.exts
    }

    /// Returns a slice containing the data after the IPv6 header
    /// and IPv6 extensions headers.
    #[inline]
    pub fn payload(&self) -> &LaxIpPayloadSlice<'a> {
        &self.payload
    }

    /// Returns true if the payload is flagged as being fragmented.
    #[inline]
    pub fn is_payload_fragmented(&self) -> bool {
        self.payload.fragmented
    }
}

#[cfg(test)]
mod test {
    use super::*;
    use crate::{
        err::{Layer, LenError},
        ip_number::{AUTH, IGMP, UDP},
        test_gens::*,
    };
    use alloc::{format, vec::Vec};
    use proptest::prelude::*;

    proptest! {
        #[test]
        fn debug_clone_eq(
            ipv6_base in ipv6_any(),
            auth_base in ip_auth_any()
        ) {
            let mut auth = auth_base.clone();
            auth.next_header = IGMP;
            let payload: [u8;4] = [1,2,3,4];
            let mut data = Vec::with_capacity(
                ipv6_base.header_len() +
                auth.header_len() +
                payload.len()
            );
            let mut ipv6 = ipv6_base.clone();
            ipv6.next_header = AUTH;
            ipv6.payload_length = (auth.header_len() + payload.len()) as u16;
            data.extend_from_slice(&ipv6.to_bytes());
            data.extend_from_slice(&auth.to_bytes());
            data.extend_from_slice(&payload);

            // decode packet
            let (slice, _) = LaxIpv6Slice::from_slice(&data).unwrap();

            // check debug output
            prop_assert_eq!(
                format!("{:?}", slice),
                format!(
                    "LaxIpv6Slice {{ header: {:?}, exts: {:?}, payload: {:?} }}",
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
            ipv6_base in ipv6_any(),
            auth_base in ip_auth_any()
        ) {
            let payload: [u8;6] = [1,2,3,4,5,6];

            // build packets
            let data_without_ext = {
                let mut data = Vec::with_capacity(
                    ipv6_base.header_len() +
                    payload.len() +
                    4
                );
                let mut ipv6 = ipv6_base.clone();
                ipv6.payload_length = (payload.len()) as u16;
                ipv6.next_header = UDP;
                data.extend_from_slice(&ipv6.to_bytes());
                data.extend_from_slice(&payload);
                data.extend_from_slice(&[0,0,0,0]);
                data
            };
            let data_with_ext = {
                let payload: [u8;6] = [1,2,3,4,5,6];
                let mut data = Vec::with_capacity(
                    ipv6_base.header_len() +
                    auth_base.header_len() +
                    payload.len() +
                    4
                );
                let mut ipv6 = ipv6_base.clone();
                ipv6.payload_length = (auth_base.header_len() + payload.len()) as u16;
                ipv6.next_header = AUTH;
                let mut auth = auth_base.clone();
                auth.next_header = UDP;
                data.extend_from_slice(&ipv6.to_bytes());
                data.extend_from_slice(&auth.to_bytes());
                data.extend_from_slice(&payload);
                data.extend_from_slice(&[0,0,0,0]);
                data
            };

            // parsing without extensions (normal length)
            {
                let (actual, actual_stop_err) = LaxIpv6Slice::from_slice(&data_without_ext).unwrap();
                prop_assert_eq!(None, actual_stop_err);
                prop_assert_eq!(actual.header().slice(), &data_without_ext[..ipv6_base.header_len()]);
                prop_assert!(actual.extensions().first_header().is_none());
                prop_assert_eq!(
                    actual.payload(),
                    &LaxIpPayloadSlice{
                        incomplete: false,
                        ip_number: UDP.into(),
                        fragmented: false,
                        len_source: LenSource::Ipv6HeaderPayloadLen,
                        payload: &payload,
                    }
                );
            }

            // parsing with extensions (normal length)
            {
                let (actual, actual_stop_err) = LaxIpv6Slice::from_slice(&data_with_ext).unwrap();
                prop_assert_eq!(None, actual_stop_err);
                prop_assert_eq!(actual.header().slice(), &data_with_ext[..ipv6_base.header_len()]);
                let (expected, _, _) = Ipv6ExtensionsSlice::from_slice(AUTH, &data_with_ext[ipv6_base.header_len()..]).unwrap();
                prop_assert_eq!(
                    actual.extensions(),
                    &expected
                );
                prop_assert_eq!(
                    actual.payload(),
                    &LaxIpPayloadSlice{
                        incomplete: false,
                        ip_number: UDP.into(),
                        fragmented: false,
                        len_source: LenSource::Ipv6HeaderPayloadLen,
                        payload: &payload,
                    }
                );
            }

            // parsing without extensions (zero length, fallback to slice length)
            {
                // inject zero as payload length
                let mut data = data_without_ext.clone();
                data[4] = 0;
                data[5] = 0;
                let (actual, actual_stop_err) = LaxIpv6Slice::from_slice(&data).unwrap();
                prop_assert_eq!(None, actual_stop_err);
                prop_assert_eq!(actual.header().slice(), &data[..ipv6_base.header_len()]);
                prop_assert!(actual.extensions().first_header().is_none());
                prop_assert_eq!(
                    actual.payload(),
                    &LaxIpPayloadSlice{
                        incomplete: false,
                        ip_number: UDP.into(),
                        fragmented: false,
                        len_source: LenSource::Slice,
                        payload: &data[ipv6_base.header_len()..],
                    }
                );
            }

            // parsing with extensions (zero length, fallback to slice length)
            {
                // inject zero as payload length
                let mut data = data_with_ext.clone();
                data[4] = 0;
                data[5] = 0;
                let (actual, actual_stop_err) = LaxIpv6Slice::from_slice(&data).unwrap();
                prop_assert_eq!(None, actual_stop_err);
                prop_assert_eq!(actual.header().slice(), &data[..ipv6_base.header_len()]);
                let (expected, _, _) = Ipv6ExtensionsSlice::from_slice(AUTH, &data[ipv6_base.header_len()..]).unwrap();
                prop_assert_eq!(
                    actual.extensions(),
                    &expected
                );
                prop_assert_eq!(
                    actual.payload(),
                    &LaxIpPayloadSlice{
                        incomplete: false,
                        ip_number: UDP.into(),
                        fragmented: false,
                        len_source: LenSource::Slice,
                        payload: &data[ipv6_base.header_len() + auth_base.header_len()..],
                    }
                );
            }

            // header content error
            {
                use crate::err::ipv6::HeaderError;
                // inject invalid ip version
                let mut data = data_without_ext.clone();
                data[0] = data[0] & 0x0f; // version 0
                prop_assert_eq!(
                    LaxIpv6Slice::from_slice(&data).unwrap_err(),
                    ipv6::HeaderSliceError::Content(
                        HeaderError::UnexpectedVersion{ version_number: 0 }
                    )
                );
            }

            // header length error
            for len in 0..Ipv6Header::LEN {
                prop_assert_eq!(
                    LaxIpv6Slice::from_slice(&data_without_ext[..len]).unwrap_err(),
                    ipv6::HeaderSliceError::Len(
                        LenError{
                            required_len: Ipv6Header::LEN,
                            len,
                            len_source: LenSource::Slice,
                            layer: Layer::Ipv6Header,
                            layer_start_offset: 0
                        }
                    )
                );
            }

            // payload length larger then slice (fallback to slice length)
            {
                let len = ipv6_base.header_len() + payload.len() - 1;
                let (actual , actual_stop_err) = LaxIpv6Slice::from_slice(&data_without_ext[..len]).unwrap();
                prop_assert_eq!(actual_stop_err, None);
                prop_assert_eq!(actual.header().slice(), &data_without_ext[..ipv6_base.header_len()]);
                prop_assert_eq!(
                    0,
                    actual.extensions().slice().len()
                );
                prop_assert_eq!(
                    actual.payload(),
                    &LaxIpPayloadSlice{
                        incomplete: true,
                        ip_number: UDP.into(),
                        fragmented: false,
                        len_source: LenSource::Slice,
                        payload: &data_without_ext[ipv6_base.header_len()..len],
                    }
                );
            }

            // payload length error auth header
            {
                use crate::err::{LenError, Layer};

                let required_len = ipv6_base.header_len() + auth_base.header_len();
                let (actual, actual_stop_err) = LaxIpv6Slice::from_slice(&data_with_ext[..required_len - 1]).unwrap();
                prop_assert_eq!(
                    actual_stop_err.unwrap(),
                    (
                        ipv6_exts::HeaderSliceError::Len(LenError{
                            required_len: required_len - Ipv6Header::LEN,
                            len: required_len - Ipv6Header::LEN - 1,
                            len_source: LenSource::Slice,
                            layer: Layer::IpAuthHeader,
                            layer_start_offset: Ipv6Header::LEN,
                        }),
                        err::Layer::IpAuthHeader
                    )
                );
                prop_assert_eq!(actual.header().slice(), &data_with_ext[..ipv6_base.header_len()]);
                prop_assert_eq!(
                    actual.payload(),
                    &LaxIpPayloadSlice{
                        incomplete: true,
                        ip_number: AUTH,
                        fragmented: false,
                        len_source: LenSource::Slice,
                        payload: &data_with_ext[ipv6_base.header_len()..required_len - 1],
                    }
                );
            }

            // auth length error
            {
                use crate::err::{LenError, Layer};

                // inject payload length that is smaller then the auth header
                let mut data = data_with_ext.clone();
                let payload_len_too_small = auth_base.header_len() - 1;
                {
                    let plts = (payload_len_too_small as u16).to_be_bytes();
                    data[4] = plts[0];
                    data[5] = plts[1];
                }

                let (actual, actual_stop_err) = LaxIpv6Slice::from_slice(&data).unwrap();
                prop_assert_eq!(
                    actual_stop_err.unwrap(),
                    (
                        ipv6_exts::HeaderSliceError::Len(
                            LenError{
                                required_len: auth_base.header_len(),
                                len: auth_base.header_len() - 1,
                                len_source: LenSource::Ipv6HeaderPayloadLen,
                                layer: Layer::IpAuthHeader,
                                layer_start_offset: ipv6_base.header_len(),
                            }
                        ),
                        err::Layer::IpAuthHeader
                    )
                );
                prop_assert_eq!(actual.header().slice(), &data[..ipv6_base.header_len()]);
                prop_assert_eq!(
                    actual.payload(),
                    &LaxIpPayloadSlice{
                        incomplete: false,
                        ip_number: AUTH,
                        fragmented: false,
                        len_source: LenSource::Ipv6HeaderPayloadLen,
                        payload: &data[ipv6_base.header_len()..ipv6_base.header_len() + payload_len_too_small],
                    }
                );
            }

            // auth content error
            {
                use crate::err::{ip_auth, ipv6_exts};

                // inject zero as auth header length
                let mut data = data_with_ext.clone();
                data[ipv6_base.header_len() + 1] = 0;

                let (actual, actual_stop_error) = LaxIpv6Slice::from_slice(&data).unwrap();

                prop_assert_eq!(
                    actual_stop_error.unwrap(),
                    (
                        ipv6_exts::HeaderSliceError::Content(ipv6_exts::HeaderError::IpAuth(
                            ip_auth::HeaderError::ZeroPayloadLen
                        )),
                        err::Layer::IpAuthHeader
                    )
                );
                prop_assert_eq!(
                    actual.header().slice(),
                    &data[..ipv6_base.header_len()]
                );
                prop_assert_eq!(
                    actual.payload(),
                    &LaxIpPayloadSlice{
                        incomplete: false,
                        ip_number: AUTH,
                        fragmented: false,
                        len_source: LenSource::Ipv6HeaderPayloadLen,
                        payload: &data[ipv6_base.header_len()..ipv6_base.header_len() + auth_base.header_len() + payload.len()],
                    }
                );
            }
        }
    }

    #[test]
    fn is_payload_fragmented() {
        use crate::ip_number::{IPV6_FRAG, UDP};

        // not fragmented
        {
            let data = Ipv6Header {
                traffic_class: 0,
                flow_label: 1.try_into().unwrap(),
                payload_length: 0,
                next_header: UDP,
                hop_limit: 4,
                source: [0; 16],
                destination: [0; 16],
            }
            .to_bytes();
            assert_eq!(
                false,
                LaxIpv6Slice::from_slice(&data)
                    .unwrap()
                    .0
                    .is_payload_fragmented()
            );
        }

        // fragmented
        {
            let ipv6_frag = Ipv6FragmentHeader {
                next_header: UDP,
                fragment_offset: 0.try_into().unwrap(),
                more_fragments: true,
                identification: 0,
            };
            let ipv6 = Ipv6Header {
                traffic_class: 0,
                flow_label: 1.try_into().unwrap(),
                payload_length: ipv6_frag.header_len() as u16,
                next_header: IPV6_FRAG,
                hop_limit: 4,
                source: [0; 16],
                destination: [0; 16],
            };

            let mut data = Vec::with_capacity(ipv6.header_len() + ipv6_frag.header_len());
            data.extend_from_slice(&ipv6.to_bytes());
            data.extend_from_slice(&ipv6_frag.to_bytes());
            assert!(Ipv6Slice::from_slice(&data)
                .unwrap()
                .is_payload_fragmented());
        }
    }
}
