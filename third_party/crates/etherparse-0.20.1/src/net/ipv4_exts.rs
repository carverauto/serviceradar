use crate::{err::ipv4_exts::ExtsWalkError, *};

/// IPv4 extension headers present after the ip header.
///
/// Currently supported:
/// * Authentication Header
///
/// Currently not supported:
/// - Encapsulating Security Payload Header (ESP)
#[derive(Clone, Debug, Eq, PartialEq, Default)]
pub struct Ipv4Extensions {
    pub auth: Option<IpAuthHeader>,
}

impl Ipv4Extensions {
    /// Minimum length required for extension header in bytes/octets.
    /// Which is zero as no extension headers are required.
    pub const MIN_LEN: usize = 0;

    /// Maximum summed up length of all extension headers in bytes/octets.
    pub const MAX_LEN: usize = IpAuthHeader::MAX_LEN;

    /// Read all known ipv4 extensions and return an `Ipv4Extensions` with the
    /// identified slices, the final ip number and a slice pointing to the non parsed data.
    pub fn from_slice(
        start_ip_number: IpNumber,
        slice: &[u8],
    ) -> Result<(Ipv4Extensions, IpNumber, &[u8]), err::ip_auth::HeaderSliceError> {
        Ipv4ExtensionsSlice::from_slice(start_ip_number, slice).map(|v| (v.0.to_header(), v.1, v.2))
    }

