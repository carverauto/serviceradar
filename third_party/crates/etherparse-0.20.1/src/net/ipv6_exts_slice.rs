use crate::*;
use core::slice::from_raw_parts;

/// Slice containing the IPv6 extension headers present after the ip header.
///
/// Currently supported:
/// * Authentication Header
/// * Hop by Hop Options Header
/// * Destination Options Header (before and after routing headers)
/// * Routing Header
/// * Fragment
/// * Authentication Header
///
/// Currently not supported:
/// * Encapsulating Security Payload Header (ESP)
/// * Host Identity Protocol (HIP)
/// * IP Mobility
/// * Site Multihoming by IPv6 Intermediation (SHIM6)
#[derive(Clone, Debug, Eq, PartialEq, Default)]
pub struct Ipv6ExtensionsSlice<'a> {
    /// IP protocol number of the first header present in the slice.
    first_header: Option<IpNumber>,
    /// True if a fragment header is present in the ipv6 header extensions that causes the payload to be fragmented.
    fragmented: bool,
    /// Slice containing ipv6 extension headers.
    slice: &'a [u8],
}

impl<'a> Ipv6ExtensionsSlice<'a> {
    /// Collects all ipv6 extension headers in a slice & checks if
    /// a fragmentation header that fragments the packet is present.
    pub fn from_slice(
        start_ip_number: IpNumber,
        start_slice: &'a [u8],
    ) -> Result<(Ipv6ExtensionsSlice<'a>, IpNumber, &'a [u8]), err::ipv6_exts::HeaderSliceError>
    {
        let mut rest = start_slice;
        let mut next_header = start_ip_number;
        let mut fragmented = false;

        use err::ipv6_exts::{HeaderError::*, HeaderSliceError::*};
        use ip_number::*;

        // the hop by hop header is required to occur directly after the ipv6 header
        if IPV6_HOP_BY_HOP == next_header {
            let slice = Ipv6RawExtHeaderSlice::from_slice(rest).map_err(Len)?;
            rest = &rest[slice.slice().len()..];
            next_header = slice.next_header();
        }

        loop {
            match next_header {
                IPV6_HOP_BY_HOP => {
                    return Err(Content(HopByHopNotAtStart));
                }
                IPV6_DEST_OPTIONS | IPV6_ROUTE => {
                    let slice = Ipv6RawExtHeaderSlice::from_slice(rest)
                        .map_err(|err| Len(err.add_offset(start_slice.len() - rest.len())))?;
                    // SAFETY:
                    // Ipv6RawExtHeaderSlice::from_slice always generates
                    // a subslice from the given slice rest. Therefor it is guaranteed
                    // that len is always greater or equal the len of rest.
                    rest = unsafe {
                        let len = slice.slice().len();
                        from_raw_parts(rest.as_ptr().add(len), rest.len() - len)
                    };
                    next_header = slice.next_header();
                }
                IPV6_FRAG => {
                    let slice = Ipv6FragmentHeaderSlice::from_slice(rest)
                        .map_err(|err| Len(err.add_offset(start_slice.len() - rest.len())))?;
                    // SAFETY:
                    // Ipv6FragmentHeaderSlice::from_slice always generates
                    // a subslice from the given slice rest. Therefor it is guaranteed
                    // that len is always greater or equal the len of rest.
                    rest = unsafe {
                        let len = slice.slice().len();
                        from_raw_parts(rest.as_ptr().add(len), rest.len() - len)
                    };
                    next_header = slice.next_header();

                    // check if the fragment header actually causes fragmentation
                    fragmented = fragmented || slice.is_fragmenting_payload();
                }
                AUTH => {
                    let slice = IpAuthHeaderSlice::from_slice(rest).map_err(|err| {
                        use err::ip_auth::HeaderSliceError as I;
                        match err {
                            I::Len(err) => Len(err.add_offset(start_slice.len() - rest.len())),
                            I::Content(err) => Content(IpAuth(err)),
                        }
                    })?;
                    // SAFETY:
                    // IpAuthHeaderSlice::from_slice always generates
                    // a subslice from the given slice rest. Therefor it is guaranteed
                    // that len is always greater or equal the len of rest.
                    rest = unsafe {
                        let len = slice.slice().len();
                        from_raw_parts(rest.as_ptr().add(len), rest.len() - len)
                    };
                    next_header = slice.next_header();
                }
                // done parsing, the next header is not a known/supported header extension
                _ => break,
            }
        }

        Ok((
            Ipv6ExtensionsSlice {
                first_header: if rest.len() != start_slice.len() {
                    Some(start_ip_number)
                } else {
                    None
                },
                fragmented,
                slice: &start_slice[..start_slice.len() - rest.len()],
            },
            next_header,
            rest,
        ))
    }

