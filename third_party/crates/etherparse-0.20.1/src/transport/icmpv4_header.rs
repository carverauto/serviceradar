use crate::*;
use arrayvec::ArrayVec;

/// A header of an ICMPv4 packet.
///
/// What is part of the header depends on the ICMPv4 type
/// and code. But usually the static sized elements are part
/// of the header.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Icmpv4Header {
    /// Type & type specific values & code.
    pub icmp_type: Icmpv4Type,
    /// Checksum in the ICMP header.
    pub checksum: u16,
}

impl Icmpv4Header {
    /// Minimum number of bytes/octets an Icmpv4Header takes up
    /// in serialized form.
    pub const MIN_LEN: usize = 8;

    /// Deprecated, use [`Icmpv4Header::MIN_LEN`] instead.
    #[deprecated(since = "0.14.0", note = "Please use Icmpv4Header::MIN_LEN instead")]
    pub const MIN_SERIALIZED_SIZE: usize = 8;

    /// Maximum number of bytes/octets an Icmpv4Header takes up
    /// in serialized form.
    ///
    /// Currently this number is determined by the biggest
    /// supported ICMPv4 header type, which is currently the
    /// "Timestamp" and "Timestamp Reply Message".
    pub const MAX_LEN: usize = 20;

    /// Deprecated, use [`Icmpv4Header::MAX_LEN`] instead.
    #[deprecated(since = "0.14.0", note = "Please use Icmpv4Header::MAX_LEN instead")]
    pub const MAX_SERIALIZED_SIZE: usize = 20;

    /// Constructs an [`Icmpv4Header`] using the given type
    /// and the checksum set to 0.
    pub fn new(icmp_type: Icmpv4Type) -> Icmpv4Header {
        // Note: will calculate checksum on send
        Icmpv4Header {
            icmp_type,
            checksum: 0,
        }
    }

    /// Creates a [`Icmpv4Header`] with a checksum calculated based on the given payload.
    pub fn with_checksum(icmp_type: Icmpv4Type, payload: &[u8]) -> Icmpv4Header {
        let checksum = icmp_type.calc_checksum(payload);
        Icmpv4Header {
            icmp_type,
            checksum,
        }
    }

    /// Reads an icmp4 header from a slice directly and returns a tuple containing the resulting header & unused part of the slice.
    #[inline]
    pub fn from_slice(slice: &[u8]) -> Result<(Icmpv4Header, &[u8]), err::LenError> {
        let header = Icmpv4Slice::from_slice(slice)?.header();
        let rest = &slice[header.header_len()..];
        Ok((header, rest))
    }

    /// Reads an ICMPv4 header from the given reader.
    #[cfg(feature = "std")]
    #[cfg_attr(docsrs, doc(cfg(feature = "std")))]
    pub fn read<T: std::io::Read + Sized>(reader: &mut T) -> Result<Icmpv4Header, std::io::Error> {
        let mut bytes = [0u8; Icmpv4Header::MAX_LEN];

        // try reading the initial 8 bytes
        reader.read_exact(&mut bytes[..8])?;

        match bytes[0] {
            icmpv4::TYPE_TIMESTAMP_REPLY | icmpv4::TYPE_TIMESTAMP => {
                if 0 == bytes[1] {
                    // Timetamp messages need additional data read & it and
                    // then set the slice correspondently
                    reader.read_exact(&mut bytes[8..icmpv4::TimestampMessage::LEN])?;
                    Ok(Icmpv4Slice {
                        slice: &bytes[..icmpv4::TimestampMessage::LEN],
                    }
                    .header())
                } else {
                    // fallback to unknown
                    Ok(Icmpv4Slice { slice: &bytes[..8] }.header())
                }
            }
            _ => Ok(Icmpv4Slice { slice: &bytes[..8] }.header()),
        }
    }

    /// Write the ICMPv4 header to the given writer.
    #[cfg(feature = "std")]
    #[cfg_attr(docsrs, doc(cfg(feature = "std")))]
    pub fn write<T: std::io::Write + Sized>(&self, writer: &mut T) -> Result<(), std::io::Error> {
        writer.write_all(&self.to_bytes())
    }

