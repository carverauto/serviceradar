use crate::{
    err::{ValueTooBigError, ValueType},
    *,
};
use arrayvec::ArrayVec;

/// IPv4 header with options.
///
/// # Example Usage:
///
/// ```
/// use etherparse::{Ipv4Header, IpNumber};
///
/// let mut header = Ipv4Header {
///     source: [1,2,3,4],
///     destination: [1,2,3,4],
///     time_to_live: 4,
///     total_len: Ipv4Header::MIN_LEN as u16 + 100,
///     protocol: IpNumber::UDP,
///     ..Default::default()
/// };
///
/// // depending on your use case you might want to set the correct checksum
/// header.header_checksum = header.calc_header_checksum();
///
/// // header can be serialized into the "on the wire" format
/// // using the "write" or "to_bytes" methods
/// let bytes = header.to_bytes();
///
/// // IPv4 headers can be decoded via "read" or "from_slice"
/// let (decoded, slice_rest) = Ipv4Header::from_slice(&bytes).unwrap();
/// assert_eq!(header, decoded);
/// assert_eq!(slice_rest, &[]);
/// ```
#[derive(Clone, Debug, Eq, PartialEq, Hash, PartialOrd, Ord)]
pub struct Ipv4Header {
    /// Differentiated Services Code Point
    pub dscp: IpDscp,
    /// Explicit Congestion Notification
    pub ecn: IpEcn,
    /// Total length of the IPv4 header (including extension headers) and the payload after it.
    pub total_len: u16,
    /// Number used to identify packets that contain an originally fragmented packet.
    pub identification: u16,
    /// If set the packet is not allowed to fragmented.
    pub dont_fragment: bool,
    /// Indicates that the packet contains part of an fragmented message and that
    /// additional data is needed to reconstruct the original packet.
    pub more_fragments: bool,
    /// In case this message contains parts of a fragmented packet the fragment
    /// offset is the offset of payload the current message relative to the
    /// original payload of the message.
    pub fragment_offset: IpFragOffset,
    /// Number of hops the packet is allowed to take before it should be discarded.
    pub time_to_live: u8,
    /// IP protocol number specifying the next header or transport layer protocol.
    ///
    /// See [IpNumber] or [ip_number] for a definitions of ids.
    pub protocol: IpNumber,
    pub header_checksum: u16,
    /// IPv4 source address
    pub source: [u8; 4],
    /// IPv4 destination address
    pub destination: [u8; 4],
    /// Options in the header (in raw).
    pub options: Ipv4Options,
}

impl Ipv4Header {
    /// Minimum length of an IPv4 header in bytes/octets.
    pub const MIN_LEN: usize = 20;

    /// Minimum length of an IPv4 header in bytes/octets as an `u16`.
    pub const MIN_LEN_U16: u16 = 20;

    /// Maximum length of an IPv4 header in bytes/octets.
    ///
    /// This number is calculated by taking the maximum value
    /// that the "internet header length" field supports (0xf,
    /// as the field is only 4 bits long) and multiplying it
    /// with 4 as the "internet header length" specifies how
    /// many 4 bytes words are present in the header.
    pub const MAX_LEN: usize = 0b1111 * 4;

    /// Deprecated use [`Ipv4Header::MIN_LEN`] instead.
    #[deprecated(since = "0.14.0", note = "Use `Ipv4Header::MIN_LEN` instead")]
    pub const SERIALIZED_SIZE: usize = Ipv4Header::MIN_LEN;

    /// Constructs an Ipv4Header with standard values for non specified values.
    ///
    /// This method is equivalent to partially initializing a struct with
    /// default values:
    ///
    /// ```
    /// use etherparse::{Ipv4Header, IpNumber};
    ///
    /// let mut header = Ipv4Header::new(100, 4, IpNumber::UDP, [1,2,3,4], [5,6,7,8]).unwrap();
    ///
    /// assert_eq!(
    ///     header,
    ///     Ipv4Header {
    ///         total_len: (100 + Ipv4Header::MIN_LEN) as u16,
    ///         time_to_live: 4,
    ///         protocol: IpNumber::UDP,
    ///         source: [1,2,3,4],
    ///         destination: [5,6,7,8],
    ///         ..Default::default()
    ///     }
    /// );
    ///
    /// // for the rest of the fields the following default values will be used:
    /// assert_eq!(0, header.dscp.value());
    /// assert_eq!(0, header.ecn.value());
    /// assert_eq!(0, header.identification);
    /// assert_eq!(true, header.dont_fragment);
    /// assert_eq!(false, header.more_fragments);
    /// assert_eq!(0, header.fragment_offset.value());
    /// assert_eq!(0, header.header_checksum);
    ///
    /// // in case you also want to have a correct checksum you will have to
    /// // additionally update it:
    /// header.header_checksum = header.calc_header_checksum();
    /// ```
    pub fn new(
        payload_len: u16,
        time_to_live: u8,
        protocol: IpNumber,
        source: [u8; 4],
        destination: [u8; 4],
    ) -> Result<Ipv4Header, ValueTooBigError<u16>> {
        const MAX_PAYLOAD: u16 = u16::MAX - (Ipv4Header::MIN_LEN as u16);
        if payload_len > MAX_PAYLOAD {
            Err(ValueTooBigError {
                actual: payload_len,
                max_allowed: MAX_PAYLOAD,
                value_type: ValueType::Ipv4PayloadLength,
            })
        } else {
            Ok(Ipv4Header {
                dscp: Default::default(),
                ecn: Default::default(),
                total_len: payload_len + (Ipv4Header::MIN_LEN as u16),
                identification: 0,
                dont_fragment: true,
                more_fragments: false,
                fragment_offset: Default::default(),
                time_to_live,
                protocol,
                header_checksum: 0,
                source,
                destination,
                options: Default::default(),
            })
        }
    }

