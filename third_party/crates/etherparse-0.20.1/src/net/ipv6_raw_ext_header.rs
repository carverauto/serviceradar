use super::super::*;
use crate::err::ipv6_exts::ExtPayloadLenError;
use arrayvec::ArrayVec;
use core::fmt::{Debug, Formatter};

/// Deprecated. Use [Ipv6RawExtHeader] instead.
#[deprecated(
    since = "0.14.0",
    note = "Please use the type Ipv6RawExtHeader instead"
)]
pub type Ipv6RawExtensionHeader = Ipv6RawExtHeader;

/// Raw IPv6 extension header (undecoded payload).
///
/// IPv6 extension header with only minimal data interpretation. NOTE only ipv6 header
/// extensions with the first two bytes representing the next header and the header length
/// in 8-octets (- 8 octets) can be represented with this struct. This excludes the "Authentication
/// Header" (AH) and "Encapsulating Security Payload" (ESP).
///
/// The following headers can be represented in a [`Ipv6RawExtHeader`]:
/// * Hop by Hop
/// * Destination Options
/// * Routing
/// * Mobility
/// * Host Identity Protocol
/// * Shim6 Protocol
#[derive(Clone)]
pub struct Ipv6RawExtHeader {
    /// IP protocol number specifying the next header or transport layer protocol.
    ///
    /// See [IpNumber] or [ip_number] for a definition of the known values.
    pub next_header: IpNumber,
    /// Length of the extension header in 8 octets (minus the first 8 octets).
    header_length: u8,
    //// The data contained in the extension header (excluding next_header & hdr length).
    payload_buffer: [u8; 0xff * 8 + 6],
}

impl Debug for Ipv6RawExtHeader {
    fn fmt(&self, f: &mut Formatter) -> Result<(), core::fmt::Error> {
        let mut s = f.debug_struct("Ipv6RawExtHeader");
        s.field("next_header", &self.next_header);
        s.field("payload", &self.payload());
        s.finish()
    }
}

impl PartialEq for Ipv6RawExtHeader {
    fn eq(&self, other: &Self) -> bool {
        self.next_header == other.next_header && self.payload() == other.payload()
    }
}

impl Eq for Ipv6RawExtHeader {}

impl Default for Ipv6RawExtHeader {
    fn default() -> Self {
        Ipv6RawExtHeader {
            next_header: IpNumber(255),
            header_length: 0,
            payload_buffer: [0; 0xff * 8 + 6],
        }
    }
}

impl Ipv6RawExtHeader {
    /// Minimum length of an raw IPv6 extension header in bytes/octets.
    pub const MIN_LEN: usize = 8;

    /// Maximum length of an raw IPv6 extension header in bytes/octets.
    ///
    /// This number is calculated by multiplying the maximum "hdr ext len"
    /// (0xff) with 8 and adding 8. As RFC8200 states that "hdr ext len" is
    /// defined as "8-bit unsigned integer. Length of the Hop-by-Hop Options
    /// header in 8-octet units, not including the first 8 octets."
    pub const MAX_LEN: usize = 8 + (8 * 0xff);

    /// Minimum length of a [Ipv6RawExtHeader] payload
    pub const MIN_PAYLOAD_LEN: usize = 6;

    /// Maximum length of a [Ipv6RawExtHeader] the payload
    pub const MAX_PAYLOAD_LEN: usize = 0xff * 8 + 6;

    /// Returns true if the given header type ip number can be represented in an `Ipv6ExtensionHeader`.
    pub fn header_type_supported(next_header: IpNumber) -> bool {
        use crate::ip_number::*;
        matches!(
            next_header,
            IPV6_HOP_BY_HOP | IPV6_ROUTE | IPV6_DEST_OPTIONS | MOBILITY | HIP | SHIM6
        )
    }

