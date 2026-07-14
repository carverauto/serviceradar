use super::*;
use crate::models::NetworkPrefix;
use ipnet::IpNet;

#[cfg(test)]
use std::str::FromStr;

/// Parse Flow-Spec NLRI from byte data according to RFC 8955/8956
pub fn parse_flowspec_nlri(data: &[u8]) -> Result<FlowSpecNlri, FlowSpecError> {
    let mut offset = 0;
    let length = parse_length(data, &mut offset)?;

    if offset + length as usize > data.len() {
        return Err(FlowSpecError::InsufficientData);
    }

    let end_offset = offset + length as usize;
    let mut components = Vec::new();
    let mut last_type = 0u8;

    while offset < end_offset {
        let component_type = data[offset];
        offset += 1;

        // Verify ordering
        if component_type <= last_type {
            return Err(FlowSpecError::InvalidComponentOrder {
                expected_greater_than: last_type,
                found: component_type,
            });
        }
        last_type = component_type;

        let component = match component_type {
            1 => parse_destination_prefix(data, &mut offset)?,
            2 => parse_source_prefix(data, &mut offset)?,
            3 => parse_ip_protocol(data, &mut offset)?,
            4 => parse_port(data, &mut offset)?,
            5 => parse_destination_port(data, &mut offset)?,
            6 => parse_source_port(data, &mut offset)?,
            7 => parse_icmp_type(data, &mut offset)?,
            8 => parse_icmp_code(data, &mut offset)?,
            9 => parse_tcp_flags(data, &mut offset)?,
            10 => parse_packet_length(data, &mut offset)?,
            11 => parse_dscp(data, &mut offset)?,
            12 => parse_fragment(data, &mut offset)?,
            13 => parse_flow_label(data, &mut offset)?,
            _ => return Err(FlowSpecError::InvalidComponentType(component_type)),
        };

        components.push(component);
    }

    Ok(FlowSpecNlri { components })
}

/// Encode Flow-Spec NLRI to byte data
pub fn encode_flowspec_nlri(nlri: &FlowSpecNlri) -> Vec<u8> {
    let mut data = Vec::new();

    // Encode each component
    for component in &nlri.components {
        data.push(component.component_type());

        match component {
            FlowSpecComponent::DestinationPrefix(prefix)
            | FlowSpecComponent::SourcePrefix(prefix) => {
                encode_prefix(prefix, &mut data);
            }
            FlowSpecComponent::DestinationIpv6Prefix { offset, prefix }
            | FlowSpecComponent::SourceIpv6Prefix { offset, prefix } => {
                encode_ipv6_prefix(*offset, prefix, &mut data);
            }
            FlowSpecComponent::IpProtocol(ops)
            | FlowSpecComponent::Port(ops)
            | FlowSpecComponent::DestinationPort(ops)
            | FlowSpecComponent::SourcePort(ops)
            | FlowSpecComponent::IcmpType(ops)
            | FlowSpecComponent::IcmpCode(ops)
            | FlowSpecComponent::PacketLength(ops)
            | FlowSpecComponent::Dscp(ops)
            | FlowSpecComponent::FlowLabel(ops) => {
                encode_numeric_operators(ops, &mut data);
            }
            FlowSpecComponent::TcpFlags(ops) | FlowSpecComponent::Fragment(ops) => {
                encode_bitmask_operators(ops, &mut data);
            }
        }
    }

    // Prepend length
    let mut result = Vec::new();
    encode_length(data.len() as u16, &mut result);
    result.extend(data);
    result
}

/// Parse length field (1 or 2 octets)
pub(crate) fn parse_length(data: &[u8], offset: &mut usize) -> Result<u16, FlowSpecError> {
    if *offset >= data.len() {
        return Err(FlowSpecError::InsufficientData);
    }

    let first_byte = data[*offset];
    *offset += 1;

    if first_byte < 240 {
        Ok(first_byte as u16)
    } else {
        if *offset >= data.len() {
            return Err(FlowSpecError::InsufficientData);
        }
        let second_byte = data[*offset];
        *offset += 1;
        Ok(((first_byte & 0x0F) as u16) << 8 | second_byte as u16)
    }
}