    /// Length of the header in multiples of 4 bytes (often also called
    /// IHL - Internet Header length). This field is part of the serialized
    /// header and determines / is determined by the byte length of the options.
    ///
    /// The minimum allowed length of a header is 5 (= 20 bytes) and the
    /// maximum length is 15 (= 60 bytes).
    ///
    /// ```
    /// use etherparse::Ipv4Header;
    /// {
    ///     let header = Ipv4Header {
    ///         options: [].into(),
    ///         ..Default::default()
    ///     };
    ///     // minimum IHL is 5
    ///     assert_eq!(5, header.ihl());
    /// }
    /// {
    ///     let header = Ipv4Header {
    ///         options: [1,2,3,4].into(),
    ///         ..Default::default()
    ///     };
    ///     // IHL is increased by 1 for every 4 bytes of options
    ///     assert_eq!(6, header.ihl());
    /// }
    /// {
    ///     let header = Ipv4Header {
    ///         options: [0;40].into(),
    ///         ..Default::default()
    ///     };
    ///     // maximum ihl
    ///     assert_eq!(15, header.ihl());
    /// }
    /// ```
    #[inline]
    pub fn ihl(&self) -> u8 {
        (self.options.len_u8() / 4) + 5
    }

    /// Length of the header (includes options) in bytes.
    ///
    /// The minimum allowed length of a header is 5 (= 20 bytes) and the
    /// maximum length is 15 (= 60 bytes).
    ///
    /// ```
    /// use etherparse::Ipv4Header;
    /// {
    ///     let header = Ipv4Header {
    ///         options: [].into(),
    ///         ..Default::default()
    ///     };
    ///     // minimum IHL is 5
    ///     assert_eq!(5, header.ihl());
    /// }
    /// {
    ///     let header = Ipv4Header {
    ///         options: [1,2,3,4].into(),
    ///         ..Default::default()
    ///     };
    ///     // IHL is increased by 1 for every 4 bytes of options
    ///     assert_eq!(6, header.ihl());
    /// }
    /// {
    ///     let header = Ipv4Header {
    ///         options: [0;40].into(),
    ///         ..Default::default()
    ///     };
    ///     // maximum ihl
    ///     assert_eq!(15, header.ihl());
    /// }
    /// ```
    #[inline]
    pub fn header_len(&self) -> usize {
        Ipv4Header::MIN_LEN + self.options.len()
    }

    /// Determine the payload length based on the ihl & total_length
    /// field of the header.
    ///
    /// # Example Usage
    ///
    /// ```
    /// use etherparse::{Ipv4Header, Ipv4HeaderSlice};
    ///
    /// let header = Ipv4Header{
    ///     // the payload len will be calculated by subtracting the
    ///     // header length from the total length
    ///     total_len: Ipv4Header::MIN_LEN as u16 + 100,
    ///     ..Default::default()
    /// };
    ///
    /// assert_eq!(Ok(100), header.payload_len());
    ///
    /// // error case
    /// let bad_header = Ipv4Header {
    ///     // total len should also include the header, in case it does
    ///     // not it is not possible to calculate the payload length
    ///     total_len: Ipv4Header::MIN_LEN as u16 - 1,
    ///     ..Default::default()
    /// };
    ///
    /// // in case the total_len is smaller then the header itself an
    /// // error is returned
    /// use etherparse::{LenSource, err::{LenError, Layer}};
    /// assert_eq!(
    ///     bad_header.payload_len(),
    ///     Err(LenError {
    ///         required_len: Ipv4Header::MIN_LEN,
    ///         len: Ipv4Header::MIN_LEN - 1,
    ///         len_source: LenSource::Ipv4HeaderTotalLen,
    ///         layer: Layer::Ipv4Packet,
    ///         layer_start_offset: 0,
    ///     })
    /// );
    /// ```
    #[inline]
    pub fn payload_len(&self) -> Result<u16, err::LenError> {
        // SAFETY: header_len() can be at most be 60 so a cast to u16 is safe.
        let header_len = self.header_len() as u16;
        if header_len <= self.total_len {
            Ok(self.total_len - header_len)
        } else {
            use err::{Layer, LenError};
            Err(LenError {
                required_len: header_len.into(),
                len: self.total_len.into(),
                len_source: LenSource::Ipv4HeaderTotalLen,
                layer: Layer::Ipv4Packet,
                layer_start_offset: 0,
            })
        }
    }

    /// Tries setting the [`Ipv4Header::total_len`] field given the length of
    /// the payload after the header & the current options length of the header.
    ///
    /// If the value is not too big. Otherwise an error is returned.
    ///
    /// Note that the set payload length is no longer valid if you change
    /// [`Ipv4Header::options`] length after calling [`Ipv4Header::set_payload_len`]
    /// as it uses  the length of options to calculate the `total_len` value.
    ///
    /// # Example Usage:
    ///
    /// ```
    /// use etherparse::Ipv4Header;
    ///
    /// let mut header = Ipv4Header{
    ///     total_len: 100, // will be reset by set_payload
    ///     options: [1,2,3,4].into(),
    ///     ..Default::default()
    /// };
    ///
    /// // set_payload_len set the total_len field based on the header_len
    /// // and given payload length
    /// header.set_payload_len(100).unwrap();
    /// assert_eq!(100 + header.header_len() as u16, header.total_len);
    ///
    /// // in case the payload is len is bigger then can represented in the
    /// // total_len field an error is returned
    /// use etherparse::err::{ValueTooBigError, ValueType};
    /// let err = header.set_payload_len(usize::from(u16::MAX) - header.header_len() + 1);
    /// assert_eq!(
    ///     err,
    ///     Err(ValueTooBigError {
    ///         actual: usize::from(u16::MAX) - header.header_len() + 1,
    ///         max_allowed: usize::from(u16::MAX) - header.header_len(),
    ///         value_type: ValueType::Ipv4PayloadLength
    ///     })
    /// );
    /// ```
    pub fn set_payload_len(&mut self, value: usize) -> Result<(), ValueTooBigError<usize>> {
        let max_allowed = usize::from(self.max_payload_len());
        if value > max_allowed {
            Err(ValueTooBigError {
                actual: value,
                max_allowed,
                value_type: ValueType::Ipv4PayloadLength,
            })
        } else {
            self.total_len = (self.header_len() + value) as u16;
            Ok(())
        }
    }