    /// Creates an generic IPv6 extension header with the given data.
    ///
    /// # Arguments
    ///
    /// * `next_header` - type of content after this header (protocol number)
    /// * `payload` - slice containing the data of the header. This must NOT contain the `next header` and `extended header length` fields of the header.
    ///
    /// Note that `payload` must have at least the length of 6 bytes and only supports
    /// length increases in steps of 8. This measn that the following expression must be true `(payload.len() + 2) % 8 == 0`.
    /// The maximum length of the payload is `2046` bytes ([`Ipv6RawExtHeader::MAX_PAYLOAD_LEN`]).
    ///
    /// If a payload with a non supported length is provided a [`crate::err::ipv6_exts::ExtPayloadLenError`] is returned.
    pub fn new_raw(
        next_header: IpNumber,
        payload: &[u8],
    ) -> Result<Ipv6RawExtHeader, ExtPayloadLenError> {
        use ExtPayloadLenError::*;
        if payload.len() < Self::MIN_PAYLOAD_LEN {
            Err(TooSmall(payload.len()))
        } else if payload.len() > Self::MAX_PAYLOAD_LEN {
            Err(TooBig(payload.len()))
        } else if 0 != (payload.len() + 2) % 8 {
            Err(Unaligned(payload.len()))
        } else {
            let mut result = Ipv6RawExtHeader {
                next_header,
                header_length: ((payload.len() - 6) / 8) as u8,
                payload_buffer: [0; Self::MAX_PAYLOAD_LEN],
            };
            result.payload_buffer[..payload.len()].copy_from_slice(payload);
            Ok(result)
        }
    }

    /// Read an Ipv6ExtensionHeader from a slice and return the header & unused parts of the slice.
    pub fn from_slice(slice: &[u8]) -> Result<(Ipv6RawExtHeader, &[u8]), err::LenError> {
        let s = Ipv6RawExtHeaderSlice::from_slice(slice)?;
        let rest = &slice[s.slice().len()..];
        let header = s.to_header();
        Ok((header, rest))
    }

    /// Return a slice containing the current payload. This does NOT contain
    /// the `next_header` and `header_length` fields. But everything after these
    /// two fields.
    pub fn payload(&self) -> &[u8] {
        &self.payload_buffer[..(6 + usize::from(self.header_length) * 8)]
    }

    /// Sets the payload (content of the header after the `next_header` & `header_length` fields).
    ///
    /// Note that `payload` must have at least the length of 6 bytes and only supports
    /// length increases in steps of 8. This measn that the following expression must be true `(payload.len() + 2) % 8 == 0`.
    /// The maximum length of the payload is `2046` bytes ([`crate::Ipv6RawExtHeader::MAX_PAYLOAD_LEN`]).
    ///
    /// If a payload with a non supported length is provided a [`crate::err::ipv6_exts::ExtPayloadLenError`] is returned and the payload of the header is not changed.
    pub fn set_payload(&mut self, payload: &[u8]) -> Result<(), ExtPayloadLenError> {
        use ExtPayloadLenError::*;
        if payload.len() < Self::MIN_PAYLOAD_LEN {
            Err(TooSmall(payload.len()))
        } else if payload.len() > Self::MAX_PAYLOAD_LEN {
            Err(TooBig(payload.len()))
        } else if 0 != (payload.len() + 2) % 8 {
            Err(Unaligned(payload.len()))
        } else {
            self.payload_buffer[..payload.len()].copy_from_slice(payload);
            self.header_length = ((payload.len() - 6) / 8) as u8;
            Ok(())
        }
    }

    /// Read an fragment header from the current reader position.
    #[cfg(feature = "std")]
    #[cfg_attr(docsrs, doc(cfg(feature = "std")))]
    pub fn read<T: std::io::Read + std::io::Seek + Sized>(
        reader: &mut T,
    ) -> Result<Ipv6RawExtHeader, std::io::Error> {
        let (next_header, header_length) = {
            let mut d: [u8; 2] = [0; 2];
            reader.read_exact(&mut d)?;
            (IpNumber(d[0]), d[1])
        };

        Ok(Ipv6RawExtHeader {
            next_header,
            header_length,
            payload_buffer: {
                let mut buffer = [0; 0xff * 8 + 6];
                reader.read_exact(&mut buffer[..usize::from(header_length) * 8 + 6])?;
                buffer
            },
        })
    }

    /// Read an fragment header from the current limited reader position.
    #[cfg(feature = "std")]
    #[cfg_attr(docsrs, doc(cfg(feature = "std")))]
    pub fn read_limited<T: std::io::Read + std::io::Seek + Sized>(
        reader: &mut crate::io::LimitedReader<T>,
    ) -> Result<Ipv6RawExtHeader, err::io::LimitedReadError> {
        // set layer start
        reader.start_layer(err::Layer::Ipv6ExtHeader);

        // read next & len
        let (next_header, header_length) = {
            let mut d: [u8; 2] = [0; 2];
            reader.read_exact(&mut d)?;
            (IpNumber(d[0]), d[1])
        };

        Ok(Ipv6RawExtHeader {
            next_header,
            header_length,
            payload_buffer: {
                let mut buffer = [0; 0xff * 8 + 6];
                reader.read_exact(&mut buffer[..usize::from(header_length) * 8 + 6])?;
                buffer
            },
        })
    }

