use crate::{icmpv4::*, *};

/// A slice containing an ICMPv4 network package.
///
/// Struct allows the selective read of fields in the ICMPv4
/// packet.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Icmpv4Slice<'a> {
    pub(crate) slice: &'a [u8],
}

impl<'a> Icmpv4Slice<'a> {
    /// Creates a slice containing an ICMPv4 packet.
    ///
    /// # Errors
    ///
    /// The function will return an `Err` `err::LenError`
    /// if the given slice is too small or does not match the expected
    /// length in case of a timestamp message.
    #[inline]
    pub fn from_slice(slice: &'a [u8]) -> Result<Icmpv4Slice<'a>, err::LenError> {
        // check length
        if slice.len() < Icmpv4Header::MIN_LEN {
            return Err(err::LenError {
                required_len: Icmpv4Header::MIN_LEN,
                len: slice.len(),
                len_source: LenSource::Slice,
                layer: err::Layer::Icmpv4,
                layer_start_offset: 0,
            });
        }

        // SAFETY:
        // Safe as it is previously checked that the slice has
        // at least the length of Icmpv4Header::MIN_LEN (8).
        let icmp_type: u8 = unsafe { *slice.get_unchecked(0) };
        let icmp_code: u8 = unsafe { *slice.get_unchecked(1) };

        // check type specific length
        match icmp_type {
            TYPE_TIMESTAMP if 0 == icmp_code && TimestampMessage::LEN != slice.len() => {
                return Err(err::LenError {
                    required_len: TimestampMessage::LEN,
                    len: slice.len(),
                    len_source: LenSource::Slice,
                    layer: err::Layer::Icmpv4Timestamp,
                    layer_start_offset: 0,
                });
            }
            TYPE_TIMESTAMP_REPLY if 0 == icmp_code && TimestampMessage::LEN != slice.len() => {
                return Err(err::LenError {
                    required_len: TimestampMessage::LEN,
                    len: slice.len(),
                    len_source: LenSource::Slice,
                    layer: err::Layer::Icmpv4TimestampReply,
                    layer_start_offset: 0,
                });
            }
            _ => {}
        }

        //done
        Ok(Icmpv4Slice { slice })
    }

    /// Decode the header values into an [`Icmpv4Header`] struct.
    #[inline]
    pub fn header(&self) -> Icmpv4Header {
        let icmp_type = self.icmp_type();
        Icmpv4Header {
            icmp_type,
            checksum: self.checksum(),
        }
    }

    /// Number of bytes/octets that will be converted into a
    /// [`Icmpv4Header`] when [`Icmpv4Slice::header`] gets called.
    #[inline]
    pub fn header_len(&self) -> usize {
        match self.type_u8() {
            TYPE_TIMESTAMP | TYPE_TIMESTAMP_REPLY if 0 == self.code_u8() => TimestampMessage::LEN,
            _ => 8,
        }
    }

    /// Decode the header values (excluding the checksum) into an [`Icmpv4Type`] enum.
    pub fn icmp_type(&self) -> Icmpv4Type {
        use Icmpv4Type::*;

        unsafe fn timestamp_message(ptr: *const u8) -> TimestampMessage {
            TimestampMessage {
                id: get_unchecked_be_u16(ptr.add(4)),
                seq: get_unchecked_be_u16(ptr.add(6)),
                originate_timestamp: get_unchecked_be_u32(ptr.add(8)),
                receive_timestamp: get_unchecked_be_u32(ptr.add(12)),
                transmit_timestamp: get_unchecked_be_u32(ptr.add(16)),
            }
        }

        match self.type_u8() {
            TYPE_ECHO_REPLY if 0 == self.code_u8() => {
                return EchoReply(IcmpEchoHeader::from_bytes(self.bytes5to8()));
            }
            TYPE_DEST_UNREACH => {
                use DestUnreachableHeader::*;
                match self.code_u8() {
                    CODE_DST_UNREACH_NET => return DestinationUnreachable(Network),
                    CODE_DST_UNREACH_HOST => return DestinationUnreachable(Host),
                    CODE_DST_UNREACH_PROTOCOL => return DestinationUnreachable(Protocol),
                    CODE_DST_UNREACH_PORT => return DestinationUnreachable(Port),
                    CODE_DST_UNREACH_NEED_FRAG => {
                        return DestinationUnreachable(FragmentationNeeded {
                            // SAFETY:
                            // Safe as the contructor checks that the slice has
                            // at least the length of Icmpv4Header::MIN_LEN (8).
                            next_hop_mtu: unsafe {
                                get_unchecked_be_u16(self.slice.as_ptr().add(6))
                            },
                        });
                    }
                    CODE_DST_UNREACH_SOURCE_ROUTE_FAILED => {
                        return DestinationUnreachable(SourceRouteFailed)
                    }
                    CODE_DST_UNREACH_NET_UNKNOWN => return DestinationUnreachable(NetworkUnknown),
                    CODE_DST_UNREACH_HOST_UNKNOWN => return DestinationUnreachable(HostUnknown),
                    CODE_DST_UNREACH_ISOLATED => return DestinationUnreachable(Isolated),
                    CODE_DST_UNREACH_NET_PROHIB => {
                        return DestinationUnreachable(NetworkProhibited)
                    }
                    CODE_DST_UNREACH_HOST_PROHIB => return DestinationUnreachable(HostProhibited),
                    CODE_DST_UNREACH_TOS_NET => return DestinationUnreachable(TosNetwork),
                    CODE_DST_UNREACH_TOS_HOST => return DestinationUnreachable(TosHost),
                    CODE_DST_UNREACH_FILTER_PROHIB => {
                        return DestinationUnreachable(FilterProhibited)
                    }
                    CODE_DST_UNREACH_HOST_PRECEDENCE_VIOLATION => {
                        return DestinationUnreachable(HostPrecedenceViolation)
                    }
                    CODE_DST_UNREACH_PRECEDENCE_CUTOFF => {
                        return DestinationUnreachable(PrecedenceCutoff)
                    }
                    _ => {}
                }
            }
            TYPE_REDIRECT => {
                use RedirectCode::*;
                let code = match self.code_u8() {
                    CODE_REDIRECT_FOR_NETWORK => Some(RedirectForNetwork),
                    CODE_REDIRECT_FOR_HOST => Some(RedirectForHost),
                    CODE_REDIRECT_TYPE_OF_SERVICE_AND_NETWORK => {
                        Some(RedirectForTypeOfServiceAndNetwork)
                    }
                    CODE_REDIRECT_TYPE_OF_SERVICE_AND_HOST => Some(RedirectForTypeOfServiceAndHost),
                    _ => None,
                };
                if let Some(code) = code {
                    return Redirect(RedirectHeader {
                        code,
                        gateway_internet_address: self.bytes5to8(),
                    });
                }
            }
            TYPE_ECHO_REQUEST if 0 == self.code_u8() => {
                return EchoRequest(IcmpEchoHeader::from_bytes(self.bytes5to8()));
            }
            TYPE_TIME_EXCEEDED => {
                use TimeExceededCode::*;
                match self.code_u8() {
                    CODE_TIME_EXCEEDED_TTL_EXCEEDED_IN_TRANSIT => {
                        return TimeExceeded(TtlExceededInTransit);
                    }
                    CODE_TIME_EXCEEDED_FRAG_REASSEMBLY_TIME_EXCEEDED => {
                        return TimeExceeded(FragmentReassemblyTimeExceeded);
                    }
                    _ => {}
                }
            }
            TYPE_PARAMETER_PROBLEM => {
                use ParameterProblemHeader::*;
                match self.code_u8() {
                    CODE_PARAMETER_PROBLEM_POINTER_INDICATES_ERROR => {
                        return ParameterProblem(PointerIndicatesError(
                            // SAFETY:
                            // Safe as the contructor checks that the slice has
                            // at least the length of Icmpv4Header::MIN_LEN (8).
                            unsafe { *self.slice.get_unchecked(4) },
                        ));
                    }
                    CODE_PARAMETER_PROBLEM_MISSING_REQUIRED_OPTION => {
                        return ParameterProblem(MissingRequiredOption);
                    }
                    CODE_PARAMETER_PROBLEM_BAD_LENGTH => {
                        return ParameterProblem(BadLength);
                    }
                    _ => {}
                }
            }
            TYPE_TIMESTAMP if 0 == self.code_u8() => {
                // SAFETY:
                // Safe as the contructor checks that the slice has
                // the length of TimestampMessage::SERIALIZED_SIZE (20).
                unsafe {
                    return TimestampRequest(timestamp_message(self.slice.as_ptr()));
                }
            }
            TYPE_TIMESTAMP_REPLY if 0 == self.code_u8() => {
                // SAFETY:
                // Safe as the contructor checks that the slice has
                // the length of TimestampMessage::SERIALIZED_SIZE (20).
                unsafe {
                    return TimestampReply(timestamp_message(self.slice.as_ptr()));
                }
            }
            _ => {}
        }

        Unknown {
            type_u8: self.type_u8(),
            code_u8: self.code_u8(),
            bytes5to8: self.bytes5to8(),
        }
    }

    /// Returns "type" value in the ICMPv4 header.
    #[inline]
    pub fn type_u8(&self) -> u8 {
        // SAFETY:
        // Safe as the contructor checks that the slice has
        // at least the length of Icmpv4Header::MIN_LEN (8).
        unsafe { *self.slice.get_unchecked(0) }
    }

    /// Returns "code" value in the ICMPv4 header.
    #[inline]
    pub fn code_u8(&self) -> u8 {
        // SAFETY:
        // Safe as the contructor checks that the slice has
        // at least the length of Icmpv4Header::MIN_LEN (8).
        unsafe { *self.slice.get_unchecked(1) }
    }

    /// Returns "checksum" value in the ICMPv4 header.
    #[inline]
    pub fn checksum(&self) -> u16 {
        // SAFETY:
        // Safe as the contructor checks that the slice has
        // at least the length of Icmpv4Header::MIN_LEN (8).
        unsafe { get_unchecked_be_u16(self.slice.as_ptr().add(2)) }
    }

    /// Returns the bytes from position 4 till and including the 8th position
    /// in the ICMPv4 header.
    ///
    /// These bytes located at th 5th, 6th, 7th and 8th position of the ICMP
    /// packet can depending on the ICMPv4 type and code contain additional data.
    #[inline]
    pub fn bytes5to8(&self) -> [u8; 4] {
        // SAFETY:
        // Safe as the contructor checks that the slice has
        // at least the length of Icmpv4Header::MIN_LEN (8).
        unsafe {
            [
                *self.slice.get_unchecked(4),
                *self.slice.get_unchecked(5),
                *self.slice.get_unchecked(6),
                *self.slice.get_unchecked(7),
            ]
        }
    }

    /// Returns a slice to the bytes not covered by `.header()`.
    ///
    /// The contents of the slice returned by `payload()` depends on the type
    /// and code of the ICMP packet:
    ///
    /// | `.header().icmp_type` or `.icmp_type()`                                                                                                    | Payload Content                                                              |
    /// |--------------------------------------------------------------------------------------------------------------------------------------------|------------------------------------------------------------------------------|
    /// | [`Icmpv4Type::EchoReply`]<br>[`Icmpv4Type::EchoRequest`]<br>                                                                               | Data part of the echo message                                                |
    /// | [`Icmpv4Type::DestinationUnreachable`]<br>[`Icmpv4Type::Redirect`]<br>[`Icmpv4Type::TimeExceeded`]<br>[`Icmpv4Type::ParameterProblem`]<br> | Internet Header + 64 bits of Original Data Datagram causing the ICMP message |
    /// | [`Icmpv4Type::TimestampRequest`]<br>[`Icmpv4Type::TimestampReply`]<br>                                                                     | Nothing                                                                      |
    /// | [`Icmpv4Type::Unknown`]                                                                                                                    | Everything after the 8th byte/octet of the ICMP packet.                      |
    #[inline]
    pub fn payload(&self) -> &'a [u8] {
        // explicitly inlined the code to determine the
        // length of the payload to make the cecking of the
        // usafe code easier.
        let header_len = match self.type_u8() {
            // SAFETY:
            // Length safe as the contructor checks that the slice has
            // the length of TimestampMessage::SERIALIZED_SIZE (20)
            // for the messages types TYPE_TIMESTAMP and TYPE_TIMESTAMP_REPLY.
            TYPE_TIMESTAMP | TYPE_TIMESTAMP_REPLY if 0 == self.code_u8() => TimestampMessage::LEN,
            // SAFETY:
            // Length safe as the contructor checks that the slice has
            // at least the length of Icmpv4Header::MIN_LEN(8) for
            // all message types.
            _ => 8,
        };
        // SAFETY:
        // Lengths have been depending on type in the constructor of the
        // ICMPv4Slice.
        unsafe {
            core::slice::from_raw_parts(
                self.slice.as_ptr().add(header_len),
                self.slice.len() - header_len,
            )
        }
    }