    /// Returns the maximum payload size based on the current options size.
    #[inline]
    pub fn max_payload_len(&self) -> u16 {
        u16::MAX - u16::from(self.options.len_u8()) - (Ipv4Header::MIN_LEN as u16)
    }

    /// Returns a slice to the options part of the header (empty if no options are present).
    #[deprecated(
        since = "0.14.0",
        note = "Directly use `&(header.options[..])` instead."
    )]
    pub fn options(&self) -> &[u8] {
        &self.options[..]
    }

    /// Sets the options & header_length based on the provided length.
    /// The length of the given slice must be a multiple of 4 and maximum 40 bytes.
    /// If the length is not fulfilling these constraints, no data is set and
    /// an error is returned.
    #[deprecated(
        since = "0.14.0",
        note = "Directly set it via the header.options field instead."
    )]
    pub fn set_options(&mut self, data: &[u8]) -> Result<(), err::ipv4::BadOptionsLen> {
        self.options = data.try_into()?;
        Ok(())
    }

    /// Renamed to `Ipv4Header::from_slice`
    #[deprecated(since = "0.10.1", note = "Renamed to `Ipv4Header::from_slice`")]
    #[inline]
    pub fn read_from_slice(
        slice: &[u8],
    ) -> Result<(Ipv4Header, &[u8]), err::ipv4::HeaderSliceError> {
        Ipv4Header::from_slice(slice)
    }

    /// Read an Ipv4Header from a slice and return the header & unused parts
    /// of the slice.
    ///
    /// Note that this function DOES NOT separate the payload based on the
    /// `total_length` field present in the IPv4 header. It just returns the
    /// left over slice after the header.
    ///
    /// If you want to have correctly separated payload including the IP extension
    /// headers use
    ///
    /// * [`IpHeaders::from_ipv4_slice`] (decodes all the fields of the IP headers)
    /// * [`Ipv4Slice::from_slice`] (just identifies the ranges in the slice where
    ///   the headers and payload are present)
    ///
    /// or
    ///
    /// * [`IpHeaders::from_ipv4_slice_lax`]
    /// * [`LaxIpv4Slice::from_slice`]
    ///
    /// for a laxer version which falls back to slice length when the `total_length`
    /// contains an inconsistent value.
    pub fn from_slice(slice: &[u8]) -> Result<(Ipv4Header, &[u8]), err::ipv4::HeaderSliceError> {
        let header = Ipv4HeaderSlice::from_slice(slice)?.to_header();
        let rest = &slice[header.header_len()..];
        Ok((header, rest))
    }

    /// Reads an IPv4 header from the current position (requires
    /// crate feature `std`).
    #[cfg(feature = "std")]
    #[cfg_attr(docsrs, doc(cfg(feature = "std")))]
    pub fn read<T: std::io::Read + std::io::Seek + Sized>(
        reader: &mut T,
    ) -> Result<Ipv4Header, err::ipv4::HeaderReadError> {
        use err::ipv4::HeaderReadError::*;

        let mut first_byte: [u8; 1] = [0; 1];
        reader.read_exact(&mut first_byte).map_err(Io)?;

        let version_number = first_byte[0] >> 4;
        if 4 != version_number {
            use err::ipv4::HeaderError::UnexpectedVersion;
            return Err(Content(UnexpectedVersion { version_number }));
        }
        Ipv4Header::read_without_version(reader, first_byte[0])
    }

    /// Reads an IPv4 header assuming the version & ihl field have already
    /// been read (requires crate feature `std`).
    #[cfg(feature = "std")]
    #[cfg_attr(docsrs, doc(cfg(feature = "std")))]
    pub fn read_without_version<T: std::io::Read + std::io::Seek + Sized>(
        reader: &mut T,
        first_byte: u8,
    ) -> Result<Ipv4Header, err::ipv4::HeaderReadError> {
        use err::ipv4::HeaderError::*;
        use err::ipv4::HeaderReadError::*;

        // read the basic ipv4 header (the header options can be
        // read only after the internet header length was read)
        let mut header_raw = [0u8; 20];
        header_raw[0] = first_byte;
        reader.read_exact(&mut header_raw[1..]).map_err(Io)?;

        let ihl = header_raw[0] & 0xf;

        // validate that the internet header length is big enough to
        // contain a basic IPv4 header without options.
        if ihl < 5 {
            return Err(Content(HeaderLengthSmallerThanHeader { ihl }));
        }

        let (dscp, ecn) = {
            let value = header_raw[1];
            (value >> 2, value & 0b0000_0011)
        };
        let total_len = u16::from_be_bytes([header_raw[2], header_raw[3]]);
        let identification = u16::from_be_bytes([header_raw[4], header_raw[5]]);
        let (dont_fragment, more_fragments, fragments_offset) = (
            0 != (header_raw[6] & 0b0100_0000),
            0 != (header_raw[6] & 0b0010_0000),
            u16::from_be_bytes([header_raw[6] & 0b0001_1111, header_raw[7]]),
        );
        Ok(Ipv4Header {
            dscp: unsafe {
                // Safe as only 6 bits were used to decode the
                // dscp value
                IpDscp::new_unchecked(dscp)
            },
            ecn: unsafe {
                // Safe as only 2 bits were used to decode the
                // ecn value
                IpEcn::new_unchecked(ecn)
            },
            total_len,
            identification,
            dont_fragment,
            more_fragments,
            fragment_offset: unsafe {
                // Safe as only 13 bits were used to decode the
                // fragment offset
                IpFragOffset::new_unchecked(fragments_offset)
            },
            time_to_live: header_raw[8],
            protocol: IpNumber(header_raw[9]),
            header_checksum: u16::from_be_bytes([header_raw[10], header_raw[11]]),
            source: [
                header_raw[12],
                header_raw[13],
                header_raw[14],
                header_raw[15],
            ],
            destination: [
                header_raw[16],
                header_raw[17],
                header_raw[18],
                header_raw[19],
            ],
            options: {
                let mut options = Ipv4Options::new();
                options.len = (ihl - 5) * 4;
                if false == options.is_empty() {
                    reader.read_exact(options.as_mut()).map_err(Io)?;
                }
                options
            },
        })
    }

    /// Writes a given IPv4 header to the current position (this method automatically calculates
    /// the header length and checksum).
    #[cfg(feature = "std")]
    #[cfg_attr(docsrs, doc(cfg(feature = "std")))]
    pub fn write<T: std::io::Write + Sized>(&self, writer: &mut T) -> Result<(), std::io::Error> {
        // write with recalculations
        self.write_ipv4_header_internal(writer, self.calc_header_checksum())
    }

    /// Writes a given IPv4 header to the current position (this method just writes the specified
    /// checksum and does not compute it).
    #[cfg(feature = "std")]
    #[cfg_attr(docsrs, doc(cfg(feature = "std")))]
    pub fn write_raw<T: std::io::Write + Sized>(
        &self,
        writer: &mut T,
    ) -> Result<(), std::io::Error> {
        self.write_ipv4_header_internal(writer, self.header_checksum)
    }

    /// Returns the serialized header (note that this method does NOT
    /// update & calculate the checksum).
    pub fn to_bytes(&self) -> ArrayVec<u8, { Ipv4Header::MAX_LEN }> {
        // prep the values for copy
        let total_len_be = self.total_len.to_be_bytes();
        let id_be = self.identification.to_be_bytes();
        let frag_and_flags = {
            let frag_be: [u8; 2] = self.fragment_offset.value().to_be_bytes();
            let flags = {
                let mut result = 0;
                if self.dont_fragment {
                    result |= 64;
                }
                if self.more_fragments {
                    result |= 32;
                }
                result
            };
            [flags | (frag_be[0] & 0x1f), frag_be[1]]
        };
        let header_checksum_be = self.header_checksum.to_be_bytes();

        #[rustfmt::skip]
        let mut header_raw: ArrayVec<u8, { Ipv4Header::MAX_LEN } > = [
            (4 << 4) | self.ihl(),
            (self.dscp.value() << 2) | self.ecn.value(),
            total_len_be[0],
            total_len_be[1],

            id_be[0], id_be[1], frag_and_flags[0], frag_and_flags[1],

            self.time_to_live, self.protocol.0, header_checksum_be[0], header_checksum_be[1],
            self.source[0], self.source[1], self.source[2], self.source[3],

            self.destination[0], self.destination[1], self.destination[2], self.destination[3],
            self.options.buf[0], self.options.buf[1], self.options.buf[2], self.options.buf[3],

            self.options.buf[4], self.options.buf[5], self.options.buf[6], self.options.buf[7],
            self.options.buf[8], self.options.buf[9], self.options.buf[10], self.options.buf[11],

            self.options.buf[12], self.options.buf[13], self.options.buf[14], self.options.buf[15],
            self.options.buf[16], self.options.buf[17], self.options.buf[18], self.options.buf[19],

            self.options.buf[20], self.options.buf[21], self.options.buf[22], self.options.buf[23],
            self.options.buf[24], self.options.buf[25], self.options.buf[26], self.options.buf[27],

            self.options.buf[28], self.options.buf[29], self.options.buf[30], self.options.buf[31],
            self.options.buf[32], self.options.buf[33], self.options.buf[34], self.options.buf[35],

            self.options.buf[36], self.options.buf[37], self.options.buf[38], self.options.buf[39],
        ].into();

        // SAFETY: Safe as header_len() can never exceed the maximum length of an
        // IPv4 header which is the upper limit of the array vec.
        unsafe {
            header_raw.set_len(self.header_len());
        }

        header_raw
    }

    /// Write the given header with the  checksum and header length specified in the separate arguments
    #[cfg(feature = "std")]
    fn write_ipv4_header_internal<T: std::io::Write>(
        &self,
        write: &mut T,
        header_checksum: u16,
    ) -> Result<(), std::io::Error> {
        let total_len_be = self.total_len.to_be_bytes();
        let id_be = self.identification.to_be_bytes();
        let frag_and_flags = {
            let frag_be: [u8; 2] = self.fragment_offset.value().to_be_bytes();
            let flags = {
                let mut result = 0;
                if self.dont_fragment {
                    result |= 64;
                }
                if self.more_fragments {
                    result |= 32;
                }
                result
            };
            [flags | (frag_be[0] & 0x1f), frag_be[1]]
        };
        let header_checksum_be = header_checksum.to_be_bytes();

        let header_raw = [
            (4 << 4) | self.ihl(),
            (self.dscp.value() << 2) | self.ecn.value(),
            total_len_be[0],
            total_len_be[1],
            id_be[0],
            id_be[1],
            frag_and_flags[0],
            frag_and_flags[1],
            self.time_to_live,
            self.protocol.0,
            header_checksum_be[0],
            header_checksum_be[1],
            self.source[0],
            self.source[1],
            self.source[2],
            self.source[3],
            self.destination[0],
            self.destination[1],
            self.destination[2],
            self.destination[3],
        ];
        write.write_all(&header_raw)?;

        //options
        write.write_all(&self.options)?;

        //done
        Ok(())
    }

    /// Calculate header checksum of the current ipv4 header.
    pub fn calc_header_checksum(&self) -> u16 {
        checksum::Sum16BitWords::new()
            .add_2bytes([
                (4 << 4) | self.ihl(),
                (self.dscp.value() << 2) | self.ecn.value(),
            ])
            .add_2bytes(self.total_len.to_be_bytes())
            .add_2bytes(self.identification.to_be_bytes())
            .add_2bytes({
                let frag_off_be = self.fragment_offset.value().to_be_bytes();
                let flags = {
                    let mut result = 0;
                    if self.dont_fragment {
                        result |= 64;
                    }
                    if self.more_fragments {
                        result |= 32;
                    }
                    result
                };
                [flags | (frag_off_be[0] & 0x1f), frag_off_be[1]]
            })
            .add_2bytes([self.time_to_live, self.protocol.0])
            .add_4bytes(self.source)
            .add_4bytes(self.destination)
            .add_slice(&self.options)
            .ones_complement()
            .to_be()
    }

    /// Returns true if the payload is fragmented.
    ///
    /// Either data is missing (more_fragments set) or there is
    /// an fragment offset.
    #[inline]
    pub fn is_fragmenting_payload(&self) -> bool {
        self.more_fragments || (0 != self.fragment_offset.value())
    }
}