    /// Collects all known ipv4 extension headers in a slice until an error
    /// is encountered or a "non IP extension header" is found and
    /// returns the successfully parsed parts (+ the unparsed slice
    /// it's [`IpNumber`] and the error if one occurred).
    ///
    /// The returned values are
    ///
    /// * [`Ipv4Extensions`] containing the successfully parsed IPv6 extension headers
    /// * [`IpNumber`] of unparsed data
    /// * Slice with unparsed data
    /// * Optional with error if there was an error wich stoped the parsing.
    ///
    /// # Examples
    ///
    /// ```
    /// use etherparse::{Ipv4Extensions, IpAuthHeader, ip_number::{UDP, AUTHENTICATION_HEADER}};
    ///
    /// let auth_header = IpAuthHeader::new(UDP, 0, 0, &[]).unwrap();
    /// let data = auth_header.to_bytes();
    ///
    /// let (ipv4_exts, next_ip_num, next_data, err) =
    ///     Ipv4Extensions::from_slice_lax(AUTHENTICATION_HEADER, &data);
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
    /// use etherparse::{Ipv4Extensions, ip_number::UDP};
    ///
    /// let data = [0,1,2,3];
    /// // passing a non "ip extension header" ip number
    /// let (ipv4_exts, next_ip_num, next_data, err) =
    ///     Ipv4Extensions::from_slice_lax(UDP, &data);
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
    ///     Ipv4Extensions,
    ///     IpAuthHeader,
    ///     ip_number::AUTHENTICATION_HEADER,
    ///     LenSource,
    ///     err::{ip_auth::HeaderSliceError::Len, LenError, Layer}
    /// };
    ///
    /// // providing not enough data
    /// let (ipv4_exts, next_ip_num, next_data, err) =
    ///     Ipv4Extensions::from_slice_lax(AUTHENTICATION_HEADER, &[]);
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
        start_slice: &[u8],
    ) -> (
        Ipv4Extensions,
        IpNumber,
        &[u8],
        Option<err::ip_auth::HeaderSliceError>,
    ) {
        let (slice, next_ip_number, next_data, error) =
            Ipv4ExtensionsSlice::from_slice_lax(start_ip_number, start_slice);
        (slice.to_header(), next_ip_number, next_data, error)
    }

    /// Reads the known ipv4 extension headers from the reader and returns the
    /// headers together with the internet protocol number identifying the protocol
    /// that will be next.
    #[cfg(feature = "std")]
    #[cfg_attr(docsrs, doc(cfg(feature = "std")))]
    pub fn read<T: std::io::Read + Sized>(
        reader: &mut T,
        start_ip_number: IpNumber,
    ) -> Result<(Ipv4Extensions, IpNumber), err::ip_auth::HeaderReadError> {
        use ip_number::*;
        if AUTH == start_ip_number {
            let header = IpAuthHeader::read(reader)?;
            let next_ip_number = header.next_header;
            Ok((Ipv4Extensions { auth: Some(header) }, next_ip_number))
        } else {
            Ok((Default::default(), start_ip_number))
        }
    }

    /// Reads the known ipv4 extension headers from a length limited reader and returns the
    /// headers together with the internet protocol number identifying the protocol
    /// that will be next.
    #[cfg(feature = "std")]
    #[cfg_attr(docsrs, doc(cfg(feature = "std")))]
    pub fn read_limited<T: std::io::Read + Sized>(
        reader: &mut crate::io::LimitedReader<T>,
        start_ip_number: IpNumber,
    ) -> Result<(Ipv4Extensions, IpNumber), err::ip_auth::HeaderLimitedReadError> {
        use ip_number::*;
        if AUTH == start_ip_number {
            let header = IpAuthHeader::read_limited(reader)?;
            let next_ip_number = header.next_header;
            Ok((Ipv4Extensions { auth: Some(header) }, next_ip_number))
        } else {
            Ok((Default::default(), start_ip_number))
        }
    }

    /// Write the extensions to the writer.
    pub(crate) fn write_internal<T: CoreWrite + ?Sized>(
        &self,
        writer: &mut T,
        start_ip_number: IpNumber,
    ) -> Result<(), WriteError<T::Error, err::ipv4_exts::ExtsWalkError>> {
        use err::ipv4_exts::ExtsWalkError::*;
        use ip_number::*;
        match self.auth {
            Some(ref header) => {
                if AUTH == start_ip_number {
                    writer.write_all(&header.to_bytes()).map_err(WriteError::Io)
                } else {
                    Err(WriteError::Content(ExtNotReferenced {
                        missing_ext: IpNumber::AUTHENTICATION_HEADER,
                    }))
                }
            }
            None => Ok(()),
        }
    }

    /// Write the extensions to the writer.
    #[cfg(feature = "std")]
    #[cfg_attr(docsrs, doc(cfg(feature = "std")))]
    pub fn write<T: std::io::Write + Sized>(
        &self,
        writer: &mut T,
        start_ip_number: IpNumber,
    ) -> Result<(), err::ipv4_exts::HeaderWriteError> {
        self.write_internal(&mut IoWriter(writer), start_ip_number)
            .map_err(|err| match err {
                WriteError::Io(err) => err::ipv4_exts::HeaderWriteError::Io(err),
                WriteError::Content(err) => err::ipv4_exts::HeaderWriteError::Content(err),
            })
    }

    ///Length of the all present headers in bytes.
    pub fn header_len(&self) -> usize {
        if let Some(ref header) = self.auth {
            header.header_len()
        } else {
            0
        }
    }

    /// Sets all the next_header fields of the headers based on the adviced default order
    /// with the given protocol number as last "next header" value. The return value is the protocol
    /// number of the first existing extension header that should be entered in the ipv4 header as
    /// protocol_number.
    ///
    /// If no extension headers are present the value of the argument is returned.
    pub fn set_next_headers(&mut self, last_protocol_number: IpNumber) -> IpNumber {
        use ip_number::*;

        let mut next = last_protocol_number;

        if let Some(ref mut header) = self.auth {
            header.next_header = next;
            next = AUTH;
        }

        next
    }

    /// Return next header based on the extension headers and
    /// the first ip protocol number.
    ///
    /// In case a header is never referenced a
    /// [`err::ipv4_exts::ExtsWalkError::ExtNotReferenced`] is returned.
    pub fn next_header(&self, first_next_header: IpNumber) -> Result<IpNumber, ExtsWalkError> {
        use ip_number::*;
        if let Some(ref auth) = self.auth {
            if first_next_header == AUTH {
                Ok(auth.next_header)
            } else {
                Err(ExtsWalkError::ExtNotReferenced {
                    missing_ext: IpNumber::AUTHENTICATION_HEADER,
                })
            }
        } else {
            Ok(first_next_header)
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
    use crate::ip_number::*;
    use crate::test_gens::*;
    use alloc::vec::Vec;
    use proptest::prelude::*;
    use std::io::Cursor;

    #[test]
    fn from_slice() {
        let auth_header = IpAuthHeader::new(UDP, 0, 0, &[]).unwrap();

        let buffer = {
            let mut buffer = Vec::with_capacity(auth_header.header_len());
            auth_header.write(&mut buffer).unwrap();
            buffer.push(1);
            buffer.push(2);
            buffer
        };

        // no auth header
        {
            let (header, next, rest) = Ipv4Extensions::from_slice(TCP, &buffer).unwrap();
            assert!(header.auth.is_none());
            assert_eq!(TCP, next);
            assert_eq!(rest, &buffer);
        }

        // with auth header
        {
            let (actual, next, rest) = Ipv4Extensions::from_slice(AUTH, &buffer).unwrap();
            assert_eq!(actual.auth.unwrap(), auth_header);
            assert_eq!(UDP, next);
            assert_eq!(rest, &buffer[auth_header.header_len()..]);
        }

        // too small
        {
            use err::ip_auth::HeaderSliceError::Len;
            const AUTH_HEADER_LEN: usize = 12;
            assert_eq!(
                Ipv4Extensions::from_slice(AUTH, &buffer[..auth_header.header_len() - 1])
                    .unwrap_err(),
                Len(err::LenError {
                    required_len: AUTH_HEADER_LEN,
                    len: auth_header.header_len() - 1,
                    len_source: LenSource::Slice,
                    layer: err::Layer::IpAuthHeader,
                    layer_start_offset: 0,
                })
            );
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
                    Ipv4Extensions::from_slice_lax(AUTHENTICATION_HEADER, &data);

                // authentication header is separated and no error occurred
                assert_eq!(ipv4_exts.auth, Some(auth.clone()));
                assert_eq!(next_ip_num, auth.next_header);
                assert_eq!(next_data, &[]);
                assert!(err.is_none());
            }
            // normal read with no extension header
            {
                let data = [0,1,2,3];
                // passing a non "ip extension header" ip number
                let (ipv4_exts, next_ip_num, next_data, err) =
                    Ipv4Extensions::from_slice_lax(UDP, &data);

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
                    Ipv4Extensions::from_slice_lax(AUTHENTICATION_HEADER, &[]);

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
        fn read(auth in ip_auth_any()) {
            // None
            {
                let mut cursor = Cursor::new(&[]);
                let (actual, next) = Ipv4Extensions::read(&mut cursor, UDP).unwrap();
                assert_eq!(next, UDP);
                assert_eq!(
                    actual,
                    Ipv4Extensions{
                        auth: None,
                    }
                );
            }

            // Some sucessfull
            {
                let buffer = {
                    let mut buffer = Vec::with_capacity(auth.header_len());
                    auth.write(&mut buffer).unwrap();
                    buffer.push(1);
                    buffer
                };
                let mut cursor = Cursor::new(&buffer);
                let (actual, next) = Ipv4Extensions::read(&mut cursor, AUTH).unwrap();
                assert_eq!(auth.header_len(), cursor.position() as usize);
                assert_eq!(next, auth.next_header);
                assert_eq!(
                    actual,
                    Ipv4Extensions{
                        auth: Some(auth.clone()),
                    }
                );
            }

            // Some error
            {
                let mut cursor = Cursor::new(&[]);
                assert!(Ipv4Extensions::read(&mut cursor, AUTH).is_err());
            }
        }
    }

    #[test]
    fn write() {
        // None
        {
            let mut buffer = Vec::new();
            Ipv4Extensions { auth: None }
                .write(&mut buffer, UDP)
                .unwrap();
            assert_eq!(0, buffer.len());
        }

        // Some
        let auth_header = IpAuthHeader::new(UDP, 0, 0, &[]).unwrap();
        {
            let mut buffer = Vec::with_capacity(auth_header.header_len());
            Ipv4Extensions {
                auth: Some(auth_header.clone()),
            }
            .write(&mut buffer, AUTH)
            .unwrap();
            let (read_header, _) = IpAuthHeader::from_slice(&buffer).unwrap();
            assert_eq!(auth_header, read_header);
        }

        // Some bad start number
        {
            use crate::err::ipv4_exts::ExtsWalkError::ExtNotReferenced;

            let mut buffer = Vec::new();
            let err = Ipv4Extensions {
                auth: Some(auth_header.clone()),
            }
            .write(&mut buffer, UDP)
            .unwrap_err();
            assert_eq!(
                err.content().unwrap(),
                &ExtNotReferenced {
                    missing_ext: IpNumber::AUTHENTICATION_HEADER,
                }
            );
        }

        // Some: Write error
        {
            let mut buffer = Vec::with_capacity(auth_header.header_len() - 1);
            buffer.resize(auth_header.header_len() - 1, 0);
            let mut cursor = Cursor::new(&mut buffer[..]);
            let err = Ipv4Extensions {
                auth: Some(auth_header.clone()),
            }
            .write(&mut cursor, AUTH)
            .unwrap_err();
            assert!(err.io().is_some());
        }
    }

    #[test]
    fn header_len() {
        // None
        assert_eq!(0, Ipv4Extensions { auth: None }.header_len());

        // Some
        {
            let auth = IpAuthHeader::new(UDP, 0, 0, &[]).unwrap();
            assert_eq!(
                auth.header_len(),
                Ipv4Extensions { auth: Some(auth) }.header_len()
            );
        }
        // Some with paylaod
        {
            let auth = IpAuthHeader::new(UDP, 0, 0, &[1, 2, 3, 4]).unwrap();
            assert_eq!(
                auth.header_len(),
                Ipv4Extensions { auth: Some(auth) }.header_len()
            );
        }
    }

    #[test]
    fn set_next_headers() {
        // None
        {
            let mut exts = Ipv4Extensions { auth: None };
            assert_eq!(UDP, exts.set_next_headers(UDP));
        }

        // Some
        {
            let mut exts = Ipv4Extensions {
                auth: Some(IpAuthHeader::new(TCP, 0, 0, &[]).unwrap()),
            };
            assert_eq!(TCP, exts.auth.as_ref().unwrap().next_header);
            // change from TCP to UDP
            let re = exts.set_next_headers(UDP);
            assert_eq!(AUTH, re);
            assert_eq!(UDP, exts.auth.as_ref().unwrap().next_header);
        }
    }

    #[test]
    fn next_header() {
        // None
        {
            let exts = Ipv4Extensions { auth: None };
            assert_eq!(UDP, exts.next_header(UDP).unwrap());
        }
        // Some
        {
            let exts = Ipv4Extensions {
                auth: Some(IpAuthHeader::new(TCP, 0, 0, &[]).unwrap()),
            };

            // auth referenced
            assert_eq!(TCP, exts.next_header(AUTH).unwrap());

            // auth not referenced (error)
            use crate::err::ipv4_exts::ExtsWalkError::ExtNotReferenced;
            assert_eq!(
                ExtNotReferenced {
                    missing_ext: IpNumber::AUTHENTICATION_HEADER
                },
                exts.next_header(TCP).unwrap_err()
            );
        }
    }

    #[test]
    fn is_empty() {
        // empty
        assert!(Ipv4Extensions { auth: None }.is_empty());

        // auth
        assert_eq!(
            false,
            Ipv4Extensions {
                auth: Some(IpAuthHeader::new(ip_number::UDP, 0, 0, &[]).unwrap()),
            }
            .is_empty()
        );
    }

    proptest! {
        #[test]
        fn debug(auth in ip_auth_any()) {
            use alloc::format;

            // None
            assert_eq!(
                &format!("Ipv4Extensions {{ auth: {:?} }}", Option::<IpAuthHeader>::None),
                &format!(
                    "{:?}",
                    Ipv4Extensions {
                        auth: None,
                    }
                )
            );

            // Some
            assert_eq!(
                &format!("Ipv4Extensions {{ auth: {:?} }}", Some(auth.clone())),
                &format!(
                    "{:?}",
                    Ipv4Extensions {
                        auth: Some(auth.clone()),
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
                let header = Ipv4Extensions{
                    auth: None,
                };
                assert_eq!(
                    header.clone(),
                    Ipv4Extensions{
                        auth: None,
                    }
                );
            }

            // Some
            {
                let header = Ipv4Extensions{
                    auth: Some(auth.clone()),
                };
                assert_eq!(
                    header.clone(),
                    Ipv4Extensions{
                        auth: Some(auth.clone()),
                    }
                );
            }
        }
    }
}
