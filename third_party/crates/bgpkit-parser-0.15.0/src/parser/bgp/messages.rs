use crate::models::*;
use bytes::{Buf, BufMut, Bytes, BytesMut};
use std::convert::TryFrom;

use crate::error::ParserError;
use crate::models::capabilities::{
    AddPathCapability, BgpCapabilityType, BgpExtendedMessageCapability, BgpRoleCapability,
    ExtendedNextHopCapability, FourOctetAsCapability, GracefulRestartCapability,
    MultiprotocolExtensionsCapability, RouteRefreshCapability,
};
use crate::models::error::BgpError;
use crate::parser::bgp::attributes::parse_attributes;
use crate::parser::{encode_ipaddr, encode_nlri_prefixes, parse_nlri_list, ReadUtils};
use log::warn;

/// BGP message
///
/// Format:
/// ```text
/// 0                   1                   2                   3
/// 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
/// +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
/// |                                                               |
/// +                                                               +
/// |                                                               |
/// +                                                               +
/// |                           Marker                              |
/// +                                                               +
/// |                                                               |
/// +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
/// |          Length               |      Type     |
/// +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
/// ```
pub fn parse_bgp_message(
    data: &mut Bytes,
    add_path: bool,
    asn_len: &AsnLength,
) -> Result<BgpMessage, ParserError> {
    let total_size = data.len();
    data.has_n_remaining(19)?;
    data.advance(16);
    /*
    This 2-octet unsigned integer indicates the total length of the
    message, including the header in octets.  Thus, it allows one
    to locate the (Marker field of the) next message in the TCP
    stream.  The value of the Length field MUST always be at least
    19 and no greater than 4096, and MAY be further constrained,
    depending on the message type.  "padding" of extra data after
    the message is not allowed.  Therefore, the Length field MUST
    have the smallest value required, given the rest of the
    message.
    */
    let length = data.read_u16()?;

    // Validate message length according to RFC 8654
    // For now, we allow extended messages for all message types except when we know
    // for certain that extended messages are not supported.
    // RFC 8654: Extended messages up to 65535 bytes are allowed for all message types
    // except OPEN and KEEPALIVE (which remain limited to 4096 bytes).
    // However, since we're parsing MRT data without session context, we'll be permissive.
    let max_length = 65535; // RFC 8654 maximum
    if !(19..=max_length).contains(&length) {
        return Err(ParserError::ParseError(format!(
            "invalid BGP message length {length}"
        )));
    }

    let bgp_msg_length = if (length as usize) > total_size {
        total_size - 19
    } else {
        length as usize - 19
    };

    let msg_type: BgpMessageType = match BgpMessageType::try_from(data.read_u8()?) {
        Ok(t) => t,
        Err(_) => {
            return Err(ParserError::ParseError(
                "Unknown BGP Message Type".to_string(),
            ))
        }
    };

    // Additional validation for OPEN and KEEPALIVE messages per RFC 8654
    // These message types cannot exceed 4096 bytes even with extended message capability
    match msg_type {
        BgpMessageType::OPEN | BgpMessageType::KEEPALIVE => {
            if length > 4096 {
                return Err(ParserError::ParseError(format!(
                    "BGP {} message length {} exceeds maximum allowed 4096 bytes (RFC 8654)",
                    match msg_type {
                        BgpMessageType::OPEN => "OPEN",
                        BgpMessageType::KEEPALIVE => "KEEPALIVE",
                        _ => unreachable!(),
                    },
                    length
                )));
            }
        }
        BgpMessageType::UPDATE | BgpMessageType::NOTIFICATION => {
            // These can be extended messages up to 65535 bytes when capability is negotiated
            // Since we're parsing MRT data, we allow extended lengths
        }
    }

    if data.remaining() != bgp_msg_length {
        warn!(
            "BGP message length {} does not match the actual length {}",
            bgp_msg_length,
            data.remaining()
        );
    }
    data.has_n_remaining(bgp_msg_length)?;
    let mut msg_data = data.split_to(bgp_msg_length);

    Ok(match msg_type {
        BgpMessageType::OPEN => BgpMessage::Open(parse_bgp_open_message(&mut msg_data)?),
        BgpMessageType::UPDATE => {
            BgpMessage::Update(parse_bgp_update_message(msg_data, add_path, asn_len)?)
        }
        BgpMessageType::NOTIFICATION => {
            BgpMessage::Notification(parse_bgp_notification_message(msg_data)?)
        }
        BgpMessageType::KEEPALIVE => BgpMessage::KeepAlive,
    })
}

/// Parse BGP NOTIFICATION message.
///
/// The BGP NOTIFICATION messages contains BGP error codes received from a connected BGP router. The
/// error code is parsed into [BgpError] data structure and any unknown codes will produce warning
/// messages, but not critical errors.
///
pub fn parse_bgp_notification_message(
    mut input: Bytes,
) -> Result<BgpNotificationMessage, ParserError> {
    let error_code = input.read_u8()?;
    let error_subcode = input.read_u8()?;

    Ok(BgpNotificationMessage {
        error: BgpError::new(error_code, error_subcode),
        data: input.read_n_bytes(input.len())?,
    })
}

impl BgpNotificationMessage {
    pub fn encode(&self) -> Bytes {
        let mut buf = BytesMut::new();
        let (code, subcode) = self.error.get_codes();
        buf.put_u8(code);
        buf.put_u8(subcode);
        buf.put_slice(&self.data);
        buf.freeze()
    }
}