    /// Returns the slice containing the ICMPv4 packet.
    #[inline]
    pub fn slice(&self) -> &'a [u8] {
        self.slice
    }
}

#[cfg(test)]
mod test {
    use super::*;
    use alloc::{format, vec::Vec};
    use proptest::prelude::*;

    #[test]
    fn from_slice() {
        // normal case
        {
            let bytes = [0u8; 8];
            let slice = Icmpv4Slice::from_slice(&bytes).unwrap();
            assert_eq!(slice.slice(), &bytes);
        }

        // smaller then min size error
        for bad_len in 0..8 {
            let bytes = [0u8; 8];
            assert_eq!(
                Icmpv4Slice::from_slice(&bytes[..bad_len]).unwrap_err(),
                err::LenError {
                    required_len: Icmpv4Header::MIN_LEN,
                    len: bad_len,
                    len_source: LenSource::Slice,
                    layer: err::Layer::Icmpv4,
                    layer_start_offset: 0,
                }
            );
        }

        // timestamp tests
        for ts_type_u8 in [TYPE_TIMESTAMP, TYPE_TIMESTAMP_REPLY] {
            let bytes = {
                let mut bytes = [0u8; 26];
                bytes[0] = ts_type_u8;
                bytes
            };

            // valid timestamps
            {
                let slice = Icmpv4Slice::from_slice(&bytes[..20]).unwrap();
                assert_eq!(slice.slice(), &bytes[..20]);
            }

            // too short timestamps
            for bad_len in 8..20 {
                assert_eq!(
                    Icmpv4Slice::from_slice(&bytes[..bad_len]).unwrap_err(),
                    err::LenError {
                        required_len: TimestampMessage::LEN,
                        len: bad_len,
                        len_source: LenSource::Slice,
                        layer: if ts_type_u8 == TYPE_TIMESTAMP {
                            err::Layer::Icmpv4Timestamp
                        } else {
                            err::Layer::Icmpv4TimestampReply
                        },
                        layer_start_offset: 0,
                    }
                );
            }

            // too large timestamps
            for bad_len in 21..26 {
                assert_eq!(
                    Icmpv4Slice::from_slice(&bytes[..bad_len]).unwrap_err(),
                    err::LenError {
                        required_len: TimestampMessage::LEN,
                        len: bad_len,
                        len_source: LenSource::Slice,
                        layer: if ts_type_u8 == TYPE_TIMESTAMP {
                            err::Layer::Icmpv4Timestamp
                        } else {
                            err::Layer::Icmpv4TimestampReply
                        },
                        layer_start_offset: 0,
                    }
                );
            }

            // timestamp with a non zero code
            for code_u8 in 1..=u8::MAX {
                let mut bytes = [0u8; 20];
                bytes[0] = ts_type_u8;
                bytes[1] = code_u8;
                let slice = Icmpv4Slice::from_slice(&bytes[..8]).unwrap();
                assert_eq!(slice.slice(), &bytes[..8]);
            }
        }
    }