    /// Writes a given IPv6 extension header to the current position.
    #[cfg(feature = "std")]
    #[cfg_attr(docsrs, doc(cfg(feature = "std")))]
    pub fn write<W: std::io::Write + Sized>(&self, writer: &mut W) -> Result<(), std::io::Error> {
        writer.write_all(&[self.next_header.0, self.header_length])?;
        writer.write_all(self.payload())?;
        Ok(())
    }

    /// Returns the serialized header.
    pub fn to_bytes(&self) -> ArrayVec<u8, { Ipv6RawExtHeader::MAX_LEN }> {
        let mut result = ArrayVec::new();
        result.extend([self.next_header.0, self.header_length]);
        // Unwrap Panic Safety:
        // The following unwrap should never panic, as
        // the payload length can at most have the size max
        // header length - 2 and as the internal buffer used to
        // store the payload data has exactly this size.
        result.try_extend_from_slice(self.payload()).unwrap();
        result
    }

    /// Length of the header in bytes.
    pub fn header_len(&self) -> usize {
        2 + (6 + usize::from(self.header_length) * 8)
    }
}

#[cfg(test)]
mod test {
    use super::*;
    use crate::test_gens::*;
    use alloc::{format, vec::Vec};
    use proptest::prelude::*;
    use std::io::Cursor;

    #[test]
    fn default() {
        let default_header = Ipv6RawExtHeader {
            ..Default::default()
        };

        assert_eq!(default_header.next_header, IpNumber(255));
        assert_eq!(default_header.header_length, 0);
        assert_eq!(default_header.payload_buffer, [0; 0xff * 8 + 6])
    }

    proptest! {
        #[test]
        fn debug(header in ipv6_raw_ext_any()) {
            assert_eq!(
                format!("{:?}", header),
                format!(
                    "Ipv6RawExtHeader {{ next_header: {:?}, payload: {:?} }}",
                    header.next_header,
                    header.payload()
                )
            );
        }
    }

    proptest! {
        #[test]
        fn clone_eq(header in ipv6_raw_ext_any()) {
            assert_eq!(header.clone(), header);
        }
    }

    #[test]
    fn header_type_supported() {
        use ip_number::*;
        for value in 0..=u8::MAX {
            let expected_supported = match IpNumber(value) {
                IPV6_HOP_BY_HOP | IPV6_DEST_OPTIONS | IPV6_ROUTE | MOBILITY | HIP | SHIM6 => true,
                _ => false,
            };
            assert_eq!(
                expected_supported,
                Ipv6RawExtHeader::header_type_supported(IpNumber(value))
            );
        }
    }

    proptest! {
        #[test]
        fn new_raw(header in ipv6_raw_ext_any()) {
            use ExtPayloadLenError::*;

            // ok
            {
                let actual = Ipv6RawExtHeader::new_raw(header.next_header, header.payload()).unwrap();
                assert_eq!(actual.next_header, header.next_header);
                assert_eq!(actual.payload(), header.payload());
            }

            // smaller then minimum
            for len in 0..Ipv6RawExtHeader::MIN_PAYLOAD_LEN {
                assert_eq!(
                    Ipv6RawExtHeader::new_raw(header.next_header, &header.payload()[..len]).unwrap_err(),
                    TooSmall(len)
                );
            }

            // bigger then maximum
            {
                let bytes = [0u8;Ipv6RawExtHeader::MAX_PAYLOAD_LEN + 1];
                assert_eq!(
                    Ipv6RawExtHeader::new_raw(header.next_header, &bytes).unwrap_err(),
                    TooBig(bytes.len())
                );
            }

            // non aligned payload
            {
                let mut bytes = header.to_bytes();
                bytes.pop().unwrap();
                bytes.pop().unwrap();

                for offset in 1..8 {
                    if offset + header.header_len() < Ipv6RawExtHeader::MAX_LEN {
                        bytes.push(0);
                        assert_eq!(
                            Ipv6RawExtHeader::new_raw(header.next_header, &bytes).unwrap_err(),
                            Unaligned(bytes.len())
                        );
                    }
                }
            }
        }
    }

