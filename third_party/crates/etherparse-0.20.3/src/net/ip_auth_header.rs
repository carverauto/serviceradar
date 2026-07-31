use super::super::*;
use crate::err::ip_auth::IcvLenError;
use arrayvec::ArrayVec;
use core::fmt::{Debug, Formatter};

/// Deprecated use [IpAuthHeader] instead.
#[deprecated(since = "0.10.1", note = "Please use the type IpAuthHeader instead")]
pub type IPv6AuthenticationHeader = IpAuthHeader;

/// Deprecated use [IpAuthHeader] instead.
#[deprecated(since = "0.14.0", note = "Please use the type IpAuthHeader instead")]
pub type IpAuthenticationHeader = IpAuthHeader;

/// IP Authentication Header (rfc4302)
#[derive(Clone)]
pub struct IpAuthHeader {
    /// IP protocol number specifying the next header or transport layer protocol.
    ///
    /// See [IpNumber] or [ip_number] for a definition of the known values.
    pub next_header: IpNumber,
    /// Security Parameters Index
    pub spi: u32,
    /// This unsigned 32-bit field contains a counter value that
    /// increases by one for each packet sent.
    pub sequence_number: u32,
    /// Length in 4-octets (maximum valid value is 0xfe) of data filled in the
    /// `raw_icv_buffer`.
    raw_icv_len: u8,
    /// Buffer containing the "Encoded Integrity Check Value-ICV" (variable).
    /// The length of the used data can be set via the `variable` (must be a multiple of 4 bytes).
    raw_icv_buffer: [u8; 0xfe * 4],
}

impl Debug for IpAuthHeader {
    fn fmt(&self, formatter: &mut Formatter) -> Result<(), core::fmt::Error> {
        let mut s = formatter.debug_struct("IpAuthHeader");
        s.field("next_header", &self.next_header);
        s.field("spi", &self.spi);
        s.field("sequence_number", &self.sequence_number);
        s.field("raw_icv", &self.raw_icv());
        s.finish()
    }
}

impl PartialEq for IpAuthHeader {
    fn eq(&self, other: &Self) -> bool {
        self.next_header == other.next_header
            && self.spi == other.spi
            && self.sequence_number == other.sequence_number
            && self.raw_icv() == other.raw_icv()
    }
}

impl Eq for IpAuthHeader {}

impl Default for IpAuthHeader {
    fn default() -> Self {
        IpAuthHeader {
            next_header: IpNumber(255),
            spi: 0,
            sequence_number: 0,
            raw_icv_len: 0,
            raw_icv_buffer: [0; 0xfe * 4],
        }
    }
}

