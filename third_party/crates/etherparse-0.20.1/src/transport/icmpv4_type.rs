use crate::*;

/// Starting contents of an ICMPv4 packet without the checksum.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Icmpv4Type {
    /// In case of an unknown ICMP type and code combination is received the
    /// header elements are stored raw in this enum value. The `Unknown` value can
    /// also be passed to the `Icmpv4Header::write` function to write arbitrary ICMP
    /// packets.
    ///
    /// # What is part of the header for `Icmpv4Type::Unknown`?
    ///
    /// For unknown ICMP type & code combination the first 8 bytes are stored
    /// in the [`Icmpv4Header`] and the rest is stored in the payload
    /// ([`Icmpv4Slice::payload`] or [`PacketHeaders::payload`]).
    ///
    ///
    /// ```text
    /// 0               1               2               3               4
    /// +---------------------------------------------------------------+  -
    /// |     type_u8   |    code_u8    |  checksum (in Icmpv4Header)   |  |
    /// +---------------------------------------------------------------+  | part of header & type
    /// |                          bytes5to8                            |  ↓
    /// +---------------------------------------------------------------+  -
    /// |                                                               |  |
    /// ...                           ...                             ...  | part of payload
    /// |                                                               |  ↓
    /// +---------------------------------------------------------------+  -
    /// ```
    Unknown {
        /// ICMP type (present in the first byte of the ICMP packet).
        type_u8: u8,
        /// ICMP code (present in the 2nd byte of the ICMP packet).
        code_u8: u8,
        /// Bytes located at th 5th, 6th, 7th and 8th position of the ICMP packet.
        bytes5to8: [u8; 4],
    },

    /// Response to an `EchoRequest` message (defined in RFC792).
    ///
    /// # What is part of the header for `Icmpv4Type::EchoReply`?
    ///
    /// For the [`Icmpv4Type::EchoReply`] type the first 8 bytes/octets of the
    /// ICMP packet are part of the header. This includes the `id` and `seq`
    /// fields. The data part of the ICMP Echo Reply packet is part of the
    /// payload ([`Icmpv4Slice::payload`] or [`PacketHeaders::payload`])
    /// and not part of the [`Icmpv4Header`].
    ///
    /// ```text
    /// 0               1               2               3               4
    /// +---------------------------------------------------------------+  -
    /// |       0       |       0       |  checksum (in Icmpv4Header)   |  |
    /// +---------------------------------------------------------------+  | part of header & type
    /// |          [value].id           |         [value].seq           |  ↓
    /// +---------------------------------------------------------------+  -
    /// |                                                               |  |
    /// ...                          <data>                           ...  | part of payload
    /// |                                                               |  ↓
    /// +---------------------------------------------------------------+  -
    /// ```
    EchoReply(IcmpEchoHeader),

    /// Message sent to inform the client that the destination is unreachable for
    /// some reason (defined in RFC792).
    ///
    /// # What is part of the header for `Icmpv4Type::DestinationUnreachable`?
    ///
    /// For the [`Icmpv4Type::DestinationUnreachable`] type the first 8 bytes/octets
    /// of the ICMP packet are part of the header. This includes the `next_hop_mtu`
    /// field. The `unused` part is not stored and droped. The offending packet
    /// is stored in the payload part of the packet ([`Icmpv4Slice::payload`] or
    /// [`PacketHeaders::payload`]) and is not part of the [`Icmpv4Header`].
    ///
    /// ```text
    /// 0               1               2               3               4
    /// +---------------------------------------------------------------+  -
    /// |       3       |       0       |  checksum (in Icmpv4Header)   |  |
    /// +---------------------------------------------------------------+  | part of header & type
    /// |[v].next_hop...|                    <unused>                   |  ↓
    /// +---------------------------------------------------------------+  -
    /// |                                                               |  |
    /// ...    Internet Header + 64 bits of Original Data Datagram    ...  | part of payload
    /// |                                                               |  ↓
    /// +---------------------------------------------------------------+  -
    /// ```
    DestinationUnreachable(icmpv4::DestUnreachableHeader),

    /// Requests data packets be sent on an alternative route (defined in RFC792).
    ///
    /// # What is part of the header for `Icmpv4Type::Redirect`?
    ///
    /// For the [`Icmpv4Type::Redirect`] type the first 8 bytes/octets of the ICMP
    /// packet are part of the header. This includes the `gateway_internet_address`
    /// field. The offending packet is stored in the payload part of the packet
    /// ([`Icmpv4Slice::payload`] or [`PacketHeaders::payload`]) and is not part of
    /// the [`Icmpv4Header`].
    ///
    /// ```text
    /// 0               1               2               3               4
    /// +---------------------------------------------------------------+  -
    /// |       5       | [value].code  |  checksum (in Icmpv4Header)   |  |
    /// +---------------------------------------------------------------+  | part of header & type
    /// |                [value].gateway_internet_address               |  ↓
    /// +---------------------------------------------------------------+  -
    /// |                                                               |  |
    /// ..     Internet Header + 64 bits of Original Data Datagram    ...  | part of payload
    /// |                                                               |  ↓
    /// +---------------------------------------------------------------+  -
    Redirect(icmpv4::RedirectHeader),

    /// Requesting an `EchoReply` from the receiver (defined in RFC792)
    ///
    /// # What is part of the header for `Icmpv4Type::EchoRequest`?
    ///
    /// For the [`Icmpv4Type::EchoRequest`] type the first 8 bytes/octets of the
    /// ICMP packet are part of the header. This includes the `id` and `seq`
    /// fields. The data part of the ICMP echo request packet is part of the payload
    /// ([`Icmpv4Slice::payload`] & [`PacketHeaders::payload`]) and not part of the
    /// [`Icmpv4Header`].
    ///
    /// ```text
    /// 0               1               2               3               4
    /// +---------------------------------------------------------------+  -
    /// |       8       |       0       |  checksum (in Icmpv4Header)   |  |
    /// +---------------------------------------------------------------+  | part of header & type
    /// |          [value].id           |         [value].seq           |  ↓
    /// +---------------------------------------------------------------+  -
    /// |                                                               |  |
    /// ...                          <data>                           ...  | part of payload
    /// |                                                               |  ↓
    /// +---------------------------------------------------------------+  -
    /// ```
    EchoRequest(IcmpEchoHeader),

    /// Generated when a datagram had to be discarded due to the time to live field
    /// reaching zero (defined in RFC792).
    ///
    /// # What is part of the header for `Icmpv4Type::TimeExceeded`?
    ///
    /// For the `Icmpv4Type::TimeExceeded` type the first 8 bytes/octets of the ICMP
    /// packet are part of the header. The `unused` part is not stored and droped.
    /// The offending packet is stored in the payload part of the packet
    /// ([`Icmpv4Slice::payload`] & [`PacketHeaders::payload`]) and is not part of
    /// the [`Icmpv4Header`].
    ///
    /// ```text
    /// 0               1               2               3               4
    /// +---------------------------------------------------------------+  -
    /// |       11      | [value as u8] |  checksum (in Icmpv4Header)   |  |
    /// +---------------------------------------------------------------+  | part of header & type
    /// |                           <unused>                            |  ↓
    /// +---------------------------------------------------------------+  -
    /// |                                                               |  |
    /// ...    Internet Header + 64 bits of Original Data Datagram    ...  | part of payload
    /// |                                                               |  ↓
    /// +---------------------------------------------------------------+  -
    TimeExceeded(icmpv4::TimeExceededCode),

    /// Sent if there is a problem with a parameter in a received packet.
    ///
    /// # What is part of the header for `Icmpv4Type::ParameterProblem`?
    ///
    /// For the `Icmpv4Type::ParameterProblem` type the first 8 bytes/octets of the ICMP
    /// packet are part of the header. The `unused` part is not stored and droped.
    /// The offending packet is stored in the payload part of the packet
    /// ([`Icmpv4Slice::payload`] & [`PacketHeaders::payload`]) and is not part of
    /// the [`Icmpv4Header`].
    ///
    /// ```text
    /// 0               1               2               3               4
    /// +---------------------------------------------------------------+  -
    /// |       12      | [v].code_u8() |  checksum (in Icmpv4Header)   |  |
    /// +---------------------------------------------------------------+  | part of header & type
    /// |[value].pointer|                   <unused>                    |  ↓
    /// +---------------------------------------------------------------+  -
    /// |                                                               |  |
    /// ...    Internet Header + 64 bits of Original Data Datagram    ...  | part of payload
    /// |                                                               |  ↓
    /// +---------------------------------------------------------------+  -
    ParameterProblem(icmpv4::ParameterProblemHeader),

    /// Timestamp is used for time synchronization.
    ///
    /// # What is part of the header for `Icmpv4Type::TimestampRequest`?
    ///
    /// For the `Icmpv4Type::TimestampRequest` type the entire ICMP packet is
    /// contained within the header. The payload data is empty.
    TimestampRequest(icmpv4::TimestampMessage),

    /// Anwser to a `TimestampRequest` message.
    ///
    /// # What is part of the header for `Icmpv4Type::TimestampReply`?
    ///
    /// For the `Icmpv4Type::TimestampReply` type the entire ICMP packet is
    /// contained within the header. The payload data is empty.
    TimestampReply(icmpv4::TimestampMessage),
}