    /// Length in bytes/octets of this header type.
    #[inline]
    pub fn header_len(&self) -> usize {
        self.icmp_type.header_len()
    }

    /// If the ICMP type has a fixed size returns the number of
    /// bytes that should be present after the header of this type.
    #[inline]
    pub fn fixed_payload_size(&self) -> Option<usize> {
        self.icmp_type.fixed_payload_size()
    }

    /// Calculates & updates the checksum in the header.
    ///
    /// Note this method assumes that all unused bytes/octets
    /// are filled with zeroes.
    pub fn update_checksum(&mut self, payload: &[u8]) {
        self.checksum = self.icmp_type.calc_checksum(payload);
    }

    /// Converts the header to the on the wire bytes.
    #[rustfmt::skip]
    pub fn to_bytes(&self) -> ArrayVec<u8, { Icmpv4Header::MAX_LEN }> {
        let checksum_be = self.checksum.to_be_bytes();
        let re_zero =
            |type_u8: u8, code_u8: u8| -> ArrayVec<u8, { Icmpv4Header::MAX_LEN }> {

                #[rustfmt::skip]
                let mut re = ArrayVec::from([
                    type_u8, code_u8, checksum_be[0], checksum_be[1],
                    0, 0, 0, 0,
                    0, 0, 0, 0,
                    0, 0, 0, 0,
                    0, 0, 0, 0,
                ]);
                // SAFETY: Safe as u8 has no destruction behavior and as 8 is smaller then 20.
                unsafe {
                    re.set_len(8);
                }
                re
            };

        let re_2u16 = |type_u8: u8,
                       code_u8: u8,
                       a_u16: u16,
                       b_u16: u16|
         -> ArrayVec<u8, { Icmpv4Header::MAX_LEN }> {
            let a = a_u16.to_be_bytes();
            let b = b_u16.to_be_bytes();

            #[rustfmt::skip]
            let mut re = ArrayVec::from([
                type_u8, code_u8, checksum_be[0], checksum_be[1],
                a[0], a[1], b[0], b[1],
                0, 0, 0, 0,
                0, 0, 0, 0,
                0, 0, 0, 0,
            ]);
            // SAFETY: Safe as u8 has no destruction behavior and as 8 is smaller then 20.
            unsafe {
                re.set_len(8);
            }
            re
        };

        let re_4u8 = |type_u8: u8,
                      code_u8: u8,
                      bytes5to8: [u8; 4]|
         -> ArrayVec<u8, { Icmpv4Header::MAX_LEN }> {

            #[rustfmt::skip]
            let mut re = ArrayVec::from([
                type_u8, code_u8, checksum_be[0], checksum_be[1],
                bytes5to8[0], bytes5to8[1], bytes5to8[2], bytes5to8[3],
                0, 0, 0, 0,
                0, 0, 0, 0,
                0, 0, 0, 0,
            ]);
            // SAFETY: Safe as u8 has no destruction behavior and as 8 is smaller then 20.
            unsafe {
                re.set_len(8);
            }
            re
        };

        let re_timestamp_msg = |type_u8: u8,
                                msg: &icmpv4::TimestampMessage|
         -> ArrayVec<u8, { Icmpv4Header::MAX_LEN }> {
            let id = msg.id.to_be_bytes();
            let seq = msg.seq.to_be_bytes();
            let o = msg.originate_timestamp.to_be_bytes();
            let r = msg.receive_timestamp.to_be_bytes();
            let t = msg.transmit_timestamp.to_be_bytes();

            ArrayVec::from([
                type_u8, 0, checksum_be[0], checksum_be[1],
                id[0], id[1], seq[0], seq[1],
                o[0], o[1], o[2], o[3],
                r[0], r[1], r[2], r[3],
                t[0], t[1], t[2], t[3],
            ])
        };

        use Icmpv4Type::*;
        use icmpv4::*;
        match self.icmp_type {
            Unknown {
                type_u8,
                code_u8,
                bytes5to8,
            } => re_4u8(type_u8, code_u8, bytes5to8),
            EchoReply(echo) => re_2u16(TYPE_ECHO_REPLY, 0, echo.id, echo.seq),
            DestinationUnreachable(ref dest) => {
                use DestUnreachableHeader::*;
                match dest {
                    Network => re_zero(TYPE_DEST_UNREACH, CODE_DST_UNREACH_NET),
                    Host => re_zero(TYPE_DEST_UNREACH, CODE_DST_UNREACH_HOST),
                    Protocol => re_zero(TYPE_DEST_UNREACH, CODE_DST_UNREACH_PROTOCOL),
                    Port => re_zero(TYPE_DEST_UNREACH, CODE_DST_UNREACH_PORT),
                    FragmentationNeeded { next_hop_mtu } => {
                        let m_be = next_hop_mtu.to_be_bytes();
                        re_4u8(
                            TYPE_DEST_UNREACH,
                            CODE_DST_UNREACH_NEED_FRAG,
                            [0, 0, m_be[0], m_be[1]],
                        )
                    }
                    SourceRouteFailed => re_zero(TYPE_DEST_UNREACH, CODE_DST_UNREACH_SOURCE_ROUTE_FAILED),
                    NetworkUnknown => re_zero(TYPE_DEST_UNREACH, CODE_DST_UNREACH_NET_UNKNOWN),
                    HostUnknown => re_zero(TYPE_DEST_UNREACH, CODE_DST_UNREACH_HOST_UNKNOWN),
                    Isolated => re_zero(TYPE_DEST_UNREACH, CODE_DST_UNREACH_ISOLATED),
                    NetworkProhibited => re_zero(TYPE_DEST_UNREACH, CODE_DST_UNREACH_NET_PROHIB),
                    HostProhibited => re_zero(TYPE_DEST_UNREACH, CODE_DST_UNREACH_HOST_PROHIB),
                    TosNetwork => re_zero(TYPE_DEST_UNREACH, CODE_DST_UNREACH_TOS_NET),
                    TosHost => re_zero(TYPE_DEST_UNREACH, CODE_DST_UNREACH_TOS_HOST),
                    FilterProhibited => re_zero(TYPE_DEST_UNREACH, CODE_DST_UNREACH_FILTER_PROHIB),
                    HostPrecedenceViolation => re_zero(
                        TYPE_DEST_UNREACH,
                        CODE_DST_UNREACH_HOST_PRECEDENCE_VIOLATION,
                    ),
                    PrecedenceCutoff => {
                        re_zero(TYPE_DEST_UNREACH, CODE_DST_UNREACH_PRECEDENCE_CUTOFF)
                    }
                }
            }
            Redirect(ref msg) => {
                re_4u8(TYPE_REDIRECT, msg.code as u8, msg.gateway_internet_address)
            }
            EchoRequest(echo) => re_2u16(TYPE_ECHO_REQUEST, 0, echo.id, echo.seq),
            TimeExceeded(code) => re_zero(TYPE_TIME_EXCEEDED, code as u8),
            ParameterProblem(ref header) => {
                use ParameterProblemHeader::*;
                match header {
                    PointerIndicatesError(pointer) => re_4u8(
                        TYPE_PARAMETER_PROBLEM,
                        CODE_PARAMETER_PROBLEM_POINTER_INDICATES_ERROR,
                        [*pointer, 0, 0, 0],
                    ),
                    MissingRequiredOption => re_zero(
                        TYPE_PARAMETER_PROBLEM,
                        CODE_PARAMETER_PROBLEM_MISSING_REQUIRED_OPTION,
                    ),
                    BadLength => re_zero(TYPE_PARAMETER_PROBLEM, CODE_PARAMETER_PROBLEM_BAD_LENGTH),
                }
            }
            TimestampRequest(ref msg) => re_timestamp_msg(TYPE_TIMESTAMP, msg),
            TimestampReply(ref msg) => re_timestamp_msg(TYPE_TIMESTAMP_REPLY, msg),
        }
    }
}