    proptest! {
        #[test]
        fn header(bytes in any::<[u8;20]>()) {
            let slice = Icmpv4Slice::from_slice(&bytes).unwrap();
            assert_eq!(
                Icmpv4Header {
                    icmp_type: slice.icmp_type(),
                    checksum: slice.checksum(),
                },
                slice.header()
            );
        }
    }

    #[test]
    fn header_len() {
        use Icmpv4Type::*;
        let dummy_ts = TimestampMessage {
            id: 0,
            seq: 0,
            originate_timestamp: 0,
            receive_timestamp: 0,
            transmit_timestamp: 0,
        };
        let dummy_echo = IcmpEchoHeader { id: 0, seq: 0 };
        let dummy_redirect = RedirectHeader {
            code: RedirectCode::RedirectForNetwork,
            gateway_internet_address: [0; 4],
        };
        let tests = [
            (Unknown {
                type_u8: u8::MAX,
                code_u8: 0,
                bytes5to8: [0; 4],
            }),
            (EchoReply(dummy_echo)),
            (DestinationUnreachable(DestUnreachableHeader::Network)),
            (Redirect(dummy_redirect)),
            (EchoRequest(dummy_echo)),
            (TimeExceeded(TimeExceededCode::TtlExceededInTransit)),
            (ParameterProblem(ParameterProblemHeader::BadLength)),
            (TimestampRequest(dummy_ts.clone())),
            // check that a non zero code value return 8
            (Unknown {
                type_u8: TYPE_TIMESTAMP,
                code_u8: 1,
                bytes5to8: [0; 4],
            }),
            (TimestampReply(dummy_ts)),
            // check that a non zero code value return 8
            (Unknown {
                type_u8: TYPE_TIMESTAMP_REPLY,
                code_u8: 1,
                bytes5to8: [0; 4],
            }),
        ];
        for t in tests {
            assert_eq!(
                t.header_len(),
                Icmpv4Slice::from_slice(&Icmpv4Header::new(t).to_bytes())
                    .unwrap()
                    .header_len()
            );
        }
    }