impl<'a> IpAuthHeader {
    /// Minimum length of an IP authentication header in bytes/octets.
    pub const MIN_LEN: usize = 4 + 4 + 4;

    /// Maximum length of an IP authentication header in bytes/octets.
    ///
    /// This number is calculated by taking the maximum value
    /// that the "payload length" field supports (0xff) adding 2 and
    /// multiplying the sum by 4 as the "payload length" specifies how
    /// many 4 bytes words are present in the header.
    pub const MAX_LEN: usize = 4 * (0xff + 2);

    /// The maximum amount of bytes/octets that can be stored in the ICV
    /// part of an IP authentication header.
    pub const MAX_ICV_LEN: usize = 0xfe * 4;

    /// Create a new authentication header with the given parameters.
    ///
    /// Note: The length of the raw_icv slice must be a multiple of 4
    /// and the maximum allowed length is 1016 bytes
    /// (`IpAuthHeader::MAX_ICV_LEN`). If the slice length does
    /// not fulfill these requirements the value is not copied and an
    /// [`crate::err::ip_auth::IcvLenError`] is returned.
    /// If successful an Ok(()) is returned.
    pub fn new(
        next_header: IpNumber,
        spi: u32,
        sequence_number: u32,
        raw_icv: &'a [u8],
    ) -> Result<IpAuthHeader, IcvLenError> {
        use IcvLenError::*;
        if raw_icv.len() > IpAuthHeader::MAX_ICV_LEN {
            Err(TooBig(raw_icv.len()))
        } else if 0 != raw_icv.len() % 4 {
            Err(Unaligned(raw_icv.len()))
        } else {
            let mut result = IpAuthHeader {
                next_header,
                spi,
                sequence_number,
                raw_icv_len: (raw_icv.len() / 4) as u8,
                raw_icv_buffer: [0; IpAuthHeader::MAX_ICV_LEN],
            };
            result.raw_icv_buffer[..raw_icv.len()].copy_from_slice(raw_icv);
            Ok(result)
        }
    }

    /// Read an  authentication header from a slice and return the header & unused parts of the slice.
    pub fn from_slice(
        slice: &'a [u8],
    ) -> Result<(IpAuthHeader, &'a [u8]), err::ip_auth::HeaderSliceError> {
        let s = IpAuthHeaderSlice::from_slice(slice)?;
        let rest = &slice[s.slice().len()..];
        let header = s.to_header();
        Ok((header, rest))
    }

    /// Read an authentication header from the current reader position.
    #[cfg(feature = "std")]
    #[cfg_attr(docsrs, doc(cfg(feature = "std")))]
    pub fn read<T: std::io::Read + Sized>(
        reader: &mut T,
    ) -> Result<IpAuthHeader, err::ip_auth::HeaderReadError> {
        use err::ip_auth::HeaderError::*;
        use err::ip_auth::HeaderReadError::*;

        let start = {
            let mut start = [0; 4 + 4 + 4];
            reader.read_exact(&mut start).map_err(Io)?;
            start
        };

        let next_header = IpNumber(start[0]);
        let payload_len = start[1];

        // payload len must be at least 1
        if payload_len < 1 {
            Err(Content(ZeroPayloadLen))
        } else {
            // read the rest of the header
            Ok(IpAuthHeader {
                next_header,
                spi: u32::from_be_bytes([start[4], start[5], start[6], start[7]]),
                sequence_number: u32::from_be_bytes([start[8], start[9], start[10], start[11]]),
                raw_icv_len: payload_len - 1,
                raw_icv_buffer: {
                    let mut buffer = [0; 0xfe * 4];
                    reader
                        .read_exact(&mut buffer[..usize::from(payload_len - 1) * 4])
                        .map_err(Io)?;
                    buffer
                },
            })
        }
    }

    /// Read an authentication header from the current reader position
    /// with a limited reader.
    #[cfg(feature = "std")]
    #[cfg_attr(docsrs, doc(cfg(feature = "std")))]
    pub fn read_limited<T: std::io::Read + Sized>(
        reader: &mut crate::io::LimitedReader<T>,
    ) -> Result<IpAuthHeader, err::ip_auth::HeaderLimitedReadError> {
        use err::{
            ip_auth::HeaderError::*,
            ip_auth::HeaderLimitedReadError::{self, *},
            Layer,
        };

        fn map_err(err: err::io::LimitedReadError) -> HeaderLimitedReadError {
            use err::io::LimitedReadError as I;
            match err {
                I::Io(err) => Io(err),
                I::Len(err) => Len(err),
            }
        }

        // notify reader of layer start
        reader.start_layer(Layer::IpAuthHeader);

        let start = {
            let mut start = [0; 4 + 4 + 4];
            reader.read_exact(&mut start).map_err(map_err)?;
            start
        };

        let next_header = IpNumber(start[0]);
        let payload_len = start[1];

        // payload len must be at least 1
        if payload_len < 1 {
            Err(Content(ZeroPayloadLen))
        } else {
            // read the rest of the header
            Ok(IpAuthHeader {
                next_header,
                spi: u32::from_be_bytes([start[4], start[5], start[6], start[7]]),
                sequence_number: u32::from_be_bytes([start[8], start[9], start[10], start[11]]),
                raw_icv_len: payload_len - 1,
                raw_icv_buffer: {
                    let mut buffer = [0; 0xfe * 4];
                    reader
                        .read_exact(&mut buffer[..usize::from(payload_len - 1) * 4])
                        .map_err(map_err)?;
                    buffer
                },
            })
        }
    }

    /// Returns a slice the raw icv value.
    pub fn raw_icv(&self) -> &[u8] {
        &self.raw_icv_buffer[..usize::from(self.raw_icv_len) * 4]
    }

    /// Sets the icv value to the given raw value. The length of the slice must be
    /// a multiple of 4 and the maximum allowed length is 1016 bytes
    /// (`IpAuthHeader::MAX_ICV_LEN`). If the slice length does
    /// not fulfill these requirements the value is not copied and an
    /// [`crate::err::ip_auth::IcvLenError`] is returned.
    /// If successful an Ok(()) is returned.
    pub fn set_raw_icv(&mut self, raw_icv: &[u8]) -> Result<(), IcvLenError> {
        use IcvLenError::*;
        if raw_icv.len() > IpAuthHeader::MAX_ICV_LEN {
            Err(TooBig(raw_icv.len()))
        } else if 0 != raw_icv.len() % 4 {
            Err(Unaligned(raw_icv.len()))
        } else {
            self.raw_icv_buffer[..raw_icv.len()].copy_from_slice(raw_icv);
            self.raw_icv_len = (raw_icv.len() / 4) as u8;
            Ok(())
        }
    }

    /// Writes the given authentication header to the current position.
    #[cfg(feature = "std")]
    #[cfg_attr(docsrs, doc(cfg(feature = "std")))]
    pub fn write<T: std::io::Write + Sized>(&self, writer: &mut T) -> Result<(), std::io::Error> {
        let spi_be = self.spi.to_be_bytes();
        let sequence_number_be = self.sequence_number.to_be_bytes();
        debug_assert!(self.raw_icv_len != 0xff);

        writer.write_all(&[
            self.next_header.0,
            self.raw_icv_len + 1,
            0,
            0,
            spi_be[0],
            spi_be[1],
            spi_be[2],
            spi_be[3],
            sequence_number_be[0],
            sequence_number_be[1],
            sequence_number_be[2],
            sequence_number_be[3],
        ])?;
        writer.write_all(self.raw_icv())?;
        Ok(())
    }

    ///Length of the header in bytes.
    pub fn header_len(&self) -> usize {
        12 + usize::from(self.raw_icv_len) * 4
    }

    /// Returns the serialized header.
    pub fn to_bytes(&self) -> ArrayVec<u8, { IpAuthHeader::MAX_LEN }> {
        let spi_be = self.spi.to_be_bytes();
        let seq_be = self.sequence_number.to_be_bytes();

        let mut result = ArrayVec::<u8, { IpAuthHeader::MAX_LEN }>::new();
        result.extend([
            self.next_header.0,
            self.raw_icv_len + 1,
            0,
            0,
            spi_be[0],
            spi_be[1],
            spi_be[2],
            spi_be[3],
            seq_be[0],
            seq_be[1],
            seq_be[2],
            seq_be[3],
        ]);
        result.extend(self.raw_icv_buffer);
        // SAFETY: Safe as the header len can not exceed the maximum length
        // of the header.
        unsafe {
            result.set_len(self.header_len());
        }

        result
    }
}