#[cfg(test)]
mod test {
    use crate::{
        err::{Layer, LenError},
        icmpv4::*,
        test_gens::*,
        *,
    };
    use alloc::{format, vec::Vec};
    use proptest::prelude::*;

    #[test]
    #[allow(deprecated)]
    fn constants() {
        assert_eq!(8, Icmpv4Header::MIN_LEN);
        assert_eq!(20, Icmpv4Header::MAX_LEN);
        assert_eq!(8, Icmpv4Header::MIN_SERIALIZED_SIZE);
        assert_eq!(20, Icmpv4Header::MAX_SERIALIZED_SIZE);
    }

    proptest! {
        #[test]
        fn new(icmpv4_type in icmpv4_type_any()) {
            assert_eq!(
                Icmpv4Header {
                    icmp_type: icmpv4_type.clone(),
                    checksum: 0,
                },
                Icmpv4Header::new(icmpv4_type)
            );
        }
    }

    proptest! {
        #[test]
        fn with_checksum(
            icmpv4_type in icmpv4_type_any(),
            payload in proptest::collection::vec(any::<u8>(), 0..1024),
        ) {
            assert_eq!(
                Icmpv4Header {
                    icmp_type: icmpv4_type.clone(),
                    checksum: icmpv4_type.calc_checksum(&payload),
                },
                Icmpv4Header::with_checksum(icmpv4_type, &payload)
            );
        }
    }