/// Parse BGP OPEN message.
///
/// The parsing of BGP OPEN message also includes decoding the BGP capabilities.
///
/// RFC 4271: https://datatracker.ietf.org/doc/html/rfc4271
/// ```text
///       0                   1                   2                   3
///       0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
///       +-+-+-+-+-+-+-+-+
///       |    Version    |
///       +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
///       |     My Autonomous System      |
///       +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
///       |           Hold Time           |
///       +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
///       |                         BGP Identifier                        |
///       +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
///       | Opt Parm Len  |
///       +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
///       |                                                               |
///       |             Optional Parameters (variable)                    |
///       |                                                               |
///       +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
///
///       0                   1
///       0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5
///       +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-...
///       |  Parm. Type   | Parm. Length  |  Parameter Value (variable)
///       +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-...
/// ```
pub fn parse_bgp_open_message(input: &mut Bytes) -> Result<BgpOpenMessage, ParserError> {
    input.has_n_remaining(10)?;
    let version = input.read_u8()?;
    let asn = Asn::new_16bit(input.read_u16()?);
    let hold_time = input.read_u16()?;

    let sender_ip = input.read_ipv4_address()?;
    let mut opt_params_len: u16 = input.read_u8()? as u16;

    let mut extended_length = false;
    let mut first = true;

    let mut params: Vec<OptParam> = vec![];
    while input.remaining() >= 2 {
        let mut param_type = input.read_u8()?;
        if first {
            if opt_params_len == 0 && param_type == 255 {
                return Err(ParserError::ParseError(
                    "RFC 9072 violation: Non-Extended Optional Parameters Length must not be 0 when using extended format".to_string()
                ));
            }
            // first parameter, check if it is extended length message
            if opt_params_len != 0 && param_type == 255 {
                // RFC 9072: https://datatracker.ietf.org/doc/rfc9072/
                //
                // 0                   1                   2                   3
                // 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
                //     +-+-+-+-+-+-+-+-+
                //     |    Version    |
                //     +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
                //     |     My Autonomous System      |
                //     +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
                //     |           Hold Time           |
                //     +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
                //     |                         BGP Identifier                        |
                //     +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
                //     |Non-Ext OP Len.|Non-Ext OP Type|  Extended Opt. Parm. Length   |
                //     +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
                //     |                                                               |
                //     |             Optional Parameters (variable)                    |
                //     |                                                               |
                //     +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
                //
                //         Figure 1: Extended Encoding OPEN Format
                extended_length = true;
                opt_params_len = input.read_u16()?;
                if opt_params_len == 0 {
                    break;
                }
                // let pos_end = input.position() + opt_params_len as u64;
                if input.remaining() != opt_params_len as usize {
                    warn!(
                        "BGP open message length {} does not match the actual length {}",
                        opt_params_len,
                        input.remaining()
                    );
                }

                param_type = input.read_u8()?;
            }
            first = false;
        }
        // reaching here means all the remain params are regular non-extended-length parameters

        let param_len = match extended_length {
            true => input.read_u16()?,
            false => input.read_u8()? as u16,
        };

        // https://tools.ietf.org/html/rfc3392
        // https://www.iana.org/assignments/bgp-parameters/bgp-parameters.xhtml#bgp-parameters-11

        let param_value = match param_type {
            2 => {
                let mut capacities = vec![];

                // Split off only the bytes for this parameter to avoid consuming other parameters
                input.has_n_remaining(param_len as usize)?;
                let mut param_data = input.split_to(param_len as usize);

                while param_data.remaining() >= 2 {
                    // capability codes:
                    // https://www.iana.org/assignments/capability-codes/capability-codes.xhtml#capability-codes-2
                    let code = param_data.read_u8()?;
                    let len = param_data.read_u8()? as u16; // Capability length is ALWAYS 1 byte per RFC 5492

                    let capability_data = param_data.read_n_bytes(len as usize)?;
                    let capability_type = BgpCapabilityType::from(code);

                    // Parse specific capability types with fallback to raw bytes
                    macro_rules! parse_capability {
                        ($parser:path, $variant:ident) => {
                            match $parser(Bytes::from(capability_data.clone())) {
                                Ok(parsed) => CapabilityValue::$variant(parsed),
                                Err(_) => CapabilityValue::Raw(capability_data),
                            }
                        };
                    }

                    let capability_value = match capability_type {
                        BgpCapabilityType::MULTIPROTOCOL_EXTENSIONS_FOR_BGP_4 => {
                            parse_capability!(
                                MultiprotocolExtensionsCapability::parse,
                                MultiprotocolExtensions
                            )
                        }
                        BgpCapabilityType::ROUTE_REFRESH_CAPABILITY_FOR_BGP_4 => {
                            parse_capability!(RouteRefreshCapability::parse, RouteRefresh)
                        }
                        BgpCapabilityType::EXTENDED_NEXT_HOP_ENCODING => {
                            parse_capability!(ExtendedNextHopCapability::parse, ExtendedNextHop)
                        }
                        BgpCapabilityType::GRACEFUL_RESTART_CAPABILITY => {
                            parse_capability!(GracefulRestartCapability::parse, GracefulRestart)
                        }
                        BgpCapabilityType::SUPPORT_FOR_4_OCTET_AS_NUMBER_CAPABILITY => {
                            parse_capability!(FourOctetAsCapability::parse, FourOctetAs)
                        }
                        BgpCapabilityType::ADD_PATH_CAPABILITY => {
                            parse_capability!(AddPathCapability::parse, AddPath)
                        }
                        BgpCapabilityType::BGP_ROLE => {
                            parse_capability!(BgpRoleCapability::parse, BgpRole)
                        }
                        BgpCapabilityType::BGP_EXTENDED_MESSAGE => {
                            parse_capability!(
                                BgpExtendedMessageCapability::parse,
                                BgpExtendedMessage
                            )
                        }
                        _ => CapabilityValue::Raw(capability_data),
                    };

                    capacities.push(Capability {
                        ty: capability_type,
                        value: capability_value,
                    });
                }

                ParamValue::Capacities(capacities)
            }
            _ => {
                // unsupported param, read as raw bytes
                let bytes = input.read_n_bytes(param_len as usize)?;
                ParamValue::Raw(bytes)
            }
        };
        params.push(OptParam {
            param_type,
            param_len,
            param_value,
        });
    }

    Ok(BgpOpenMessage {
        version,
        asn,
        hold_time,
        sender_ip,
        extended_length,
        opt_params: params,
    })
}

impl BgpOpenMessage {
    pub fn encode(&self) -> Bytes {
        let mut buf = BytesMut::new();
        buf.put_u8(self.version);
        buf.put_u16(self.asn.into());
        buf.put_u16(self.hold_time);
        buf.extend(encode_ipaddr(&self.sender_ip.into()));
        buf.put_u8(self.opt_params.len() as u8);
        for param in &self.opt_params {
            buf.put_u8(param.param_type);
            buf.put_u8(param.param_len as u8);
            match &param.param_value {
                ParamValue::Capacities(capacities) => {
                    for cap in capacities {
                        buf.put_u8(cap.ty.into());
                        let encoded_value = match &cap.value {
                            CapabilityValue::MultiprotocolExtensions(mp) => mp.encode(),
                            CapabilityValue::RouteRefresh(rr) => rr.encode(),
                            CapabilityValue::ExtendedNextHop(enh) => enh.encode(),
                            CapabilityValue::GracefulRestart(gr) => gr.encode(),
                            CapabilityValue::FourOctetAs(foa) => foa.encode(),
                            CapabilityValue::AddPath(ap) => ap.encode(),
                            CapabilityValue::BgpRole(br) => br.encode(),
                            CapabilityValue::BgpExtendedMessage(bem) => bem.encode(),
                            CapabilityValue::Raw(raw) => Bytes::from(raw.clone()),
                        };
                        buf.put_u8(encoded_value.len() as u8);
                        buf.extend(&encoded_value);
                    }
                }
                ParamValue::Raw(bytes) => {
                    buf.extend(bytes);
                }
            }
        }
        buf.freeze()
    }
}