impl Default for Ipv4Header {
    fn default() -> Ipv4Header {
        Ipv4Header {
            dscp: Default::default(),
            ecn: Default::default(),
            total_len: 0,
            identification: 0,
            dont_fragment: true,
            more_fragments: false,
            fragment_offset: Default::default(),
            time_to_live: 0,
            protocol: IpNumber(255),
            header_checksum: 0,
            source: [0; 4],
            destination: [0; 4],
            options: Ipv4Options::new(),
        }
    }
}

#[cfg(test)]
mod test {
    use crate::{
        err::{Layer, LenError, ValueTooBigError, ValueType},
        test_gens::*,
        *,
    };
    use alloc::{format, vec::Vec};
    use arrayvec::ArrayVec;
    use proptest::prelude::*;
    use std::io::Cursor;

    #[test]
    fn default() {
        let default: Ipv4Header = Default::default();
        assert_eq!(5, default.ihl());
        assert_eq!(0, default.dscp.value());
        assert_eq!(0, default.ecn.value());
        assert_eq!(0, default.total_len);
        assert_eq!(0, default.identification);
        assert_eq!(true, default.dont_fragment);
        assert_eq!(false, default.more_fragments);
        assert_eq!(0, default.fragment_offset.value());
        assert_eq!(0, default.time_to_live);
        assert_eq!(IpNumber(255), default.protocol);
        assert_eq!(0, default.header_checksum);
        assert_eq!([0; 4], default.source);
        assert_eq!([0; 4], default.destination);
        assert_eq!(&default.options[..], &[]);
    }

