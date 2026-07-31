use crate::{err::ValueTooBigError, *};

/// IPv6 header according to rfc8200.
#[derive(Clone, Debug, Eq, PartialEq, Hash, Default, PartialOrd, Ord)]
pub struct Ipv6Header {
    pub traffic_class: u8,
    /// If non 0 serves as a hint to router and switches with multiple outbound paths that these packets should stay on the same path, so that they will not be reordered.
    pub flow_label: Ipv6FlowLabel,
    ///The length of the payload and extension headers in bytes (0 in case of jumbo payloads).
    pub payload_length: u16,
    /// IP protocol number specifying the next header or transport layer protocol.
    ///
    /// See [IpNumber] or [ip_number] for a definitions of ids.
    pub next_header: IpNumber,
    /// The number of hops the packet can take before it is discarded.
    pub hop_limit: u8,
    /// IPv6 source address
    pub source: [u8; 16],
    /// IPv6 destination address
    pub destination: [u8; 16],
}

impl Ipv6Header {
    /// Serialized size of an IPv6 header in bytes/octets.
    pub const LEN: usize = 40;

    #[deprecated(since = "0.14.0", note = "Use `Ipv6Header::LEN` instead")]
    pub const SERIALIZED_SIZE: usize = Ipv6Header::LEN;

    /// Renamed to `Ipv6Header::from_slice`
    #[deprecated(since = "0.10.1", note = "Renamed to `Ipv6Header::from_slice`")]
    #[inline]
    pub fn read_from_slice(
        slice: &[u8],
    ) -> Result<(Ipv6Header, &[u8]), err::ipv6::HeaderSliceError> {
        Ipv6Header::from_slice(slice)
    }

    /// Read an Ipv6Header from a slice and return the header & unused parts of the slice.
    ///
    /// Note that this function DOES NOT separate the payload based on the length
    /// payload_length present in the IPv6 header. It just returns the left over slice
    /// after the header.
    ///
    /// If you want to have correctly separated payload including the IP extension
    /// headers use
    ///
    /// * [`crate::IpHeaders::from_ipv6_slice`] (decodes all the fields of the IP headers)
    /// * [`crate::Ipv6Slice::from_slice`] (just identifies the ranges in the slice where
    ///   the headers and payload are present)
    ///
    /// or
    ///
    /// * [`crate::IpHeaders::from_ipv6_slice_lax`]
    /// * [`crate::Ipv6Slice::from_slice_lax`]
    ///
    /// for a laxer version which falls back to slice length when the `payload_length`
    /// contains an inconsistent value.
    #[inline]
    pub fn from_slice(slice: &[u8]) -> Result<(Ipv6Header, &[u8]), err::ipv6::HeaderSliceError> {
        Ok((
            Ipv6HeaderSlice::from_slice(slice)?.to_header(),
            &slice[Ipv6Header::LEN..],
        ))
    }

    ///Reads an IPv6 header from the current position.
    #[cfg(feature = "std")]
    #[cfg_attr(docsrs, doc(cfg(feature = "std")))]
    pub fn read<T: std::io::Read + std::io::Seek + Sized>(
        reader: &mut T,
    ) -> Result<Ipv6Header, err::ipv6::HeaderReadError> {
        use err::ipv6::{HeaderError::*, HeaderReadError::*};

        let mut value: [u8; 1] = [0; 1];
        reader.read_exact(&mut value).map_err(Io)?;
        let version_number = value[0] >> 4;
        if 6 != version_number {
            return Err(Content(UnexpectedVersion { version_number }));
        }
        Ipv6Header::read_without_version(reader, value[0] & 0xf).map_err(Io)
    }

