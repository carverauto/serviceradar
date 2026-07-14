use crate::*;

/// Slices of the IPv4 extension headers present after the ip header.
///
/// Currently supported:
/// * Authentication Header
///
/// Currently not supported:
/// * Encapsulating Security Payload Header (ESP)
#[derive(Copy, Clone, Debug, Eq, PartialEq, Default)]
pub struct Ipv4ExtensionsSlice<'a> {
    pub auth: Option<IpAuthHeaderSlice<'a>>,
}

impl<'a> Ipv4ExtensionsSlice<'a> {
    /// Read all known ipv4 extensions and return an `Ipv4ExtensionSlices` with the
    /// identified slices, the final ip number and a slice pointing to the non parsed data.
    pub fn from_slice(
        start_ip_number: IpNumber,
        start_slice: &'a [u8],
    ) -> Result<(Ipv4ExtensionsSlice<'a>, IpNumber, &'a [u8]), err::ip_auth::HeaderSliceError> {
        use ip_number::*;
        if AUTH == start_ip_number {
            let header = IpAuthHeaderSlice::from_slice(start_slice)?;
            let rest = &start_slice[header.slice().len()..];
            let next_header = header.next_header();
            Ok((
                Ipv4ExtensionsSlice { auth: Some(header) },
                next_header,
                rest,
            ))
        } else {
            Ok((Default::default(), start_ip_number, start_slice))
        }
    }

    /// Collects all ipv4 extension headers in a slice until an error
    /// is encountered or a "non IP extension header" is found and
    /// returns the successfully parsed parts (+ the unparsed slice
    /// it's [`IpNumber`] and the error if one occurred).
    ///
    /// The returned values are
    ///
    /// * [`Ipv4ExtensionsSlice`] containing the successfully parsed IPv6 extension headers
    /// * [`IpNumber`] of unparsed data
    /// * Slice with unparsed data
    /// * Optional with error if there was an error wich stoped the parsing.
    ///
    /// # Examples
    ///
    /// ```
    /// use etherparse::{Ipv4ExtensionsSlice, IpAuthHeader, ip_number::{UDP, AUTHENTICATION_HEADER}};
    ///
    /// let auth_header = IpAuthHeader::new(UDP, 0, 0, &[]).unwrap();
    /// let data = auth_header.to_bytes();
    ///
    /// let (ipv4_exts, next_ip_num, next_data, err) =
    ///     Ipv4ExtensionsSlice::from_slice_lax(AUTHENTICATION_HEADER, &data);
    ///
    /// // authentication header is separated and no error occurred
    /// assert!(ipv4_exts.auth.is_some());
    /// assert_eq!(next_ip_num, UDP);
    /// assert_eq!(next_data, &[]);
    /// assert!(err.is_none());
    /// ```
    ///
    /// It is also ok to pass in a "non ip extension":
    ///
    /// ```
    /// use etherparse::{Ipv4ExtensionsSlice, ip_number::UDP};
    ///
    /// let data = [0,1,2,3];
    /// // passing a non "ip extension header" ip number
    /// let (ipv4_exts, next_ip_num, next_data, err) =
    ///     Ipv4ExtensionsSlice::from_slice_lax(UDP, &data);
    ///
    /// // the original data gets returned as UDP is not a
    /// // an IP extension header
    /// assert!(ipv4_exts.is_empty());
    /// assert_eq!(next_ip_num, UDP);
    /// assert_eq!(next_data, &data);
    /// // no errors gets triggered as the data is valid
    /// assert!(err.is_none());
    /// ```
    ///
    /// In case an error occurred the original data gets
    /// returned together with the error:
    ///
    /// ```
    /// use etherparse::{
    ///     Ipv4ExtensionsSlice,
    ///     IpAuthHeader,
    ///     ip_number::AUTHENTICATION_HEADER,
    ///     LenSource,
    ///     err::{ip_auth::HeaderSliceError::Len, LenError, Layer}
    /// };
    ///
    /// // providing not enough data
    /// let (ipv4_exts, next_ip_num, next_data, err) =
    ///     Ipv4ExtensionsSlice::from_slice_lax(AUTHENTICATION_HEADER, &[]);
    ///
    /// // original data will be returned with no data parsed
    /// assert!(ipv4_exts.is_empty());
    /// assert_eq!(next_ip_num, AUTHENTICATION_HEADER);
    /// assert_eq!(next_data, &[]);
    /// // the error that stopped the parsing will also be returned
    /// assert_eq!(err, Some(Len(LenError{
    ///     required_len: IpAuthHeader::MIN_LEN,
    ///     len: 0,
    ///     len_source: LenSource::Slice,
    ///     layer: Layer::IpAuthHeader,
    ///     layer_start_offset: 0,
    /// })));
    /// ```
    pub fn from_slice_lax(
        start_ip_number: IpNumber,
        start_slice: &'a [u8],
    ) -> (
        Ipv4ExtensionsSlice<'a>,
        IpNumber,
        &'a [u8],
        Option<err::ip_auth::HeaderSliceError>,
    ) {
        use ip_number::*;
        if AUTH == start_ip_number {
            match IpAuthHeaderSlice::from_slice(start_slice) {
                Ok(header) => {
                    let rest = unsafe {
                        // SAFE as header.slice() has the same start and is a
                        // subslice of start_slice.
                        core::slice::from_raw_parts(
                            start_slice.as_ptr().add(header.slice().len()),
                            start_slice.len() - header.slice().len(),
                        )
                    };
                    let next_header = header.next_header();
                    (
                        Ipv4ExtensionsSlice { auth: Some(header) },
                        next_header,
                        rest,
                        None,
                    )
                }
                Err(err) => (
                    Ipv4ExtensionsSlice { auth: None },
                    start_ip_number,
                    start_slice,
                    Some(err),
                ),
            }
        } else {
            (
                Ipv4ExtensionsSlice { auth: None },
                start_ip_number,
                start_slice,
                None,
            )
        }
    }