    proptest! {
        #[test]
        fn debug(input in ipv4_any()) {
            assert_eq!(&format!("Ipv4Header {{ dscp: {:?}, ecn: {:?}, total_len: {}, identification: {}, dont_fragment: {}, more_fragments: {}, fragment_offset: {:?}, time_to_live: {}, protocol: {:?}, header_checksum: {}, source: {:?}, destination: {:?}, options: {:?} }}",
                    input.dscp,
                    input.ecn,
                    input.total_len,
                    input.identification,
                    input.dont_fragment,
                    input.more_fragments,
                    input.fragment_offset,
                    input.time_to_live,
                    input.protocol,
                    input.header_checksum,
                    input.source,
                    input.destination,
                    input.options
                ),
                &format!("{:?}", input)
            );
        }
    }

    proptest! {
        #[test]
        fn eq(a in ipv4_any(),
              b in ipv4_any())
        {
            //check identity equality
            assert!(a == a);
            assert!(b == b);

            //check every field
            //differentiated_services_code_point
            assert_eq!(
                a.dscp == b.dscp,
                a == {
                    let mut other = a.clone();
                    other.dscp = b.dscp;
                    other
                }
            );
            //explicit_congestion_notification
            assert_eq!(
                a.ecn == b.ecn,
                a == {
                    let mut other = a.clone();
                    other.ecn = b.ecn;
                    other
                }
            );
            //total_len
            assert_eq!(
                a.total_len == b.total_len,
                a == {
                    let mut other = a.clone();
                    other.total_len = b.total_len;
                    other
                }
            );
            //identification
            assert_eq!(
                a.identification == b.identification,
                a == {
                    let mut other = a.clone();
                    other.identification = b.identification;
                    other
                }
            );
            //dont_fragment
            assert_eq!(
                a.dont_fragment == b.dont_fragment,
                a == {
                    let mut other = a.clone();
                    other.dont_fragment = b.dont_fragment;
                    other
                }
            );
            //more_fragments
            assert_eq!(
                a.more_fragments == b.more_fragments,
                a == {
                    let mut other = a.clone();
                    other.more_fragments = b.more_fragments;
                    other
                }
            );
            //fragments_offset
            assert_eq!(
                a.fragment_offset == b.fragment_offset,
                a == {
                    let mut other = a.clone();
                    other.fragment_offset = b.fragment_offset;
                    other
                }
            );
            //time_to_live
            assert_eq!(
                a.time_to_live == b.time_to_live,
                a == {
                    let mut other = a.clone();
                    other.time_to_live = b.time_to_live;
                    other
                }
            );
            //protocol
            assert_eq!(
                a.protocol == b.protocol,
                a == {
                    let mut other = a.clone();
                    other.protocol = b.protocol;
                    other
                }
            );
            //header_checksum
            assert_eq!(
                a.header_checksum == b.header_checksum,
                a == {
                    let mut other = a.clone();
                    other.header_checksum = b.header_checksum;
                    other
                }
            );
            //source
            assert_eq!(
                a.source == b.source,
                a == {
                    let mut other = a.clone();
                    other.source = b.source;
                    other
                }
            );
            //destination
            assert_eq!(
                a.destination == b.destination,
                a == {
                    let mut other = a.clone();
                    other.destination = b.destination;
                    other
                }
            );

            //options
            assert_eq!(
                a.options == b.options,
                a == {
                    let mut other = a.clone();
                    other.options = b.options;
                    other
                }
            );
        }
    }