    ///Reads an IPv6 header assuming the version & flow_label field have already been read.
    #[cfg(feature = "std")]
    #[cfg_attr(docsrs, doc(cfg(feature = "std")))]
    pub fn read_without_version<T: std::io::Read + std::io::Seek + Sized>(
        reader: &mut T,
        version_rest: u8,
    ) -> Result<Ipv6Header, std::io::Error> {
        let mut buffer: [u8; 8 + 32 - 1] = [0; 8 + 32 - 1];
        reader.read_exact(&mut buffer[..])?;

        Ok(Ipv6Header {
            traffic_class: (version_rest << 4) | (buffer[0] >> 4),
            flow_label: unsafe {
                // SAFETY: Safe as the bitmask & 0 contant guarantee that the value
                // does not exceed 20 bytes.
                Ipv6FlowLabel::new_unchecked(u32::from_be_bytes([
                    0,
                    buffer[0] & 0b0000_1111,
                    buffer[1],
                    buffer[2],
                ]))
            },
            payload_length: u16::from_be_bytes([buffer[3], buffer[4]]),
            next_header: IpNumber(buffer[5]),
            hop_limit: buffer[6],
            #[rustfmt::skip]
            source: [
                buffer[7],   buffer[8],  buffer[9], buffer[10],
                buffer[11], buffer[12], buffer[13], buffer[14],
                buffer[15], buffer[16], buffer[17], buffer[18],
                buffer[19], buffer[20], buffer[21], buffer[22],
            ],
            #[rustfmt::skip]
            destination: [
                buffer[23], buffer[24], buffer[25], buffer[26],
                buffer[27], buffer[28], buffer[29], buffer[30],
                buffer[31], buffer[32], buffer[33], buffer[34],
                buffer[35], buffer[36], buffer[37], buffer[38],
            ],
        })
    }

    ///Takes a slice and skips an ipv6 header extensions and returns the next_header ip number & the slice past the header.
    pub fn skip_header_extension_in_slice(
        slice: &[u8],
        next_header: IpNumber,
    ) -> Result<(IpNumber, &[u8]), err::LenError> {
        use crate::ip_number::*;

        // verify that a ipv6 extension is present (before
        // validating the slice length)
        match next_header {
            IPV6_FRAG | AUTH | IPV6_HOP_BY_HOP | IPV6_ROUTE | IPV6_DEST_OPTIONS | MOBILITY
            | HIP | SHIM6 => {}
            _ => {
                return Ok((next_header, slice));
            }
        }

        if slice.len() >= 2 {
            //determine the length
            let len = match next_header {
                IPV6_FRAG => 8,
                AUTH => (usize::from(slice[1]) + 2) * 4,
                IPV6_HOP_BY_HOP | IPV6_ROUTE | IPV6_DEST_OPTIONS | MOBILITY | HIP | SHIM6 => {
                    (usize::from(slice[1]) + 1) * 8
                }
                // not a ipv6 header extension that can be skipped
                _ => unreachable!(),
            };

            if slice.len() < len {
                Err(err::LenError {
                    required_len: len,
                    len: slice.len(),
                    len_source: LenSource::Slice,
                    layer: err::Layer::Ipv6ExtHeader,
                    layer_start_offset: 0,
                })
            } else {
                Ok((IpNumber(slice[0]), &slice[len..]))
            }
        } else {
            Err(err::LenError {
                required_len: 2,
                len: slice.len(),
                len_source: LenSource::Slice,
                layer: err::Layer::Ipv6ExtHeader,
                layer_start_offset: 0,
            })
        }
    }

    /// Returns true if the given ip protocol number is a skippable header extension.
    ///
    /// A skippable header extension is an extension header for which it is known how
    /// to determine the protocol number of the following header as well as how many
    /// octets have to be skipped to reach the start of the following header.
    pub fn is_skippable_header_extension(ip_protocol_number: IpNumber) -> bool {
        use crate::ip_number::*;
        //Note: EncapsulatingSecurityPayload & ExperimentalAndTesting0 can not be skipped
        matches!(
            ip_protocol_number,
            IPV6_HOP_BY_HOP
                | IPV6_ROUTE
                | IPV6_FRAG
                | AUTH
                | IPV6_DEST_OPTIONS
                | MOBILITY
                | HIP
                | SHIM6
        )
    }

    ///Takes a slice & ip protocol number (identifying the first header type) and returns next_header id & the slice past after all ipv6 header extensions.
    pub fn skip_all_header_extensions_in_slice(
        slice: &[u8],
        next_header: IpNumber,
    ) -> Result<(IpNumber, &[u8]), err::LenError> {
        let mut next_header = next_header;
        let mut rest = slice;
        let mut offset = 0;

        loop {
            let (n_id, n_rest) = Ipv6Header::skip_header_extension_in_slice(rest, next_header)
                .map_err(|err| err.add_offset(offset))?;
            offset = slice.len() - n_rest.len();

            if n_rest.len() == rest.len() {
                return Ok((next_header, rest));
            } else {
                next_header = n_id;
                rest = n_rest;
            }
        }
    }