    /// Convert the slices into actual headers.
    pub fn to_header(&self) -> Ipv4Extensions {
        Ipv4Extensions {
            auth: self.auth.as_ref().map(|v| v.to_header()),
        }
    }

    /// Returns true if no IPv4 extension header is present (all fields `None`).
    #[inline]
    pub fn is_empty(&self) -> bool {
        self.auth.is_none()
    }
}

#[cfg(test)]
mod test {
    use super::*;
    use crate::test_gens::*;
    use alloc::vec::Vec;
    use proptest::prelude::*;

    proptest! {
        #[test]
        fn debug(auth in ip_auth_any()) {
            use alloc::format;

            // None
            assert_eq!(
                &format!("Ipv4ExtensionsSlice {{ auth: {:?} }}", Option::<IpAuthHeader>::None),
                &format!(
                    "{:?}",
                    Ipv4ExtensionsSlice {
                        auth: None,
                    }
                )
            );

            // Some
            let buffer = {
                let mut buffer = Vec::with_capacity(auth.header_len());
                auth.write(&mut buffer).unwrap();
                buffer
            };
            let auth_slice = IpAuthHeaderSlice::from_slice(&buffer).unwrap();
            assert_eq!(
                &format!("Ipv4ExtensionsSlice {{ auth: {:?} }}", Some(auth_slice.clone())),
                &format!(
                    "{:?}",
                    Ipv4ExtensionsSlice {
                        auth: Some(auth_slice.clone()),
                    }
                )
            );
        }
    }