    /// Collects all ipv6 extension headers in a slice until an error
    /// is encountered or a "non IP extension header" is found and
    /// returns the successfully parsed parts (+ the unparsed slice
    /// it's `IpNumber` and the error if one occurred).
    ///
    /// The returned values are
    ///
    /// * [`Ipv6ExtensionsSlice`] containing the successfully parsed IPv6 extension headers
    /// * [`IpNumber`] of unparsed data
    /// * Slice with unparsed data
    /// * Optional with error if there was an error wich stoped the parsing.
    pub fn from_slice_lax(
        start_ip_number: IpNumber,
        start_slice: &'a [u8],
    ) -> (
        Ipv6ExtensionsSlice<'a>,
        IpNumber,
        &'a [u8],
        Option<(err::ipv6_exts::HeaderSliceError, err::Layer)>,
    ) {
        let mut rest = start_slice;
        let mut next_header = start_ip_number;
        let mut error = None;
        let mut fragmented = false;

        use err::ipv6_exts::{HeaderError::*, HeaderSliceError::*};
        use ip_number::*;

        // the hop by hop header is required to occur directly after the ipv6 header
        if IPV6_HOP_BY_HOP == next_header {
            match Ipv6RawExtHeaderSlice::from_slice(rest) {
                Ok(slice) => {
                    rest = &rest[slice.slice().len()..];
                    next_header = slice.next_header();
                }
                Err(err) => {
                    error = Some((Len(err), err::Layer::Ipv6HopByHopHeader));
                }
            }
        }

        while error.is_none() {
            match next_header {
                IPV6_HOP_BY_HOP => {
                    error = Some((Content(HopByHopNotAtStart), err::Layer::Ipv6HopByHopHeader));
                    break;
                }
                IPV6_DEST_OPTIONS | IPV6_ROUTE => {
                    let slice = match Ipv6RawExtHeaderSlice::from_slice(rest) {
                        Ok(s) => s,
                        Err(err) => {
                            error = Some((
                                Len(err.add_offset(start_slice.len() - rest.len())),
                                if next_header == IPV6_DEST_OPTIONS {
                                    err::Layer::Ipv6DestOptionsHeader
                                } else {
                                    err::Layer::Ipv6RouteHeader
                                },
                            ));
                            break;
                        }
                    };
                    // SAFETY:
                    // Ipv6RawExtHeaderSlice::from_slice always generates
                    // a subslice from the given slice rest. Therefor it is guranteed
                    // that len is always greater or equal the len of rest.
                    rest = unsafe {
                        let len = slice.slice().len();
                        from_raw_parts(rest.as_ptr().add(len), rest.len() - len)
                    };
                    next_header = slice.next_header();
                }
                IPV6_FRAG => {
                    let slice = match Ipv6FragmentHeaderSlice::from_slice(rest) {
                        Ok(s) => s,
                        Err(err) => {
                            error = Some((
                                Len(err.add_offset(start_slice.len() - rest.len())),
                                err::Layer::Ipv6FragHeader,
                            ));
                            break;
                        }
                    };

                    // SAFETY:
                    // Ipv6FragmentHeaderSlice::from_slice always generates
                    // a subslice from the given slice rest. Therefor it is guranteed
                    // that len is always greater or equal the len of rest.
                    rest = unsafe {
                        let len = slice.slice().len();
                        from_raw_parts(rest.as_ptr().add(len), rest.len() - len)
                    };
                    next_header = slice.next_header();

                    // check if the fragment header actually causes fragmentation
                    fragmented = fragmented || slice.is_fragmenting_payload();
                }
                AUTH => {
                    use err::ip_auth::HeaderSliceError as I;
                    let slice = match IpAuthHeaderSlice::from_slice(rest) {
                        Ok(s) => s,
                        Err(err) => {
                            error = Some((
                                match err {
                                    I::Len(err) => {
                                        Len(err.add_offset(start_slice.len() - rest.len()))
                                    }
                                    I::Content(err) => Content(IpAuth(err)),
                                },
                                err::Layer::IpAuthHeader,
                            ));
                            break;
                        }
                    };
                    // SAFETY:
                    // IpAuthHeaderSlice::from_slice always generates
                    // a subslice from the given slice rest. Therefor it is guranteed
                    // that len is always greater or equal the len of rest.
                    rest = unsafe {
                        let len = slice.slice().len();
                        from_raw_parts(rest.as_ptr().add(len), rest.len() - len)
                    };
                    next_header = slice.next_header();
                }
                // done parsing, the next header is not a known/supported header extension
                _ => break,
            }
        }

        (
            Ipv6ExtensionsSlice {
                first_header: if rest.len() != start_slice.len() {
                    Some(start_ip_number)
                } else {
                    None
                },
                fragmented,
                slice: &start_slice[..start_slice.len() - rest.len()],
            },
            next_header,
            rest,
            error,
        )
    }