    ///Skips the ipv6 header extension and returns the next ip protocol number
    #[cfg(feature = "std")]
    #[cfg_attr(docsrs, doc(cfg(feature = "std")))]
    pub fn skip_header_extension<T: std::io::Read + std::io::Seek + Sized>(
        reader: &mut T,
        next_header: IpNumber,
    ) -> Result<IpNumber, std::io::Error> {
        use crate::ip_number::*;

        let (next_header, rest_length) = match next_header {
            IPV6_FRAG => {
                let mut buf = [0; 1];
                reader.read_exact(&mut buf)?;
                (IpNumber(buf[0]), 7)
            }
            AUTH => {
                let mut buf = [0; 2];
                reader.read_exact(&mut buf)?;
                (IpNumber(buf[0]), i64::from(buf[1]) * 4 + 6)
            }
            IPV6_HOP_BY_HOP | IPV6_ROUTE | IPV6_DEST_OPTIONS | MOBILITY | HIP | SHIM6 => {
                let mut buf = [0; 2];
                reader.read_exact(&mut buf)?;
                (IpNumber(buf[0]), i64::from(buf[1]) * 8 + 6)
            }
            // not a ipv6 header extension that can be skipped
            _ => return Ok(next_header),
        };

        //Sadly seek does not return an error if the seek could not be fulfilled.
        //Some implementations do not even truncate the returned position to the
        //last valid one. std::io::Cursor for example just moves the position
        //over the border of the given slice (e.g. returns position 15 even when
        //the given slice contains only 1 element).
        //The only option, to detect that we are in an invalid state, is to move the
        //seek offset to one byte before the end and then execute a normal read to
        //trigger an error.
        reader.seek(std::io::SeekFrom::Current(rest_length - 1))?;
        {
            let mut buf = [0; 1];
            reader.read_exact(&mut buf)?;
        }
        Ok(next_header)
    }

    ///Skips all ipv6 header extensions and returns the next ip protocol number
    #[cfg(feature = "std")]
    #[cfg_attr(docsrs, doc(cfg(feature = "std")))]
    pub fn skip_all_header_extensions<T: std::io::Read + std::io::Seek + Sized>(
        reader: &mut T,
        next_header: IpNumber,
    ) -> Result<IpNumber, std::io::Error> {
        let mut next_header = next_header;

        loop {
            if Ipv6Header::is_skippable_header_extension(next_header) {
                next_header = Ipv6Header::skip_header_extension(reader, next_header)?;
            } else {
                return Ok(next_header);
            }
        }
    }

    ///Writes a given IPv6 header to the current position.
    #[cfg(feature = "std")]
    #[cfg_attr(docsrs, doc(cfg(feature = "std")))]
    pub fn write<T: std::io::Write + Sized>(&self, writer: &mut T) -> Result<(), std::io::Error> {
        writer.write_all(&self.to_bytes())
    }

    /// Return the ipv6 source address as an core::net::Ipv6Addr
    #[inline]
    pub fn source_addr(&self) -> core::net::Ipv6Addr {
        core::net::Ipv6Addr::from(self.source)
    }

    /// Return the ipv6 destination address as an core::net::Ipv6Addr
    #[inline]
    pub fn destination_addr(&self) -> core::net::Ipv6Addr {
        core::net::Ipv6Addr::from(self.destination)
    }

    /// Length of the serialized header in bytes.
    ///
    /// The function always returns the constant Ipv6Header::LEN
    /// and exists to keep the methods consistent with other headers.
    #[inline]
    pub fn header_len(&self) -> usize {
        Ipv6Header::LEN
    }

    /// Sets the field total_length based on the size of the payload and the options. Returns an error if the payload is too big to fit.
    pub fn set_payload_length(&mut self, size: usize) -> Result<(), ValueTooBigError<usize>> {
        use crate::err::ValueType;
        // check that the total length fits into the field
        const MAX_PAYLOAD_LENGTH: usize = u16::MAX as usize;
        if MAX_PAYLOAD_LENGTH < size {
            return Err(ValueTooBigError {
                actual: size,
                max_allowed: MAX_PAYLOAD_LENGTH,
                value_type: ValueType::Ipv6PayloadLength,
            });
        }

        self.payload_length = size as u16;
        Ok(())
    }

    /// Sets the ECN field in the `traffic_class` octet.
    pub fn set_ecn(&mut self, ecn: IpEcn) {
        self.traffic_class = (self.traffic_class & 0b1111_1100) | (ecn.value() & 0b11);
    }

    /// Returns the [`IpEcn`] decoded from the `traffic_class` octet.
    pub fn ecn(&self) -> IpEcn {
        // SAFETY: Safe as value can only be at most 0b11 as it is bit-and-ed with 0b11.
        unsafe { IpEcn::new_unchecked(self.traffic_class & 0b0000_0011) }
    }