/// Encode length field (1 or 2 octets)
pub(crate) fn encode_length(length: u16, data: &mut Vec<u8>) {
    if length < 240 {
        data.push(length as u8);
    } else {
        data.push(0xF0 | ((length >> 8) as u8));
        data.push(length as u8);
    }
}

/// Parse prefix component (Types 1 & 2)
fn parse_prefix_component(data: &[u8], offset: &mut usize) -> Result<NetworkPrefix, FlowSpecError> {
    if *offset >= data.len() {
        return Err(FlowSpecError::InsufficientData);
    }

    let prefix_len = data[*offset];
    *offset += 1;

    let prefix_bytes = prefix_len.div_ceil(8);
    if *offset + prefix_bytes as usize > data.len() {
        return Err(FlowSpecError::InsufficientData);
    }

    let prefix_data = &data[*offset..*offset + prefix_bytes as usize];
    *offset += prefix_bytes as usize;

    // Construct prefix based on address family
    let prefix = if prefix_bytes <= 4 {
        // IPv4
        let mut addr_bytes = [0u8; 4];
        addr_bytes[..prefix_data.len()].copy_from_slice(prefix_data);
        let addr = std::net::Ipv4Addr::from(addr_bytes);
        let ipnet = IpNet::V4(
            ipnet::Ipv4Net::new(addr, prefix_len).map_err(|_| FlowSpecError::InvalidPrefix)?,
        );
        NetworkPrefix::new(ipnet, None)
    } else {
        // IPv6
        let mut addr_bytes = [0u8; 16];
        addr_bytes[..prefix_data.len()].copy_from_slice(prefix_data);
        let addr = std::net::Ipv6Addr::from(addr_bytes);
        let ipnet = IpNet::V6(
            ipnet::Ipv6Net::new(addr, prefix_len).map_err(|_| FlowSpecError::InvalidPrefix)?,
        );
        NetworkPrefix::new(ipnet, None)
    };

    Ok(prefix)
}

/// Parse destination prefix (Type 1)
fn parse_destination_prefix(
    data: &[u8],
    offset: &mut usize,
) -> Result<FlowSpecComponent, FlowSpecError> {
    let prefix = parse_prefix_component(data, offset)?;
    Ok(FlowSpecComponent::DestinationPrefix(prefix))
}

/// Parse source prefix (Type 2)
fn parse_source_prefix(
    data: &[u8],
    offset: &mut usize,
) -> Result<FlowSpecComponent, FlowSpecError> {
    let prefix = parse_prefix_component(data, offset)?;
    Ok(FlowSpecComponent::SourcePrefix(prefix))
}

/// Parse numeric operators sequence
fn parse_numeric_operators(
    data: &[u8],
    offset: &mut usize,
) -> Result<Vec<NumericOperator>, FlowSpecError> {
    let mut operators = Vec::new();

    loop {
        if *offset >= data.len() {
            return Err(FlowSpecError::InsufficientData);
        }

        let operator_byte = data[*offset];
        *offset += 1;

        let value_length = match (operator_byte >> 4) & 0x03 {
            0 => 1,
            1 => 2,
            2 => 4,
            3 => 8,
            _ => {
                return Err(FlowSpecError::InvalidValueLength(
                    (operator_byte >> 4) & 0x03,
                ))
            }
        };

        if *offset + value_length > data.len() {
            return Err(FlowSpecError::InsufficientData);
        }

        let value = read_value(&data[*offset..*offset + value_length]);
        *offset += value_length;

        let operator = NumericOperator::from_byte_and_value(operator_byte, value)?;
        let is_end = operator.end_of_list;
        operators.push(operator);

        if is_end {
            break;
        }
    }

    Ok(operators)
}