    proptest! {
        #[test]
        fn clone_eq(auth in ip_auth_any()) {
            // None
            {
                let header = Ipv4ExtensionsSlice{
                    auth: None,
                };
                assert_eq!(
                    header.clone(),
                    Ipv4ExtensionsSlice{
                        auth: None,
                    }
                );
            }

            // Some
            {
                let buffer = {
                    let mut buffer = Vec::with_capacity(auth.header_len());
                    auth.write(&mut buffer).unwrap();
                    buffer
                };
                let auth_slice = IpAuthHeaderSlice::from_slice(&buffer).unwrap();
                let slice = Ipv4ExtensionsSlice {
                    auth: Some(auth_slice.clone()),
                };
                assert_eq!(
                    slice.clone(),
                    Ipv4ExtensionsSlice{
                        auth: Some(auth_slice.clone()),
                    }
                );
            }
        }
    }

    proptest! {
        #[test]
        fn from_slice_lax(auth in ip_auth_any()) {
            use crate::ip_number::{UDP, AUTHENTICATION_HEADER};
            use crate::err::{*, ip_auth::HeaderSliceError::Len};

            // normal read
            {
                let data = auth.to_bytes();

                let (ipv4_exts, next_ip_num, next_data, err) =
                    Ipv4ExtensionsSlice::from_slice_lax(AUTHENTICATION_HEADER, &data);

                // authentication header is separated and no error occurred
                assert_eq!(ipv4_exts.auth.unwrap().to_header(), auth);
                assert_eq!(next_ip_num, auth.next_header);
                assert_eq!(next_data, &[]);
                assert!(err.is_none());
            }
            // normal read with no extension header
            {
                let data = [0,1,2,3];
                // passing a non "ip extension header" ip number
                let (ipv4_exts, next_ip_num, next_data, err) =
                    Ipv4ExtensionsSlice::from_slice_lax(UDP, &data);

                // the original data gets returned as UDP is not a
                // an IP extension header
                assert!(ipv4_exts.is_empty());
                assert_eq!(next_ip_num, UDP);
                assert_eq!(next_data, &data);
                // no errors gets triggered as the data is valid
                assert!(err.is_none());
            }
            // len error during parsing
            {
                // providing not enough data
                let (ipv4_exts, next_ip_num, next_data, err) =
                    Ipv4ExtensionsSlice::from_slice_lax(AUTHENTICATION_HEADER, &[]);

                // original data will be returned with no data parsed
                assert!(ipv4_exts.is_empty());
                assert_eq!(next_ip_num, AUTHENTICATION_HEADER);
                assert_eq!(next_data, &[]);
                // the error that stopped the parsing will also be returned
                assert_eq!(err, Some(Len(LenError{
                    required_len: IpAuthHeader::MIN_LEN,
                    len: 0,
                    len_source: LenSource::Slice,
                    layer: Layer::IpAuthHeader,
                    layer_start_offset: 0,
                })));
            }
        }
    }

    proptest! {
        #[test]
        fn to_header(auth in ip_auth_any()) {
            // None
            assert_eq!(
                Ipv4ExtensionsSlice{
                    auth: None,
                }.to_header(),
                Ipv4Extensions{
                    auth: None,
                }
            );

            // Some
            {
                let buffer = {
                    let mut buffer = Vec::with_capacity(auth.header_len());
                    auth.write(&mut buffer).unwrap();
                    buffer
                };
                let slice = Ipv4ExtensionsSlice{
                    auth: Some(
                        IpAuthHeaderSlice::from_slice(&buffer).unwrap()
                    ),
                };
                assert_eq!(
                    slice.to_header(),
                    Ipv4Extensions{
                        auth: Some(auth.clone()),
                    }
                );
            }
        }
    }

    #[test]
    fn is_empty() {
        // empty
        assert!(Ipv4ExtensionsSlice { auth: None }.is_empty());

        // auth
        {
            let buffer = {
                let auth = IpAuthHeader::new(ip_number::UDP, 0, 0, &[]).unwrap();
                let mut buffer = Vec::with_capacity(auth.header_len());
                auth.write(&mut buffer).unwrap();
                buffer
            };
            assert_eq!(
                false,
                Ipv4ExtensionsSlice {
                    auth: Some(IpAuthHeaderSlice::from_slice(&buffer).unwrap()),
                }
                .is_empty()
            );
        }
    }
}