/// read nlri portion of a bgp update message.
fn read_nlri(
    mut input: Bytes,
    afi: &Afi,
    add_path: bool,
) -> Result<Vec<NetworkPrefix>, ParserError> {
    let length = input.len();
    if length == 0 {
        return Ok(vec![]);
    }
    if length == 1 {
        // 1 byte does not make sense
        warn!("seeing strange one-byte NLRI field");
        input.advance(1); // skip the byte
        return Ok(vec![]);
    }

    parse_nlri_list(input, add_path, afi)
}

/// read bgp update message.
///
/// RFC: <https://tools.ietf.org/html/rfc4271#section-4.3>
pub fn parse_bgp_update_message(
    mut input: Bytes,
    add_path: bool,
    asn_len: &AsnLength,
) -> Result<BgpUpdateMessage, ParserError> {
    // NOTE: AFI for routes outside attributes are IPv4 ONLY.
    let afi = Afi::Ipv4;

    // parse withdrawn prefixes NLRI
    let withdrawn_bytes_length = input.read_u16()? as usize;
    input.has_n_remaining(withdrawn_bytes_length)?;
    let withdrawn_bytes = input.split_to(withdrawn_bytes_length);
    let withdrawn_prefixes = read_nlri(withdrawn_bytes, &afi, add_path)?;

    // parse attributes
    let attribute_length = input.read_u16()? as usize;

    input.has_n_remaining(attribute_length)?;
    let attr_data_slice = input.split_to(attribute_length);
    let attributes = parse_attributes(attr_data_slice, asn_len, add_path, None, None, None)?;

    // parse announced prefixes nlri.
    // the remaining bytes are announced prefixes.
    let announced_prefixes = read_nlri(input, &afi, add_path)?;

    Ok(BgpUpdateMessage {
        withdrawn_prefixes,
        attributes,
        announced_prefixes,
    })
}

impl BgpUpdateMessage {
    pub fn encode(&self, asn_len: AsnLength) -> Bytes {
        let mut bytes = BytesMut::new();

        // withdrawn prefixes
        let withdrawn_bytes = encode_nlri_prefixes(&self.withdrawn_prefixes);
        bytes.put_u16(withdrawn_bytes.len() as u16);
        bytes.put_slice(&withdrawn_bytes);

        // attributes
        let attr_bytes = self.attributes.encode(asn_len);

        bytes.put_u16(attr_bytes.len() as u16);
        bytes.put_slice(&attr_bytes);

        bytes.extend(encode_nlri_prefixes(&self.announced_prefixes));
        bytes.freeze()
    }

    /// Check if this is an end-of-rib message.
    ///
    /// <https://datatracker.ietf.org/doc/html/rfc4724#section-2>
    /// End-of-rib message is a special update message that contains no NLRI or withdrawal NLRI prefixes.
    pub fn is_end_of_rib(&self) -> bool {
        // there are two cases for end-of-rib message:
        // 1. IPv4 unicast address family: no announced, no withdrawn, no attributes
        // 2. Other cases: no announced, no withdrawal, only MP_UNREACH_NRLI with no prefixes

        if !self.announced_prefixes.is_empty() || !self.withdrawn_prefixes.is_empty() {
            // has announced or withdrawal IPv4 unicast prefixes:
            // definitely not end-of-rib

            return false;
        }

        if self.attributes.inner.is_empty() {
            // no attributes, no prefixes:
            // case 1 end-of-rib
            return true;
        }

        // has some attributes, it can only be withdrawal with no prefixes

        if self.attributes.inner.len() > 1 {
            // has more than one attributes, not end-of-rib
            return false;
        }

        // has only one attribute, check if it is withdrawal attribute
        if let AttributeValue::MpUnreachNlri(nlri) = &self.attributes.inner.first().unwrap().value {
            if nlri.prefixes.is_empty() {
                // the only attribute is MP_UNREACH_NLRI with no prefixes:
                // case 2 end-of-rib
                return true;
            }
        }

        // all other cases: not end-of-rib
        false
    }
}

impl BgpMessage {
    pub fn encode(&self, asn_len: AsnLength) -> Bytes {
        let mut bytes = BytesMut::new();
        bytes.put_u32(0); // marker
        bytes.put_u32(0); // marker
        bytes.put_u32(0); // marker
        bytes.put_u32(0); // marker

        let (msg_type, msg_bytes) = match self {
            BgpMessage::Open(msg) => (BgpMessageType::OPEN, msg.encode()),
            BgpMessage::Update(msg) => (BgpMessageType::UPDATE, msg.encode(asn_len)),
            BgpMessage::Notification(msg) => (BgpMessageType::NOTIFICATION, msg.encode()),
            BgpMessage::KeepAlive => (BgpMessageType::KEEPALIVE, Bytes::new()),
        };

        // msg total bytes length = msg bytes + 16 bytes marker + 2 bytes length + 1 byte type
        bytes.put_u16(msg_bytes.len() as u16 + 16 + 2 + 1);
        bytes.put_u8(msg_type as u8);
        bytes.put_slice(&msg_bytes);
        bytes.freeze()
    }
}

impl From<&BgpElem> for BgpUpdateMessage {
    fn from(elem: &BgpElem) -> Self {
        BgpUpdateMessage {
            withdrawn_prefixes: vec![],
            attributes: Attributes::from(elem),
            announced_prefixes: vec![],
        }
    }
}