#[cfg(test)]
mod test {
    use super::*;
    use crate::{
        err::{Layer, LenError},
        io::LimitedReader,
        test_gens::*,
    };
    use alloc::{format, vec::Vec};
    use err::ip_auth::HeaderError::*;
    use proptest::prelude::*;
    use std::io::Cursor;

    #[test]
    fn default() {
        let default_header = IpAuthHeader {
            ..Default::default()
        };

        assert_eq!(default_header.next_header, IpNumber(255));
        assert_eq!(default_header.spi, 0);
        assert_eq!(default_header.sequence_number, 0);
        assert_eq!(default_header.raw_icv_len, 0);
        assert_eq!(default_header.raw_icv_buffer, [0; 0xfe * 4]);
    }

    proptest! {
        #[test]
        fn debug(input in ip_auth_any()) {
            assert_eq!(
                &format!(
                    "IpAuthHeader {{ next_header: {:?}, spi: {}, sequence_number: {}, raw_icv: {:?} }}",
                    input.next_header,
                    input.spi,
                    input.sequence_number,
                    input.raw_icv()),
                &format!("{:?}", input)
            );
        }
    }

    #[test]
    pub fn clone() {
        let a = IpAuthHeader::new(0.into(), 0, 0, &[0; 4]);
        assert_eq!(a.clone(), a);
    }

    #[test]
    pub fn partial_eq() {
        let a = IpAuthHeader::new(0.into(), 0, 0, &[0; 4]);

        //equal
        assert!(a == IpAuthHeader::new(0.into(), 0, 0, &[0; 4]));

        //not equal tests
        assert!(a != IpAuthHeader::new(1.into(), 0, 0, &[0; 4]));
        assert!(a != IpAuthHeader::new(0.into(), 1, 0, &[0; 4]));
        assert!(a != IpAuthHeader::new(0.into(), 0, 1, &[0; 4]));
        assert!(a != IpAuthHeader::new(0.into(), 0, 0, &[0, 1, 0, 0]));
        assert!(a != IpAuthHeader::new(0.into(), 0, 1, &[]));
        assert!(a != IpAuthHeader::new(0.into(), 0, 1, &[0; 8]));
    }