    proptest! {
        #[test]
        fn hash(header in ipv4_any()) {
            use std::collections::hash_map::DefaultHasher;
            use core::hash::{Hash, Hasher};
            let a = {
                let mut hasher = DefaultHasher::new();
                header.hash(&mut hasher);
                hasher.finish()
            };
            let b = {
                let mut hasher = DefaultHasher::new();
                header.hash(&mut hasher);
                hasher.finish()
            };
            assert_eq!(a, b);
        }
    }

    proptest! {
        #[test]
        fn new(
            source_ip in prop::array::uniform4(any::<u8>()),
            dest_ip in prop::array::uniform4(any::<u8>()),
            ttl in any::<u8>(),
            ok_payload_len in 0u16..=(u16::MAX - Ipv4Header::MIN_LEN as u16),
            err_payload_len in (u16::MAX - Ipv4Header::MIN_LEN as u16 + 1)..=u16::MAX
        ) {
            // ok case
            {
                let result = Ipv4Header::new(
                    ok_payload_len,
                    ttl,
                    ip_number::UDP,
                    source_ip,
                    dest_ip
                ).unwrap();

                assert_eq!(result.dscp.value(), 0);
                assert_eq!(result.ecn.value(), 0);
                assert_eq!(result.total_len, ok_payload_len + Ipv4Header::MIN_LEN as u16);
                assert_eq!(result.identification, 0);
                assert_eq!(result.dont_fragment, true);
                assert_eq!(result.more_fragments, false);
                assert_eq!(result.fragment_offset.value(), 0);
                assert_eq!(result.time_to_live, ttl);
                assert_eq!(result.protocol, ip_number::UDP);
                assert_eq!(result.header_checksum, 0);
                assert_eq!(result.source, source_ip);
                assert_eq!(result.destination, dest_ip);
                assert_eq!(result.options.as_slice(), &[]);
            }
            // err
            {
                assert_eq!(
                    Ipv4Header::new(
                        err_payload_len,
                        ttl,
                        ip_number::UDP,
                        source_ip,
                        dest_ip
                    ),
                    Err(ValueTooBigError::<u16>{
                        actual: err_payload_len,
                        max_allowed: u16::MAX - Ipv4Header::MIN_LEN as u16,
                        value_type: ValueType::Ipv4PayloadLength,
                    })
                );
            }
        }
    }

    proptest! {
        #[test]
        fn ihl(header in ipv4_any()) {
            assert_eq!(header.ihl(), (header.header_len() / 4) as u8);
        }
    }

    proptest! {
        #[test]
        fn header_len(header in ipv4_any()) {
            assert_eq!(header.header_len(), 20 + usize::from(header.options.len()));
        }
    }

    proptest! {
        #[test]
        fn payload_len(
            header in ipv4_any()
        ) {
            // ok case
            assert_eq!(
                header.payload_len().unwrap(),
                header.total_len - 20 - (header.options.len() as u16)
            );
            // err case
            for bad_len in 0u16..(header.header_len() as u16) {
                let mut header = header.clone();
                header.total_len = bad_len;
                assert_eq!(
                    header.payload_len().unwrap_err(),
                    LenError{
                        required_len: header.header_len(),
                        len: bad_len.into(),
                        len_source: LenSource::Ipv4HeaderTotalLen,
                        layer: Layer::Ipv4Packet,
                        layer_start_offset: 0
                    }
                );
            }

        }
    }

    #[test]
    fn set_payload_len() {
        let mut header = Ipv4Header::new(0, 0, ip_number::UDP, [0; 4], [0; 4]).unwrap();

        //add options (to make sure they are included in the calculation)
        header.options = [1, 2, 3, 4].into();

        //zero check
        assert!(header.set_payload_len(0).is_ok());
        assert_eq!(header.total_len, 24);

        //max check
        const MAX: usize = (core::u16::MAX as usize) - Ipv4Header::MIN_LEN - 4;
        assert!(header.set_payload_len(MAX).is_ok());
        assert_eq!(header.total_len, core::u16::MAX);

        const OVER_MAX: usize = MAX + 1;
        assert_eq!(
            header.set_payload_len(OVER_MAX),
            Err(ValueTooBigError {
                actual: OVER_MAX,
                max_allowed: usize::from(u16::MAX) - header.header_len(),
                value_type: ValueType::Ipv4PayloadLength
            })
        );
    }

    proptest! {
        #[test]
        fn max_payload_len(header in ipv4_any()) {
            assert_eq!(header.max_payload_len(), core::u16::MAX - 20 - u16::from(header.options.len_u8()));
        }
    }

