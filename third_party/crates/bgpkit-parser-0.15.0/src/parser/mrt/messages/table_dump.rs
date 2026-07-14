use crate::error::*;
use crate::models::*;
use crate::parser::bgp::attributes::parse_attributes;
use crate::parser::ReadUtils;
use bytes::{BufMut, Bytes, BytesMut};
use ipnet::IpNet;
use std::net::IpAddr;

/// Parse MRT TABLE_DUMP type message.
///
/// <https://www.rfc-editor.org/rfc/rfc6396#section-4.2>
///
/// ```text
/// The TABLE_DUMP Type does not permit 4-byte Peer AS numbers, nor does
//  it allow the AFI of the peer IP to differ from the AFI of the Prefix
//  field.  The TABLE_DUMP_V2 Type MUST be used in these situations.
/// ```
///
/// ```text
///  0                   1                   2                   3
///  0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
/// +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
/// |         View Number           |       Sequence Number         |
/// +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
/// |                        Prefix (variable)                      |
/// +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
/// | Prefix Length |    Status     |
/// +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
/// |                         Originated Time                       |
/// +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
/// |                    Peer IP Address (variable)                 |
/// +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
/// |           Peer AS             |       Attribute Length        |
/// +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
/// |                   BGP Attribute... (variable)
/// +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
/// ```
pub fn parse_table_dump_message(
    sub_type: u16,
    mut data: Bytes,
) -> Result<TableDumpMessage, ParserError> {
    // ####
    // Step 0. prepare
    //   - define AS number length
    //   - determine address family
    //   - create data slice reader cursor

    // determine address family based on the sub_type value defined in the MRT [CommonHeader].
    let afi = match sub_type {
        1 => Afi::Ipv4,
        2 => Afi::Ipv6,
        _ => {
            return Err(ParserError::ParseError(format!(
                "Invalid subtype found for TABLE_DUMP (V1) message: {sub_type}"
            )))
        }
    };

    // ####
    // Step 1. read simple fields
    //   - view number
    //   - sequence number
    //   - prefix
    //   - prefix-length
    //   - status
    //   - originated time
    //   - peer IP address
    //   - peer ASN
    //   - attribute length

    let view_number = data.read_u16()?;
    let sequence_number = data.read_u16()?;
    let prefix = match &afi {
        Afi::Ipv4 => data.read_ipv4_prefix().map(ipnet::IpNet::V4),
        Afi::Ipv6 => data.read_ipv6_prefix().map(ipnet::IpNet::V6),
        Afi::LinkState => {
            // Link-State doesn't use traditional prefixes, but we need a placeholder
            // Use 0.0.0.0/0 as a placeholder for now
            Ok(ipnet::IpNet::V4(
                ipnet::Ipv4Net::new(std::net::Ipv4Addr::new(0, 0, 0, 0), 0).unwrap(),
            ))
        }
    }?;

    let status = data.read_u8()?;
    let time = data.read_u32()? as u64;

    let peer_ip: IpAddr = data.read_address(&afi)?;
    let peer_asn = Asn::new_16bit(data.read_u16()?);

    let attribute_length = data.read_u16()? as usize;

    // ####
    // Step 2. read the attributes
    //   - create subslice based on the cursor's current position
    //   - pass the data into the parser function

    data.has_n_remaining(attribute_length)?;
    let attr_data_slice = data.split_to(attribute_length);

    // for TABLE_DUMP type, the AS number length is always 2-byte.
    let attributes =
        parse_attributes(attr_data_slice, &AsnLength::Bits16, false, None, None, None)?;

    Ok(TableDumpMessage {
        view_number,
        sequence_number,
        prefix: NetworkPrefix::new(prefix, None),
        status,
        originated_time: time,
        peer_ip,
        peer_asn,
        attributes,
    })
}