/// Parse bitmask operators sequence
fn parse_bitmask_operators(
    data: &[u8],
    offset: &mut usize,
) -> Result<Vec<BitmaskOperator>, FlowSpecError> {
    let mut operators = Vec::new();

    loop {
        if *offset >= data.len() {
            return Err(FlowSpecError::InsufficientData);
        }

        let operator_byte = data[*offset];
        *offset += 1;

        let value_length = match (operator_byte >> 4) & 0x03 {
            0 => 1,
            1 => 2,
            2 => 4,
            3 => 8,
            _ => {
                return Err(FlowSpecError::InvalidValueLength(
                    (operator_byte >> 4) & 0x03,
                ))
            }
        };

        if *offset + value_length > data.len() {
            return Err(FlowSpecError::InsufficientData);
        }

        let bitmask = read_value(&data[*offset..*offset + value_length]);
        *offset += value_length;

        let operator = BitmaskOperator::from_byte_and_value(operator_byte, bitmask)?;
        let is_end = operator.end_of_list;
        operators.push(operator);

        if is_end {
            break;
        }
    }

    Ok(operators)
}

/// Read value from bytes (big-endian)
fn read_value(bytes: &[u8]) -> u64 {
    let mut value = 0u64;
    for &byte in bytes {
        value = (value << 8) | byte as u64;
    }
    value
}

/// Write value to bytes (big-endian)
fn write_value(value: u64, length: usize, data: &mut Vec<u8>) {
    for i in (0..length).rev() {
        data.push((value >> (i * 8)) as u8);
    }
}

// Component parsers
fn parse_ip_protocol(data: &[u8], offset: &mut usize) -> Result<FlowSpecComponent, FlowSpecError> {
    let operators = parse_numeric_operators(data, offset)?;
    Ok(FlowSpecComponent::IpProtocol(operators))
}

fn parse_port(data: &[u8], offset: &mut usize) -> Result<FlowSpecComponent, FlowSpecError> {
    let operators = parse_numeric_operators(data, offset)?;
    Ok(FlowSpecComponent::Port(operators))
}

fn parse_destination_port(
    data: &[u8],
    offset: &mut usize,
) -> Result<FlowSpecComponent, FlowSpecError> {
    let operators = parse_numeric_operators(data, offset)?;
    Ok(FlowSpecComponent::DestinationPort(operators))
}

fn parse_source_port(data: &[u8], offset: &mut usize) -> Result<FlowSpecComponent, FlowSpecError> {
    let operators = parse_numeric_operators(data, offset)?;
    Ok(FlowSpecComponent::SourcePort(operators))
}

fn parse_icmp_type(data: &[u8], offset: &mut usize) -> Result<FlowSpecComponent, FlowSpecError> {
    let operators = parse_numeric_operators(data, offset)?;
    Ok(FlowSpecComponent::IcmpType(operators))
}

fn parse_icmp_code(data: &[u8], offset: &mut usize) -> Result<FlowSpecComponent, FlowSpecError> {
    let operators = parse_numeric_operators(data, offset)?;
    Ok(FlowSpecComponent::IcmpCode(operators))
}

fn parse_tcp_flags(data: &[u8], offset: &mut usize) -> Result<FlowSpecComponent, FlowSpecError> {
    let operators = parse_bitmask_operators(data, offset)?;
    Ok(FlowSpecComponent::TcpFlags(operators))
}

fn parse_packet_length(
    data: &[u8],
    offset: &mut usize,
) -> Result<FlowSpecComponent, FlowSpecError> {
    let operators = parse_numeric_operators(data, offset)?;
    Ok(FlowSpecComponent::PacketLength(operators))
}

fn parse_dscp(data: &[u8], offset: &mut usize) -> Result<FlowSpecComponent, FlowSpecError> {
    let operators = parse_numeric_operators(data, offset)?;
    Ok(FlowSpecComponent::Dscp(operators))
}

fn parse_fragment(data: &[u8], offset: &mut usize) -> Result<FlowSpecComponent, FlowSpecError> {
    let operators = parse_bitmask_operators(data, offset)?;
    Ok(FlowSpecComponent::Fragment(operators))
}

fn parse_flow_label(data: &[u8], offset: &mut usize) -> Result<FlowSpecComponent, FlowSpecError> {
    let operators = parse_numeric_operators(data, offset)?;
    Ok(FlowSpecComponent::FlowLabel(operators))
}

// Encoding functions
fn encode_prefix(prefix: &NetworkPrefix, data: &mut Vec<u8>) {
    let prefix_len = prefix.prefix.prefix_len();
    data.push(prefix_len);

    let prefix_bytes = prefix_len.div_ceil(8);
    let addr_bytes = match prefix.prefix.addr() {
        std::net::IpAddr::V4(addr) => addr.octets().to_vec(),
        std::net::IpAddr::V6(addr) => addr.octets().to_vec(),
    };

    data.extend(&addr_bytes[..prefix_bytes as usize]);
}

