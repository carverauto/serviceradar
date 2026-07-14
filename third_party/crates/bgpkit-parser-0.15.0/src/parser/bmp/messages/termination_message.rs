use crate::parser::bmp::error::ParserBmpError;
use crate::parser::ReadUtils;
use bytes::{Buf, Bytes};
use num_enum::{IntoPrimitive, TryFromPrimitive};
use std::convert::TryFrom;

#[derive(Debug, PartialEq, Clone)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
pub struct TerminationMessage {
    pub tlvs: Vec<TerminationTlv>,
}

#[derive(Debug, PartialEq, Clone)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
pub struct TerminationTlv {
    pub info_type: TerminationTlvType,
    pub info_len: u16,
    pub info_value: TerminationTlvValue,
}

#[derive(Debug, PartialEq, Clone)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
pub enum TerminationTlvValue {
    String(String),
    Reason(TerminationReason),
}

#[derive(Debug, TryFromPrimitive, IntoPrimitive, PartialEq, Clone, Copy)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
#[repr(u16)]
pub enum TerminationReason {
    AdministrativelyClosed = 0,
    UnspecifiedReason = 1,
    OutOfResources = 2,
    RedundantConnection = 3,
    PermanentlyAdministrativelyClosed = 4,
}

///Type-Length-Value Type
///
/// For more, see: https://datatracker.ietf.org/doc/html/rfc1213
#[derive(Debug, TryFromPrimitive, IntoPrimitive, PartialEq, Clone, Copy)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
#[repr(u16)]
pub enum TerminationTlvType {
    String = 0,
    Reason = 1,
}

pub fn parse_termination_message(data: &mut Bytes) -> Result<TerminationMessage, ParserBmpError> {
    let mut tlvs = vec![];

    while data.remaining() > 4 {
        let info_type: TerminationTlvType = TerminationTlvType::try_from(data.read_u16()?)?;
        let info_len = data.read_u16()?;
        if data.remaining() < info_len as usize {
            // not enough bytes to read
            break;
        }
        let info_value = match info_type {
            TerminationTlvType::String => {
                let info = data.read_n_bytes_to_string(info_len as usize)?;
                TerminationTlvValue::String(info)
            }
            TerminationTlvType::Reason => {
                let reason = TerminationReason::try_from(data.read_u16()?)?;
                TerminationTlvValue::Reason(reason)
            }
        };
        tlvs.push(TerminationTlv {
            info_type,
            info_len,
            info_value,
        })
    }

    Ok(TerminationMessage { tlvs })
}

#[cfg(test)]
mod tests {
    use super::*;
    use bytes::Bytes;

    #[test]
    fn test_parse_termination_message() {
        // Create a Bytes object to simulate the incoming data
        let mut data = Bytes::copy_from_slice(&[
            0, 0, // info_type: String
            0, 5, // info_len: 5
            67, 79, 68, 69, 83, // info: "CODES"
            0, 1, // info_type: Reason
            0, 2, // info_len: 2
            0, 1, // info: UnspecifiedReason
        ]);

        // Check if parse_termination_message correctly reads the data
        let result = parse_termination_message(&mut data);
        match result {
            Ok(termination_message) => {
                assert_eq!(termination_message.tlvs.len(), 2);

                // tlvs[0] assertions
                assert_eq!(
                    termination_message.tlvs[0].info_type,
                    TerminationTlvType::String
                );
                assert_eq!(termination_message.tlvs[0].info_len, 5);
                assert_eq!(
                    termination_message.tlvs[0].info_value,
                    TerminationTlvValue::String("CODES".to_string())
                );

                // tlvs[1] assertions
                assert_eq!(
                    termination_message.tlvs[1].info_type,
                    TerminationTlvType::Reason
                );
                assert_eq!(termination_message.tlvs[1].info_len, 2);
                assert_eq!(
                    termination_message.tlvs[1].info_value,
                    TerminationTlvValue::Reason(TerminationReason::UnspecifiedReason)
                );
            }
            Err(e) => panic!("Failed to parse: {e}"),
        }
    }

    #[test]
    fn test_parse_termination_message_truncated() {
        // Test case where there's not enough bytes to read for a TLV

        // Case 1: Not enough bytes for info_len
        let mut data = Bytes::copy_from_slice(&[
            0, 0, // info_type: String
            0, // Only one byte for info_len, should be two
        ]);

        let result = parse_termination_message(&mut data);
        assert!(result.is_ok());
        assert_eq!(result.unwrap().tlvs.len(), 0);

        // Case 2: Not enough bytes for info_value
        let mut data = Bytes::copy_from_slice(&[
            0, 0, // info_type: String
            0, 5, // info_len: 5
            67, 79, 68, // Only 3 bytes for info_value, should be 5
        ]);

        let result = parse_termination_message(&mut data);
        // This should still succeed, but with an empty TLV list
        // because the function breaks out of the loop when there's not enough bytes
        assert!(result.is_ok());
        assert_eq!(result.unwrap().tlvs.len(), 0);

        // Case 3: Not enough bytes for the second TLV's info_value
        let mut data = Bytes::copy_from_slice(&[
            0, 0, // info_type: String
            0, 5, // info_len: 5
            67, 79, 68, 69, 83, // info: "CODES"
            0, 1, // info_type: Reason
            0, 2, // info_len: 2
            0, // Only one byte for info_value, should be two
        ]);

        let result = parse_termination_message(&mut data);
        // This should still succeed, but with only the first TLV
        assert!(result.is_ok());
        let termination_message = result.unwrap();
        assert_eq!(termination_message.tlvs.len(), 1);
        assert_eq!(
            termination_message.tlvs[0].info_type,
            TerminationTlvType::String
        );
        assert_eq!(
            termination_message.tlvs[0].info_value,
            TerminationTlvValue::String("CODES".to_string())
        );
    }
}