impl Icmpv4Type {
    /// Returns the length in bytes/octets of the header of
    /// this ICMPv4 message type.
    #[inline]
    pub fn header_len(&self) -> usize {
        use Icmpv4Type::*;
        match self {
            Unknown {
                type_u8: _,
                code_u8: _,
                bytes5to8: _,
            }
            | EchoReply(_)
            | DestinationUnreachable(_)
            | Redirect(_)
            | EchoRequest(_)
            | TimeExceeded(_)
            | ParameterProblem(_) => 8,
            TimestampRequest(_) | TimestampReply(_) => icmpv4::TimestampMessage::LEN,
        }
    }

    /// If the ICMP type has a fixed size returns the number of
    /// bytes that should be present after the header of this type.
    #[inline]
    pub fn fixed_payload_size(&self) -> Option<usize> {
        use Icmpv4Type::*;
        match self {
            Unknown {
                type_u8: _,
                code_u8: _,
                bytes5to8: _,
            }
            | EchoReply(_)
            | DestinationUnreachable(_)
            | Redirect(_)
            | EchoRequest(_)
            | TimeExceeded(_)
            | ParameterProblem(_) => None,
            TimestampRequest(_) | TimestampReply(_) => Some(0),
        }
    }

    /// Calculate the ICMP checksum value.
    pub fn calc_checksum(&self, payload: &[u8]) -> u16 {
        use crate::{icmpv4::*, Icmpv4Type::*};
        match self {
            Unknown {
                type_u8,
                code_u8,
                bytes5to8,
            } => checksum::Sum16BitWords::new()
                .add_2bytes([*type_u8, *code_u8])
                .add_4bytes(*bytes5to8),
            EchoReply(header) => checksum::Sum16BitWords::new()
                .add_2bytes([TYPE_ECHO_REPLY, 0])
                .add_2bytes(header.id.to_be_bytes())
                .add_2bytes(header.seq.to_be_bytes()),
            DestinationUnreachable(ref header) => {
                use DestUnreachableHeader::*;
                match header {
                    Network => checksum::Sum16BitWords::new()
                        .add_2bytes([TYPE_DEST_UNREACH, CODE_DST_UNREACH_NET]),
                    Host => checksum::Sum16BitWords::new()
                        .add_2bytes([TYPE_DEST_UNREACH, CODE_DST_UNREACH_HOST]),
                    Protocol => checksum::Sum16BitWords::new()
                        .add_2bytes([TYPE_DEST_UNREACH, CODE_DST_UNREACH_PROTOCOL]),
                    Port => checksum::Sum16BitWords::new()
                        .add_2bytes([TYPE_DEST_UNREACH, CODE_DST_UNREACH_PORT]),
                    FragmentationNeeded { next_hop_mtu } => checksum::Sum16BitWords::new()
                        .add_2bytes([TYPE_DEST_UNREACH, CODE_DST_UNREACH_NEED_FRAG])
                        .add_2bytes(next_hop_mtu.to_be_bytes()),
                    SourceRouteFailed => checksum::Sum16BitWords::new()
                        .add_2bytes([TYPE_DEST_UNREACH, CODE_DST_UNREACH_SOURCE_ROUTE_FAILED]),
                    NetworkUnknown => checksum::Sum16BitWords::new()
                        .add_2bytes([TYPE_DEST_UNREACH, CODE_DST_UNREACH_NET_UNKNOWN]),
                    HostUnknown => checksum::Sum16BitWords::new()
                        .add_2bytes([TYPE_DEST_UNREACH, CODE_DST_UNREACH_HOST_UNKNOWN]),
                    Isolated => checksum::Sum16BitWords::new()
                        .add_2bytes([TYPE_DEST_UNREACH, CODE_DST_UNREACH_ISOLATED]),
                    NetworkProhibited => checksum::Sum16BitWords::new()
                        .add_2bytes([TYPE_DEST_UNREACH, CODE_DST_UNREACH_NET_PROHIB]),
                    HostProhibited => checksum::Sum16BitWords::new()
                        .add_2bytes([TYPE_DEST_UNREACH, CODE_DST_UNREACH_HOST_PROHIB]),
                    TosNetwork => checksum::Sum16BitWords::new()
                        .add_2bytes([TYPE_DEST_UNREACH, CODE_DST_UNREACH_TOS_NET]),
                    TosHost => checksum::Sum16BitWords::new()
                        .add_2bytes([TYPE_DEST_UNREACH, CODE_DST_UNREACH_TOS_HOST]),
                    FilterProhibited => checksum::Sum16BitWords::new()
                        .add_2bytes([TYPE_DEST_UNREACH, CODE_DST_UNREACH_FILTER_PROHIB]),
                    HostPrecedenceViolation => checksum::Sum16BitWords::new().add_2bytes([
                        TYPE_DEST_UNREACH,
                        CODE_DST_UNREACH_HOST_PRECEDENCE_VIOLATION,
                    ]),
                    PrecedenceCutoff => checksum::Sum16BitWords::new()
                        .add_2bytes([TYPE_DEST_UNREACH, CODE_DST_UNREACH_PRECEDENCE_CUTOFF]),
                }
            }
            Redirect(header) => checksum::Sum16BitWords::new()
                .add_2bytes([TYPE_REDIRECT, header.code as u8])
                .add_4bytes(header.gateway_internet_address),
            EchoRequest(header) => checksum::Sum16BitWords::new()
                .add_2bytes([TYPE_ECHO_REQUEST, 0])
                .add_2bytes(header.id.to_be_bytes())
                .add_2bytes(header.seq.to_be_bytes()),
            TimeExceeded(code) => {
                checksum::Sum16BitWords::new().add_2bytes([TYPE_TIME_EXCEEDED, *code as u8])
            }
            ParameterProblem(header) => {
                use ParameterProblemHeader::*;
                match header {
                    PointerIndicatesError(pointer) => checksum::Sum16BitWords::new()
                        .add_2bytes([
                            TYPE_PARAMETER_PROBLEM,
                            CODE_PARAMETER_PROBLEM_POINTER_INDICATES_ERROR,
                        ])
                        .add_2bytes([*pointer, 0]),
                    MissingRequiredOption => checksum::Sum16BitWords::new().add_2bytes([
                        TYPE_PARAMETER_PROBLEM,
                        CODE_PARAMETER_PROBLEM_MISSING_REQUIRED_OPTION,
                    ]),
                    BadLength => checksum::Sum16BitWords::new()
                        .add_2bytes([TYPE_PARAMETER_PROBLEM, CODE_PARAMETER_PROBLEM_BAD_LENGTH]),
                }
            }
            TimestampRequest(msg) => checksum::Sum16BitWords::new()
                .add_2bytes([TYPE_TIMESTAMP, 0])
                .add_2bytes(msg.id.to_be_bytes())
                .add_2bytes(msg.seq.to_be_bytes())
                .add_4bytes(msg.originate_timestamp.to_be_bytes())
                .add_4bytes(msg.receive_timestamp.to_be_bytes())
                .add_4bytes(msg.transmit_timestamp.to_be_bytes()),
            TimestampReply(msg) => checksum::Sum16BitWords::new()
                .add_2bytes([TYPE_TIMESTAMP_REPLY, 0])
                .add_2bytes(msg.id.to_be_bytes())
                .add_2bytes(msg.seq.to_be_bytes())
                .add_4bytes(msg.originate_timestamp.to_be_bytes())
                .add_4bytes(msg.receive_timestamp.to_be_bytes())
                .add_4bytes(msg.transmit_timestamp.to_be_bytes()),
        }
        .add_slice(payload)
        .ones_complement()
        .to_be()
    }
}

