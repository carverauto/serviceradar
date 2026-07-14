use crate::bgp::parse_bgp_message;
use crate::models::*;
use crate::parser::bmp::error::ParserBmpError;
use crate::parser::bmp::messages::BmpPeerType;
use crate::parser::ReadUtils;
use bytes::{Buf, Bytes};
use num_enum::{IntoPrimitive, TryFromPrimitive};
use std::convert::TryFrom;

#[derive(Debug, PartialEq, Clone)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
pub struct RouteMirroring {
    pub tlvs: Vec<RouteMirroringTlv>,
}

#[derive(Debug, PartialEq, Clone)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
pub struct RouteMirroringTlv {
    pub info_len: u16,
    pub value: RouteMirroringValue,
}

#[derive(Debug, PartialEq, Clone)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
pub enum RouteMirroringValue {
    BgpMessage(BgpMessage),
    Information(RouteMirroringInfo),
}

#[derive(Debug, TryFromPrimitive, IntoPrimitive, PartialEq, Clone, Copy)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
#[repr(u16)]
pub enum RouteMirroringInfo {
    ErroredPdu = 0,
    MessageLost = 1,
}

pub fn parse_route_mirroring(
    data: &mut Bytes,
    asn_len: &AsnLength,
    _peer_type: Option<&BmpPeerType>,
) -> Result<RouteMirroring, ParserBmpError> {
    let mut tlvs = vec![];
    while data.remaining() > 4 {
        match data.read_u16()? {
            0 => {
                let info_len = data.read_u16()?;
                data.has_n_remaining(info_len as usize)?;
                let mut bytes = data.split_to(info_len as usize);
                let value = parse_bgp_message(&mut bytes, false, asn_len)?;
                tlvs.push(RouteMirroringTlv {
                    info_len,
                    value: RouteMirroringValue::BgpMessage(value),
                });
            }
            1 => {
                let info_len = data.read_u16()?;
                let value = RouteMirroringInfo::try_from(data.read_u16()?)?;
                tlvs.push(RouteMirroringTlv {
                    info_len,
                    value: RouteMirroringValue::Information(value),
                });
            }
            _ => {
                return Err(ParserBmpError::CorruptedBmpMessage);
            }
        }
    }
    Ok(RouteMirroring { tlvs })
}

#[cfg(test)]
mod tests {
    use super::*;
    use bytes::{BufMut, BytesMut};
    use std::net::Ipv4Addr;

    #[test]
    fn test_route_mirroring_bgp_messsage() {
        let bgp_message = BgpMessage::Open(BgpOpenMessage {
            version: 4,
            asn: Asn::new_32bit(1),
            hold_time: 180,
            sender_ip: Ipv4Addr::new(192, 0, 2, 1),
            extended_length: false,
            opt_params: vec![],
        });
        let bgp_message_bytes = bgp_message.encode(AsnLength::Bits32);
        let expected_asn_len = AsnLength::Bits32;
        let actual_info_len = bgp_message_bytes.len() as u16;

        let mut message = BytesMut::new();
        message.put_u16(0);
        message.put_u16(actual_info_len);
        message.put_slice(&bgp_message_bytes);
        let mut data = message.freeze();
        let result = parse_route_mirroring(&mut data, &expected_asn_len, None);

        match result {
            Ok(route_mirroring) => {
                assert_eq!(route_mirroring.tlvs.len(), 1);
                let tlv = &route_mirroring.tlvs[0];
                assert_eq!(tlv.info_len, actual_info_len);
            }
            Err(_) => panic!("Error parsing route mirroring"),
        }
    }

    #[test]
    fn route_mirroring_information() {
        let mut message = BytesMut::new();
        message.put_u16(1);
        message.put_u16(2);
        message.put_u16(0);
        let mut data = message.freeze();
        let result = parse_route_mirroring(&mut data, &AsnLength::Bits32, None).unwrap();
        assert_eq!(result.tlvs.len(), 1);
        let tlv = &result.tlvs[0];
        assert_eq!(tlv.info_len, 2);
        match &tlv.value {
            RouteMirroringValue::Information(info) => {
                assert_eq!(info, &RouteMirroringInfo::ErroredPdu)
            }
            _ => panic!("Expected RouteMirroringValue::Information"),
        }
    }
}