    /// Set the DSCP field in the `traffic_class` octet.
    pub fn set_dscp(&mut self, dscp: IpDscp) {
        self.traffic_class =
            (self.traffic_class & 0b0000_0011) | ((dscp.value() << 2) & 0b1111_1100);
    }

    /// Returns the [`IpDscp`] decoded from the `traffic_class` octet.
    pub fn dscp(&self) -> IpDscp {
        // SAFETY: Safe as value can not be bigger than IpDscp::MAX_U8 as it
        //         is bit masked with IpDscp::MAX_U8 (0b0011_1111).
        unsafe { IpDscp::new_unchecked((self.traffic_class >> 2) & 0b0011_1111) }
    }

    /// Returns the serialized form of the header as a statically
    /// sized byte array.
    #[rustfmt::skip]
    pub fn to_bytes(&self) -> [u8;Ipv6Header::LEN] {
        // serialize header
        let flow_label_be = self.flow_label.value().to_be_bytes();
        let payload_len_be = self.payload_length.to_be_bytes();

        [
            (6 << 4) | (self.traffic_class >> 4),
            (self.traffic_class << 4) | flow_label_be[1],
            flow_label_be[2],
            flow_label_be[3],
            payload_len_be[0],
            payload_len_be[1],
            self.next_header.0,
            self.hop_limit,
            self.source[0], self.source[1], self.source[2], self.source[3],
            self.source[4], self.source[5], self.source[6], self.source[7],
            self.source[8], self.source[9], self.source[10], self.source[11],
            self.source[12], self.source[13], self.source[14], self.source[15],
            self.destination[0], self.destination[1], self.destination[2], self.destination[3],
            self.destination[4], self.destination[5], self.destination[6], self.destination[7],
            self.destination[8], self.destination[9], self.destination[10], self.destination[11],
            self.destination[12], self.destination[13], self.destination[14], self.destination[15],
        ]
    }
}

#[cfg(test)]
mod test {
    use crate::{
        err::ipv6::HeaderError::*, err::ipv6::HeaderSliceError::*, ip_number::*, test_gens::*, *,
    };
    use alloc::format;
    use arrayvec::ArrayVec;
    use proptest::*;
    use std::io::Cursor;

    #[test]
    fn default() {
        let header: Ipv6Header = Default::default();
        assert_eq!(0, header.traffic_class);
        assert_eq!(0, header.flow_label.value());
        assert_eq!(0, header.payload_length);
        assert_eq!(255, header.next_header.0);
        assert_eq!(0, header.hop_limit);
        assert_eq!([0u8; 16], header.source);
        assert_eq!([0u8; 16], header.destination);
    }

    #[test]
    fn debug() {
        let header: Ipv6Header = Default::default();
        assert_eq!(
            format!("{:?}", header),
            format!(
                "Ipv6Header {{ traffic_class: {}, flow_label: {:?}, payload_length: {}, next_header: {:?}, hop_limit: {}, source: {:?}, destination: {:?} }}",
                header.traffic_class,
                header.flow_label,
                header.payload_length,
                header.next_header,
                header.hop_limit,
                header.source,
                header.destination
            )
        );
    }

    proptest! {
        #[test]
        fn clone_eq(header in ipv6_any()) {
            assert_eq!(header.clone(), header);
        }
    }

    proptest! {
        #[test]
        #[allow(deprecated)]
        fn read_from_slice(
            header in ipv6_any(),
            bad_version in 0..=0b1111u8
        ) {
            // ok read
            {
                let bytes = header.to_bytes();
                let (actual, rest) = Ipv6Header::read_from_slice(&bytes).unwrap();
                assert_eq!(header, actual);
                assert_eq!(rest, &[]);
            }

            // version error
            if bad_version != 6 {
                let mut bytes = header.to_bytes();
                // inject a bad version number
                bytes[0] = (0b1111 & bytes[0]) | (bad_version << 4);

                assert_eq!(
                    Ipv6Header::read_from_slice(&bytes).unwrap_err(),
                    Content(UnexpectedVersion{ version_number: bad_version })
                );
            }

            // length error
            {
                let bytes = header.to_bytes();
                for len in 0..bytes.len() {
                    assert_eq!(
                        Ipv6Header::read_from_slice(&bytes[..len])
                            .unwrap_err(),
                        Len(err::LenError{
                            required_len: Ipv6Header::LEN,
                            len: len,
                            len_source: LenSource::Slice,
                            layer: err::Layer::Ipv6Header,
                            layer_start_offset: 0,
                        })
                    );
                }
            }
        }
    }