    proptest! {
        #[test]
        fn from_slice(
            icmpv4_type in icmpv4_type_any(),
            checksum in any::<u16>(),
            payload in proptest::collection::vec(any::<u8>(), 0..1024),
        ) {
            use Icmpv4Type::*;

            // ok case
            let header = Icmpv4Header {
                icmp_type: icmpv4_type.clone(),
                checksum: checksum,
            };
            let buffer = {
                let mut buffer = Vec::with_capacity(header.header_len() + payload.len());
                buffer.extend_from_slice(&header.to_bytes());

                match icmpv4_type {
                    // skip the payoad for the timestamp request (those don't have a payload)
                    TimestampRequest(_) | TimestampReply(_) => {},
                    _ => {
                        buffer.extend_from_slice(&[0u8;36]);
                    }
                }
                buffer
            };
            {
                let (actual, rest) = Icmpv4Header::from_slice(&buffer).unwrap();
                assert_eq!(actual, header);
                assert_eq!(rest, &buffer[header.header_len()..]);
            }

            // error case
            for bad_len in 0..header.header_len() {
                assert_eq!(
                    Icmpv4Header::from_slice(&buffer[..bad_len]),
                    Err(LenError{
                        required_len: if bad_len < Icmpv4Header::MIN_LEN {
                            Icmpv4Header::MIN_LEN
                        } else {
                            header.header_len()
                        },
                        len: bad_len,
                        len_source: LenSource::Slice,
                        layer: if bad_len < Icmpv4Header::MIN_LEN {
                            Layer::Icmpv4
                        } else {
                            use crate::Icmpv4Type::*;
                            match icmpv4_type {
                                TimestampRequest(_) => Layer::Icmpv4Timestamp,
                                TimestampReply(_) => Layer::Icmpv4TimestampReply,
                                _ => Layer::Icmpv4,
                            }
                        },
                        layer_start_offset: 0,
                    })
                );
            }
        }
    }