    /// Returns true if a fragmentation header is present in
    /// the extensions that fragments the payload.
    ///
    /// Note: A fragmentation header can still be present
    /// even if the return value is false in case the fragmentation
    /// headers don't fragment the payload. This is the case if
    /// the offset of all fragmentation header is 0 and the
    /// more fragment bit is not set.
    #[inline]
    pub fn is_fragmenting_payload(&self) -> bool {
        self.fragmented
    }

    /// Returns the ip protocol number of the first header in the slice
    /// if the slice contains an ipv6 extension header. If no ipv6 header
    /// is present None is returned.
    ///
    /// None is only returned if the slice length of this struct is 0.
    #[inline]
    pub fn first_header(&self) -> Option<IpNumber> {
        self.first_header
    }

    /// Slice containing the ipv6 extension headers.
    #[inline]
    pub fn slice(&self) -> &'a [u8] {
        self.slice
    }

    /// Returns true if no IPv6 extension header is present (slice is empty).
    #[inline]
    pub fn is_empty(&self) -> bool {
        self.slice.is_empty()
    }
}

impl<'a> IntoIterator for Ipv6ExtensionsSlice<'a> {
    type Item = Ipv6ExtensionSlice<'a>;
    type IntoIter = Ipv6ExtensionSliceIter<'a>;

    fn into_iter(self) -> Self::IntoIter {
        Ipv6ExtensionSliceIter {
            // map the next header None value to some non ipv6 ext header
            // value.
            next_header: self.first_header.unwrap_or(ip_number::UDP),
            rest: self.slice,
        }
    }
}

#[cfg(test)]
mod test {
    use super::ipv6_exts_test_helpers::*;
    use super::*;
    use crate::ip_number::*;
    use crate::test_gens::*;
    use alloc::{borrow::ToOwned, vec::Vec};
    use proptest::prelude::*;