    proptest! {
        #[test]
        fn set_dscp(
            header in ipv6_any(),
            dscp in ip_dscp_any()
        ) {
            let mut header = header;
            assert_eq!(header.dscp(), IpDscp::try_new(header.traffic_class >> 2).unwrap());
            header.set_dscp(dscp);
            assert_eq!(dscp, IpDscp::try_new(header.traffic_class >> 2).unwrap());
            assert_eq!(header.dscp(), dscp);
        }
    }

    proptest! {
        #[test]
        fn set_ecn(
            header in ipv6_any(),
            ecn in ip_ecn_any()
        ) {
            let mut header = header;
            assert_eq!(header.ecn(), IpEcn::try_new(header.traffic_class & 0b11).unwrap());
            header.set_ecn(ecn);
            assert_eq!(ecn, IpEcn::try_new(header.traffic_class & 0b11).unwrap());
            assert_eq!(header.ecn(), ecn);
        }
    }

    proptest! {
        #[test]
        fn from_slice(
            header in ipv6_any(),
            bad_version in 0..=0b1111u8
        ) {
            // ok read
            {
                let bytes = header.to_bytes();
                let (actual, rest) = Ipv6Header::from_slice(&bytes).unwrap();
                assert_eq!(header, actual);
                assert_eq!(rest, &[]);
            }

            // version error
            if bad_version != 6 {
                let mut bytes = header.to_bytes();
                // inject a bad version number
                bytes[0] = (0b1111 & bytes[0]) | (bad_version << 4);

                assert_eq!(
                    Ipv6Header::from_slice(&bytes).unwrap_err(),
                    Content(UnexpectedVersion{ version_number: bad_version })
                );
            }

            // length error
            {
                let bytes = header.to_bytes();
                for len in 0..bytes.len() {
                    assert_eq!(
                        Ipv6Header::from_slice(&bytes[..len])
                            .unwrap_err(),
                        Len(err::LenError{
                            required_len: Ipv6Header::LEN,
                            len: len,
                            len_source: LenSource::Slice,
                            layer: err::Layer::Ipv6Header,
                            layer_start_offset: 0,
                        })
                    );
                }
            }
        }
    }

    proptest! {
        #[test]
        fn read(
            header in ipv6_any(),
            bad_version in 0..=0b1111u8
        ) {
            use err::ipv6::HeaderError::*;

            // ok read
            {
                let bytes = header.to_bytes();
                let mut cursor = Cursor::new(&bytes[..]);
                let actual = Ipv6Header::read(&mut cursor).unwrap();
                assert_eq!(header, actual);
                assert_eq!(cursor.position(), bytes.len() as u64);
            }

            // version error
            if bad_version != 6 {
                let mut bytes = header.to_bytes();
                // inject a bad version number
                bytes[0] = (0b1111 & bytes[0]) | (bad_version << 4);

                let mut cursor = Cursor::new(&bytes[..]);
                assert_eq!(
                    Ipv6Header::read(&mut cursor)
                        .unwrap_err()
                        .content_error()
                        .unwrap(),
                    UnexpectedVersion {
                        version_number: bad_version,
                    }
                );
            }

            // io error
            {
                let bytes = header.to_bytes();
                for len in 0..bytes.len() {
                    let mut cursor = Cursor::new(&bytes[..len]);
                    assert!(Ipv6Header::read(&mut cursor).is_err());
                }
            }
        }
    }

    proptest! {
        #[test]
        fn read_without_version(header in ipv6_any()) {
            // ok read
            {
                let bytes = header.to_bytes();
                let mut cursor = Cursor::new(&bytes[1..]);
                let actual = Ipv6Header::read_without_version(&mut cursor, bytes[0] & 0xf).unwrap();
                assert_eq!(header, actual);
                assert_eq!(cursor.position(), bytes.len() as u64 - 1);
            }

            // io error
            {
                let bytes = header.to_bytes();
                for len in 1..bytes.len() {
                    let mut cursor = Cursor::new(&bytes[1..len]);
                    assert!(Ipv6Header::read_without_version(&mut cursor, bytes[0] & 0xf).is_err());
                }
            }
        }
    }