    #[test]
    fn new_and_set_icv() {
        use IcvLenError::*;

        struct Test {
            icv: &'static [u8],
            err: Option<IcvLenError>,
        }

        let tests = [
            // ok
            Test {
                icv: &[],
                err: None,
            },
            Test {
                icv: &[1, 2, 3, 4],
                err: None,
            },
            Test {
                icv: &[1, 2, 3, 4, 5, 6, 7, 8],
                err: None,
            },
            Test {
                icv: &[1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12],
                err: None,
            },
            Test {
                icv: &[0; 0xfe * 4],
                err: None,
            },
            // unaligned
            Test {
                icv: &[1],
                err: Some(Unaligned(1)),
            },
            Test {
                icv: &[1, 2, 3],
                err: Some(Unaligned(3)),
            },
            Test {
                icv: &[1, 2, 3, 4, 5],
                err: Some(Unaligned(5)),
            },
            Test {
                icv: &[1, 2, 3, 4, 5, 6, 7],
                err: Some(Unaligned(7)),
            },
            // too big
            Test {
                icv: &[0; 0xff * 4],
                err: Some(TooBig(0xff * 4)),
            },
        ];

        for test in tests.iter() {
            // new
            {
                let a = IpAuthHeader::new(5.into(), 6, 7, test.icv);
                if let Some(err) = &test.err {
                    assert_eq!(Err(err.clone()), a);
                } else {
                    let unwrapped = a.unwrap();
                    assert_eq!(IpNumber(5), unwrapped.next_header);
                    assert_eq!(6, unwrapped.spi);
                    assert_eq!(7, unwrapped.sequence_number);
                    assert_eq!(test.icv, unwrapped.raw_icv());
                }
            }
            // set_raw_icv
            {
                let mut header = IpAuthHeader::new(5.into(), 6, 7, &[0; 4]).unwrap();
                let result = header.set_raw_icv(test.icv);
                assert_eq!(IpNumber(5), header.next_header);
                assert_eq!(6, header.spi);
                assert_eq!(7, header.sequence_number);
                if let Some(err) = &test.err {
                    assert_eq!(Err(err.clone()), result);
                    assert_eq!(&[0; 4], header.raw_icv());
                } else {
                    assert_eq!(Ok(()), result);
                    assert_eq!(test.icv, header.raw_icv());
                }
            }
        }
    }

    proptest! {
        #[test]
        fn from_slice(header in ip_auth_any()) {
            use err::ip_auth::HeaderSliceError::*;

            // ok
            {
                let mut bytes = ArrayVec::<u8, {IpAuthHeader::MAX_LEN + 2}>::new();
                bytes.extend(header.to_bytes());
                bytes.push(1);
                bytes.push(2);

                let (actual_header, actual_slice) = IpAuthHeader::from_slice(&bytes).unwrap();
                assert_eq!(header, actual_header);
                assert_eq!(&[1,2], actual_slice);
            }

            // length error
            {
                let bytes = header.to_bytes();
                for len in 0..header.header_len() {
                    assert_eq!(
                        IpAuthHeader::from_slice(&bytes[..len]).unwrap_err(),
                        Len(err::LenError{
                            required_len: if len < IpAuthHeader::MIN_LEN {
                                IpAuthHeader::MIN_LEN
                            } else {
                                header.header_len()
                            },
                            len: len,
                            len_source: LenSource::Slice,
                            layer: err::Layer::IpAuthHeader,
                            layer_start_offset: 0,
                        })
                    );
                }
            }

            // payload length error
            {
                let mut bytes = header.to_bytes();
                // set payload length to 0
                bytes[1] = 0;
                assert_eq!(
                    IpAuthHeader::from_slice(&bytes).unwrap_err(),
                    Content(ZeroPayloadLen)
                );
            }
        }
    }