    #[test]
    #[allow(deprecated)]
    fn set_options() {
        //length of 1
        {
            let mut header: Ipv4Header = Default::default();
            let options = [1, 2, 3, 4];
            assert_eq!(header.set_options(&options), Ok(()));

            assert_eq!(&options, header.options());
            assert_eq!(24, header.header_len());
            assert_eq!(0, header.total_len);
            assert_eq!(6, header.ihl());

            //length 0
            assert_eq!(header.set_options(&[]), Ok(()));

            assert_eq!(&options[..0], header.options());
            assert_eq!(20, header.header_len());
            assert_eq!(0, header.total_len);
            assert_eq!(5, header.ihl());
        }
        //maximum length (40)
        {
            let mut header: Ipv4Header = Default::default();
            let options = [
                1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23,
                24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35, 36, 37, 38, 39, 40,
            ];
            assert_eq!(header.set_options(&options), Ok(()));

            assert_eq!(&options[..], header.options());
            assert_eq!(60, header.header_len());
            assert_eq!(0, header.total_len);
            assert_eq!(15, header.ihl());
        }
        //errors
        {
            let buffer: [u8; 50] = [0; 50];
            for len in &[
                1usize, 2, 3, //unaligned
                5, 6, 7, 41, 44, //over max
            ] {
                let mut header: Ipv4Header = Default::default();

                //expect an error
                use self::err::ipv4::BadOptionsLen;
                assert_eq!(
                    Err(BadOptionsLen { bad_len: *len }),
                    header.set_options(&buffer[..*len])
                );

                //check value was not taken
                assert_eq!(&buffer[..0], header.options());
                assert_eq!(20, header.header_len());
                assert_eq!(0, header.total_len);
                assert_eq!(5, header.ihl());
            }
        }
    }

    proptest! {
        #[test]
        #[allow(deprecated)]
        fn read_from_slice(ref input in ipv4_any()) {
            //serialize
            let mut buffer: Vec<u8> = Vec::with_capacity(input.header_len());
            input.write_raw(&mut buffer).unwrap();
            assert_eq!(input.header_len(), buffer.len());

            //deserialize (read_from_slice)
            let result = Ipv4Header::read_from_slice(&buffer).unwrap();
            assert_eq!(input, &result.0);
            assert_eq!(&buffer[usize::from(input.header_len())..], result.1);
        }
    }

    proptest! {
        #[test]
        fn from_slice(header in ipv4_any()) {
            use err::ipv4::HeaderError::*;
            use err::ipv4::HeaderSliceError::*;

            // ok
            {
                let mut buffer = ArrayVec::<u8, { Ipv4Header::MAX_LEN + 1 }>::new();
                buffer.try_extend_from_slice(&header.to_bytes()).unwrap();
                buffer.try_extend_from_slice(&[1]).unwrap();

                let (actual_header, actual_rest) = Ipv4Header::from_slice(&buffer).unwrap();
                assert_eq!(actual_header, header);
                assert_eq!(actual_rest, &[1]);
            }

            // unexpected end of slice
            {
                let buffer = header.to_bytes();
                for len in 0..header.header_len() {
                    assert_eq!(
                        Ipv4Header::from_slice(&buffer[..len]),
                        Err(Len(err::LenError{
                            required_len: if len < Ipv4Header::MIN_LEN {
                                Ipv4Header::MIN_LEN
                            } else {
                                header.header_len()
                            },
                            len: len,
                            len_source: LenSource::Slice,
                            layer: err::Layer::Ipv4Header,
                            layer_start_offset: 0,
                        }))
                    );
                }
            }

            // version error
            for version_number in 0u8..0b1111u8 {
                if 4 != version_number {
                    let mut buffer = header.to_bytes();
                    // inject the bad ihl
                    buffer[0] = (version_number << 4) | (buffer[0] & 0b1111);
                    // expect an error
                    assert_eq!(
                        Ipv4Header::from_slice(&buffer).unwrap_err(),
                        Content(UnexpectedVersion{
                            version_number,
                        })
                    );
                }
            }

            // ihl too small error
            for ihl in 0u8..5u8 {
                let mut buffer = header.to_bytes();
                // inject the bad ihl
                buffer[0] = (4 << 4) | ihl;
                // expect an error
                assert_eq!(
                    Ipv4Header::from_slice(&buffer).unwrap_err(),
                    Content(HeaderLengthSmallerThanHeader{
                        ihl,
                    })
                );
            }
        }
    }