    proptest! {
        #[test]
        fn from_slice(
            header_size in any::<u8>(),
            post_header in ip_number_any()
                .prop_filter("Must be a non ipv6 header relevant ip number".to_owned(),
                    |v| !EXTENSION_KNOWN_IP_NUMBERS.iter().any(|&x| v == &x)
                )
        ) {
            use err::ipv6_exts::{HeaderError::*, HeaderSliceError::*};

            // no extension headers filled
            {
                let some_data = [1,2,3,4];
                let actual = Ipv6ExtensionsSlice::from_slice(UDP, &some_data).unwrap();
                assert_eq!(actual.0.is_fragmenting_payload(), false);
                assert_eq!(actual.0.first_header(), None);
                assert_eq!(actual.0.slice().len(), 0);
                assert_eq!(actual.1, UDP);
                assert_eq!(actual.2, &some_data);
            }

            /// Run a test with the given ip numbers
            fn run_test(ip_numbers: &[IpNumber], header_sizes: &[u8]) {
                // setup test payload
                let e = ExtensionTestPayload::new(
                    ip_numbers,
                    header_sizes
                );

                if e.ip_numbers[1..].iter().any(|&x| x == IPV6_HOP_BY_HOP) {
                    // a hop by hop header that is not at the start triggers an error
                    assert_eq!(
                        Ipv6ExtensionsSlice::from_slice(ip_numbers[0], e.slice()).unwrap_err(),
                        Content(HopByHopNotAtStart)
                    );
                } else {
                    // normal read
                    let (header, next, rest) = Ipv6ExtensionsSlice::from_slice(ip_numbers[0], e.slice()).unwrap();
                    assert_eq!(header.first_header(), Some(ip_numbers[0]));
                    assert_eq!(header.slice(), e.slice());
                    assert_eq!(next, *ip_numbers.last().unwrap());
                    assert_eq!(rest, &e.slice()[e.slice().len()..]);

                    // unexpected end of slice
                    {
                        let offset: usize = e.lengths[..e.lengths.len() - 1].into_iter().sum();

                        assert_eq!(
                            Ipv6ExtensionsSlice::from_slice(ip_numbers[0], &e.slice()[..e.slice().len() - 1]).unwrap_err(),
                            Len(err::LenError {
                                required_len: e.slice().len() - offset,
                                len: e.slice().len() - offset - 1,
                                len_source: LenSource::Slice,
                                layer: match ip_numbers[ip_numbers.len() - 2] {
                                    AUTH => err::Layer::IpAuthHeader,
                                    IPV6_FRAG => err::Layer::Ipv6FragHeader,
                                    _ => err::Layer::Ipv6ExtHeader
                                },
                                layer_start_offset: offset,
                            })
                        );
                    }
                }
            }

            // test the parsing of different extension header combinations
            for first_header in &EXTENSION_KNOWN_IP_NUMBERS {

                // single header parsing
                run_test(
                    &[*first_header, post_header],
                    &[header_size],
                );

                for second_header in &EXTENSION_KNOWN_IP_NUMBERS {

                    // double header parsing
                    run_test(
                        &[*first_header, *second_header, post_header],
                        &[header_size],
                    );

                    for third_header in &EXTENSION_KNOWN_IP_NUMBERS {
                        // tripple header parsing
                        run_test(
                            &[*first_header, *second_header, *third_header, post_header],
                            &[header_size],
                        );
                    }
                }
            }
        }
    }