impl From<BgpUpdateMessage> for BgpMessage {
    fn from(value: BgpUpdateMessage) -> Self {
        BgpMessage::Update(value)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::net::Ipv4Addr;
    use std::str::FromStr;

    #[test]
    fn test_end_of_rib() {
        // No prefixes and empty attributes: end-of-rib
        let attrs = Attributes::default();
        let msg = BgpUpdateMessage {
            withdrawn_prefixes: vec![],
            attributes: attrs,
            announced_prefixes: vec![],
        };
        assert!(msg.is_end_of_rib());

        // single MP_UNREACH_NLRI attribute with no prefixes: end-of-rib
        let attrs = Attributes::from_iter(vec![AttributeValue::MpUnreachNlri(Nlri {
            afi: Afi::Ipv4,
            safi: Safi::Unicast,
            next_hop: None,
            prefixes: vec![],
            link_state_nlris: None,
            flowspec_nlris: None,
        })]);
        let msg = BgpUpdateMessage {
            withdrawn_prefixes: vec![],
            attributes: attrs,
            announced_prefixes: vec![],
        };
        assert!(msg.is_end_of_rib());

        // message with announced prefixes
        let prefix = NetworkPrefix::from_str("192.168.1.0/24").unwrap();
        let attrs = Attributes::default();
        let msg = BgpUpdateMessage {
            withdrawn_prefixes: vec![],
            attributes: attrs,
            announced_prefixes: vec![prefix],
        };
        assert!(!msg.is_end_of_rib());

        // message with withdrawn prefixes
        let prefix = NetworkPrefix::from_str("192.168.1.0/24").unwrap();
        let attrs = Attributes::default();
        let msg = BgpUpdateMessage {
            withdrawn_prefixes: vec![prefix],
            attributes: attrs,
            announced_prefixes: vec![],
        };
        assert!(!msg.is_end_of_rib());

        // NLRI attribute with empty prefixes: NOT end-of-rib
        let attrs = Attributes::from_iter(vec![AttributeValue::MpReachNlri(Nlri {
            afi: Afi::Ipv4,
            safi: Safi::Unicast,
            next_hop: None,
            prefixes: vec![],
            link_state_nlris: None,
            flowspec_nlris: None,
        })]);
        let msg = BgpUpdateMessage {
            withdrawn_prefixes: vec![],
            attributes: attrs,
            announced_prefixes: vec![],
        };
        assert!(!msg.is_end_of_rib());

        // NLRI attribute with non-empty prefixes
        let attrs = Attributes::from_iter(vec![AttributeValue::MpReachNlri(Nlri {
            afi: Afi::Ipv4,
            safi: Safi::Unicast,
            next_hop: None,
            prefixes: vec![prefix],
            link_state_nlris: None,
            flowspec_nlris: None,
        })]);
        let msg = BgpUpdateMessage {
            withdrawn_prefixes: vec![],
            attributes: attrs,
            announced_prefixes: vec![],
        };
        assert!(!msg.is_end_of_rib());

        // Unreachable NLRI attribute with non-empty prefixes
        let attrs = Attributes::from_iter(vec![AttributeValue::MpUnreachNlri(Nlri {
            afi: Afi::Ipv4,
            safi: Safi::Unicast,
            next_hop: None,
            prefixes: vec![prefix],
            link_state_nlris: None,
            flowspec_nlris: None,
        })]);
        let msg = BgpUpdateMessage {
            withdrawn_prefixes: vec![],
            attributes: attrs,
            announced_prefixes: vec![],
        };
        assert!(!msg.is_end_of_rib());

        // message with more than one attributes
        let attrs = Attributes::from_iter(vec![
            AttributeValue::MpUnreachNlri(Nlri {
                afi: Afi::Ipv4,
                safi: Safi::Unicast,
                next_hop: None,
                prefixes: vec![],
                link_state_nlris: None,
                flowspec_nlris: None,
            }),
            AttributeValue::AtomicAggregate,
        ]);
        let msg = BgpUpdateMessage {
            withdrawn_prefixes: vec![],
            attributes: attrs,
            announced_prefixes: vec![],
        };
        assert!(!msg.is_end_of_rib());
    }

    #[test]
    fn test_invlaid_length() {
        let bytes = Bytes::from_static(&[
            0x00, 0x00, 0x00, 0x00, // marker
            0x00, 0x00, 0x00, 0x00, // marker
            0x00, 0x00, 0x00, 0x00, // marker
            0x00, 0x00, 0x00, 0x00, // marker
            0x00, 0x00, // length
            0x05, // type
        ]);
        let mut data = bytes.clone();
        assert!(parse_bgp_message(&mut data, false, &AsnLength::Bits16).is_err());

        let bytes = Bytes::from_static(&[
            0x00, 0x00, 0x00, 0x00, // marker
            0x00, 0x00, 0x00, 0x00, // marker
            0x00, 0x00, 0x00, 0x00, // marker
            0x00, 0x00, 0x00, 0x00, // marker
            0x00, 0x28, // length
            0x05, // type
        ]);
        let mut data = bytes.clone();
        assert!(parse_bgp_message(&mut data, false, &AsnLength::Bits16).is_err());
    }

    #[test]
    fn test_invlaid_type() {
        let bytes = Bytes::from_static(&[
            0x00, 0x00, 0x00, 0x00, // marker
            0x00, 0x00, 0x00, 0x00, // marker
            0x00, 0x00, 0x00, 0x00, // marker
            0x00, 0x00, 0x00, 0x00, // marker
            0x00, 0x28, // length
            0x05, // type
        ]);
        let mut data = bytes.clone();
        assert!(parse_bgp_message(&mut data, false, &AsnLength::Bits16).is_err());
    }

    #[test]
    fn test_parse_bgp_notification_message() {
        let bytes = Bytes::from_static(&[
            0x01, // error code
            0x02, // error subcode
            0x00, 0x00, // data
        ]);
        let msg = parse_bgp_notification_message(bytes).unwrap();
        matches!(
            msg.error,
            BgpError::MessageHeaderError(MessageHeaderError::BAD_MESSAGE_LENGTH)
        );
        assert_eq!(msg.data, Bytes::from_static(&[0x00, 0x00]));
    }

    #[test]
    fn test_encode_bgp_notification_messsage() {
        let msg = BgpNotificationMessage {
            error: BgpError::MessageHeaderError(MessageHeaderError::BAD_MESSAGE_LENGTH),
            data: vec![0x00, 0x00],
        };
        let bytes = msg.encode();
        assert_eq!(bytes, Bytes::from_static(&[0x01, 0x02, 0x00, 0x00]));
    }

    #[test]
    fn test_parse_bgp_open_message() {
        let bytes = Bytes::from_static(&[
            0x04, // version
            0x00, 0x01, // asn
            0x00, 0xb4, // hold time
            0xc0, 0x00, 0x02, 0x01, // sender ip
            0x00, // opt params length
        ]);
        let msg = parse_bgp_open_message(&mut bytes.clone()).unwrap();
        assert_eq!(msg.version, 4);
        assert_eq!(msg.asn, Asn::new_16bit(1));
        assert_eq!(msg.hold_time, 180);
        assert_eq!(msg.sender_ip, Ipv4Addr::new(192, 0, 2, 1));
        assert!(!msg.extended_length);
        assert_eq!(msg.opt_params.len(), 0);
    }

    #[test]
    fn test_encode_bgp_open_message() {
        let msg = BgpOpenMessage {
            version: 4,
            asn: Asn::new_16bit(1),
            hold_time: 180,
            sender_ip: Ipv4Addr::new(192, 0, 2, 1),
            extended_length: false,
            opt_params: vec![],
        };
        let bytes = msg.encode();
        assert_eq!(
            bytes,
            Bytes::from_static(&[
                0x04, // version
                0x00, 0x01, // asn
                0x00, 0xb4, // hold time
                0xc0, 0x00, 0x02, 0x01, // sender ip
                0x00, // opt params length
            ])
        );
    }

    #[test]
    fn test_encode_bgp_notification_message() {
        let bgp_message = BgpMessage::Notification(BgpNotificationMessage {
            error: BgpError::MessageHeaderError(MessageHeaderError::BAD_MESSAGE_LENGTH),
            data: vec![0x00, 0x00],
        });
        let bytes = bgp_message.encode(AsnLength::Bits16);
        assert_eq!(
            bytes,
            Bytes::from_static(&[
                0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                0x00, 0x00, 0x00, 0x17, 0x03, 0x01, 0x02, 0x00, 0x00
            ])
        );
    }

    #[test]
    fn test_bgp_message_from_bgp_update_message() {
        let msg = BgpMessage::from(BgpUpdateMessage::default());
        assert!(matches!(msg, BgpMessage::Update(_)));
    }

    #[test]
    fn test_parse_bgp_open_message_with_extended_next_hop_capability() {
        use crate::models::{Afi, Safi};

        // BGP OPEN message with Extended Next Hop capability - RFC 8950, Section 3
        // Version=4, ASN=65001, HoldTime=180, BGP-ID=192.0.2.1
        // One capability: Extended Next Hop (type=5) with two entries:
        // 1) IPv4 Unicast (AFI=1, SAFI=1) can use IPv6 NextHop (AFI=2)
        // 2) IPv4 MPLS VPN (AFI=1, SAFI=128) can use IPv6 NextHop (AFI=2)
        let bytes = Bytes::from(vec![
            0x04, // version
            0xfd, 0xe9, // asn = 65001
            0x00, 0xb4, // hold time = 180
            0xc0, 0x00, 0x02, 0x01, // sender ip = 192.0.2.1
            0x10, // opt params length = 16
            0x02, // param type = 2 (capability)
            0x0e, // param length = 14
            0x05, // capability type = 5 (Extended Next Hop)
            0x0c, // capability length = 12 (2 entries * 6 bytes each)
            0x00, 0x01, // NLRI AFI = 1 (IPv4)
            0x00, 0x01, // NLRI SAFI = 1 (Unicast)
            0x00, 0x02, // NextHop AFI = 2 (IPv6)
            0x00, 0x01, // NLRI AFI = 1 (IPv4) - second entry
            0x00, 0x80, // NLRI SAFI = 128 (MPLS VPN)
            0x00, 0x02, // NextHop AFI = 2 (IPv6)
        ]);

        let msg = parse_bgp_open_message(&mut bytes.clone()).unwrap();
        assert_eq!(msg.version, 4);
        assert_eq!(msg.asn, Asn::new_16bit(65001));
        assert_eq!(msg.hold_time, 180);
        assert_eq!(msg.sender_ip, Ipv4Addr::new(192, 0, 2, 1));
        assert!(!msg.extended_length);
        assert_eq!(msg.opt_params.len(), 1);

        // Check the capability
        if let ParamValue::Capacities(cap) = &msg.opt_params[0].param_value {
            assert_eq!(cap[0].ty, BgpCapabilityType::EXTENDED_NEXT_HOP_ENCODING);

            if let CapabilityValue::ExtendedNextHop(enh_cap) = &cap[0].value {
                assert_eq!(enh_cap.entries.len(), 2);

                // Check first entry: IPv4 Unicast can use IPv6 NextHop
                let entry1 = &enh_cap.entries[0];
                assert_eq!(entry1.nlri_afi, Afi::Ipv4);
                assert_eq!(entry1.nlri_safi, Safi::Unicast);
                assert_eq!(entry1.nexthop_afi, Afi::Ipv6);

                // Check second entry: IPv4 MPLS VPN can use IPv6 NextHop
                let entry2 = &enh_cap.entries[1];
                assert_eq!(entry2.nlri_afi, Afi::Ipv4);
                assert_eq!(entry2.nlri_safi, Safi::MplsVpn);
                assert_eq!(entry2.nexthop_afi, Afi::Ipv6);

                // Test functionality
                assert!(enh_cap.supports(Afi::Ipv4, Safi::Unicast, Afi::Ipv6));
                assert!(enh_cap.supports(Afi::Ipv4, Safi::MplsVpn, Afi::Ipv6));
                assert!(!enh_cap.supports(Afi::Ipv4, Safi::Multicast, Afi::Ipv6));
            } else {
                panic!("Expected ExtendedNextHop capability value");
            }
        } else {
            panic!("Expected capability parameter");
        }
    }

    #[test]
    fn test_rfc8654_extended_message_length_validation() {
        // Test valid extended UPDATE message (within 65535 limit)
        let bytes = Bytes::from_static(&[
            0x00, 0x00, 0x00, 0x00, // marker
            0x00, 0x00, 0x00, 0x00, // marker
            0x00, 0x00, 0x00, 0x00, // marker
            0x00, 0x00, 0x00, 0x00, // marker
            0x13, 0x00, // length = 4864 (0x1300) (extended message)
            0x02, // type = UPDATE
            0x00, 0x00, // withdrawn length = 0
            0x00,
            0x00, // path attribute length = 0
                  // No NLRI data needed for this test
        ]);
        let mut data = bytes.clone();
        // This should succeed because UPDATE messages can be extended
        assert!(parse_bgp_message(&mut data, false, &AsnLength::Bits16).is_ok());

        // Test OPEN message exceeding 4096 bytes (should fail)
        let bytes = Bytes::from_static(&[
            0x00, 0x00, 0x00, 0x00, // marker
            0x00, 0x00, 0x00, 0x00, // marker
            0x00, 0x00, 0x00, 0x00, // marker
            0x00, 0x00, 0x00, 0x00, // marker
            0x13, 0x00, // length = 4864 (0x1300) (exceeds 4096 for OPEN)
            0x01, // type = OPEN
        ]);
        let mut data = bytes.clone();
        let result = parse_bgp_message(&mut data, false, &AsnLength::Bits16);
        assert!(result.is_err());
        if let Err(ParserError::ParseError(msg)) = result {
            assert!(msg.contains("BGP OPEN message length"));
            assert!(msg.contains("4096 bytes"));
        }

        // Test KEEPALIVE message exceeding 4096 bytes (should fail)
        let bytes = Bytes::from_static(&[
            0x00, 0x00, 0x00, 0x00, // marker
            0x00, 0x00, 0x00, 0x00, // marker
            0x00, 0x00, 0x00, 0x00, // marker
            0x00, 0x00, 0x00, 0x00, // marker
            0x13, 0x00, // length = 4864 (0x1300) (exceeds 4096 for KEEPALIVE)
            0x04, // type = KEEPALIVE
        ]);
        let mut data = bytes.clone();
        let result = parse_bgp_message(&mut data, false, &AsnLength::Bits16);
        assert!(result.is_err());
        if let Err(ParserError::ParseError(msg)) = result {
            assert!(msg.contains("BGP KEEPALIVE message length"));
            assert!(msg.contains("4096 bytes"));
        }

        // Test message exceeding 65535 bytes (maximum allowed)
        let bytes = Bytes::from_static(&[
            0x00, 0x00, 0x00, 0x00, // marker
            0x00, 0x00, 0x00, 0x00, // marker
            0x00, 0x00, 0x00, 0x00, // marker
            0x00, 0x00, 0x00, 0x00, // marker
            0xFF, 0xFF, // length = 65535 (0xFFFF) (maximum allowed)
            0x02, // type = UPDATE
        ]);
        let mut data = bytes.clone();
        // This might fail due to insufficient data, but should not fail on length validation
        let result = parse_bgp_message(&mut data, false, &AsnLength::Bits16);
        if let Err(ParserError::ParseError(msg)) = result {
            // Should not be a length validation error
            assert!(!msg.contains("invalid BGP message length"));
        }
    }

    #[test]
    fn test_bgp_extended_message_capability_parsing() {
        use crate::models::CapabilityValue;

        // Test BGP OPEN message with Extended Message capability (capability code 6)
        let bytes = Bytes::from(vec![
            0x04, // version
            0x00, 0x01, // asn
            0x00, 0xb4, // hold time
            0xc0, 0x00, 0x02, 0x01, // sender ip
            0x04, // opt params length = 4
            0x02, // param type = 2 (capability)
            0x02, // param length = 2
            0x06, // capability type = 6 (Extended Message)
            0x00, // capability length = 0 (no parameters)
        ]);

        let msg = parse_bgp_open_message(&mut bytes.clone()).unwrap();
        assert_eq!(msg.version, 4);
        assert_eq!(msg.asn, Asn::new_16bit(1));
        assert_eq!(msg.opt_params.len(), 1);

        // Check that we have the extended message capability
        if let ParamValue::Capacities(cap) = &msg.opt_params[0].param_value {
            assert_eq!(cap[0].ty, BgpCapabilityType::BGP_EXTENDED_MESSAGE);
            if let CapabilityValue::BgpExtendedMessage(_) = &cap[0].value {
                // Extended Message capability should have no parameters
            } else {
                panic!("Expected BgpExtendedMessage capability value");
            }
        } else {
            panic!("Expected capability parameter");
        }
    }

    #[test]
    fn test_rfc8654_edge_cases() {
        // Test NOTIFICATION message with extended length (should be allowed)
        let bytes = Bytes::from_static(&[
            0x00, 0x00, 0x00, 0x00, // marker
            0x00, 0x00, 0x00, 0x00, // marker
            0x00, 0x00, 0x00, 0x00, // marker
            0x00, 0x00, 0x00, 0x00, // marker
            0x20, 0x00, // length = 8192 (extended NOTIFICATION message)
            0x03, // type = NOTIFICATION
            0x06, // error code (Cease)
            0x00, // error subcode
                  // Additional data would go here
        ]);
        let mut data = bytes.clone();
        // This should succeed because NOTIFICATION messages can be extended
        let result = parse_bgp_message(&mut data, false, &AsnLength::Bits16);
        // May fail due to insufficient data, but not due to length validation
        if let Err(ParserError::ParseError(msg)) = result {
            assert!(!msg.contains("invalid BGP message length"));
            assert!(!msg.contains("exceeds maximum allowed 4096 bytes"));
        }

        // Test message exactly at 4096 bytes for OPEN (should be allowed)
        let open_data = vec![
            0x00, 0x00, 0x00, 0x00, // marker
            0x00, 0x00, 0x00, 0x00, // marker
            0x00, 0x00, 0x00, 0x00, // marker
            0x00, 0x00, 0x00, 0x00, // marker
            0x10, 0x00, // length = 4096 (exactly at limit for OPEN)
            0x01, // type = OPEN
        ];
        let bytes = Bytes::from(open_data);
        let mut data = bytes.clone();
        let result = parse_bgp_message(&mut data, false, &AsnLength::Bits16);
        // Should not fail on length validation (may fail on parsing due to insufficient data)
        if let Err(ParserError::ParseError(msg)) = result {
            assert!(!msg.contains("exceeds maximum allowed 4096 bytes"));
        }

        // Test message exactly at 65535 bytes for UPDATE (should be allowed)
        let bytes = Bytes::from_static(&[
            0x00, 0x00, 0x00, 0x00, // marker
            0x00, 0x00, 0x00, 0x00, // marker
            0x00, 0x00, 0x00, 0x00, // marker
            0x00, 0x00, 0x00, 0x00, // marker
            0xFF, 0xFF, // length = 65535 (0xFFFF) (maximum allowed)
            0x02, // type = UPDATE
        ]);
        let mut data = bytes.clone();
        let result = parse_bgp_message(&mut data, false, &AsnLength::Bits16);
        // Should not fail on length validation
        if let Err(ParserError::ParseError(msg)) = result {
            assert!(!msg.contains("invalid BGP message length"));
        }
    }

    #[test]
    fn test_rfc8654_capability_encoding_path() {
        use crate::models::capabilities::BgpExtendedMessageCapability;

        // Test that the encoding path for BgpExtendedMessage capability is covered
        // This specifically tests the line: CapabilityValue::BgpExtendedMessage(bem) => bem.encode()
        let capability_value =
            CapabilityValue::BgpExtendedMessage(BgpExtendedMessageCapability::new());
        let capability = Capability {
            ty: BgpCapabilityType::BGP_EXTENDED_MESSAGE,
            value: capability_value,
        };

        let opt_param = OptParam {
            param_type: 2, // capability
            param_len: 2,
            param_value: ParamValue::Capacities(vec![capability]),
        };

        let msg = BgpOpenMessage {
            version: 4,
            asn: Asn::new_16bit(65001),
            hold_time: 180,
            sender_ip: Ipv4Addr::new(192, 0, 2, 1),
            extended_length: false,
            opt_params: vec![opt_param],
        };

        // This will exercise the encoding path we need to test
        let encoded = msg.encode();
        assert!(!encoded.is_empty());

        // Verify we can parse it back (exercises the parsing path too)
        let parsed = parse_bgp_open_message(&mut encoded.clone()).unwrap();
        assert_eq!(parsed.opt_params.len(), 1);
        if let ParamValue::Capacities(cap) = &parsed.opt_params[0].param_value {
            assert_eq!(cap[0].ty, BgpCapabilityType::BGP_EXTENDED_MESSAGE);
        }
    }

    #[test]
    fn test_rfc8654_error_message_formatting() {
        // Test the error message formatting paths that include message type names
        // This tests the match arms for OPEN and KEEPALIVE in error messages

        // Test OPEN message error path
        let bytes = Bytes::from_static(&[
            0x00, 0x00, 0x00, 0x00, // marker
            0x00, 0x00, 0x00, 0x00, // marker
            0x00, 0x00, 0x00, 0x00, // marker
            0x00, 0x00, 0x00, 0x00, // marker
            0x20, 0x01, // length = 8193 (exceeds 4096 for OPEN)
            0x01, // type = OPEN
        ]);
        let mut data = bytes.clone();
        let result = parse_bgp_message(&mut data, false, &AsnLength::Bits16);
        assert!(result.is_err());
        if let Err(ParserError::ParseError(msg)) = result {
            assert!(msg.contains("BGP OPEN message length"));
            assert!(msg.contains("exceeds maximum allowed 4096 bytes"));
        }

        // Test KEEPALIVE message error path
        let bytes = Bytes::from_static(&[
            0x00, 0x00, 0x00, 0x00, // marker
            0x00, 0x00, 0x00, 0x00, // marker
            0x00, 0x00, 0x00, 0x00, // marker
            0x00, 0x00, 0x00, 0x00, // marker
            0x20, 0x01, // length = 8193 (exceeds 4096 for KEEPALIVE)
            0x04, // type = KEEPALIVE
        ]);
        let mut data = bytes.clone();
        let result = parse_bgp_message(&mut data, false, &AsnLength::Bits16);
        assert!(result.is_err());
        if let Err(ParserError::ParseError(msg)) = result {
            assert!(msg.contains("BGP KEEPALIVE message length"));
            assert!(msg.contains("exceeds maximum allowed 4096 bytes"));
        }
    }

    #[test]
    fn test_encode_bgp_open_message_with_extended_message_capability() {
        use crate::models::capabilities::BgpExtendedMessageCapability;

        // Create Extended Message capability
        let extended_msg_capability = BgpExtendedMessageCapability::new();

        let msg = BgpOpenMessage {
            version: 4,
            asn: Asn::new_16bit(65001),
            hold_time: 180,
            sender_ip: Ipv4Addr::new(192, 0, 2, 1),
            extended_length: false,
            opt_params: vec![OptParam {
                param_type: 2, // capability
                param_len: 2,  // 1 (type) + 1 (len) + 0 (no parameters)
                param_value: ParamValue::Capacities(vec![Capability {
                    ty: BgpCapabilityType::BGP_EXTENDED_MESSAGE,
                    value: CapabilityValue::BgpExtendedMessage(extended_msg_capability),
                }]),
            }],
        };

        let encoded = msg.encode();

        // Parse the encoded message back and verify it matches
        let parsed = parse_bgp_open_message(&mut encoded.clone()).unwrap();
        assert_eq!(parsed.version, msg.version);
        assert_eq!(parsed.asn, msg.asn);
        assert_eq!(parsed.hold_time, msg.hold_time);
        assert_eq!(parsed.sender_ip, msg.sender_ip);
        assert_eq!(parsed.opt_params.len(), 1);

        // Verify the capability was encoded and parsed correctly
        if let ParamValue::Capacities(cap) = &parsed.opt_params[0].param_value {
            assert_eq!(cap[0].ty, BgpCapabilityType::BGP_EXTENDED_MESSAGE);
            if let CapabilityValue::BgpExtendedMessage(_) = &cap[0].value {
                // Extended Message capability should have no parameters
            } else {
                panic!("Expected BgpExtendedMessage capability value after round trip");
            }
        } else {
            panic!("Expected capability parameter after round trip");
        }
    }

    #[test]
    fn test_encode_bgp_open_message_with_extended_next_hop_capability() {
        use crate::models::capabilities::{ExtendedNextHopCapability, ExtendedNextHopEntry};
        use crate::models::{Afi, Safi};

        // Create Extended Next Hop capability
        let entries = vec![
            ExtendedNextHopEntry {
                nlri_afi: Afi::Ipv4,
                nlri_safi: Safi::Unicast,
                nexthop_afi: Afi::Ipv6,
            },
            ExtendedNextHopEntry {
                nlri_afi: Afi::Ipv4,
                nlri_safi: Safi::MplsVpn,
                nexthop_afi: Afi::Ipv6,
            },
        ];
        let enh_capability = ExtendedNextHopCapability::new(entries);

        let msg = BgpOpenMessage {
            version: 4,
            asn: Asn::new_16bit(65001),
            hold_time: 180,
            sender_ip: Ipv4Addr::new(192, 0, 2, 1),
            extended_length: false,
            opt_params: vec![OptParam {
                param_type: 2, // capability
                param_len: 14, // 1 (type) + 1 (len) + 12 (2 entries * 6 bytes)
                param_value: ParamValue::Capacities(vec![Capability {
                    ty: BgpCapabilityType::EXTENDED_NEXT_HOP_ENCODING,
                    value: CapabilityValue::ExtendedNextHop(enh_capability),
                }]),
            }],
        };

        let encoded = msg.encode();

        // Parse the encoded message back and verify it matches
        let parsed = parse_bgp_open_message(&mut encoded.clone()).unwrap();
        assert_eq!(parsed.version, msg.version);
        assert_eq!(parsed.asn, msg.asn);
        assert_eq!(parsed.hold_time, msg.hold_time);
        assert_eq!(parsed.sender_ip, msg.sender_ip);
        assert_eq!(parsed.extended_length, msg.extended_length);
        assert_eq!(parsed.opt_params.len(), 1);

        // Verify the capability was encoded and parsed correctly
        if let ParamValue::Capacities(cap) = &parsed.opt_params[0].param_value {
            assert_eq!(cap[0].ty, BgpCapabilityType::EXTENDED_NEXT_HOP_ENCODING);
            if let CapabilityValue::ExtendedNextHop(enh_cap) = &cap[0].value {
                assert_eq!(enh_cap.entries.len(), 2);
                assert!(enh_cap.supports(Afi::Ipv4, Safi::Unicast, Afi::Ipv6));
                assert!(enh_cap.supports(Afi::Ipv4, Safi::MplsVpn, Afi::Ipv6));
            } else {
                panic!("Expected ExtendedNextHop capability value after round trip");
            }
        } else {
            panic!("Expected capability parameter after round trip");
        }
    }

    #[test]
    fn test_parse_bgp_open_message_with_multiple_capabilities() {
        // Create a BGP OPEN message with multiple capabilities in a single optional parameter
        // This tests RFC 5492 support for multiple capabilities per parameter

        // Build capabilities: Extended Message, Route Refresh, and 4-octet AS
        let extended_msg_cap = Capability {
            ty: BgpCapabilityType::BGP_EXTENDED_MESSAGE,
            value: CapabilityValue::BgpExtendedMessage(BgpExtendedMessageCapability {}),
        };

        let route_refresh_cap = Capability {
            ty: BgpCapabilityType::ROUTE_REFRESH_CAPABILITY_FOR_BGP_4,
            value: CapabilityValue::RouteRefresh(RouteRefreshCapability {}),
        };

        let four_octet_as_cap = Capability {
            ty: BgpCapabilityType::SUPPORT_FOR_4_OCTET_AS_NUMBER_CAPABILITY,
            value: CapabilityValue::FourOctetAs(FourOctetAsCapability { asn: 65536 }),
        };

        // Create OPEN message with all three capabilities in one parameter
        let msg = BgpOpenMessage {
            version: 4,
            asn: Asn::new_32bit(65000),
            hold_time: 180,
            sender_ip: "10.0.0.1".parse().unwrap(),
            extended_length: false,
            opt_params: vec![OptParam {
                param_type: 2, // capability
                param_len: 10, // 3 capabilities: (1+1+0) + (1+1+0) + (1+1+4) = 2+2+6 = 10
                param_value: ParamValue::Capacities(vec![
                    extended_msg_cap,
                    route_refresh_cap,
                    four_octet_as_cap,
                ]),
            }],
        };

        // Encode the message
        let encoded = msg.encode();

        // Parse it back
        let mut encoded_bytes = encoded.clone();
        let parsed = parse_bgp_open_message(&mut encoded_bytes).unwrap();

        // Verify basic fields
        assert_eq!(parsed.version, 4);
        assert_eq!(parsed.asn, Asn::new_32bit(65000));
        assert_eq!(parsed.hold_time, 180);
        assert_eq!(
            parsed.sender_ip,
            "10.0.0.1".parse::<std::net::Ipv4Addr>().unwrap()
        );
        assert_eq!(parsed.opt_params.len(), 1);

        // Verify we have all three capabilities
        if let ParamValue::Capacities(caps) = &parsed.opt_params[0].param_value {
            assert_eq!(caps.len(), 3, "Should have 3 capabilities");

            // Check first capability: Extended Message
            assert_eq!(caps[0].ty, BgpCapabilityType::BGP_EXTENDED_MESSAGE);
            assert!(matches!(
                caps[0].value,
                CapabilityValue::BgpExtendedMessage(_)
            ));

            // Check second capability: Route Refresh
            assert_eq!(
                caps[1].ty,
                BgpCapabilityType::ROUTE_REFRESH_CAPABILITY_FOR_BGP_4
            );
            assert!(matches!(caps[1].value, CapabilityValue::RouteRefresh(_)));

            // Check third capability: 4-octet AS
            assert_eq!(
                caps[2].ty,
                BgpCapabilityType::SUPPORT_FOR_4_OCTET_AS_NUMBER_CAPABILITY
            );
            if let CapabilityValue::FourOctetAs(foa) = &caps[2].value {
                assert_eq!(foa.asn, 65536);
            } else {
                panic!("Expected FourOctetAs capability value");
            }
        } else {
            panic!("Expected Capacities parameter");
        }
    }

    #[test]
    fn test_parse_bgp_open_message_with_multiple_capability_parameters() {
        // Test parsing OPEN message with multiple optional parameters, each containing capabilities
        // This is less common but still valid per RFC 5492

        let msg = BgpOpenMessage {
            version: 4,
            asn: Asn::new_32bit(65001),
            hold_time: 90,
            sender_ip: "192.168.1.1".parse().unwrap(),
            extended_length: false,
            opt_params: vec![
                OptParam {
                    param_type: 2, // capability
                    param_len: 2,
                    param_value: ParamValue::Capacities(vec![Capability {
                        ty: BgpCapabilityType::BGP_EXTENDED_MESSAGE,
                        value: CapabilityValue::BgpExtendedMessage(BgpExtendedMessageCapability {}),
                    }]),
                },
                OptParam {
                    param_type: 2, // capability
                    param_len: 6,
                    param_value: ParamValue::Capacities(vec![Capability {
                        ty: BgpCapabilityType::SUPPORT_FOR_4_OCTET_AS_NUMBER_CAPABILITY,
                        value: CapabilityValue::FourOctetAs(FourOctetAsCapability {
                            asn: 4200000000,
                        }),
                    }]),
                },
            ],
        };

        // Encode and parse back
        let encoded = msg.encode();
        let mut encoded_bytes = encoded.clone();
        let parsed = parse_bgp_open_message(&mut encoded_bytes).unwrap();

        // Verify we have 2 optional parameters
        assert_eq!(parsed.opt_params.len(), 2);

        // Check first parameter
        if let ParamValue::Capacities(caps) = &parsed.opt_params[0].param_value {
            assert_eq!(caps.len(), 1);
            assert_eq!(caps[0].ty, BgpCapabilityType::BGP_EXTENDED_MESSAGE);
        } else {
            panic!("Expected Capacities in first parameter");
        }

        // Check second parameter
        if let ParamValue::Capacities(caps) = &parsed.opt_params[1].param_value {
            assert_eq!(caps.len(), 1);
            assert_eq!(
                caps[0].ty,
                BgpCapabilityType::SUPPORT_FOR_4_OCTET_AS_NUMBER_CAPABILITY
            );
            if let CapabilityValue::FourOctetAs(foa) = &caps[0].value {
                assert_eq!(foa.asn, 4200000000);
            }
        } else {
            panic!("Expected Capacities in second parameter");
        }
    }
}