    proptest! {
        #[test]
        fn from_slice(header in ipv6_raw_ext_any()) {
            // ok
            {
                let mut bytes = Vec::with_capacity(header.header_len() + 2);
                bytes.extend_from_slice(&header.to_bytes());
                bytes.push(1);
                bytes.push(2);

                let (actual_header, actual_rest) = Ipv6RawExtHeader::from_slice(&bytes).unwrap();
                assert_eq!(actual_header, header);
                assert_eq!(actual_rest, &[1, 2]);
            }

            // length error
            {
                let bytes = header.to_bytes();
                for len in 0..bytes.len() {
                    assert_eq!(
                        Ipv6RawExtHeader::from_slice(&bytes[..len]).unwrap_err(),
                        err::LenError{
                            required_len: if len < Ipv6RawExtHeader::MIN_LEN {
                                Ipv6RawExtHeader::MIN_LEN
                            } else {
                                header.header_len()
                            },
                            len: len,
                            len_source: LenSource::Slice,
                            layer: err::Layer::Ipv6ExtHeader,
                            layer_start_offset: 0,
                        }
                    );
                }
            }
        }
    }

    proptest! {
        #[test]
        fn set_payload(
            header_a in ipv6_raw_ext_any(),
            header_b in ipv6_raw_ext_any()
        ) {
            use ExtPayloadLenError::*;
            // ok
            {
                let mut actual = header_a.clone();
                actual.set_payload(header_b.payload()).unwrap();
                assert_eq!(actual.payload(), header_b.payload());
            }

            // smaller then minimum
            for len in 0..Ipv6RawExtHeader::MIN_PAYLOAD_LEN {
                let mut actual = header_a.clone();
                assert_eq!(
                    actual.set_payload(&header_b.payload()[..len]).unwrap_err(),
                    TooSmall(len)
                );
                assert_eq!(actual.payload(), header_a.payload());
            }

            // bigger then maximum
            {
                let bytes = [0u8;Ipv6RawExtHeader::MAX_PAYLOAD_LEN + 1];
                let mut actual = header_a.clone();
                assert_eq!(
                    actual.set_payload(&bytes).unwrap_err(),
                    TooBig(bytes.len())
                );
            }

            // non aligned payload
            {
                let mut bytes = header_b.to_bytes();
                bytes.pop().unwrap();
                bytes.pop().unwrap();

                for offset in 1..8 {
                    if offset + header_b.header_len() < Ipv6RawExtHeader::MAX_LEN {
                        bytes.push(0);
                        let mut actual = header_a.clone();
                        assert_eq!(
                            actual.set_payload(&bytes).unwrap_err(),
                            Unaligned(bytes.len())
                        );
                    }
                }
            }
        }
    }

    proptest! {
        #[test]
        fn read(header in ipv6_raw_ext_any()) {
            // ok
            {
                let bytes = header.to_bytes();
                let mut cursor = Cursor::new(&bytes[..]);
                let actual = Ipv6RawExtHeader::read(&mut cursor).unwrap();
                assert_eq!(actual, header);
            }

            // length error
            {
                let bytes = header.to_bytes();
                for len in 0..bytes.len() {
                    let mut cursor = Cursor::new(&bytes[..len]);
                    assert!(Ipv6RawExtHeader::read(&mut cursor).is_err());
                }
            }
        }
    }

    proptest! {
        #[test]
        fn write(header in ipv6_raw_ext_any()) {
            // ok case
            {
                let mut buffer = [0u8;Ipv6RawExtHeader::MAX_LEN];
                let len = {
                    let mut cursor = Cursor::new(&mut buffer[..]);
                    header.write(&mut cursor).unwrap();
                    cursor.position() as usize
                };
                let (dec_header, dec_rest) = Ipv6RawExtHeader::from_slice(&buffer[..len]).unwrap();
                assert_eq!(header, dec_header);
                assert_eq!(dec_rest, &[]);
            }

            // length error
            for len in 0..header.header_len() {
                let mut buffer = [0u8;Ipv6RawExtHeader::MAX_LEN];
                let mut cursor = Cursor::new(&mut buffer[..len]);
                assert!(header.write(&mut cursor).is_err());
            }
        }
    }

    proptest! {
        #[test]
        fn to_bytes(header in ipv6_raw_ext_any()) {
            let bytes = header.to_bytes();
            assert_eq!(bytes[0], header.next_header.0);
            assert_eq!(bytes[1], header.header_length);
            assert_eq!(&bytes[2..], header.payload());
        }
    }

    proptest! {
        #[test]
        fn header_len(header in ipv6_raw_ext_any()) {
            assert_eq!(header.header_len(), header.to_bytes().len());
        }
    }
}