    proptest! {
        #[test]
        fn from_slice_lax(
            header_size in any::<u8>(),
            post_header in ip_number_any()
                .prop_filter("Must be a non ipv6 header relevant ip number".to_owned(),
                    |v| !EXTENSION_KNOWN_IP_NUMBERS.iter().any(|&x| v == &x)
                )
        ) {
            use err::ipv6_exts::{HeaderError::*, HeaderSliceError::*};

            // no extension headers filled
            {
                let some_data = [1,2,3,4];
                let actual = Ipv6ExtensionsSlice::from_slice_lax(UDP, &some_data);
                assert_eq!(actual.0.is_fragmenting_payload(), false);
                assert_eq!(actual.0.first_header(), None);
                assert_eq!(actual.0.slice().len(), 0);
                assert_eq!(actual.1, UDP);
                assert_eq!(actual.2, &some_data);
            }

            /// Run a test with the given ip numbers
            fn run_test(ip_numbers: &[IpNumber], header_sizes: &[u8]) {
                // setup test payload
                let e = ExtensionTestPayload::new(
                    ip_numbers,
                    header_sizes
                );

                if e.ip_numbers[1..].iter().any(|&x| x == IPV6_HOP_BY_HOP) {
                    // a hop by hop header that is not at the start triggers an error
                    assert_eq!(
                        Ipv6ExtensionsSlice::from_slice_lax(ip_numbers[0], e.slice()).3.unwrap(),
                        (Content(HopByHopNotAtStart), err::Layer::Ipv6HopByHopHeader)
                    );
                } else {
                    // normal read
                    let actual_normal = Ipv6ExtensionsSlice::from_slice_lax(ip_numbers[0], e.slice());
                    assert_eq!(actual_normal.0.first_header(), Some(ip_numbers[0]));
                    assert_eq!(actual_normal.0.slice(), e.slice());
                    assert_eq!(actual_normal.1, *ip_numbers.last().unwrap());
                    assert_eq!(actual_normal.2, &[]);

                    // unexpected end of slice
                    {
                        let offset: usize = e.lengths[..e.lengths.len() - 1].into_iter().sum();

                        let actual = Ipv6ExtensionsSlice::from_slice_lax(
                            ip_numbers[0],
                            &e.slice()[..e.slice().len() - 1]
                        );
                        assert_eq!(&e.slice()[offset..e.slice().len() - 1], actual.2);
                        assert_eq!(
                            actual.3.unwrap().0,
                            Len(err::LenError {
                                required_len: e.slice().len() - offset,
                                len: e.slice().len() - offset - 1,
                                len_source: LenSource::Slice,
                                layer: match ip_numbers[ip_numbers.len() - 2] {
                                    AUTH => err::Layer::IpAuthHeader,
                                    IPV6_FRAG => err::Layer::Ipv6FragHeader,
                                    _ => err::Layer::Ipv6ExtHeader
                                },
                                layer_start_offset: offset,
                            })
                        );
                    }
                }
            }

            // test the parsing of different extension header combinations
            for first_header in &EXTENSION_KNOWN_IP_NUMBERS {

                // single header parsing
                run_test(
                    &[*first_header, post_header],
                    &[header_size],
                );

                for second_header in &EXTENSION_KNOWN_IP_NUMBERS {

                    // double header parsing
                    run_test(
                        &[*first_header, *second_header, post_header],
                        &[header_size],
                    );

                    for third_header in &EXTENSION_KNOWN_IP_NUMBERS {
                        // tripple header parsing
                        run_test(
                            &[*first_header, *second_header, *third_header, post_header],
                            &[header_size],
                        );
                    }
                }
            }

            // test that the auth content error gets forwarded
            {
                let auth = IpAuthHeader::new(post_header, 0, 0, &[]).unwrap();
                let mut bytes = auth.to_bytes();
                // inject an invalid len value
                bytes[1] = 0;
                let actual = Ipv6ExtensionsSlice::from_slice_lax(AUTH, &bytes);

                use err::ipv6_exts::HeaderError::IpAuth;
                use err::ip_auth::HeaderError::ZeroPayloadLen;
                assert_eq!(actual.0.slice(), &[]);
                assert_eq!(actual.1, AUTH);
                assert_eq!(actual.2, &bytes[..]);
                assert_eq!(actual.3.unwrap().0.content().unwrap(), &IpAuth(ZeroPayloadLen));
            }
        }
    }

