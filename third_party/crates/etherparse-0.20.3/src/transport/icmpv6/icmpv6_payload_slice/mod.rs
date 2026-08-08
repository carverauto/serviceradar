mod destination_unreachable_payload_slice;
pub use destination_unreachable_payload_slice::*;

mod packet_too_big_payload_slice;
pub use packet_too_big_payload_slice::*;

mod time_exceeded_payload_slice;
pub use time_exceeded_payload_slice::*;

mod parameter_problem_payload_slice;
pub use parameter_problem_payload_slice::*;

mod echo_request_payload_slice;
pub use echo_request_payload_slice::*;

mod echo_reply_payload_slice;
pub use echo_reply_payload_slice::*;

mod neighbor_advertisement_payload_slice;
pub use neighbor_advertisement_payload_slice::*;

mod neighbor_solicitation_payload_slice;
pub use neighbor_solicitation_payload_slice::*;

mod redirect_payload_slice;
pub use redirect_payload_slice::*;

mod router_advertisement_payload_slice;
pub use router_advertisement_payload_slice::*;

mod router_solicitation_payload_slice;
pub use router_solicitation_payload_slice::*;

use crate::{err, icmpv6::Icmpv6Payload};

/// Borrowed, structured payload data that follows the first 8 bytes of an ICMPv6 packet.
#[derive(Clone, Debug, Eq, PartialEq)]
#[non_exhaustive]
pub enum Icmpv6PayloadSlice<'a> {
    /// Payload of a Destination Unreachable message.
    DestinationUnreachable(DestinationUnreachablePayloadSlice<'a>),
    /// Payload of a Packet Too Big message.
    PacketTooBig(PacketTooBigPayloadSlice<'a>),
    /// Payload of a Time Exceeded message.
    TimeExceeded(TimeExceededPayloadSlice<'a>),
    /// Payload of a Parameter Problem message.
    ParameterProblem(ParameterProblemPayloadSlice<'a>),
    /// Payload of an Echo Request message.
    EchoRequest(EchoRequestPayloadSlice<'a>),
    /// Payload of an Echo Reply message.
    EchoReply(EchoReplyPayloadSlice<'a>),
    /// Payload of a Router Solicitation message.
    RouterSolicitation(RouterSolicitationPayloadSlice<'a>),
    /// Payload of a Router Advertisement message.
    RouterAdvertisement(RouterAdvertisementPayloadSlice<'a>),
    /// Payload of a Neighbor Solicitation message.
    NeighborSolicitation(NeighborSolicitationPayloadSlice<'a>),
    /// Payload of a Neighbor Advertisement message.
    NeighborAdvertisement(NeighborAdvertisementPayloadSlice<'a>),
    /// Payload of a Redirect message.
    Redirect(RedirectPayloadSlice<'a>),
    /// Raw payload of an unsupported or currently unmodeled ICMPv6 message.
    Raw(&'a [u8]),
}

impl<'a> Icmpv6PayloadSlice<'a> {
    /// Decode a structured payload based on the ICMPv6 type.
    pub fn from_slice(
        icmp_type: &crate::Icmpv6Type,
        payload: &'a [u8],
    ) -> Result<Icmpv6PayloadSlice<'a>, err::LenError> {
        use crate::Icmpv6Type::*;

        Ok(match icmp_type {
            DestinationUnreachable(_) => Icmpv6PayloadSlice::DestinationUnreachable(
                DestinationUnreachablePayloadSlice::from_slice(payload)?,
            ),
            PacketTooBig { mtu: _ } => {
                Icmpv6PayloadSlice::PacketTooBig(PacketTooBigPayloadSlice::from_slice(payload)?)
            }
            TimeExceeded(_) => {
                Icmpv6PayloadSlice::TimeExceeded(TimeExceededPayloadSlice::from_slice(payload)?)
            }
            ParameterProblem(_) => Icmpv6PayloadSlice::ParameterProblem(
                ParameterProblemPayloadSlice::from_slice(payload)?,
            ),
            EchoRequest(_) => {
                Icmpv6PayloadSlice::EchoRequest(EchoRequestPayloadSlice::from_slice(payload)?)
            }
            EchoReply(_) => {
                Icmpv6PayloadSlice::EchoReply(EchoReplyPayloadSlice::from_slice(payload)?)
            }
            RouterSolicitation => Icmpv6PayloadSlice::RouterSolicitation(
                RouterSolicitationPayloadSlice::from_slice(payload)?,
            ),
            RouterAdvertisement(_) => Icmpv6PayloadSlice::RouterAdvertisement(
                RouterAdvertisementPayloadSlice::from_slice(payload)?,
            ),
            NeighborSolicitation => Icmpv6PayloadSlice::NeighborSolicitation(
                NeighborSolicitationPayloadSlice::from_slice(payload)?,
            ),
            NeighborAdvertisement(_) => Icmpv6PayloadSlice::NeighborAdvertisement(
                NeighborAdvertisementPayloadSlice::from_slice(payload)?,
            ),
            Redirect => Icmpv6PayloadSlice::Redirect(RedirectPayloadSlice::from_slice(payload)?),
            _ => Icmpv6PayloadSlice::Raw(payload),
        })
    }

    pub(crate) fn from_type_u8(
        type_u8: u8,
        code_u8: u8,
        payload: &'a [u8],
    ) -> Result<Icmpv6PayloadSlice<'a>, err::LenError> {
        use crate::icmpv6::*;

        match type_u8 {
            TYPE_DST_UNREACH if DestUnreachableCode::from_u8(code_u8).is_some() => {
                Ok(Icmpv6PayloadSlice::DestinationUnreachable(
                    DestinationUnreachablePayloadSlice::from_slice(payload)?,
                ))
            }
            TYPE_PACKET_TOO_BIG if 0 == code_u8 => Ok(Icmpv6PayloadSlice::PacketTooBig(
                PacketTooBigPayloadSlice::from_slice(payload)?,
            )),
            TYPE_TIME_EXCEEDED if TimeExceededCode::from_u8(code_u8).is_some() => Ok(
                Icmpv6PayloadSlice::TimeExceeded(TimeExceededPayloadSlice::from_slice(payload)?),
            ),
            TYPE_PARAMETER_PROBLEM if ParameterProblemCode::from_u8(code_u8).is_some() => {
                Ok(Icmpv6PayloadSlice::ParameterProblem(
                    ParameterProblemPayloadSlice::from_slice(payload)?,
                ))
            }
            TYPE_ECHO_REQUEST if 0 == code_u8 => Ok(Icmpv6PayloadSlice::EchoRequest(
                EchoRequestPayloadSlice::from_slice(payload)?,
            )),
            TYPE_ECHO_REPLY if 0 == code_u8 => Ok(Icmpv6PayloadSlice::EchoReply(
                EchoReplyPayloadSlice::from_slice(payload)?,
            )),
            // RFC 4861 sections 6.1.1, 6.1.2, 7.1.1, 7.1.2 and 8.1:
            // "ICMP Code is 0."
            TYPE_ROUTER_SOLICITATION if 0 == code_u8 => Ok(Icmpv6PayloadSlice::RouterSolicitation(
                RouterSolicitationPayloadSlice::from_slice(payload)?,
            )),
            TYPE_ROUTER_ADVERTISEMENT if 0 == code_u8 => {
                Ok(Icmpv6PayloadSlice::RouterAdvertisement(
                    RouterAdvertisementPayloadSlice::from_slice(payload)?,
                ))
            }
            TYPE_NEIGHBOR_SOLICITATION if 0 == code_u8 => {
                Ok(Icmpv6PayloadSlice::NeighborSolicitation(
                    NeighborSolicitationPayloadSlice::from_slice(payload)?,
                ))
            }
            TYPE_NEIGHBOR_ADVERTISEMENT if 0 == code_u8 => {
                Ok(Icmpv6PayloadSlice::NeighborAdvertisement(
                    NeighborAdvertisementPayloadSlice::from_slice(payload)?,
                ))
            }
            TYPE_REDIRECT_MESSAGE if 0 == code_u8 => Ok(Icmpv6PayloadSlice::Redirect(
                RedirectPayloadSlice::from_slice(payload)?,
            )),
            _ => Ok(Icmpv6PayloadSlice::Raw(payload)),
        }
    }

    /// Returns the full borrowed payload bytes.
    pub fn slice(&self) -> &'a [u8] {
        match self {
            Icmpv6PayloadSlice::DestinationUnreachable(value) => value.slice(),
            Icmpv6PayloadSlice::PacketTooBig(value) => value.slice(),
            Icmpv6PayloadSlice::TimeExceeded(value) => value.slice(),
            Icmpv6PayloadSlice::ParameterProblem(value) => value.slice(),
            Icmpv6PayloadSlice::EchoRequest(value) => value.slice(),
            Icmpv6PayloadSlice::EchoReply(value) => value.slice(),
            Icmpv6PayloadSlice::RouterSolicitation(value) => value.slice(),
            Icmpv6PayloadSlice::RouterAdvertisement(value) => value.slice(),
            Icmpv6PayloadSlice::NeighborSolicitation(value) => value.slice(),
            Icmpv6PayloadSlice::NeighborAdvertisement(value) => value.slice(),
            Icmpv6PayloadSlice::Redirect(value) => value.slice(),
            Icmpv6PayloadSlice::Raw(value) => value,
        }
    }

    /// Convert the borrowed payload to an owned structured payload if supported.
    ///
    /// For payload types with variable trailing data (for example ND options),
    /// the second tuple element contains the remaining unparsed bytes.
    pub fn to_payload(&self) -> Option<(Icmpv6Payload, &'a [u8])> {
        match self {
            Icmpv6PayloadSlice::DestinationUnreachable(_)
            | Icmpv6PayloadSlice::PacketTooBig(_)
            | Icmpv6PayloadSlice::TimeExceeded(_)
            | Icmpv6PayloadSlice::ParameterProblem(_)
            | Icmpv6PayloadSlice::EchoRequest(_)
            | Icmpv6PayloadSlice::EchoReply(_) => None,
            Icmpv6PayloadSlice::RouterSolicitation(value) => {
                let (payload, options) = value.to_payload();
                Some((Icmpv6Payload::RouterSolicitation(payload), options))
            }
            Icmpv6PayloadSlice::RouterAdvertisement(value) => {
                let (payload, options) = value.to_payload();
                Some((Icmpv6Payload::RouterAdvertisement(payload), options))
            }
            Icmpv6PayloadSlice::NeighborSolicitation(value) => {
                let (payload, options) = value.to_payload();
                Some((Icmpv6Payload::NeighborSolicitation(payload), options))
            }
            Icmpv6PayloadSlice::NeighborAdvertisement(value) => {
                let (payload, options) = value.to_payload();
                Some((Icmpv6Payload::NeighborAdvertisement(payload), options))
            }
            Icmpv6PayloadSlice::Redirect(value) => {
                let (payload, options) = value.to_payload();
                Some((Icmpv6Payload::Redirect(payload), options))
            }
            Icmpv6PayloadSlice::Raw(_) => None,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::icmpv6::{
        NeighborAdvertisementPayload, NeighborSolicitationPayload, RedirectPayload,
        RouterAdvertisementPayload, RouterSolicitationPayload,
    };
    use crate::{err, err::Layer, LenSource};
    use core::net::Ipv6Addr;
    use proptest::prelude::*;

    proptest! {
        #[test]
        fn destination_unreachable(slice in proptest::collection::vec(any::<u8>(), 0..64)) {
            let actual = DestinationUnreachablePayloadSlice::from_slice(&slice).unwrap();
            assert_eq!(actual.slice(), &slice[..]);
            assert_eq!(actual.invoking_packet(), &slice[..]);
        }

        #[test]
        fn packet_too_big(slice in proptest::collection::vec(any::<u8>(), 0..64)) {
            let actual = PacketTooBigPayloadSlice::from_slice(&slice).unwrap();
            assert_eq!(actual.slice(), &slice[..]);
            assert_eq!(actual.invoking_packet(), &slice[..]);
        }

        #[test]
        fn time_exceeded(slice in proptest::collection::vec(any::<u8>(), 0..64)) {
            let actual = TimeExceededPayloadSlice::from_slice(&slice).unwrap();
            assert_eq!(actual.slice(), &slice[..]);
            assert_eq!(actual.invoking_packet(), &slice[..]);
        }

        #[test]
        fn parameter_problem(slice in proptest::collection::vec(any::<u8>(), 0..64)) {
            let actual = ParameterProblemPayloadSlice::from_slice(&slice).unwrap();
            assert_eq!(actual.slice(), &slice[..]);
            assert_eq!(actual.invoking_packet(), &slice[..]);
        }

        #[test]
        fn echo_request(slice in proptest::collection::vec(any::<u8>(), 0..64)) {
            let actual = EchoRequestPayloadSlice::from_slice(&slice).unwrap();
            assert_eq!(actual.slice(), &slice[..]);
            assert_eq!(actual.data(), &slice[..]);
        }

        #[test]
        fn echo_reply(slice in proptest::collection::vec(any::<u8>(), 0..64)) {
            let actual = EchoReplyPayloadSlice::from_slice(&slice).unwrap();
            assert_eq!(actual.slice(), &slice[..]);
            assert_eq!(actual.data(), &slice[..]);
        }

        #[test]
        fn router_solicitation(slice in proptest::collection::vec(any::<u8>(), 0..64)) {
            let actual = RouterSolicitationPayloadSlice::from_slice(&slice).unwrap();
            assert_eq!(actual.slice(), &slice[..]);
            assert_eq!(actual.options(), &slice[..]);
            assert_eq!(actual.to_payload(), (RouterSolicitationPayload, &slice[..]));
        }

        #[test]
        fn router_advertisement(
            reachable_time in any::<u32>(),
            retrans_timer in any::<u32>(),
            options in proptest::collection::vec(any::<u8>(), 0..32)
        ) {
            let mut data = [0u8; 8];
            data[..4].copy_from_slice(&reachable_time.to_be_bytes());
            data[4..].copy_from_slice(&retrans_timer.to_be_bytes());
            let mut payload = alloc::vec::Vec::from(data);
            payload.extend_from_slice(&options);

            let actual = RouterAdvertisementPayloadSlice::from_slice(&payload).unwrap();
            assert_eq!(actual.reachable_time(), reachable_time);
            assert_eq!(actual.retrans_timer(), retrans_timer);
            assert_eq!(actual.options(), &options[..]);
            assert_eq!(
                actual.to_payload(),
                (
                    RouterAdvertisementPayload {
                        reachable_time,
                        retrans_timer,
                    },
                    &options[..]
                )
            );
        }

        #[test]
        fn neighbor_solicitation(
            target_address in any::<[u8;16]>(),
            options in proptest::collection::vec(any::<u8>(), 0..32)
        ) {
            let mut payload = alloc::vec::Vec::from(target_address);
            payload.extend_from_slice(&options);
            let actual = NeighborSolicitationPayloadSlice::from_slice(&payload).unwrap();
            assert_eq!(actual.target_address(), Ipv6Addr::from(target_address));
            assert_eq!(actual.options(), &options[..]);
            assert_eq!(
                actual.to_payload(),
                (
                    NeighborSolicitationPayload {
                        target_address: Ipv6Addr::from(target_address)
                    },
                    &options[..]
                )
            );
        }

        #[test]
        fn neighbor_advertisement(
            target_address in any::<[u8;16]>(),
            options in proptest::collection::vec(any::<u8>(), 0..32)
        ) {
            let mut payload = alloc::vec::Vec::from(target_address);
            payload.extend_from_slice(&options);
            let actual = NeighborAdvertisementPayloadSlice::from_slice(&payload).unwrap();
            assert_eq!(actual.target_address(), Ipv6Addr::from(target_address));
            assert_eq!(actual.options(), &options[..]);
            assert_eq!(
                actual.to_payload(),
                (
                    NeighborAdvertisementPayload {
                        target_address: Ipv6Addr::from(target_address),
                    },
                    &options[..]
                )
            );
        }

        #[test]
        fn redirect(
            target_address in any::<[u8;16]>(),
            destination_address in any::<[u8;16]>(),
            options in proptest::collection::vec(any::<u8>(), 0..32)
        ) {
            let mut payload = alloc::vec::Vec::from(target_address);
            payload.extend_from_slice(&destination_address);
            payload.extend_from_slice(&options);
            let actual = RedirectPayloadSlice::from_slice(&payload).unwrap();
            assert_eq!(actual.target_address(), Ipv6Addr::from(target_address));
            assert_eq!(actual.destination_address(), Ipv6Addr::from(destination_address));
            assert_eq!(actual.options(), &options[..]);
            assert_eq!(
                actual.to_payload(),
                (
                    RedirectPayload {
                        target_address: Ipv6Addr::from(target_address),
                        destination_address: Ipv6Addr::from(destination_address),
                    },
                    &options[..]
                )
            );
        }
    }

    #[test]
    fn len_errors() {
        assert_eq!(
            Err(err::LenError {
                required_len: RouterAdvertisementPayloadSlice::FIXED_PART_LEN,
                len: 7,
                len_source: LenSource::Slice,
                layer: Layer::Icmpv6,
                layer_start_offset: 0,
            }),
            RouterAdvertisementPayloadSlice::from_slice(&[0; 7])
        );
        assert_eq!(
            Err(err::LenError {
                required_len: NeighborSolicitationPayloadSlice::FIXED_PART_LEN,
                len: 15,
                len_source: LenSource::Slice,
                layer: Layer::Icmpv6,
                layer_start_offset: 0,
            }),
            NeighborSolicitationPayloadSlice::from_slice(&[0; 15])
        );
        assert_eq!(
            Err(err::LenError {
                required_len: NeighborAdvertisementPayloadSlice::FIXED_PART_LEN,
                len: 15,
                len_source: LenSource::Slice,
                layer: Layer::Icmpv6,
                layer_start_offset: 0,
            }),
            NeighborAdvertisementPayloadSlice::from_slice(&[0; 15])
        );
        assert_eq!(
            Err(err::LenError {
                required_len: RedirectPayloadSlice::FIXED_PART_LEN,
                len: 31,
                len_source: LenSource::Slice,
                layer: Layer::Icmpv6,
                layer_start_offset: 0,
            }),
            RedirectPayloadSlice::from_slice(&[0; 31])
        );
    }

    #[test]
    fn from_type_u8() {
        use crate::icmpv6::*;

        let payload = [1, 2, 3, 4];

        assert_eq!(
            Icmpv6PayloadSlice::DestinationUnreachable(
                DestinationUnreachablePayloadSlice::from_slice(&payload).unwrap()
            ),
            Icmpv6PayloadSlice::from_type_u8(TYPE_DST_UNREACH, CODE_DST_UNREACH_PORT, &payload)
                .unwrap()
        );
        assert_eq!(
            Icmpv6PayloadSlice::Raw(&payload),
            Icmpv6PayloadSlice::from_type_u8(TYPE_DST_UNREACH, u8::MAX, &payload).unwrap()
        );

        assert_eq!(
            Icmpv6PayloadSlice::PacketTooBig(
                PacketTooBigPayloadSlice::from_slice(&payload).unwrap()
            ),
            Icmpv6PayloadSlice::from_type_u8(TYPE_PACKET_TOO_BIG, 0, &payload).unwrap()
        );
        assert_eq!(
            Icmpv6PayloadSlice::Raw(&payload),
            Icmpv6PayloadSlice::from_type_u8(TYPE_PACKET_TOO_BIG, 1, &payload).unwrap()
        );

        assert_eq!(
            Icmpv6PayloadSlice::TimeExceeded(
                TimeExceededPayloadSlice::from_slice(&payload).unwrap()
            ),
            Icmpv6PayloadSlice::from_type_u8(
                TYPE_TIME_EXCEEDED,
                CODE_TIME_EXCEEDED_HOP_LIMIT_EXCEEDED,
                &payload
            )
            .unwrap()
        );
        assert_eq!(
            Icmpv6PayloadSlice::Raw(&payload),
            Icmpv6PayloadSlice::from_type_u8(TYPE_TIME_EXCEEDED, 2, &payload).unwrap()
        );

        assert_eq!(
            Icmpv6PayloadSlice::ParameterProblem(
                ParameterProblemPayloadSlice::from_slice(&payload).unwrap()
            ),
            Icmpv6PayloadSlice::from_type_u8(
                TYPE_PARAMETER_PROBLEM,
                CODE_PARAM_PROBLEM_UNRECOG_IPV6_OPTION,
                &payload
            )
            .unwrap()
        );
        assert_eq!(
            Icmpv6PayloadSlice::Raw(&payload),
            Icmpv6PayloadSlice::from_type_u8(TYPE_PARAMETER_PROBLEM, u8::MAX, &payload).unwrap()
        );

        assert_eq!(
            Icmpv6PayloadSlice::EchoRequest(EchoRequestPayloadSlice::from_slice(&payload).unwrap()),
            Icmpv6PayloadSlice::from_type_u8(TYPE_ECHO_REQUEST, 0, &payload).unwrap()
        );
        assert_eq!(
            Icmpv6PayloadSlice::Raw(&payload),
            Icmpv6PayloadSlice::from_type_u8(TYPE_ECHO_REQUEST, 1, &payload).unwrap()
        );

        assert_eq!(
            Icmpv6PayloadSlice::EchoReply(EchoReplyPayloadSlice::from_slice(&payload).unwrap()),
            Icmpv6PayloadSlice::from_type_u8(TYPE_ECHO_REPLY, 0, &payload).unwrap()
        );
        assert_eq!(
            Icmpv6PayloadSlice::Raw(&payload),
            Icmpv6PayloadSlice::from_type_u8(TYPE_ECHO_REPLY, 1, &payload).unwrap()
        );
    }

    #[test]
    fn as_lax_ip_slice() {
        let invoking_packet = [
            0x45, 0, 0, 20, 0, 0, 0, 0, 64, 17, 0, 0, 1, 2, 3, 4, 5, 6, 7, 8,
        ];
        let expected = crate::LaxIpSlice::from_slice(&invoking_packet).unwrap();

        assert_eq!(
            DestinationUnreachablePayloadSlice::from_slice(&invoking_packet)
                .unwrap()
                .as_lax_ip_slice()
                .unwrap(),
            expected
        );
        assert_eq!(
            PacketTooBigPayloadSlice::from_slice(&invoking_packet)
                .unwrap()
                .as_lax_ip_slice()
                .unwrap(),
            expected
        );
        assert_eq!(
            TimeExceededPayloadSlice::from_slice(&invoking_packet)
                .unwrap()
                .as_lax_ip_slice()
                .unwrap(),
            expected
        );
        assert_eq!(
            ParameterProblemPayloadSlice::from_slice(&invoking_packet)
                .unwrap()
                .as_lax_ip_slice()
                .unwrap(),
            expected
        );
    }
}