    proptest! {
        #[test]
        fn icmp_type(base_bytes in any::<[u8;20]>()) {

            use Icmpv4Type::*;

            let gen_bytes = |type_u8: u8, code_u8: u8| -> [u8;20] {
                let mut bytes = base_bytes;
                bytes[0] = type_u8;
                bytes[1] = code_u8;
                bytes
            };

            let assert_unknown = |type_u8: u8, code_u8: u8| {
                let bytes = gen_bytes(type_u8, code_u8);
                let slice = Icmpv4Slice::from_slice(&bytes).unwrap();
                assert_eq!(
                    slice.icmp_type(),
                    Unknown{
                        type_u8,
                        code_u8,
                        bytes5to8: slice.bytes5to8(),
                    }
                );
            };

            // unknown types
            for type_u8 in 0..=u8::MAX{
                match type_u8 {
                    TYPE_ECHO_REPLY | TYPE_DEST_UNREACH | TYPE_REDIRECT |
                    TYPE_ECHO_REQUEST | TYPE_TIME_EXCEEDED | TYPE_PARAMETER_PROBLEM |
                    TYPE_TIMESTAMP | TYPE_TIMESTAMP_REPLY => {},
                    type_u8 => {
                        assert_unknown(type_u8, base_bytes[1]);
                    }
                }
            }

            // echo reply
            {
                // matching code
                {
                    let bytes = gen_bytes(TYPE_ECHO_REPLY, 0);
                    let slice = Icmpv4Slice::from_slice(&bytes).unwrap();
                    assert_eq!(
                        slice.icmp_type(),
                        EchoReply(IcmpEchoHeader::from_bytes(slice.bytes5to8()))
                    );
                }

                // unknown code
                for unknow_code in 1..=u8::MAX {
                    assert_unknown(TYPE_ECHO_REPLY, unknow_code);
                }
            }

            // destination unreachable
            {
                use DestUnreachableHeader::*;
                // trivial code values
                {
                    let trivial_tests = [
                        (CODE_DST_UNREACH_NET, Network),
                        (CODE_DST_UNREACH_HOST, Host),
                        (CODE_DST_UNREACH_PROTOCOL, Protocol),
                        (CODE_DST_UNREACH_PORT, Port),
                        // need frag skipped as contains an additional value
                        (CODE_DST_UNREACH_SOURCE_ROUTE_FAILED, SourceRouteFailed),
                        (CODE_DST_UNREACH_NET_UNKNOWN, NetworkUnknown),
                        (CODE_DST_UNREACH_HOST_UNKNOWN, HostUnknown),
                        (CODE_DST_UNREACH_ISOLATED, Isolated),
                        (CODE_DST_UNREACH_NET_PROHIB, NetworkProhibited),
                        (CODE_DST_UNREACH_HOST_PROHIB, HostProhibited),
                        (CODE_DST_UNREACH_TOS_NET, TosNetwork),
                        (CODE_DST_UNREACH_TOS_HOST, TosHost),
                        (CODE_DST_UNREACH_FILTER_PROHIB, FilterProhibited),
                        (CODE_DST_UNREACH_HOST_PRECEDENCE_VIOLATION, HostPrecedenceViolation),
                        (CODE_DST_UNREACH_PRECEDENCE_CUTOFF, PrecedenceCutoff),
                    ];

                    for (code_u8, expected) in trivial_tests {
                        let bytes = gen_bytes(TYPE_DEST_UNREACH, code_u8);
                        let slice = Icmpv4Slice::from_slice(&bytes).unwrap();
                        assert_eq!(
                            slice.icmp_type(),
                            DestinationUnreachable(expected)
                        );
                    }
                }

                // need frag
                {
                    let bytes = gen_bytes(TYPE_DEST_UNREACH, CODE_DST_UNREACH_NEED_FRAG);
                    let slice = Icmpv4Slice::from_slice(&bytes).unwrap();
                    assert_eq!(
                        slice.icmp_type(),
                        DestinationUnreachable(FragmentationNeeded {
                            next_hop_mtu: u16::from_be_bytes([bytes[6], bytes[7]])
                        })
                    );
                }

                // unknown codes
                for unknow_code in 16..=u8::MAX {
                    assert_unknown(TYPE_ECHO_REPLY, unknow_code);
                }
            }

            // redirect
            {
                use RedirectCode::*;
                // known codes
                {
                    let trivial_tests = [
                        (CODE_REDIRECT_FOR_NETWORK, RedirectForNetwork),
                        (CODE_REDIRECT_FOR_HOST, RedirectForHost),
                        (CODE_REDIRECT_TYPE_OF_SERVICE_AND_NETWORK, RedirectForTypeOfServiceAndNetwork),
                        (CODE_REDIRECT_TYPE_OF_SERVICE_AND_HOST, RedirectForTypeOfServiceAndHost),
                    ];

                    for (code_u8, expected) in trivial_tests {
                        let bytes = gen_bytes(TYPE_REDIRECT, code_u8);
                        let slice = Icmpv4Slice::from_slice(&bytes).unwrap();
                        assert_eq!(
                            slice.icmp_type(),
                            Redirect(RedirectHeader{
                                code: expected,
                                gateway_internet_address: slice.bytes5to8(),
                            })
                        );
                    }
                }

                // unknown codes
                for unknow_code in 4..=u8::MAX {
                    assert_unknown(TYPE_REDIRECT, unknow_code);
                }
            }

            // echo request
            {
                // matching code
                {
                    let bytes = gen_bytes(TYPE_ECHO_REQUEST, 0);
                    let slice = Icmpv4Slice::from_slice(&bytes).unwrap();
                    assert_eq!(
                        slice.icmp_type(),
                        EchoRequest(IcmpEchoHeader::from_bytes(slice.bytes5to8()))
                    );
                }

                // unknown code
                for unknow_code in 1..=u8::MAX {
                    assert_unknown(TYPE_ECHO_REQUEST, unknow_code);
                }
            }

            // time exceeded
            {
                use TimeExceededCode::*;
                // known codes
                {
                    let trivial_tests = [
                        (CODE_TIME_EXCEEDED_TTL_EXCEEDED_IN_TRANSIT, TtlExceededInTransit),
                        (CODE_TIME_EXCEEDED_FRAG_REASSEMBLY_TIME_EXCEEDED, FragmentReassemblyTimeExceeded),
                    ];

                    for (code_u8, expected) in trivial_tests {
                        let bytes = gen_bytes(TYPE_TIME_EXCEEDED, code_u8);
                        let slice = Icmpv4Slice::from_slice(&bytes).unwrap();
                        assert_eq!(
                            slice.icmp_type(),
                            TimeExceeded(expected)
                        );
                    }
                }

                // unknown code
                for unknow_code in 2..=u8::MAX {
                    assert_unknown(TYPE_TIME_EXCEEDED, unknow_code);
                }
            }

            // parameter porblem
            {
                use ParameterProblemHeader::*;
                // trivial code values
                {
                    let trivial_tests = [
                        (CODE_PARAMETER_PROBLEM_MISSING_REQUIRED_OPTION, MissingRequiredOption),
                        (CODE_PARAMETER_PROBLEM_BAD_LENGTH, BadLength),
                    ];

                    for (code_u8, expected) in trivial_tests {
                        let bytes = gen_bytes(TYPE_PARAMETER_PROBLEM, code_u8);
                        let slice = Icmpv4Slice::from_slice(&bytes).unwrap();
                        assert_eq!(
                            slice.icmp_type(),
                            ParameterProblem(expected)
                        );
                    }
                }

                // with pointer
                {
                    let bytes = gen_bytes(TYPE_PARAMETER_PROBLEM, CODE_PARAMETER_PROBLEM_POINTER_INDICATES_ERROR);
                    let slice = Icmpv4Slice::from_slice(&bytes).unwrap();
                    assert_eq!(
                        slice.icmp_type(),
                        ParameterProblem(PointerIndicatesError(bytes[4]))
                    );
                }

                // unknown codes
                for unknow_code in 3..=u8::MAX {
                    assert_unknown(TYPE_PARAMETER_PROBLEM, unknow_code);
                }
            }

            // timestamp
            {
                // matching code
                {
                    let bytes = gen_bytes(TYPE_TIMESTAMP, 0);
                    let slice = Icmpv4Slice::from_slice(&bytes).unwrap();
                    assert_eq!(
                        slice.icmp_type(),
                        TimestampRequest(TimestampMessage::from_bytes([
                            bytes[4], bytes[5], bytes[6], bytes[7],
                            bytes[8], bytes[9], bytes[10], bytes[11],
                            bytes[12], bytes[13], bytes[14], bytes[15],
                            bytes[16], bytes[17], bytes[18], bytes[19],
                        ]))
                    );
                }

                // unknown code
                for unknow_code in 1..=u8::MAX {
                    assert_unknown(TYPE_TIMESTAMP, unknow_code);
                }
            }

            // timestamp reply
            {
                // matching code
                {
                    let bytes = gen_bytes(TYPE_TIMESTAMP_REPLY, 0);
                    let slice = Icmpv4Slice::from_slice(&bytes).unwrap();
                    assert_eq!(
                        slice.icmp_type(),
                        TimestampReply(TimestampMessage::from_bytes([
                            bytes[4], bytes[5], bytes[6], bytes[7],
                            bytes[8], bytes[9], bytes[10], bytes[11],
                            bytes[12], bytes[13], bytes[14], bytes[15],
                            bytes[16], bytes[17], bytes[18], bytes[19],
                        ]))
                    );
                }

                // unknown code
                for unknow_code in 1..=u8::MAX {
                    assert_unknown(TYPE_TIMESTAMP_REPLY, unknow_code);
                }
            }
        }
    }