    proptest! {
        #[test]
        fn read_and_read_without_version(header in ipv4_any()) {
            use err::ipv4::HeaderError::*;
            use std::io::Cursor;

            // ok
            {
                let buffer = header.to_bytes();

                // read
                {
                    let mut cursor = Cursor::new(&buffer);
                    let actual_header = Ipv4Header::read(&mut cursor).unwrap();
                    assert_eq!(actual_header, header);
                    assert_eq!(cursor.position(), header.header_len() as u64);
                }
                // read_without_version
                {
                    let mut cursor = Cursor::new(&buffer[1..]);
                    let actual_header = Ipv4Header::read_without_version(&mut cursor, buffer[0]).unwrap();
                    assert_eq!(actual_header, header);
                    assert_eq!(cursor.position(), (header.header_len() - 1) as u64);
                }
            }

            // io error
            {
                let buffer = header.to_bytes();
                for len in 0..header.header_len() {
                    // read
                    {
                        let mut cursor = Cursor::new(&buffer[..len]);
                        let err = Ipv4Header::read(&mut cursor).unwrap_err();
                        assert!(err.io_error().is_some());
                    }

                    // read_without_version
                    if len > 0 {
                        let mut cursor = Cursor::new(&buffer[1..len]);
                        let err = Ipv4Header::read_without_version(&mut cursor, buffer[0]).unwrap_err();
                        assert!(err.io_error().is_some());
                    }
                }
            }

            // version error
            for version_number in 0u8..0b1111u8 {
                if 4 != version_number {
                    let mut buffer = header.to_bytes();
                    // inject the bad version number
                    buffer[0] = (version_number << 4) | (buffer[0] & 0b1111);

                    // expect an error
                    // read
                    {
                        let mut cursor = Cursor::new(&buffer[..]);
                        let err = Ipv4Header::read(&mut cursor)
                            .unwrap_err()
                            .content_error()
                            .unwrap();
                        assert_eq!(err, UnexpectedVersion{ version_number });
                    }

                    // read_without_version skipped as version is not checked
                }
            }

            // ihl too small error
            for ihl in 0u8..5u8 {
                let mut buffer = header.to_bytes();
                // inject the bad ihl
                buffer[0] = (4 << 4) | ihl;
                // expect an error
                // read
                {
                    let mut cursor = Cursor::new(&buffer[..]);
                    let err = Ipv4Header::read(&mut cursor)
                        .unwrap_err()
                        .content_error()
                        .unwrap();
                    assert_eq!(err, HeaderLengthSmallerThanHeader{ ihl });
                }

                // read_without_version
                {
                    let mut cursor = Cursor::new(&buffer[1..]);
                    let err = Ipv4Header::read_without_version(&mut cursor, buffer[0])
                        .unwrap_err()
                        .content_error()
                        .unwrap();
                    assert_eq!(err, HeaderLengthSmallerThanHeader{ ihl });
                }
            }
        }
    }

    proptest! {
        #[test]
        fn write(ref base_header in ipv4_any()) {
            use std::io::Cursor;

            let header = {
                let mut header = base_header.clone();
                // set the header checksum to something else to
                // ensure it is calculated during the write call
                header.header_checksum = 0;
                header
            };

            // normal write
            {
                //serialize
                let buffer = {
                    let mut buffer: Vec<u8> = Vec::with_capacity(header.header_len());
                    header.write(&mut buffer).unwrap();
                    buffer
                };
                assert_eq!(header.header_len(), buffer.len());

                //deserialize
                let mut cursor = Cursor::new(&buffer);
                let result = Ipv4Header::read(&mut cursor).unwrap();
                assert_eq!(header.header_len(), cursor.position() as usize);

                //check equivalence (with calculated checksum)
                let header_with_checksum = {
                    let mut h = header.clone();
                    h.header_checksum = h.calc_header_checksum();
                    h
                };
                assert_eq!(header_with_checksum, result);
            }

            // io error
            for len in 0..header.header_len() {
                let mut buffer = [0u8; Ipv4Header::MAX_LEN];
                let mut cursor = Cursor::new(&mut buffer[..len]);
                assert!(
                    header.write(&mut cursor).is_err()
                );
            }
        }
    }

    proptest! {
        #[test]
        fn write_raw(base_header in ipv4_any()) {
            // normal write
            {
                //serialize
                let buffer = {
                    let mut buffer: Vec<u8> = Vec::with_capacity(base_header.header_len());
                    base_header.write_raw(&mut buffer).unwrap();
                    buffer
                };
                assert_eq!(base_header.header_len(), buffer.len());

                // decode and check for equality
                assert_eq!(
                    Ipv4Header::from_slice(&buffer).unwrap().0,
                    base_header
                );
            }

            // io error
            for len in 0..base_header.header_len() {
                let mut buffer = [0u8; Ipv4Header::MAX_LEN];
                let mut cursor = Cursor::new(&mut buffer[..len]);
                assert!(
                    base_header.write_raw(&mut cursor).is_err()
                );
            }
        }
    }

    proptest! {
        #[test]
        fn to_bytes(base_header in ipv4_any()) {
            let bytes = base_header.to_bytes();
            assert_eq!(
                base_header,
                Ipv4HeaderSlice::from_slice(&bytes).unwrap().to_header()
            );
        }
    }

    #[test]
    fn calc_header_checksum() {
        let base: Ipv4Header = Ipv4Header::new(
            40,
            4, // ttl
            ip_number::UDP,
            [192, 168, 1, 1],   // source
            [212, 10, 11, 123], // destination
        )
        .unwrap();

        //without options
        {
            //dont_fragment && !more_fragments
            let header = base.clone();
            assert_eq!(0xd582, header.calc_header_checksum());
            // !dont_fragment && more_fragments
            let header = {
                let mut header = base.clone();
                header.dont_fragment = false;
                header.more_fragments = true;
                header
            };
            assert_eq!(0xf582, header.calc_header_checksum());
        }
        //with options
        {
            let header = {
                let mut header = base.clone();
                header.options = [1, 2, 3, 4, 5, 6, 7, 8].into();
                header.total_len = (header.header_len() + 32) as u16;
                header
            };
            assert_eq!(0xc36e, header.calc_header_checksum());
        }
    }

    #[test]
    fn is_fragmenting_payload() {
        // not fragmenting
        {
            let mut header: Ipv4Header = Default::default();
            header.fragment_offset = 0.try_into().unwrap();
            header.more_fragments = false;
            assert_eq!(false, header.is_fragmenting_payload());
        }

        // fragmenting based on offset
        {
            let mut header: Ipv4Header = Default::default();
            header.fragment_offset = 1.try_into().unwrap();
            header.more_fragments = false;
            assert!(header.is_fragmenting_payload());
        }

        // fragmenting based on more_fragments
        {
            let mut header: Ipv4Header = Default::default();
            header.fragment_offset = 0.try_into().unwrap();
            header.more_fragments = true;
            assert!(header.is_fragmenting_payload());
        }
    }
}