impl TableDumpMessage {
    pub fn encode(&self) -> Bytes {
        let mut bytes = BytesMut::new();
        bytes.put_u16(self.view_number);
        bytes.put_u16(self.sequence_number);
        match &self.prefix.prefix {
            IpNet::V4(p) => {
                bytes.put_u32(p.addr().into());
                bytes.put_u8(p.prefix_len());
            }
            IpNet::V6(p) => {
                bytes.put_u128(p.addr().into());
                bytes.put_u8(p.prefix_len());
            }
        }
        bytes.put_u8(self.status);
        bytes.put_u32(self.originated_time as u32);

        // peer address and peer asn
        match self.peer_ip {
            IpAddr::V4(a) => {
                bytes.put_u32(a.into());
            }
            IpAddr::V6(a) => {
                bytes.put_u128(a.into());
            }
        }
        bytes.put_u16(self.peer_asn.into());

        // encode attributes
        let mut attr_bytes = BytesMut::new();
        for attr in &self.attributes.inner {
            // asn_len always 16 bites
            attr_bytes.extend(attr.encode(AsnLength::Bits16));
        }

        bytes.put_u16(attr_bytes.len() as u16);
        bytes.put_slice(&attr_bytes);

        bytes.freeze()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use bytes::{BufMut, BytesMut};
    use std::net::{Ipv4Addr, Ipv6Addr};

    const VIEW_NUMBER: u16 = 0;
    const SEQUENCE_NUMBER: u16 = 0;
    const IPV4_PREFIX: Ipv4Addr = Ipv4Addr::new(0, 0, 0, 0);
    const IPV6_PREFIX: Ipv6Addr = Ipv6Addr::new(0, 0, 0, 0, 0, 0, 0, 0);
    const PREFIX_LEN: u8 = 0;
    const STATUS: u8 = 0;
    const TIME: u64 = 0;
    const PEER_IPV4: Ipv4Addr = Ipv4Addr::new(0, 0, 0, 0);
    const PEER_IPV6: Ipv6Addr = Ipv6Addr::new(0, 0, 0, 0, 0, 0, 0, 0);
    const PEER_ASN_16BIT: u16 = 0;
    const ATTRIBUTE_LENGTH: usize = 0;
    const DUMMY_ATTRIBUTES: &[u8] = &[];

    #[test]
    fn test_parse_table_dump_message_ipv4() {
        let mut bytes_mut = BytesMut::new();
        // Populate the bytes_mut with the same sequence that parse_table_dump_message() expects to parse
        bytes_mut.put_u16(VIEW_NUMBER);
        bytes_mut.put_u16(SEQUENCE_NUMBER);
        bytes_mut.put_u32(IPV4_PREFIX.into());
        bytes_mut.put_u8(PREFIX_LEN);
        bytes_mut.put_u8(STATUS);
        bytes_mut.put_u32(TIME as u32);
        bytes_mut.put_u32(PEER_IPV4.into());
        bytes_mut.put_u16(PEER_ASN_16BIT);
        bytes_mut.put_u16(ATTRIBUTE_LENGTH as u16);
        bytes_mut.put_slice(DUMMY_ATTRIBUTES);

        // Convert from BytesMut to Bytes
        let bytes = bytes_mut.freeze();

        let table_dump_message_res = parse_table_dump_message(1, bytes.clone());
        assert!(
            table_dump_message_res.is_ok(),
            "Failed to parse TABLE_DUMP_V1 message"
        );

        let table_dump_message = table_dump_message_res.unwrap();
        assert_eq!(
            table_dump_message.view_number, VIEW_NUMBER,
            "VIEW_NUMBER mismatch"
        );
        assert_eq!(
            table_dump_message.sequence_number, SEQUENCE_NUMBER,
            "SEQUENCE_NUMBER mismatch"
        );
        // Add more assertions here as per your actual requirements
        let encoded = table_dump_message.encode();
        assert_eq!(encoded, bytes);
    }
    #[test]
    fn test_parse_table_dump_message_ipv6() {
        let mut bytes_mut = BytesMut::new();
        // Populate the bytes_mut with the same sequence that parse_table_dump_message() expects to parse
        bytes_mut.put_u16(VIEW_NUMBER);
        bytes_mut.put_u16(SEQUENCE_NUMBER);
        bytes_mut.put_u128(IPV6_PREFIX.into());
        bytes_mut.put_u8(PREFIX_LEN);
        bytes_mut.put_u8(STATUS);
        bytes_mut.put_u32(TIME as u32);
        bytes_mut.put_u128(PEER_IPV6.into());
        bytes_mut.put_u16(PEER_ASN_16BIT);
        bytes_mut.put_u16(ATTRIBUTE_LENGTH as u16);
        bytes_mut.put_slice(DUMMY_ATTRIBUTES);

        // Convert from BytesMut to Bytes
        let bytes = bytes_mut.freeze();

        let table_dump_message_res = parse_table_dump_message(2, bytes.clone());
        assert!(
            table_dump_message_res.is_ok(),
            "Failed to parse TABLE_DUMP_V1 message"
        );

        let table_dump_message = table_dump_message_res.unwrap();
        assert_eq!(
            table_dump_message.view_number, VIEW_NUMBER,
            "VIEW_NUMBER mismatch"
        );
        assert_eq!(
            table_dump_message.sequence_number, SEQUENCE_NUMBER,
            "SEQUENCE_NUMBER mismatch"
        );
        // Add more assertions here as per your actual requirements

        // test encoding
        let encoded = table_dump_message.encode();
        assert_eq!(encoded, bytes);
    }

    #[test]
    fn test_parse_table_dump_message_invalid_subtype() {
        // Create a simple byte array for testing
        let mut bytes_mut = BytesMut::new();
        bytes_mut.put_u16(VIEW_NUMBER);
        bytes_mut.put_u16(SEQUENCE_NUMBER);
        let bytes = bytes_mut.freeze();

        // Test with an invalid sub_type (not 1 or 2)
        let result = parse_table_dump_message(0, bytes.clone());
        assert!(result.is_err(), "Expected error for invalid sub_type");

        if let Err(ParserError::ParseError(msg)) = result {
            assert!(
                msg.contains("Invalid subtype"),
                "Expected error message to mention invalid subtype"
            );
        } else {
            panic!("Expected ParseError for invalid sub_type");
        }

        // Test with another invalid sub_type
        let result = parse_table_dump_message(3, bytes);
        assert!(result.is_err(), "Expected error for invalid sub_type");

        if let Err(ParserError::ParseError(msg)) = result {
            assert!(
                msg.contains("Invalid subtype"),
                "Expected error message to mention invalid subtype"
            );
        } else {
            panic!("Expected ParseError for invalid sub_type");
        }
    }

    #[test]
    fn test_table_dump_message_encode_with_attributes() {
        use crate::models::{Asn, AttributeValue, Attributes, Origin};
        use std::str::FromStr;

        let prefix = IpNet::from_str("192.168.0.0/24").unwrap();
        let mut attributes = Attributes::default();
        attributes.add_attr(AttributeValue::Origin(Origin::IGP).into());

        let table_dump = TableDumpMessage {
            view_number: 1,
            sequence_number: 2,
            prefix: NetworkPrefix::new(prefix, None),
            status: 1,
            originated_time: 12345,
            peer_ip: IpAddr::V4("10.0.0.1".parse().unwrap()),
            peer_asn: Asn::from(65000),
            attributes,
        };

        // This should exercise the attr.encode(AsnLength::Bits16) line
        let _encoded = table_dump.encode();
    }
}