fn encode_ipv6_prefix(offset: u8, prefix: &NetworkPrefix, data: &mut Vec<u8>) {
    data.push(prefix.prefix.prefix_len());
    data.push(offset);

    let prefix_bytes = prefix.prefix.prefix_len().div_ceil(8);
    if let std::net::IpAddr::V6(addr) = prefix.prefix.addr() {
        let addr_bytes = addr.octets();
        data.extend(&addr_bytes[..prefix_bytes as usize]);
    }
}

fn encode_numeric_operators(operators: &[NumericOperator], data: &mut Vec<u8>) {
    for operator in operators {
        data.push(operator.to_byte());
        write_value(operator.value, operator.value_length as usize, data);
    }
}

fn encode_bitmask_operators(operators: &[BitmaskOperator], data: &mut Vec<u8>) {
    for operator in operators {
        data.push(operator.to_byte());
        write_value(operator.bitmask, operator.value_length as usize, data);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_length_encoding() {
        // Test short length
        let mut data = Vec::new();
        encode_length(100, &mut data);
        assert_eq!(data, vec![100]);

        let mut offset = 0;
        let parsed_len = parse_length(&data, &mut offset).unwrap();
        assert_eq!(parsed_len, 100);
        assert_eq!(offset, 1);

        // Test extended length
        let mut data = Vec::new();
        encode_length(1000, &mut data);
        assert_eq!(data, vec![0xF3, 0xE8]); // 1000 = 0x3E8

        let mut offset = 0;
        let parsed_len = parse_length(&data, &mut offset).unwrap();
        assert_eq!(parsed_len, 1000);
        assert_eq!(offset, 2);
    }

    #[test]
    fn test_read_write_value() {
        // Test 1 byte
        assert_eq!(read_value(&[0x25]), 0x25);

        // Test 2 bytes
        assert_eq!(read_value(&[0x01, 0xBB]), 443);

        // Test 4 bytes
        assert_eq!(read_value(&[0x00, 0x00, 0x00, 0x50]), 80);

        // Test writing
        let mut data = Vec::new();
        write_value(443, 2, &mut data);
        assert_eq!(data, vec![0x01, 0xBB]);
    }

    #[test]
    fn test_simple_nlri_parsing() {
        // Packets to 192.0.2.0/24 and TCP (protocol 6)
        let data = vec![
            0x08, // Length: 8 bytes (the actual NLRI content length)
            0x01, // Type 1: Destination Prefix
            0x18, // /24
            0xC0, 0x00, 0x02, // 192.0.2.0
            0x03, // Type 3: IP Protocol
            0x81, // end=1, and=0, len=00, eq=1
            0x06, // TCP
        ];

        let nlri = parse_flowspec_nlri(&data).unwrap();
        assert_eq!(nlri.components.len(), 2);

        match &nlri.components[0] {
            FlowSpecComponent::DestinationPrefix(prefix) => {
                assert_eq!(prefix.to_string(), "192.0.2.0/24");
            }
            _ => panic!("Expected destination prefix"),
        }

        match &nlri.components[1] {
            FlowSpecComponent::IpProtocol(ops) => {
                assert_eq!(ops.len(), 1);
                assert_eq!(ops[0].value, 6);
                assert!(ops[0].equal);
            }
            _ => panic!("Expected IP protocol"),
        }
    }

    #[test]
    fn test_nlri_round_trip() {
        let original_nlri = FlowSpecNlri::new(vec![
            FlowSpecComponent::DestinationPrefix(NetworkPrefix::from_str("192.0.2.0/24").unwrap()),
            FlowSpecComponent::IpProtocol(vec![NumericOperator::equal_to(6)]),
            FlowSpecComponent::DestinationPort(vec![NumericOperator::equal_to(80)]),
        ]);

        let encoded = encode_flowspec_nlri(&original_nlri);
        let parsed_nlri = parse_flowspec_nlri(&encoded).unwrap();

        assert_eq!(original_nlri, parsed_nlri);
    }
}