    proptest! {
        #[test]
        fn skip_header_extension_in_slice(
            generic in ipv6_raw_ext_any(),
            frag in ipv6_fragment_any(),
            auth in ip_auth_any()
        ) {
            const GENERICS: [IpNumber;7] = [
                IPV6_HOP_BY_HOP,
                IPV6_DEST_OPTIONS,
                IPV6_ROUTE,
                IPV6_DEST_OPTIONS,
                MOBILITY,
                HIP,
                SHIM6,
            ];

            // generic headers
            for g in GENERICS {
                let bytes = generic.to_bytes();
                // ok case
                {
                    let (next, rest) = Ipv6Header::skip_header_extension_in_slice(&bytes, g).unwrap();
                    assert_eq!(next, generic.next_header);
                    assert_eq!(rest, &[]);
                }
                // length error
                for len in 0..bytes.len() {
                    assert_eq!(
                        Ipv6Header::skip_header_extension_in_slice(&bytes[..len], g).unwrap_err(),
                        err::LenError {
                            required_len: if len < 2 {
                                2
                            } else {
                                bytes.len()
                            },
                            len: len,
                            len_source: LenSource::Slice,
                            layer: err::Layer::Ipv6ExtHeader,
                            layer_start_offset: 0,
                        }
                    );
                }
            }
            // frag header
            {
                let bytes = frag.to_bytes();
                // ok case
                {
                    let (next, rest) = Ipv6Header::skip_header_extension_in_slice(&bytes, IPV6_FRAG).unwrap();
                    assert_eq!(next, frag.next_header);
                    assert_eq!(rest, &[]);
                }
                // length error
                for len in 0..bytes.len() {
                    assert_eq!(
                        Ipv6Header::skip_header_extension_in_slice(&bytes[..len], IPV6_FRAG).unwrap_err(),
                        err::LenError {
                            required_len: if len < 2 {
                                2
                            } else {
                                bytes.len()
                            },
                            len: len,
                            len_source: LenSource::Slice,
                            layer: err::Layer::Ipv6ExtHeader,
                            layer_start_offset: 0,
                        }
                    );
                }
            }

            // auth header
            {
                let bytes = auth.to_bytes();
                // ok case
                {
                    let (next, rest) = Ipv6Header::skip_header_extension_in_slice(&bytes, AUTH).unwrap();
                    assert_eq!(next, auth.next_header);
                    assert_eq!(rest, &[]);
                }
                // length error
                for len in 0..bytes.len() {
                    assert_eq!(
                        Ipv6Header::skip_header_extension_in_slice(&bytes[..len], AUTH).unwrap_err(),
                        err::LenError {
                            required_len: if len < 2 {
                                2
                            } else {
                                bytes.len()
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

    #[test]
    fn is_skippable_header_extension() {
        for i in 0..0xffu8 {
            let expected = match IpNumber(i) {
                IPV6_HOP_BY_HOP | IPV6_ROUTE | IPV6_FRAG | AUTH | IPV6_DEST_OPTIONS | MOBILITY
                | HIP | SHIM6 => true,
                _ => false,
            };
            assert_eq!(
                expected,
                Ipv6Header::is_skippable_header_extension(IpNumber(i))
            );
        }
    }

    proptest! {
        #[test]
        fn skip_all_header_extensions_in_slice(
            hop_by_hop in ipv6_raw_ext_any(),
            dst_opt1 in ipv6_raw_ext_any(),
            route in ipv6_raw_ext_any(),
            frag in ipv6_fragment_any(),
            auth in ip_auth_any(),
            dst_opt2 in ipv6_raw_ext_any(),
            mobility in ipv6_raw_ext_any(),
            hip in ipv6_raw_ext_any(),
            shim6 in ipv6_raw_ext_any()
        ) {
            // no extension header
            {
                let (next, rest) = Ipv6Header::skip_all_header_extensions_in_slice(&[], UDP).unwrap();
                assert_eq!(UDP, next);
                assert_eq!(rest, &[]);
            }

            // setup a buffer with all extension headers present
            let buffer = {
                let mut buffer = ArrayVec::<u8, {
                    Ipv6RawExtHeader::MAX_LEN * 8 + IpAuthHeader::MAX_LEN
                }>::new();

                // based on RFC 8200 4.1. Extension Header Order
                // & IANA https://www.iana.org/assignments/ipv6-parameters/ipv6-parameters.xhtml
                //
                // IPV6_HOP_BY_HOP,
                // IPV6_DEST_OPTIONS,
                // IPV6_ROUTE,
                // IPV6_FRAG,
                // AUTH,
                // IPV6_DEST_OPTIONS,
                // MOBILITY,
                // HIP,
                // SHIM6,

                let mut hop_by_hop = hop_by_hop.clone();
                hop_by_hop.next_header = IPV6_DEST_OPTIONS;
                buffer.extend(hop_by_hop.to_bytes());

                let mut dst_opt1 = dst_opt1.clone();
                dst_opt1.next_header = IPV6_ROUTE;
                buffer.extend(dst_opt1.to_bytes());

                let mut route = route.clone();
                route.next_header = IPV6_FRAG;
                buffer.extend(route.to_bytes());

                let mut frag = frag.clone();
                frag.next_header = AUTH;
                buffer.extend(frag.to_bytes());

                let mut auth = auth.clone();
                auth.next_header = IPV6_DEST_OPTIONS;
                buffer.extend(auth.to_bytes());

                let mut dst_opt2 = dst_opt2.clone();
                dst_opt2.next_header = MOBILITY;
                buffer.extend(dst_opt2.to_bytes());

                let mut mobility = mobility.clone();
                mobility.next_header = HIP;
                buffer.extend(mobility.to_bytes());

                let mut hip = hip.clone();
                hip.next_header = SHIM6;
                buffer.extend(hip.to_bytes());

                let mut shim6 = shim6.clone();
                shim6.next_header = TCP;
                buffer.extend(shim6.to_bytes());

                buffer
            };

            // ok skip case with all extension headers
            {
                let (next, rest) = Ipv6Header::skip_all_header_extensions_in_slice(&buffer, IPV6_HOP_BY_HOP).unwrap();
                assert_eq!(next, TCP);
                assert_eq!(rest, &[]);
            }

            // length error
            {
                let len_ranges: [usize;9] = [
                    hop_by_hop.header_len(),
                    dst_opt1.header_len(),
                    route.header_len(),
                    frag.header_len(),
                    auth.header_len(),
                    dst_opt2.header_len(),
                    mobility.header_len(),
                    hip.header_len(),
                    shim6.header_len()
                ];
                let get_expected = |len: usize| -> usize{
                    let mut curr = 0;
                    for next in &len_ranges {
                        if len < curr {
                            break;
                        }
                        if len < curr + 2 {
                            curr += 2;
                            break;
                        }
                        curr += next;
                    }
                    curr
                };

                let get_offset = |len: usize| -> usize{
                    let mut curr = 0;
                    for next in &len_ranges {
                        if len < curr + next {
                            break;
                        }
                        curr += next;
                    }
                    curr
                };

                for len in 0..buffer.len() {
                    assert_eq!(
                        Ipv6Header::skip_all_header_extensions_in_slice(&buffer[..len], IPV6_HOP_BY_HOP)
                            .unwrap_err(),
                        err::LenError {
                            required_len: get_expected(len) - get_offset(len),
                            len: len - get_offset(len),
                            len_source: LenSource::Slice,
                            layer: err::Layer::Ipv6ExtHeader,
                            layer_start_offset: get_offset(len),
                        }
                    );
                }
            }
        }
    }

    #[test]
    fn skip_header_extension() {
        use crate::ip_number::*;
        {
            let buffer: [u8; 8] = [0; 8];
            let mut cursor = Cursor::new(&buffer);
            assert_eq!(
                Ipv6Header::skip_header_extension(&mut cursor, ICMP).unwrap(),
                ICMP
            );
            assert_eq!(0, cursor.position());
        }
        {
            let buffer: [u8; 8] = [0; 8];
            let mut cursor = Cursor::new(&buffer);
            assert_eq!(
                Ipv6Header::skip_header_extension(&mut cursor, IPV6_HOP_BY_HOP).unwrap(),
                IpNumber(0)
            );
            assert_eq!(8, cursor.position());
        }
        {
            #[rustfmt::skip]
            let buffer: [u8; 8 * 3] = [
                4, 2, 0, 0, 0, 0, 0, 0,
                0, 0, 0, 0, 0, 0, 0, 0,
                0, 0, 0, 0, 0, 0, 0, 0,
            ];
            let mut cursor = Cursor::new(&buffer);
            assert_eq!(
                Ipv6Header::skip_header_extension(&mut cursor, IPV6_ROUTE).unwrap(),
                IpNumber(4)
            );
            assert_eq!(8 * 3, cursor.position());
        }
        {
            //fragmentation header has a fixed size -> the 2 should be ignored
            #[rustfmt::skip]
            let buffer: [u8; 8 * 3] = [
                4, 2, 0, 0, 0, 0, 0, 0,
                0, 0, 0, 0, 0, 0, 0, 0,
                0, 0, 0, 0, 0, 0, 0, 0,
            ];
            let mut cursor = Cursor::new(&buffer);
            assert_eq!(
                Ipv6Header::skip_header_extension(&mut cursor, IPV6_FRAG).unwrap(),
                IpNumber(4)
            );
            assert_eq!(8, cursor.position());
        }
    }

    proptest! {
        #[test]
        fn skip_all_header_extensions(
            hop_by_hop in ipv6_raw_ext_any(),
            dst_opt1 in ipv6_raw_ext_any(),
            route in ipv6_raw_ext_any(),
            frag in ipv6_fragment_any(),
            auth in ip_auth_any(),
            dst_opt2 in ipv6_raw_ext_any(),
            mobility in ipv6_raw_ext_any(),
            hip in ipv6_raw_ext_any(),
            shim6 in ipv6_raw_ext_any()
        ) {
            // no extension header
            {
                let mut cursor = Cursor::new(&[]);
                let next = Ipv6Header::skip_all_header_extensions(&mut cursor, UDP).unwrap();
                assert_eq!(UDP, next);
                assert_eq!(0, cursor.position());
            }

            // setup a buffer with all extension headers present
            let buffer = {
                let mut buffer = ArrayVec::<u8, {
                    Ipv6RawExtHeader::MAX_LEN * 8 + IpAuthHeader::MAX_LEN
                }>::new();

                // based on RFC 8200 4.1. Extension Header Order
                // & IANA https://www.iana.org/assignments/ipv6-parameters/ipv6-parameters.xhtml
                //
                // IPV6_HOP_BY_HOP,
                // IPV6_DEST_OPTIONS,
                // IPV6_ROUTE,
                // IPV6_FRAG,
                // AUTH,
                // IPV6_DEST_OPTIONS,
                // MOBILITY,
                // HIP,
                // SHIM6,

                let mut hop_by_hop = hop_by_hop.clone();
                hop_by_hop.next_header = IPV6_DEST_OPTIONS;
                buffer.extend(hop_by_hop.to_bytes());

                let mut dst_opt1 = dst_opt1.clone();
                dst_opt1.next_header = IPV6_ROUTE;
                buffer.extend(dst_opt1.to_bytes());

                let mut route = route.clone();
                route.next_header = IPV6_FRAG;
                buffer.extend(route.to_bytes());

                let mut frag = frag.clone();
                frag.next_header = AUTH;
                buffer.extend(frag.to_bytes());

                let mut auth = auth.clone();
                auth.next_header = IPV6_DEST_OPTIONS;
                buffer.extend(auth.to_bytes());

                let mut dst_opt2 = dst_opt2.clone();
                dst_opt2.next_header = MOBILITY;
                buffer.extend(dst_opt2.to_bytes());

                let mut mobility = mobility.clone();
                mobility.next_header = HIP;
                buffer.extend(mobility.to_bytes());

                let mut hip = hip.clone();
                hip.next_header = SHIM6;
                buffer.extend(hip.to_bytes());

                let mut shim6 = shim6.clone();
                shim6.next_header = TCP;
                buffer.extend(shim6.to_bytes());

                buffer
            };

            // ok skip case with all extension headers
            {
                let mut cursor = Cursor::new(&buffer);
                let last = Ipv6Header::skip_all_header_extensions(&mut cursor, IPV6_HOP_BY_HOP).unwrap();
                assert_eq!(last, TCP);
                assert_eq!(cursor.position(), buffer.len() as u64);
            }

            // length error
            for len in 0..buffer.len() {
                let mut cursor = Cursor::new(&buffer[..len]);
                assert!(
                    Ipv6Header::skip_all_header_extensions(&mut cursor, IPV6_HOP_BY_HOP)
                    .is_err()
                );
            }
        }
    }

    proptest! {
        #[test]
        fn write(header in ipv6_any()) {
            let mut buffer = [0u8;Ipv6Header::LEN];
            let len = {
                let mut cursor = Cursor::new(&mut buffer[..]);
                header.write(&mut cursor).unwrap();
                cursor.position() as usize
            };
            assert_eq!(len, header.header_len());
            assert_eq!(
                Ipv6Header::from_slice(&buffer[..len]).unwrap().0,
                header
            );
        }
    }

    proptest! {
        #[test]
        fn source_addr(header in ipv6_any()) {
            assert_eq!(
                header.source_addr().octets(),
                header.source
            );
        }
    }

    proptest! {
        #[test]
        fn destination_addr(header in ipv6_any()) {
            assert_eq!(
                header.destination_addr().octets(),
                header.destination
            );
        }
    }

    proptest! {
        #[test]
        fn to_bytes(header in ipv6_any()) {
            let bytes = header.to_bytes();
            assert_eq!(
                Ipv6Header::from_slice(&bytes).unwrap().0,
                header
            );
        }
    }
}