    proptest! {
        #[test]
        fn read(header in ip_auth_any()) {
            // ok
            {
                let bytes = header.to_bytes();
                let mut cursor = Cursor::new(&bytes);
                assert_eq!(header, IpAuthHeader::read(&mut cursor).unwrap());
            }

            // length error
            {
                let bytes = header.to_bytes();
                for len in 0..header.header_len() {
                    let mut cursor = Cursor::new(&bytes[..len]);
                    assert!(
                        IpAuthHeader::read(&mut cursor)
                            .unwrap_err()
                            .io()
                            .is_some()
                    );
                }
            }

            // payload length error
            {
                let mut bytes = header.to_bytes();
                // set payload length to 0
                bytes[1] = 0;
                let mut cursor = Cursor::new(&bytes);
                assert_eq!(
                    IpAuthHeader::read(&mut cursor).unwrap_err().content(),
                    Some(ZeroPayloadLen)
                );
            }
        }
    }

    proptest! {
        #[test]
        fn read_limited(header in ip_auth_any()) {
            // ok
            {
                let bytes = header.to_bytes();
                let mut cursor = Cursor::new(&bytes);
                let mut reader = LimitedReader::new(
                    &mut cursor,
                    bytes.len(),
                    LenSource::Slice,
                    0,
                    Layer::Ipv4Header
                );
                assert_eq!(header, IpAuthHeader::read_limited(&mut reader).unwrap());
            }

            // length error
            {
                let bytes = header.to_bytes();
                for len in 0..header.header_len() {
                    // io error
                    {
                        let mut cursor = Cursor::new(&bytes[..len]);
                        let mut reader = LimitedReader::new(
                            &mut cursor,
                            bytes.len(),
                            LenSource::Slice,
                            0,
                            Layer::Ipv4Header
                        );
                        assert!(
                            IpAuthHeader::read_limited(&mut reader)
                                .unwrap_err()
                                .io()
                                .is_some()
                        );
                    }
                    // limited reader error
                    {

                        let mut cursor = Cursor::new(&bytes);
                        let mut reader = LimitedReader::new(
                            &mut cursor,
                            len,
                            LenSource::Ipv4HeaderTotalLen,
                            0,
                            Layer::Ipv4Header
                        );
                        assert_eq!(
                            IpAuthHeader::read_limited(&mut reader)
                                .unwrap_err()
                                .len()
                                .unwrap(),
                            LenError {
                                required_len: if len < 12 {
                                    12
                                } else {
                                    bytes.len()
                                },
                                len,
                                len_source: LenSource::Ipv4HeaderTotalLen,
                                layer: Layer::IpAuthHeader,
                                layer_start_offset: 0
                            }
                        );
                    }
                }
            }

            // payload length error
            {
                let mut bytes = header.to_bytes();
                // set payload length to 0
                bytes[1] = 0;
                let mut cursor = Cursor::new(&bytes);
                let mut reader = LimitedReader::new(
                    &mut cursor,
                    bytes.len(),
                    LenSource::Ipv4HeaderTotalLen,
                    0,
                    Layer::Ipv4Header
                );
                assert_eq!(
                    IpAuthHeader::read_limited(&mut reader).unwrap_err().content(),
                    Some(ZeroPayloadLen)
                );
            }
        }
    }

    proptest! {
        #[test]
        fn write(header in ip_auth_any()) {

            // ok case
            {
                let mut buffer: Vec<u8> = Vec::with_capacity(header.header_len());
                header.write(&mut buffer).unwrap();
                assert_eq!(header, IpAuthHeader::from_slice(&buffer).unwrap().0);
            };

            // io error
            for len in 0..header.header_len() {
                let mut buffer = [0u8;IpAuthHeader::MAX_LEN];
                let mut cursor = Cursor::new(&mut buffer[..len]);
                assert!(header.write(&mut cursor).is_err());
            }
        }
    }

    proptest! {
        #[test]
        fn header_len(header in ip_auth_any()) {
            assert_eq!(header.header_len(), header.raw_icv().len() + 12);
        }
    }

    proptest! {
        #[test]
        fn to_bytes(header in ip_auth_any()) {
            let bytes = header.to_bytes();

            assert_eq!(header.next_header.0, bytes[0]);
            assert_eq!((header.header_len()/4 - 2) as u8, bytes[1]);
            assert_eq!(0, bytes[2]);
            assert_eq!(0, bytes[3]);
            {
                let spi = u32::from_be_bytes([bytes[4], bytes[5], bytes[6], bytes[7]]);
                assert_eq!(spi, header.spi);
            }
            {
                let seq_nr = u32::from_be_bytes([bytes[8], bytes[9], bytes[10], bytes[11]]);
                assert_eq!(seq_nr, header.sequence_number);
            }
            assert_eq!(&bytes[12..], header.raw_icv());
        }
    }
}
