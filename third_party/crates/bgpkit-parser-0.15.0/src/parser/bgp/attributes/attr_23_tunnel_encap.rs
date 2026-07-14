//! BGP Tunnel Encapsulation attribute parsing - RFC 9012

use bytes::{Buf, BufMut, Bytes, BytesMut};

use crate::error::ParserError;
use crate::models::*;
use crate::parser::ReadUtils;

/// Parse BGP Tunnel Encapsulation attribute (type 23)
pub fn parse_tunnel_encapsulation_attribute(
    mut data: Bytes,
) -> Result<AttributeValue, ParserError> {
    let mut attr = TunnelEncapAttribute::new();

    while data.remaining() >= 4 {
        let tunnel_type = data.read_u16()?;
        let tunnel_length = data.read_u16()?;

        if data.remaining() < tunnel_length as usize {
            return Err(ParserError::TruncatedMsg(format!(
                "Expected {} bytes for Tunnel TLV, but only {} remaining",
                tunnel_length,
                data.remaining()
            )));
        }

        let tunnel_data = data.read_n_bytes(tunnel_length as usize)?;
        let tunnel_tlv = parse_tunnel_tlv(tunnel_type, tunnel_data.into())?;
        attr.add_tunnel_tlv(tunnel_tlv);
    }

    Ok(AttributeValue::TunnelEncapsulation(attr))
}

/// Parse a single Tunnel TLV
fn parse_tunnel_tlv(tunnel_type: u16, mut data: Bytes) -> Result<TunnelEncapTlv, ParserError> {
    let tunnel_type = TunnelType::from(tunnel_type);
    let mut tunnel_tlv = TunnelEncapTlv::new(tunnel_type);

    while data.remaining() > 0 {
        if data.remaining() < 2 {
            return Err(ParserError::TruncatedMsg(
                "Not enough data for Sub-TLV header".to_string(),
            ));
        }

        let sub_tlv_type = data.read_u8()?;

        // Sub-TLV length encoding: 1 byte for types 0-127, 2 bytes for types 128-255
        let sub_tlv_length: u16 = if sub_tlv_type < 128 {
            if data.remaining() < 1 {
                return Err(ParserError::TruncatedMsg(
                    "Not enough data for Sub-TLV length".to_string(),
                ));
            }
            data.read_u8()? as u16
        } else {
            if data.remaining() < 2 {
                return Err(ParserError::TruncatedMsg(
                    "Not enough data for extended Sub-TLV length".to_string(),
                ));
            }
            data.read_u16()?
        };

        if data.remaining() < sub_tlv_length as usize {
            return Err(ParserError::TruncatedMsg(format!(
                "Expected {} bytes for Sub-TLV data, but only {} remaining",
                sub_tlv_length,
                data.remaining()
            )));
        }

        let sub_tlv_data = data.read_n_bytes(sub_tlv_length as usize)?;
        let sub_tlv_type_enum = SubTlvType::from(sub_tlv_type as u16);
        let sub_tlv = SubTlv::new(sub_tlv_type_enum, sub_tlv_data.to_vec());
        tunnel_tlv.add_sub_tlv(sub_tlv);
    }

    Ok(tunnel_tlv)
}

