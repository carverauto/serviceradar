use crate::parser::bmp::error::ParserBmpError;
use crate::parser::ReadUtils;
use bytes::{Buf, Bytes};
use num_enum::{IntoPrimitive, TryFromPrimitive};
use std::convert::TryFrom;

#[derive(Debug, Clone, PartialEq)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
pub struct InitiationMessage {
    pub tlvs: Vec<InitiationTlv>,
}

#[derive(Debug, PartialEq, Clone)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
pub struct InitiationTlv {
    pub info_type: InitiationTlvType,
    pub info_len: u16,
    pub info: String,
}

///Type-Length-Value Type
///
/// https://www.iana.org/assignments/bmp-parameters/bmp-parameters.xhtml#initiation-peer-up-tlvs
#[derive(Debug, TryFromPrimitive, IntoPrimitive, PartialEq, Clone, Copy)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
#[repr(u16)]
pub enum InitiationTlvType {
    String = 0,
    SysDescr = 1,
    SysName = 2,
    VrTableName = 3,
    AdminLabel = 4,
}

/// Parse BMP initiation message
///
/// <https://www.rfc-editor.org/rfc/rfc7854#section-4.3>
pub fn parse_initiation_message(data: &mut Bytes) -> Result<InitiationMessage, ParserBmpError> {
    let mut tlvs = vec![];

    while data.remaining() > 4 {
        let info_type: InitiationTlvType = InitiationTlvType::try_from(data.read_u16()?)?;
        let info_len = data.read_u16()?;
        if data.remaining() < info_len as usize {
            // not enough bytes to read
            break;
        }
        let info = data.read_n_bytes_to_string(info_len as usize)?;
        tlvs.push(InitiationTlv {
            info_type,
            info_len,
            info,
        });
    }

    Ok(InitiationMessage { tlvs })
}

#[cfg(test)]
mod tests {
    use super::*;
    use bytes::{BufMut, BytesMut};

    #[test]
    fn test_parse_initiation_message() {
        let mut buffer = BytesMut::new();
        buffer.put_u16(1); // InitiationTlvType::SysDescr
        buffer.put_u16(5); // Length of following info
        buffer.put_slice(b"Test1"); // Info

        let mut bytes = buffer.freeze();

        match parse_initiation_message(&mut bytes) {
            Ok(initiation_message) => {
                for tlv in initiation_message.tlvs {
                    assert_eq!(tlv.info_type, InitiationTlvType::SysDescr);
                    assert_eq!(tlv.info_len, 5);
                    assert_eq!(tlv.info, "Test1".to_string());
                }
            }
            Err(_) => panic!("Failed to parse initiation message"),
        }
    }

    #[test]
    fn test_debug() {
        let initiation_message = InitiationMessage {
            tlvs: vec![InitiationTlv {
                info_type: InitiationTlvType::SysDescr,
                info_len: 5,
                info: "Test1".to_string(),
            }],
        };
        assert_eq!(
            format!("{initiation_message:?}"),
            "InitiationMessage { tlvs: [InitiationTlv { info_type: SysDescr, info_len: 5, info: \"Test1\" }] }"
        );
    }
}