    proptest! {
        #[test]
        fn read(
            non_timestamp_type in any::<u8>().prop_filter(
                "type must be a non timestamp type",
                |v| *v != icmpv4::TYPE_TIMESTAMP_REPLY && *v != icmpv4::TYPE_TIMESTAMP
            ),
            non_zero_code in 1u8..=u8::MAX,
            bytes in any::<[u8;icmpv4::TimestampMessage::LEN]>()
        ) {
            for (type_u8, code_u8) in [
                // non timestamp
                (non_timestamp_type, bytes[1]),
                // timestamp with zero code
                (TYPE_TIMESTAMP_REPLY, 0u8),
                (TYPE_TIMESTAMP, 0u8),
                // timestamp with non-zero code
                (TYPE_TIMESTAMP_REPLY, non_zero_code),
                (TYPE_TIMESTAMP, non_zero_code),
            ] {
                let b = {
                    let mut b = bytes.clone();
                    b[0] = type_u8;
                    b[1] = code_u8;
                    b
                };
                let expected = Icmpv4Header::from_slice(&b).unwrap().0;

                // ok case
                {
                    let mut cursor = std::io::Cursor::new(&b);
                    let actual = Icmpv4Header::read(&mut cursor).unwrap();
                    assert_eq!(expected, actual);
                    assert_eq!(expected.header_len() as u64, cursor.position());
                }

                // size error case
                for bad_len in 0..expected.header_len() {
                    let mut cursor = std::io::Cursor::new(&(b.as_ref()[..bad_len]));
                    assert!(Icmpv4Header::read(&mut cursor).is_err());
                }
            }
        }
    }

    proptest! {
        #[test]
        fn write(
            icmpv4_type in icmpv4_type_any(),
            checksum in any::<u16>(),
        ) {
            let header = Icmpv4Header {
                icmp_type: icmpv4_type.clone(),
                checksum,
            };

            // normal write
            {
                let bytes = header.to_bytes();
                let mut buffer = Vec::with_capacity(header.header_len());
                header.write(&mut buffer).unwrap();
                assert_eq!(&bytes[..], &buffer[..]);
            }

            // error case
            {
                for bad_len in 0..icmpv4_type.header_len() {
                    let mut bytes = [0u8;Icmpv6Header::MAX_LEN];
                    let mut writer = std::io::Cursor::new(&mut bytes[..bad_len]);
                    header.write(&mut writer).unwrap_err();
                }
            }
        }
    }

    proptest! {
        #[test]
        fn header_len(
            checksum in any::<u16>(),
            icmpv4_type in icmpv4_type_any()
        ) {
            let header = Icmpv4Header{
                icmp_type: icmpv4_type.clone(),
                checksum,
            };
            assert_eq!(header.header_len(), icmpv4_type.header_len());
        }
    }

    proptest! {
        #[test]
        fn fixed_payload_size(
            checksum in any::<u16>(),
            icmpv4_type in icmpv4_type_any()
        ) {
            let header = Icmpv4Header{
                icmp_type: icmpv4_type.clone(),
                checksum,
            };
            assert_eq!(header.fixed_payload_size(), icmpv4_type.fixed_payload_size());
        }
    }

    proptest! {
        #[test]
        fn update_checksum(
            icmpv4_type in icmpv4_type_any(),
            checksum in any::<u16>(),
            payload in proptest::collection::vec(any::<u8>(), 0..1024),
        ) {
            let mut header = Icmpv4Header {
                icmp_type: icmpv4_type.clone(),
                checksum,
            };
            header.update_checksum(&payload);
            assert_eq!(header.checksum, icmpv4_type.calc_checksum(&payload));
        }
    }