/// Encode BGP Tunnel Encapsulation attribute
pub fn encode_tunnel_encapsulation_attribute(attr: &TunnelEncapAttribute) -> Bytes {
    let mut bytes = BytesMut::new();

    for tunnel_tlv in &attr.tunnel_tlvs {
        // Encode tunnel type
        bytes.put_u16(tunnel_tlv.tunnel_type as u16);

        // Encode sub-TLVs first to calculate total length
        let mut sub_tlv_bytes = BytesMut::new();
        for sub_tlv in &tunnel_tlv.sub_tlvs {
            let sub_tlv_type = sub_tlv.sub_tlv_type as u16;

            // Encode sub-TLV type
            if sub_tlv_type < 128 {
                sub_tlv_bytes.put_u8(sub_tlv_type as u8);
                sub_tlv_bytes.put_u8(sub_tlv.value.len() as u8);
            } else {
                sub_tlv_bytes.put_u8(sub_tlv_type as u8);
                sub_tlv_bytes.put_u16(sub_tlv.value.len() as u16);
            }

            // Encode sub-TLV value
            sub_tlv_bytes.extend_from_slice(&sub_tlv.value);
        }

        // Encode tunnel length
        bytes.put_u16(sub_tlv_bytes.len() as u16);

        // Append sub-TLV data
        bytes.extend_from_slice(&sub_tlv_bytes);
    }

    bytes.freeze()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_parse_tunnel_encapsulation_simple() {
        let mut data = BytesMut::new();

        // Tunnel Type: VXLAN (8)
        data.put_u16(8);
        // Tunnel Length: 8 bytes (4 bytes for color sub-TLV)
        data.put_u16(6);
        // Color Sub-TLV: type=4, length=4, value=100
        data.put_u8(4);
        data.put_u8(4);
        data.put_u32(100);

        let bytes = data.freeze();
        let result = parse_tunnel_encapsulation_attribute(bytes).unwrap();

        if let AttributeValue::TunnelEncapsulation(attr) = result {
            assert_eq!(attr.tunnel_tlvs.len(), 1);

            let tunnel = &attr.tunnel_tlvs[0];
            assert_eq!(tunnel.tunnel_type, TunnelType::Vxlan);
            assert_eq!(tunnel.sub_tlvs.len(), 1);

            let sub_tlv = &tunnel.sub_tlvs[0];
            assert_eq!(sub_tlv.sub_tlv_type, SubTlvType::Color);
            assert_eq!(sub_tlv.value, vec![0, 0, 0, 100]);

            assert_eq!(tunnel.get_color(), Some(100));
        } else {
            panic!("Expected TunnelEncapsulation attribute");
        }
    }

    #[test]
    fn test_parse_tunnel_encapsulation_multiple_sub_tlvs() {
        let mut data = BytesMut::new();

        // Tunnel Type: VXLAN (8)
        data.put_u16(8);
        // Tunnel Length: 10 bytes total (4+2 for color, 2+2 for UDP port)
        data.put_u16(10);

        // Color Sub-TLV: type=4, length=4, value=100
        data.put_u8(4);
        data.put_u8(4);
        data.put_u32(100);

        // UDP Destination Port Sub-TLV: type=8, length=2, value=4789
        data.put_u8(8);
        data.put_u8(2);
        data.put_u16(4789);

        let bytes = data.freeze();
        let result = parse_tunnel_encapsulation_attribute(bytes).unwrap();

        if let AttributeValue::TunnelEncapsulation(attr) = result {
            assert_eq!(attr.tunnel_tlvs.len(), 1);

            let tunnel = &attr.tunnel_tlvs[0];
            assert_eq!(tunnel.tunnel_type, TunnelType::Vxlan);
            assert_eq!(tunnel.sub_tlvs.len(), 2);

            assert_eq!(tunnel.get_color(), Some(100));
            assert_eq!(tunnel.get_udp_destination_port(), Some(4789));
        } else {
            panic!("Expected TunnelEncapsulation attribute");
        }
    }

    #[test]
    fn test_parse_tunnel_encapsulation_extended_length() {
        let mut data = BytesMut::new();

        // Tunnel Type: SR Policy (15)
        data.put_u16(15);
        // Tunnel Length: 5 bytes (1 + 2 + 2 = 5 total)
        data.put_u16(5);

        // Segment List Sub-TLV (type 128): extended length format
        data.put_u8(128);
        data.put_u16(2); // 2-byte length field
        data.put_u16(0); // Empty segment list for test

        let bytes = data.freeze();
        let result = parse_tunnel_encapsulation_attribute(bytes).unwrap();

        if let AttributeValue::TunnelEncapsulation(attr) = result {
            assert_eq!(attr.tunnel_tlvs.len(), 1);

            let tunnel = &attr.tunnel_tlvs[0];
            assert_eq!(tunnel.tunnel_type, TunnelType::SrPolicy);
            assert_eq!(tunnel.sub_tlvs.len(), 1);

            let sub_tlv = &tunnel.sub_tlvs[0];
            assert_eq!(sub_tlv.sub_tlv_type, SubTlvType::SegmentList);
        } else {
            panic!("Expected TunnelEncapsulation attribute");
        }
    }

    #[test]
    fn test_encode_tunnel_encapsulation() {
        let mut attr = TunnelEncapAttribute::new();
        let mut tunnel_tlv = TunnelEncapTlv::new(TunnelType::Vxlan);

        // Add color sub-TLV
        let color_sub_tlv = SubTlv::new(SubTlvType::Color, vec![0, 0, 0, 100]);
        tunnel_tlv.add_sub_tlv(color_sub_tlv);

        attr.add_tunnel_tlv(tunnel_tlv);

        let encoded = encode_tunnel_encapsulation_attribute(&attr);

        // Should encode back to the same format we can parse
        let parsed = parse_tunnel_encapsulation_attribute(encoded).unwrap();

        if let AttributeValue::TunnelEncapsulation(parsed_attr) = parsed {
            assert_eq!(parsed_attr.tunnel_tlvs.len(), 1);
            assert_eq!(parsed_attr.tunnel_tlvs[0].tunnel_type, TunnelType::Vxlan);
            assert_eq!(parsed_attr.tunnel_tlvs[0].get_color(), Some(100));
        } else {
            panic!("Expected TunnelEncapsulation attribute");
        }
    }

    #[test]
    fn test_parse_tunnel_encapsulation_truncated() {
        // Test with truncated data
        let mut data = BytesMut::new();
        data.put_u16(8); // Tunnel type
        data.put_u16(10); // Tunnel length (but we'll only provide 2 bytes)
        data.put_u16(0); // Only 2 bytes instead of 10

        let bytes = data.freeze();
        let result = parse_tunnel_encapsulation_attribute(bytes);

        assert!(result.is_err());
        if let Err(ParserError::TruncatedMsg(msg)) = result {
            assert!(msg.contains("Expected 10 bytes"));
        } else {
            panic!("Expected TruncatedMsg error");
        }
    }

    #[test]
    fn test_tunnel_type_from_unknown() {
        // Test that unknown tunnel types get mapped to Reserved
        let tunnel_type = TunnelType::from(999u16);
        assert_eq!(tunnel_type, TunnelType::Reserved);
    }

    #[test]
    fn test_sub_tlv_type_from_unknown() {
        // Test that unknown sub-TLV types get mapped to Reserved
        let sub_tlv_type = SubTlvType::from(999u16);
        assert_eq!(sub_tlv_type, SubTlvType::Reserved);
    }
}