    proptest! {
        #[test]
        fn type_u8(bytes in any::<[u8;20]>()) {
            assert_eq!(
                bytes[0],
                Icmpv4Slice::from_slice(&bytes).unwrap().type_u8(),
            );
        }
    }

    proptest! {
        #[test]
        fn code_u8(bytes in any::<[u8;20]>()) {
            assert_eq!(
                bytes[1],
                Icmpv4Slice::from_slice(&bytes).unwrap().code_u8(),
            );
        }
    }

    proptest! {
        #[test]
        fn checksum(bytes in any::<[u8;20]>()) {
            assert_eq!(
                u16::from_be_bytes([bytes[2], bytes[3]]),
                Icmpv4Slice::from_slice(&bytes).unwrap().checksum(),
            );
        }
    }

    proptest! {
        #[test]
        fn bytes5to8(bytes in any::<[u8;20]>()) {
            assert_eq!(
                [bytes[4], bytes[5], bytes[6], bytes[7]],
                Icmpv4Slice::from_slice(&bytes).unwrap().bytes5to8(),
            );
        }
    }

    proptest! {
        #[test]
        fn payload(
            payload in proptest::collection::vec(any::<u8>(), 8..26)
        ) {
            use Icmpv4Type::*;
            let dummy_ts = TimestampMessage{
                id: 0,
                seq: 0,
                originate_timestamp: 0,
                receive_timestamp: 0,
                transmit_timestamp: 0,
            };
            let dummy_echo = IcmpEchoHeader{
                id: 0,
                seq: 0,
            };
            let dummy_redirect = RedirectHeader{
                code: RedirectCode::RedirectForNetwork,
                gateway_internet_address: [0;4],
            };
            // tests with variable payloads
            {
                let var_tests = [
                    Unknown{type_u8: 0, code_u8: 0, bytes5to8: [0;4]},
                    EchoReply(dummy_echo),
                    DestinationUnreachable(DestUnreachableHeader::Network),
                    Redirect(dummy_redirect),
                    EchoRequest(dummy_echo),
                    TimeExceeded(TimeExceededCode::TtlExceededInTransit),
                    ParameterProblem(ParameterProblemHeader::BadLength),
                    // timestamps with non-zero code values
                    Unknown{type_u8: TYPE_TIMESTAMP, code_u8: 1, bytes5to8: [0;4]},
                    Unknown{type_u8: TYPE_TIMESTAMP_REPLY, code_u8: 1, bytes5to8: [0;4]},
                ];
                for t in var_tests {

                    let mut bytes = Vec::with_capacity(t.header_len() + payload.len());
                    Icmpv4Header::new(t.clone()).write(&mut bytes).unwrap();
                    bytes.extend_from_slice(&payload);

                    assert_eq!(
                        &payload[..],
                        Icmpv4Slice::from_slice(&bytes).unwrap().payload()
                    );
                }
            }
            // tests with fixed payload sizes
            {
                let fixed_tests = [
                    (0, TimestampRequest(dummy_ts.clone())),
                    (0, TimestampReply(dummy_ts)),
                ];
                for t in fixed_tests {
                    let mut bytes = Vec::with_capacity(t.1.header_len() + t.0);
                    Icmpv4Header::new(t.1.clone()).write(&mut bytes).unwrap();
                    bytes.extend_from_slice(&payload[..t.0]);

                    assert_eq!(
                        &payload[..t.0],
                        Icmpv4Slice::from_slice(&bytes).unwrap().payload()
                    );
                }
            }
        }
    }

    proptest! {
        #[test]
        fn slice(bytes in proptest::collection::vec(any::<u8>(), 20..1024)) {
            let slice = if bytes[0] == TYPE_TIMESTAMP || bytes[0] == TYPE_TIMESTAMP_REPLY {
                &bytes[..20]
            } else {
                &bytes[..]
            };
            assert_eq!(
                slice,
                Icmpv4Slice::from_slice(slice).unwrap().slice(),
            );
        }
    }

    proptest! {
        #[test]
        fn clone_eq(bytes in any::<[u8;20]>()) {
            let slice = Icmpv4Slice::from_slice(&bytes).unwrap();
            assert_eq!(slice, slice.clone());
        }
    }

    proptest! {
        #[test]
        fn debug(bytes in any::<[u8;20]>()) {
            let slice = Icmpv4Slice::from_slice(&bytes).unwrap();
            assert_eq!(
                format!("{:?}", slice),
                format!("Icmpv4Slice {{ slice: {:?} }}", &bytes[..])
            );
        }
    }
}
