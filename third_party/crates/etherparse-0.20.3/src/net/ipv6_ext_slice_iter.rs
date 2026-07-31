use crate::*;
use core::slice::from_raw_parts;

/// Allows iterating over the IPv6 extension headers present in an [Ipv6ExtensionsSlice].
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Ipv6ExtensionSliceIter<'a> {
    pub(crate) next_header: IpNumber,
    pub(crate) rest: &'a [u8],
}

impl Default for Ipv6ExtensionSliceIter<'_> {
    fn default() -> Self {
        Ipv6ExtensionSliceIter {
            // don't use 0 as this is the reserved value
            // for the hop by hop header
            next_header: IpNumber::IPV6_NO_NEXT_HEADER,
            rest: &[],
        }
    }
}

impl<'a> Iterator for Ipv6ExtensionSliceIter<'a> {
    type Item = Ipv6ExtensionSlice<'a>;

    fn next(&mut self) -> Option<Ipv6ExtensionSlice<'a>> {
        use ip_number::*;
        use Ipv6ExtensionSlice::*;

        match self.next_header {
            // Note on the unsafe calls:
            //
            // As the slice contents & length were previously checked by
            // Ipv6ExtensionsSlice::from_slice the content does not have to be
            // rechecked.
            IPV6_HOP_BY_HOP => unsafe {
                let slice = Ipv6RawExtHeaderSlice::from_slice_unchecked(self.rest);
                let len = slice.slice().len();
                self.rest = from_raw_parts(self.rest.as_ptr().add(len), self.rest.len() - len);
                self.next_header = slice.next_header();
                Some(HopByHop(slice))
            },
            IPV6_ROUTE => unsafe {
                let slice = Ipv6RawExtHeaderSlice::from_slice_unchecked(self.rest);
                let len = slice.slice().len();
                self.rest = from_raw_parts(self.rest.as_ptr().add(len), self.rest.len() - len);
                self.next_header = slice.next_header();
                Some(Routing(slice))
            },
            IPV6_DEST_OPTIONS => unsafe {
                let slice = Ipv6RawExtHeaderSlice::from_slice_unchecked(self.rest);
                let len = slice.slice().len();
                self.rest = from_raw_parts(self.rest.as_ptr().add(len), self.rest.len() - len);
                self.next_header = slice.next_header();
                Some(DestinationOptions(slice))
            },
            IPV6_FRAG => unsafe {
                let slice = Ipv6FragmentHeaderSlice::from_slice_unchecked(self.rest);
                let len = slice.slice().len();
                self.rest = from_raw_parts(self.rest.as_ptr().add(len), self.rest.len() - len);
                self.next_header = slice.next_header();

                Some(Fragment(slice))
            },
            AUTH => unsafe {
                let slice = IpAuthHeaderSlice::from_slice_unchecked(self.rest);
                let len = slice.slice().len();
                self.rest = from_raw_parts(self.rest.as_ptr().add(len), self.rest.len() - len);
                self.next_header = slice.next_header();
                Some(Authentication(slice))
            },
            // done parsing, the next header is not a known/supported header extension
            _ => None,
        }
    }
}

#[cfg(test)]
mod test {
    use super::ipv6_exts_test_helpers::*;
    use super::*;
    use crate::ip_number::*;
    use crate::test_gens::*;
    use alloc::borrow::ToOwned;
    use proptest::prelude::*;

    #[test]
    fn into_iter() {
        let a: Ipv6ExtensionsSlice = Default::default();
        let mut iter = a.into_iter();
        assert_eq!(None, iter.next());
    }

    proptest! {
        #[test]
        fn next(
            header_size in any::<u8>(),
            post_header in ip_number_any()
                .prop_filter("Must be a non ipv6 header relevant ip number".to_owned(),
                    |v| !EXTENSION_KNOWN_IP_NUMBERS.iter().any(|&x| v == &x)
                )
        ) {
            /// Run a test with the given ip numbers
            fn run_test(ip_numbers: &[IpNumber], header_sizes: &[u8]) {
                // setup test payload
                let e = ExtensionTestPayload::new(
                    ip_numbers,
                    header_sizes
                );

                // a hop by hop header that is not at the start triggers an error
                if false == e.ip_numbers[1..].iter().any(|&x| x == IPV6_HOP_BY_HOP) {
                    // normal read
                    let (header, _, _) = Ipv6ExtensionsSlice::from_slice(ip_numbers[0], e.slice()).unwrap();
                    let mut iter = header.into_iter();
                    let mut slice = e.slice();

                    // go through all expected headers
                    for i in 0..e.ip_numbers.len() - 1 {
                        use Ipv6ExtensionSlice::*;

                        // iterate and check all results
                        let next = iter.next().unwrap();
                        match e.ip_numbers[i] {
                            IPV6_HOP_BY_HOP => {
                                let header = Ipv6RawExtHeaderSlice::from_slice(slice).unwrap();
                                assert_eq!(next, HopByHop(header.clone()));
                                slice = &slice[header.slice().len()..];
                            },
                            IPV6_ROUTE => {
                                let header = Ipv6RawExtHeaderSlice::from_slice(slice).unwrap();
                                assert_eq!(next, Routing(header.clone()));
                                slice = &slice[header.slice().len()..];
                            },
                            IPV6_DEST_OPTIONS => {
                                let header = Ipv6RawExtHeaderSlice::from_slice(slice).unwrap();
                                assert_eq!(next, DestinationOptions(header.clone()));
                                slice = &slice[header.slice().len()..];
                            }
                            IPV6_FRAG => {
                                let header = Ipv6FragmentHeaderSlice::from_slice(slice).unwrap();
                                assert_eq!(next, Fragment(header.clone()));
                                slice = &slice[header.slice().len()..];
                            },
                            AUTH => {
                                let header = IpAuthHeaderSlice::from_slice(slice).unwrap();
                                assert_eq!(next, Authentication(header.clone()));
                                slice = &slice[header.slice().len()..];
                            },
                            _ => unreachable!()
                        }
                    }

                    // expect that all headers have been visited
                    assert_eq!(None, iter.next());
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

    #[test]
    fn debug() {
        use alloc::format;

        let a: Ipv6ExtensionSliceIter = Default::default();
        assert_eq!(
            format!(
                "Ipv6ExtensionSliceIter {{ next_header: {:?}, rest: [] }}",
                IpNumber(59)
            ),
            format!("{:?}", a)
        );
    }

    #[test]
    fn clone_eq() {
        let a: Ipv6ExtensionSliceIter = Default::default();
        assert_eq!(a.clone(), a);
    }

    #[test]
    fn default() {
        let mut a: Ipv6ExtensionSliceIter = Default::default();
        assert_eq!(None, a.next());
    }
}