    proptest! {
        #[test]
        fn is_fragmenting_payload(
            hop_by_hop_options in ipv6_raw_ext_any(),
            destination_options in ipv6_raw_ext_any(),
            routing in ipv6_raw_ext_any(),
            auth in ip_auth_any(),
            final_destination_options in ipv6_raw_ext_any()
        ) {
            // no fragment header
            {
                let mut exts = Ipv6Extensions{
                    hop_by_hop_options: Some(hop_by_hop_options),
                    destination_options: Some(destination_options),
                    routing: Some(
                        Ipv6RoutingExtensions {
                            routing,
                            final_destination_options: Some(final_destination_options),
                        }
                    ),
                    fragment: None,
                    auth: Some(auth),
                };
                let first_ip_number = exts.set_next_headers(UDP);

                let mut bytes = Vec::with_capacity(exts.header_len());
                exts.write(&mut bytes, first_ip_number).unwrap();

                let (header, _, _) = Ipv6ExtensionsSlice::from_slice(first_ip_number, &bytes).unwrap();
                assert_eq!(false, header.is_fragmenting_payload());
            }

            // different variants of the fragment header with
            // variants that fragment and variants that don't fragment
            let frag_variants : [(bool, Ipv6FragmentHeader);4] = [
                (false, Ipv6FragmentHeader::new(UDP, 0.try_into().unwrap(), false, 123)),
                (true, Ipv6FragmentHeader::new(UDP, 2.try_into().unwrap(), false, 123)),
                (true, Ipv6FragmentHeader::new(UDP, 0.try_into().unwrap(), true, 123)),
                (true, Ipv6FragmentHeader::new(UDP, 3.try_into().unwrap(), true, 123)),
            ];

            for (first_expected, first_header) in frag_variants.iter() {
                // single fragment header
                {
                    let bytes = first_header.to_bytes();
                    let (header, _, _) = Ipv6ExtensionsSlice::from_slice(IPV6_FRAG, &bytes).unwrap();
                    assert_eq!(*first_expected, header.is_fragmenting_payload());
                }
                // two fragment headers
                for (second_expected, second_header) in frag_variants.iter() {
                    let mut first_mod = first_header.clone();
                    first_mod.next_header = IPV6_FRAG;
                    let mut bytes = Vec::with_capacity(first_mod.header_len() + second_header.header_len());
                    bytes.extend_from_slice(&first_mod.to_bytes());
                    bytes.extend_from_slice(&second_header.to_bytes());

                    let (header, _, _) = Ipv6ExtensionsSlice::from_slice(IPV6_FRAG, &bytes).unwrap();
                    assert_eq!(
                        *first_expected || *second_expected,
                        header.is_fragmenting_payload()
                    );
                }
            }
        }
    }

    #[test]
    fn is_empty() {
        // empty
        {
            let slice = Ipv6ExtensionsSlice::from_slice(ip_number::UDP, &[])
                .unwrap()
                .0;
            assert!(slice.is_empty());
        }

        // fragment
        {
            let bytes =
                Ipv6FragmentHeader::new(ip_number::UDP, IpFragOffset::ZERO, true, 0).to_bytes();
            let slice = Ipv6ExtensionsSlice::from_slice(ip_number::IPV6_FRAG, &bytes)
                .unwrap()
                .0;
            assert_eq!(false, slice.is_empty());
        }
    }

    #[test]
    fn debug() {
        use alloc::format;

        let a: Ipv6ExtensionsSlice = Default::default();
        assert_eq!(
            "Ipv6ExtensionsSlice { first_header: None, fragmented: false, slice: [] }",
            &format!("{:?}", a)
        );
    }

    #[test]
    fn clone_eq() {
        let a: Ipv6ExtensionsSlice = Default::default();
        assert_eq!(a, a.clone());
    }

    #[test]
    fn default() {
        let a: Ipv6ExtensionsSlice = Default::default();
        assert_eq!(a.is_fragmenting_payload(), false);
        assert_eq!(a.first_header(), None);
        assert_eq!(a.slice().len(), 0);
    }
}