#[cfg(test)]
mod test {
    use crate::{icmpv4::*, Icmpv4Type::*, *};
    use alloc::format;
    use proptest::prelude::*;

    #[test]
    fn header_len() {
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
            (
                8,
                Unknown {
                    type_u8: 0,
                    code_u8: 0,
                    bytes5to8: [0; 4],
                },
            ),
            (8, EchoReply(dummy_echo)),
            (8, DestinationUnreachable(DestUnreachableHeader::Network)),
            (8, Redirect(dummy_redirect)),
            (8, EchoRequest(dummy_echo)),
            (8, TimeExceeded(TimeExceededCode::TtlExceededInTransit)),
            (8, ParameterProblem(ParameterProblemHeader::BadLength)),
            (20, TimestampRequest(dummy_ts.clone())),
            (20, TimestampReply(dummy_ts)),
        ];
        for t in tests {
            assert_eq!(t.0, t.1.header_len());
        }
    }

    #[test]
    fn fixed_payload_size() {
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
            (
                None,
                Unknown {
                    type_u8: 0,
                    code_u8: 0,
                    bytes5to8: [0; 4],
                },
            ),
            (None, EchoReply(dummy_echo)),
            (None, DestinationUnreachable(DestUnreachableHeader::Network)),
            (None, Redirect(dummy_redirect)),
            (None, EchoRequest(dummy_echo)),
            (None, TimeExceeded(TimeExceededCode::TtlExceededInTransit)),
            (None, ParameterProblem(ParameterProblemHeader::BadLength)),
            (Some(0), TimestampRequest(dummy_ts.clone())),
            (Some(0), TimestampReply(dummy_ts)),
        ];
        for t in tests {
            assert_eq!(t.0, t.1.fixed_payload_size());
        }
    }

    proptest! {
        #[test]
        fn calc_checksum(
            dest_unreach_code_u8 in 0u8..=15,
            next_hop_mtu in any::<u16>(),
            redirect_code_u8 in 0u8..=3,
            gateway_internet_address in any::<[u8;4]>(),
            time_exceeded_code_u8 in 0u8..=1,
            id in any::<u16>(),
            seq in any::<u16>(),
            originate_timestamp in any::<u32>(),
            receive_timestamp in any::<u32>(),
            transmit_timestamp in any::<u32>(),
            param_problem_code_u8 in 0u8..=2,
            pointer in any::<u8>(),
            unknown_type_u8 in any::<u8>(),
            unknown_code_u8 in any::<u8>(),
            bytes5to8 in any::<[u8;4]>(),
            payload in proptest::collection::vec(any::<u8>(), 0..1024)
        ) {
            let ts = TimestampMessage{
                id,
                seq,
                originate_timestamp,
                receive_timestamp,
                transmit_timestamp,
            };
            let echo = IcmpEchoHeader{
                id,
                seq,
            };
            let redirect = RedirectHeader{
                code: RedirectCode::from_u8(redirect_code_u8).unwrap(),
                gateway_internet_address,
            };
            let dest_unreach = DestUnreachableHeader::from_values(dest_unreach_code_u8, next_hop_mtu).unwrap();
            let param_prob = ParameterProblemHeader::from_values(param_problem_code_u8, pointer).unwrap();
            let values = [
                Unknown {
                    type_u8: unknown_type_u8,
                    code_u8: unknown_code_u8,
                    bytes5to8: bytes5to8,
                },
                EchoReply(echo.clone()),
                DestinationUnreachable(dest_unreach),
                Redirect(redirect),
                EchoRequest(echo),
                TimeExceeded(TimeExceededCode::from_u8(time_exceeded_code_u8).unwrap()),
                ParameterProblem(param_prob),
                TimestampRequest(ts.clone()),
                TimestampReply(ts),
            ];

            for t in values {
                let bytes = Icmpv4Header{
                    icmp_type: t.clone(),
                    checksum: 0, // use zero so the checksum calculation from the bytes works
                }.to_bytes();
                let expected = crate::checksum::Sum16BitWords::new()
                    .add_slice(bytes.as_ref())
                    .add_slice(&payload)
                    .ones_complement()
                    .to_be();
                assert_eq!(expected, t.calc_checksum(&payload));
            }
        }
    }

    #[test]
    fn clone_eq() {
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
            Unknown {
                type_u8: 0,
                code_u8: 0,
                bytes5to8: [0; 4],
            },
            EchoReply(dummy_echo),
            DestinationUnreachable(DestUnreachableHeader::Network),
            Redirect(dummy_redirect),
            EchoRequest(dummy_echo),
            TimeExceeded(TimeExceededCode::TtlExceededInTransit),
            ParameterProblem(ParameterProblemHeader::BadLength),
            TimestampRequest(dummy_ts.clone()),
            TimestampReply(dummy_ts),
        ];
        for t in tests {
            assert_eq!(t.clone(), t);
        }
    }

    #[test]
    fn debug() {
        let dummy_ts = TimestampMessage {
            id: 0,
            seq: 0,
            originate_timestamp: 0,
            receive_timestamp: 0,
            transmit_timestamp: 0,
        };
        let dummy_echo = IcmpEchoHeader { id: 0, seq: 0 };

        assert_eq!(
            format!(
                "{:?}",
                Unknown {
                    type_u8: 0,
                    code_u8: 0,
                    bytes5to8: [0; 4]
                }
            ),
            format!(
                "Unknown {{ type_u8: {:?}, code_u8: {:?}, bytes5to8: {:?} }}",
                0u8, 0u8, [0u8; 4]
            )
        );
        assert_eq!(
            format!("{:?}", EchoReply(dummy_echo)),
            format!("EchoReply({:?})", dummy_echo)
        );
        assert_eq!(
            format!(
                "{:?}",
                DestinationUnreachable(DestUnreachableHeader::Network)
            ),
            format!(
                "DestinationUnreachable({:?})",
                DestUnreachableHeader::Network
            )
        );
        {
            let dummy_redirect = RedirectHeader {
                code: RedirectCode::RedirectForNetwork,
                gateway_internet_address: [0; 4],
            };
            assert_eq!(
                format!("{:?}", Redirect(dummy_redirect.clone())),
                format!("Redirect({:?})", dummy_redirect)
            );
        }
        assert_eq!(
            format!("{:?}", EchoRequest(dummy_echo)),
            format!("EchoRequest({:?})", dummy_echo)
        );
        assert_eq!(
            format!("{:?}", TimeExceeded(TimeExceededCode::TtlExceededInTransit)),
            format!("TimeExceeded({:?})", TimeExceededCode::TtlExceededInTransit)
        );
        assert_eq!(
            format!("{:?}", ParameterProblem(ParameterProblemHeader::BadLength)),
            format!("ParameterProblem({:?})", ParameterProblemHeader::BadLength)
        );
        assert_eq!(
            format!("{:?}", TimestampRequest(dummy_ts.clone())),
            format!("TimestampRequest({:?})", dummy_ts)
        );
        assert_eq!(
            format!("{:?}", TimestampReply(dummy_ts.clone())),
            format!("TimestampReply({:?})", dummy_ts)
        );
    }
}