    proptest! {
        #[test]
        #[rustfmt::skip]
        fn to_bytes(
            checksum in any::<u16>(),
            next_hop_mtu in any::<u16>(),
            redirect_code_u8 in 0u8..=3,
            gateway_internet_address in any::<[u8;4]>(),
            time_exceeded_code_u8 in 0u8..=1,
            id in any::<u16>(),
            seq in any::<u16>(),
            originate_timestamp in any::<u32>(),
            receive_timestamp in any::<u32>(),
            transmit_timestamp in any::<u32>(),
            pointer in any::<u8>(),
            unknown_type_u8 in any::<u8>(),
            unknown_code_u8 in any::<u8>(),
            bytes5to8 in any::<[u8;4]>(),
        ) {
            use Icmpv4Type::*;
            use arrayvec::ArrayVec;

            let ts = TimestampMessage{
                id,
                seq,
                originate_timestamp,
                receive_timestamp,
                transmit_timestamp,
            };
            let ts_bytes = {
                let id_be = id.to_be_bytes();
                let seq_be = seq.to_be_bytes();
                let ot = originate_timestamp.to_be_bytes();
                let rt = receive_timestamp.to_be_bytes();
                let tt = transmit_timestamp.to_be_bytes();
                [
                    0, 0, 0, 0,
                    id_be[0], id_be[1], seq_be[0], seq_be[1],
                    ot[0], ot[1], ot[2], ot[3],
                    rt[0], rt[1], rt[2], rt[3],
                    tt[0], tt[1], tt[2], tt[3],
                ]
            };
            let echo = IcmpEchoHeader{
                id,
                seq,
            };
            let redirect = RedirectHeader{
                code: RedirectCode::from_u8(redirect_code_u8).unwrap(),
                gateway_internet_address,
            };

            // test values with no need for subtests
            let random_values = [
                (
                    Unknown {
                        type_u8: unknown_type_u8,
                        code_u8: unknown_code_u8,
                        bytes5to8: bytes5to8,
                    },
                    8,
                    [
                        unknown_type_u8, unknown_code_u8, 0, 0,
                        bytes5to8[0], bytes5to8[1], bytes5to8[2], bytes5to8[3],
                        0, 0, 0, 0,
                        0, 0, 0, 0,
                        0, 0, 0, 0,
                    ],
                ),
                (
                    EchoReply(echo.clone()),
                    8,
                    {
                        let id_be = id.to_be_bytes();
                        let seq_be = seq.to_be_bytes();
                        [
                            TYPE_ECHO_REPLY, 0, 0, 0,
                            id_be[0], id_be[1], seq_be[0], seq_be[1],
                            0, 0, 0, 0,
                            0, 0, 0, 0,
                            0, 0, 0, 0,
                        ]
                    }
                ),

                (
                    Redirect(redirect),
                    8,
                    {
                        let gip = gateway_internet_address;
                        [
                            TYPE_REDIRECT, redirect_code_u8, 0, 0,
                            gip[0], gip[1], gip[2], gip[3],
                            0, 0, 0, 0,
                            0, 0, 0, 0,
                            0, 0, 0, 0,
                        ]
                    },
                ),
                (
                    EchoRequest(echo.clone()),
                    8,
                    {
                        let id_be = id.to_be_bytes();
                        let seq_be = seq.to_be_bytes();
                        [
                            TYPE_ECHO_REQUEST, 0, 0, 0,
                            id_be[0], id_be[1], seq_be[0], seq_be[1],
                            0, 0, 0, 0,
                            0, 0, 0, 0,
                            0, 0, 0, 0,
                        ]
                    }
                ),
                (
                    TimeExceeded(TimeExceededCode::from_u8(time_exceeded_code_u8).unwrap()),
                    8,
                    [
                        TYPE_TIME_EXCEEDED, time_exceeded_code_u8, 0, 0,
                        0, 0, 0, 0,
                        0, 0, 0, 0,
                        0, 0, 0, 0,
                        0, 0, 0, 0,
                    ],
                ),
                (
                    TimestampRequest(ts.clone()),
                    20,
                    {
                        let mut b = ts_bytes;
                        b[0] = TYPE_TIMESTAMP;
                        b
                    }
                ),
                (
                    TimestampReply(ts),
                    20,
                    {
                        let mut b = ts_bytes;
                        b[0] = TYPE_TIMESTAMP_REPLY;
                        b
                    }
                ),
            ];

            for t in random_values {
                let actual = Icmpv4Header{
                    icmp_type: t.0.clone(),
                    checksum,
                }.to_bytes();

                let mut expected = ArrayVec::from(t.2);
                unsafe {
                    expected.set_len(t.1)
                }
                let checksum_be = checksum.to_be_bytes();
                expected[2] = checksum_be[0];
                expected[3] = checksum_be[1];
                assert_eq!(expected, actual);
            }

            // destination unreachable
            {
                use DestUnreachableHeader::*;
                let tests = [
                    (CODE_DST_UNREACH_NET, [0;2], Network),
                    (CODE_DST_UNREACH_HOST, [0;2], Host),
                    (CODE_DST_UNREACH_PROTOCOL, [0;2], Protocol),
                    (CODE_DST_UNREACH_PORT, [0;2], Port),
                    (CODE_DST_UNREACH_NEED_FRAG, next_hop_mtu.to_be_bytes(), FragmentationNeeded{ next_hop_mtu }),
                    (CODE_DST_UNREACH_SOURCE_ROUTE_FAILED, [0;2], SourceRouteFailed),
                    (CODE_DST_UNREACH_NET_UNKNOWN, [0;2], NetworkUnknown),
                    (CODE_DST_UNREACH_HOST_UNKNOWN, [0;2], HostUnknown),
                    (CODE_DST_UNREACH_ISOLATED, [0;2], Isolated),
                    (CODE_DST_UNREACH_NET_PROHIB, [0;2], NetworkProhibited),
                    (CODE_DST_UNREACH_HOST_PROHIB, [0;2], HostProhibited),
                    (CODE_DST_UNREACH_TOS_NET, [0;2], TosNetwork),
                    (CODE_DST_UNREACH_TOS_HOST, [0;2], TosHost),
                    (CODE_DST_UNREACH_FILTER_PROHIB, [0;2], FilterProhibited),
                    (CODE_DST_UNREACH_HOST_PRECEDENCE_VIOLATION, [0;2], HostPrecedenceViolation),
                    (CODE_DST_UNREACH_PRECEDENCE_CUTOFF, [0;2], PrecedenceCutoff),
                ];
                for t in tests {
                    let checksum_be = checksum.to_be_bytes();
                    let mut expected = ArrayVec::from([
                        TYPE_DEST_UNREACH, t.0, checksum_be[0], checksum_be[1],
                        0, 0, t.1[0], t.1[1],
                        0, 0, 0, 0,
                        0, 0, 0, 0,
                        0, 0, 0, 0,
                    ]);
                    unsafe {
                        expected.set_len(8);
                    }
                    let actual = Icmpv4Header{
                        icmp_type: DestinationUnreachable(t.2.clone()),
                        checksum,
                    }.to_bytes();
                    assert_eq!(expected, actual);
                }
            }

            // parameter problem
            {
                use ParameterProblemHeader::*;
                let tests = [
                    (CODE_PARAMETER_PROBLEM_POINTER_INDICATES_ERROR, pointer, PointerIndicatesError(pointer)),
                    (CODE_PARAMETER_PROBLEM_MISSING_REQUIRED_OPTION, 0, MissingRequiredOption),
                    (CODE_PARAMETER_PROBLEM_BAD_LENGTH, 0, BadLength),
                ];
                for t in tests {
                    let checksum_be = checksum.to_be_bytes();
                    let mut expected = ArrayVec::from([
                        TYPE_PARAMETER_PROBLEM, t.0, checksum_be[0], checksum_be[1],
                        t.1, 0, 0, 0,
                        0, 0, 0, 0,
                        0, 0, 0, 0,
                        0, 0, 0, 0,
                    ]);
                    unsafe {
                        expected.set_len(8);
                    }
                    let actual = Icmpv4Header{
                        icmp_type: ParameterProblem(t.2.clone()),
                        checksum,
                    }.to_bytes();
                    assert_eq!(expected, actual);
                }
            }
        }
    }

    #[test]
    fn clone_eq() {
        use Icmpv4Type::*;
        let header = Icmpv4Header {
            icmp_type: ParameterProblem(ParameterProblemHeader::BadLength),
            checksum: 0,
        };
        assert_eq!(header.clone(), header);
    }

    #[test]
    fn debug() {
        use Icmpv4Type::*;
        let header = Icmpv4Header {
            icmp_type: ParameterProblem(ParameterProblemHeader::BadLength),
            checksum: 0,
        };
        assert_eq!(
            format!("{:?}", header),
            format!(
                "Icmpv4Header {{ icmp_type: {:?}, checksum: {:?} }}",
                header.icmp_type, header.checksum
            )
        );
    }
}
