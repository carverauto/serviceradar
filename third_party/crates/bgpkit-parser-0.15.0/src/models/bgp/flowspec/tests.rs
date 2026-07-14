use super::nlri::{encode_length, parse_length};
use super::*;
use crate::models::NetworkPrefix;
use std::str::FromStr;

/// Test cases based on RFC 8955 examples
#[cfg(test)]
mod rfc_examples {
    use super::*;

    #[test]
    fn test_rfc8955_example_1() {
        // "Packets to 192.0.2.0/24 and TCP port 25"
        // Length: 0x0b
        // Destination Prefix: 01 18 c0 00 02
        // Protocol: 03 81 06
        // Port: 04 81 19

        let data = vec![
            0x0B, // Length: 11 bytes
            0x01, // Type 1: Destination Prefix
            0x18, // /24
            0xC0, 0x00, 0x02, // 192.0.2.0
            0x03, // Type 3: IP Protocol
            0x81, // end=1, and=0, len=00, eq=1
            0x06, // TCP (6)
            0x04, // Type 4: Port
            0x81, // end=1, and=0, len=00, eq=1
            0x19, // Port 25
        ];

        let nlri = parse_flowspec_nlri(&data).unwrap();
        assert_eq!(nlri.components.len(), 3);

        // Check destination prefix
        match &nlri.components[0] {
            FlowSpecComponent::DestinationPrefix(prefix) => {
                assert_eq!(prefix.to_string(), "192.0.2.0/24");
            }
            _ => panic!("Expected destination prefix"),
        }

        // Check IP protocol
        match &nlri.components[1] {
            FlowSpecComponent::IpProtocol(ops) => {
                assert_eq!(ops.len(), 1);
                assert_eq!(ops[0].value, 6);
                assert!(ops[0].equal);
                assert!(ops[0].end_of_list);
            }
            _ => panic!("Expected IP protocol"),
        }

        // Check port
        match &nlri.components[2] {
            FlowSpecComponent::Port(ops) => {
                assert_eq!(ops.len(), 1);
                assert_eq!(ops[0].value, 25);
                assert!(ops[0].equal);
                assert!(ops[0].end_of_list);
            }
            _ => panic!("Expected port"),
        }

        // Test round-trip encoding
        let encoded = encode_flowspec_nlri(&nlri);
        assert_eq!(encoded, data);
    }

    #[test]
    fn test_rfc8955_example_2_partial() {
        // "Packets to 192.0.2.0/24 from 203.0.113.0/24 and port {range [137, 139] or 8080}"
        // This is a simplified version focusing on the prefix components

        let data = vec![
            0x0E, // Length: 14 bytes (corrected)
            0x01, // Type 1: Destination Prefix
            0x18, // /24
            0xC0, 0x00, 0x02, // 192.0.2.0
            0x02, // Type 2: Source Prefix
            0x18, // /24
            0xCB, 0x00, 0x71, // 203.0.113.0
            0x04, // Type 4: Port
            0x91, // end=1, and=0, len=01, eq=1
            0x1F, 0x90, // Port 8080
        ];

        let nlri = parse_flowspec_nlri(&data).unwrap();
        assert_eq!(nlri.components.len(), 3);

        // Check destination prefix
        match &nlri.components[0] {
            FlowSpecComponent::DestinationPrefix(prefix) => {
                assert_eq!(prefix.to_string(), "192.0.2.0/24");
            }
            _ => panic!("Expected destination prefix"),
        }

        // Check source prefix
        match &nlri.components[1] {
            FlowSpecComponent::SourcePrefix(prefix) => {
                assert_eq!(prefix.to_string(), "203.0.113.0/24");
            }
            _ => panic!("Expected source prefix"),
        }

        // Check port (simplified to just 8080)
        match &nlri.components[2] {
            FlowSpecComponent::Port(ops) => {
                assert_eq!(ops.len(), 1);
                assert_eq!(ops[0].value, 8080);
                assert!(ops[0].equal);
                assert_eq!(ops[0].value_length, 2);
            }
            _ => panic!("Expected port"),
        }
    }

    #[test]
    fn test_tcp_flags_component() {
        // TCP flags with SYN+ACK (0x12)
        let data = vec![
            0x03, // Length: 3 bytes (corrected)
            0x09, // Type 9: TCP Flags
            0x81, // end=1, and=0, len=00, not=0, match=1 (partial match)
            0x12, // SYN+ACK flags
        ];

        let nlri = parse_flowspec_nlri(&data).unwrap();
        assert_eq!(nlri.components.len(), 1);

        match &nlri.components[0] {
            FlowSpecComponent::TcpFlags(ops) => {
                assert_eq!(ops.len(), 1);
                assert_eq!(ops[0].bitmask, 0x12);
                assert!(ops[0].match_flag); // Partial match
                assert!(!ops[0].not);
                assert!(ops[0].end_of_list);
            }
            _ => panic!("Expected TCP flags"),
        }
    }

    #[test]
    fn test_packet_length_range() {
        // Packet length >= 1000 bytes
        let data = vec![
            0x04, // Length: 4 bytes (content after length byte)
            0x0A, // Type 10: Packet Length
            0x93, // end=1, and=0, len=01, 0, lt=0, gt=1, eq=1 (>=)
            0x03, 0xE8, // 1000 bytes
        ];

        let nlri = parse_flowspec_nlri(&data).unwrap();
        assert_eq!(nlri.components.len(), 1);

        match &nlri.components[0] {
            FlowSpecComponent::PacketLength(ops) => {
                assert_eq!(ops.len(), 1);
                assert_eq!(ops[0].value, 1000);
                assert!(ops[0].greater_than);
                assert!(ops[0].equal);
                assert!(!ops[0].less_than);
                assert_eq!(ops[0].value_length, 2);
            }
            _ => panic!("Expected packet length"),
        }
    }

    #[test]
    fn test_dscp_marking() {
        // DSCP value 46 (EF - Expedited Forwarding)
        let data = vec![
            0x03, // Length: 3 bytes
            0x0B, // Type 11: DSCP
            0x81, // end=1, and=0, len=00, eq=1
            0x2E, // DSCP 46 (EF)
        ];

        let nlri = parse_flowspec_nlri(&data).unwrap();
        assert_eq!(nlri.components.len(), 1);

        match &nlri.components[0] {
            FlowSpecComponent::Dscp(ops) => {
                assert_eq!(ops.len(), 1);
                assert_eq!(ops[0].value, 46);
                assert!(ops[0].equal);
            }
            _ => panic!("Expected DSCP"),
        }
    }

    #[test]
    fn test_fragment_component() {
        // Fragment: first fragment
        let data = vec![
            0x03, // Length: 3 bytes
            0x0C, // Type 12: Fragment
            0x81, // end=1, and=0, len=00, not=0, match=1
            0x01, // First fragment bit
        ];

        let nlri = parse_flowspec_nlri(&data).unwrap();
        assert_eq!(nlri.components.len(), 1);

        match &nlri.components[0] {
            FlowSpecComponent::Fragment(ops) => {
                assert_eq!(ops.len(), 1);
                assert_eq!(ops[0].bitmask, 0x01);
                assert!(ops[0].match_flag);
                assert!(!ops[0].not);
            }
            _ => panic!("Expected fragment"),
        }
    }

    #[test]
    fn test_ipv6_flow_label() {
        // IPv6 Flow Label = 0x12345 (RFC 8956)
        let data = vec![
            0x06, // Length: 6 bytes
            0x0D, // Type 13: Flow Label
            0xA1, // end=1, and=0, len=10, eq=1 (4-byte value)
            0x00, 0x01, 0x23, 0x45, // Flow Label value (20-bit in 4-byte field)
        ];

        let nlri = parse_flowspec_nlri(&data).unwrap();
        assert_eq!(nlri.components.len(), 1);

        match &nlri.components[0] {
            FlowSpecComponent::FlowLabel(ops) => {
                assert_eq!(ops.len(), 1);
                assert_eq!(ops[0].value, 0x00012345);
                assert!(ops[0].equal);
                assert_eq!(ops[0].value_length, 4);
            }
            _ => panic!("Expected flow label"),
        }
    }

    #[test]
    fn test_complex_port_range() {
        // Port range: 80 OR 443
        let data = vec![
            0x06, // Length: 6 bytes (corrected)
            0x04, // Type 4: Port
            0x01, // end=0, and=0 (OR), len=00, eq=1
            0x50, // Port 80
            0x91, // end=1, and=0, len=01, eq=1
            0x01, 0xBB, // Port 443 (2 bytes)
        ];

        let nlri = parse_flowspec_nlri(&data).unwrap();
        assert_eq!(nlri.components.len(), 1);

        match &nlri.components[0] {
            FlowSpecComponent::Port(ops) => {
                assert_eq!(ops.len(), 2);

                // First operator: == 80, OR with next
                assert_eq!(ops[0].value, 80);
                assert!(ops[0].equal);
                assert!(!ops[0].and_with_next);
                assert!(!ops[0].end_of_list);

                // Second operator: == 443, end of list
                assert_eq!(ops[1].value, 443);
                assert!(ops[1].equal);
                assert!(!ops[1].and_with_next);
                assert!(ops[1].end_of_list);
            }
            _ => panic!("Expected port"),
        }

        // Verify the operators are correctly parsed
        if let FlowSpecComponent::Port(ops) = &nlri.components[0] {
            assert_eq!(ops.len(), 2);
            assert_eq!(ops[0].value, 80);
            assert_eq!(ops[1].value, 443);
        }
    }
}

/// Test error conditions and edge cases
#[cfg(test)]
mod error_handling {
    use super::*;

    #[test]
    fn test_insufficient_data() {
        let data = vec![0x05, 0x01]; // Claims 5 bytes but only has 2
        let result = parse_flowspec_nlri(&data);
        assert!(matches!(result, Err(FlowSpecError::InsufficientData)));
    }

    #[test]
    fn test_invalid_component_type() {
        let data = vec![
            0x03, // Length: 3 bytes
            0xFF, // Invalid component type
            0x81, 0x06, // Some data
        ];

        let result = parse_flowspec_nlri(&data);
        assert!(matches!(
            result,
            Err(FlowSpecError::InvalidComponentType(0xFF))
        ));
    }

    #[test]
    fn test_extended_length_encoding() {
        // Test length >= 240
        let mut data = Vec::new();
        encode_length(1000, &mut data);

        let mut offset = 0;
        let parsed_length = parse_length(&data, &mut offset).unwrap();
        assert_eq!(parsed_length, 1000);

        // Test maximum length (4095)
        let mut data = Vec::new();
        encode_length(4095, &mut data);

        let mut offset = 0;
        let parsed_length = parse_length(&data, &mut offset).unwrap();
        assert_eq!(parsed_length, 4095);
    }
}

/// IPv6-specific test cases from RFC 8956
#[cfg(test)]
mod ipv6_tests {
    use super::*;

    #[test]
    fn test_ipv6_destination_prefix() {
        let nlri = FlowSpecNlri::new(vec![FlowSpecComponent::DestinationPrefix(
            NetworkPrefix::from_str("2001:db8::/32").unwrap(),
        )]);

        assert!(nlri.is_ipv6());
        assert!(!nlri.is_ipv4());
    }

    #[test]
    fn test_ipv6_prefix_with_offset() {
        // Test IPv6 prefix with offset (theoretical - actual parsing would need more implementation)
        let nlri = FlowSpecNlri::new(vec![FlowSpecComponent::DestinationIpv6Prefix {
            offset: 32,
            prefix: NetworkPrefix::from_str("2001:db8::/64").unwrap(),
        }]);

        assert!(nlri.is_ipv6());

        match &nlri.components[0] {
            FlowSpecComponent::DestinationIpv6Prefix { offset, prefix } => {
                assert_eq!(*offset, 32);
                assert_eq!(prefix.to_string(), "2001:db8::/64");
            }
            _ => panic!("Expected IPv6 destination prefix with offset"),
        }
    }

    #[test]
    fn test_flow_label_component() {
        let nlri = FlowSpecNlri::new(vec![FlowSpecComponent::FlowLabel(vec![
            NumericOperator::equal_to(0x12345),
        ])]);

        assert!(nlri.is_ipv6()); // Flow label implies IPv6
        assert!(!nlri.is_ipv4());
    }
}

/// Component type and method tests
#[cfg(test)]
mod component_tests {
    use super::*;

    #[test]
    fn test_component_type_ids() {
        // Test all component type IDs
        let dest_prefix =
            FlowSpecComponent::DestinationPrefix(NetworkPrefix::from_str("192.0.2.0/24").unwrap());
        assert_eq!(dest_prefix.component_type(), 1);

        let src_prefix =
            FlowSpecComponent::SourcePrefix(NetworkPrefix::from_str("192.0.2.0/24").unwrap());
        assert_eq!(src_prefix.component_type(), 2);

        let ip_protocol = FlowSpecComponent::IpProtocol(vec![NumericOperator::equal_to(6)]);
        assert_eq!(ip_protocol.component_type(), 3);

        let port = FlowSpecComponent::Port(vec![NumericOperator::equal_to(80)]);
        assert_eq!(port.component_type(), 4);

        let dest_port = FlowSpecComponent::DestinationPort(vec![NumericOperator::equal_to(80)]);
        assert_eq!(dest_port.component_type(), 5);

        let src_port = FlowSpecComponent::SourcePort(vec![NumericOperator::equal_to(80)]);
        assert_eq!(src_port.component_type(), 6);

        let icmp_type = FlowSpecComponent::IcmpType(vec![NumericOperator::equal_to(8)]);
        assert_eq!(icmp_type.component_type(), 7);

        let icmp_code = FlowSpecComponent::IcmpCode(vec![NumericOperator::equal_to(0)]);
        assert_eq!(icmp_code.component_type(), 8);

        let tcp_flags = FlowSpecComponent::TcpFlags(vec![BitmaskOperator::exact_match(0x02)]);
        assert_eq!(tcp_flags.component_type(), 9);

        let packet_length = FlowSpecComponent::PacketLength(vec![NumericOperator::equal_to(1500)]);
        assert_eq!(packet_length.component_type(), 10);

        let dscp = FlowSpecComponent::Dscp(vec![NumericOperator::equal_to(46)]);
        assert_eq!(dscp.component_type(), 11);

        let fragment = FlowSpecComponent::Fragment(vec![BitmaskOperator::exact_match(0x01)]);
        assert_eq!(fragment.component_type(), 12);

        let flow_label = FlowSpecComponent::FlowLabel(vec![NumericOperator::equal_to(0x12345)]);
        assert_eq!(flow_label.component_type(), 13);

        // Test IPv6 prefix components
        let dest_ipv6 = FlowSpecComponent::DestinationIpv6Prefix {
            offset: 32,
            prefix: NetworkPrefix::from_str("2001:db8::/64").unwrap(),
        };
        assert_eq!(dest_ipv6.component_type(), 1);

        let src_ipv6 = FlowSpecComponent::SourceIpv6Prefix {
            offset: 32,
            prefix: NetworkPrefix::from_str("2001:db8::/64").unwrap(),
        };
        assert_eq!(src_ipv6.component_type(), 2);
    }

    #[test]
    fn test_uses_numeric_operators() {
        // Components that use numeric operators
        assert!(FlowSpecComponent::IpProtocol(vec![]).uses_numeric_operators());
        assert!(FlowSpecComponent::Port(vec![]).uses_numeric_operators());
        assert!(FlowSpecComponent::DestinationPort(vec![]).uses_numeric_operators());
        assert!(FlowSpecComponent::SourcePort(vec![]).uses_numeric_operators());
        assert!(FlowSpecComponent::IcmpType(vec![]).uses_numeric_operators());
        assert!(FlowSpecComponent::IcmpCode(vec![]).uses_numeric_operators());
        assert!(FlowSpecComponent::PacketLength(vec![]).uses_numeric_operators());
        assert!(FlowSpecComponent::Dscp(vec![]).uses_numeric_operators());
        assert!(FlowSpecComponent::FlowLabel(vec![]).uses_numeric_operators());

        // Components that don't use numeric operators
        let prefix = NetworkPrefix::from_str("192.0.2.0/24").unwrap();
        assert!(!FlowSpecComponent::DestinationPrefix(prefix).uses_numeric_operators());
        assert!(!FlowSpecComponent::SourcePrefix(prefix).uses_numeric_operators());
        assert!(!FlowSpecComponent::TcpFlags(vec![]).uses_numeric_operators());
        assert!(!FlowSpecComponent::Fragment(vec![]).uses_numeric_operators());
        assert!(
            !FlowSpecComponent::DestinationIpv6Prefix { offset: 0, prefix }
                .uses_numeric_operators()
        );
        assert!(!FlowSpecComponent::SourceIpv6Prefix { offset: 0, prefix }.uses_numeric_operators());
    }

    #[test]
    fn test_uses_bitmask_operators() {
        // Components that use bitmask operators
        assert!(FlowSpecComponent::TcpFlags(vec![]).uses_bitmask_operators());
        assert!(FlowSpecComponent::Fragment(vec![]).uses_bitmask_operators());

        // Components that don't use bitmask operators
        let prefix = NetworkPrefix::from_str("192.0.2.0/24").unwrap();
        assert!(!FlowSpecComponent::DestinationPrefix(prefix).uses_bitmask_operators());
        assert!(!FlowSpecComponent::SourcePrefix(prefix).uses_bitmask_operators());
        assert!(!FlowSpecComponent::IpProtocol(vec![]).uses_bitmask_operators());
        assert!(!FlowSpecComponent::Port(vec![]).uses_bitmask_operators());
        assert!(!FlowSpecComponent::DestinationPort(vec![]).uses_bitmask_operators());
        assert!(!FlowSpecComponent::SourcePort(vec![]).uses_bitmask_operators());
        assert!(!FlowSpecComponent::IcmpType(vec![]).uses_bitmask_operators());
        assert!(!FlowSpecComponent::IcmpCode(vec![]).uses_bitmask_operators());
        assert!(!FlowSpecComponent::PacketLength(vec![]).uses_bitmask_operators());
        assert!(!FlowSpecComponent::Dscp(vec![]).uses_bitmask_operators());
        assert!(!FlowSpecComponent::FlowLabel(vec![]).uses_bitmask_operators());
        assert!(
            !FlowSpecComponent::DestinationIpv6Prefix { offset: 0, prefix }
                .uses_bitmask_operators()
        );
        assert!(!FlowSpecComponent::SourceIpv6Prefix { offset: 0, prefix }.uses_bitmask_operators());
    }

    #[test]
    fn test_nlri_methods() {
        let components = vec![
            FlowSpecComponent::DestinationPrefix(NetworkPrefix::from_str("192.0.2.0/24").unwrap()),
            FlowSpecComponent::IpProtocol(vec![NumericOperator::equal_to(6)]),
        ];
        let nlri = FlowSpecNlri::new(components.clone());

        // Test components() method
        assert_eq!(nlri.components(), &components);
        assert_eq!(nlri.components.len(), 2);
    }

    #[test]
    fn test_mixed_ipv4_ipv6_detection() {
        // Pure IPv4 NLRI
        let ipv4_nlri = FlowSpecNlri::new(vec![
            FlowSpecComponent::DestinationPrefix(NetworkPrefix::from_str("192.0.2.0/24").unwrap()),
            FlowSpecComponent::IpProtocol(vec![NumericOperator::equal_to(6)]),
        ]);
        assert!(ipv4_nlri.is_ipv4());
        assert!(!ipv4_nlri.is_ipv6());

        // Pure IPv6 NLRI
        let ipv6_nlri = FlowSpecNlri::new(vec![
            FlowSpecComponent::DestinationPrefix(NetworkPrefix::from_str("2001:db8::/32").unwrap()),
            FlowSpecComponent::IpProtocol(vec![NumericOperator::equal_to(6)]),
        ]);
        assert!(ipv6_nlri.is_ipv6());
        assert!(!ipv6_nlri.is_ipv4());

        // IPv6 with flow label
        let ipv6_flow_nlri = FlowSpecNlri::new(vec![
            FlowSpecComponent::FlowLabel(vec![NumericOperator::equal_to(0x12345)]),
            FlowSpecComponent::IpProtocol(vec![NumericOperator::equal_to(6)]),
        ]);
        assert!(ipv6_flow_nlri.is_ipv6());
        assert!(!ipv6_flow_nlri.is_ipv4());

        // NLRI with no prefix components
        let no_prefix_nlri = FlowSpecNlri::new(vec![
            FlowSpecComponent::IpProtocol(vec![NumericOperator::equal_to(6)]),
            FlowSpecComponent::Port(vec![NumericOperator::equal_to(80)]),
        ]);
        assert!(!no_prefix_nlri.is_ipv4());
        assert!(!no_prefix_nlri.is_ipv6());
    }
}

/// Error handling and Display implementation tests
#[cfg(test)]
mod error_tests {
    use super::*;

    #[test]
    fn test_flowspec_error_display() {
        // Test InvalidComponentOrder
        let error = FlowSpecError::InvalidComponentOrder {
            expected_greater_than: 5,
            found: 3,
        };
        assert_eq!(
            error.to_string(),
            "Invalid component order: expected type > 5, but found 3"
        );

        // Test InvalidOperator
        let error = FlowSpecError::InvalidOperator(0xFF);
        assert_eq!(error.to_string(), "Invalid operator: 0xFF");

        // Test InvalidComponentType
        let error = FlowSpecError::InvalidComponentType(99);
        assert_eq!(error.to_string(), "Invalid component type: 99");

        // Test InsufficientData
        let error = FlowSpecError::InsufficientData;
        assert_eq!(error.to_string(), "Insufficient data for parsing");

        // Test InvalidPrefix
        let error = FlowSpecError::InvalidPrefix;
        assert_eq!(error.to_string(), "Invalid prefix encoding");

        // Test InvalidValueLength
        let error = FlowSpecError::InvalidValueLength(7);
        assert_eq!(error.to_string(), "Invalid value length: 7");
    }

    #[test]
    fn test_flowspec_error_as_std_error() {
        let error = FlowSpecError::InsufficientData;
        let _: &dyn std::error::Error = &error;
        // If this compiles, the Error trait is implemented correctly
    }

    #[test]
    fn test_component_order_validation() {
        // Test that component order is enforced during parsing
        let data = vec![
            0x06, // Length: 6 bytes
            0x03, // Type 3: IP Protocol (first)
            0x81, 0x06, // TCP
            0x01, // Type 1: Destination Prefix (second - should fail because 1 < 3)
            0x18, 0xC0, // Invalid data
        ];

        let result = parse_flowspec_nlri(&data);
        assert!(matches!(
            result,
            Err(FlowSpecError::InvalidComponentOrder {
                expected_greater_than: 3,
                found: 1
            })
        ));
    }
}

/// NLRI parsing edge cases and error conditions
#[cfg(test)]
mod nlri_parsing_tests {
    use super::*;

    #[test]
    fn test_parse_length_insufficient_data() {
        // Test insufficient data for extended length
        let data = vec![0xF0]; // Extended length marker but no second byte
        let mut offset = 0;
        let result = parse_length(&data, &mut offset);
        assert!(matches!(result, Err(FlowSpecError::InsufficientData)));
    }

    #[test]
    fn test_parse_length_at_boundary() {
        // Test parsing at exact boundary of 240
        let data = vec![239]; // Just under extended length threshold
        let mut offset = 0;
        let result = parse_length(&data, &mut offset).unwrap();
        assert_eq!(result, 239);
        assert_eq!(offset, 1);
    }

    #[test]
    fn test_invalid_prefix_length() {
        // Test prefix with invalid length causing insufficient data
        let data = vec![
            0x05, // Length: 5 bytes (claiming more data than available)
            0x01, // Type 1: Destination Prefix
            0xFF, // Invalid prefix length (255 bits)
            0xC0, 0x00, // Only 2 bytes but need 32 bytes for /255
        ];

        let result = parse_flowspec_nlri(&data);
        assert!(matches!(result, Err(FlowSpecError::InsufficientData)));
    }

    #[test]
    fn test_numeric_operators_insufficient_data() {
        // Test numeric operators with insufficient data for value
        let data = vec![
            0x04, // Length: 4 bytes
            0x03, // Type 3: IP Protocol
            0x91, // end=1, and=0, len=01 (2 bytes), eq=1
            0x06, // Only 1 byte provided, but 2 bytes expected
        ];

        let result = parse_flowspec_nlri(&data);
        assert!(matches!(result, Err(FlowSpecError::InsufficientData)));
    }

    #[test]
    fn test_bitmask_operators_insufficient_data() {
        // Test bitmask operators with insufficient data for value
        let data = vec![
            0x04, // Length: 4 bytes
            0x09, // Type 9: TCP Flags
            0xA1, // end=1, and=0, len=10 (4 bytes), not=0, match=1
            0x02, 0x00, // Only 2 bytes provided, but 4 bytes expected
        ];

        let result = parse_flowspec_nlri(&data);
        assert!(matches!(result, Err(FlowSpecError::InsufficientData)));
    }

    #[test]
    fn test_empty_operators_list() {
        // Test component with no operators data
        let data = vec![
            0x02, // Length: 2 bytes
            0x03, // Type 3: IP Protocol
                  // No operator data follows
        ];

        let result = parse_flowspec_nlri(&data);
        assert!(matches!(result, Err(FlowSpecError::InsufficientData)));
    }

    #[test]
    fn test_multiple_operators_parsing() {
        // Test parsing multiple operators in a sequence
        let data = vec![
            0x07, // Length: 7 bytes
            0x04, // Type 4: Port
            0x01, // end=0, and=0 (OR), len=00, eq=1
            0x50, // Port 80
            0x41, // end=0, and=1 (AND), len=00, eq=1
            0x35, // Port 53
            0x81, // end=1, and=0, len=00, eq=1
            0x19, // Port 25
        ];

        let nlri = parse_flowspec_nlri(&data).unwrap();
        match &nlri.components[0] {
            FlowSpecComponent::Port(ops) => {
                assert_eq!(ops.len(), 3);
                assert_eq!(ops[0].value, 80);
                assert!(!ops[0].end_of_list);
                assert!(!ops[0].and_with_next);

                assert_eq!(ops[1].value, 53);
                assert!(!ops[1].end_of_list);
                assert!(ops[1].and_with_next);

                assert_eq!(ops[2].value, 25);
                assert!(ops[2].end_of_list);
                assert!(!ops[2].and_with_next);
            }
            _ => panic!("Expected port component"),
        }
    }

    #[test]
    fn test_encode_ipv6_prefix_offset() {
        // Test encoding IPv6 prefix with offset
        let prefix = NetworkPrefix::from_str("2001:db8::/64").unwrap();
        let nlri = FlowSpecNlri::new(vec![FlowSpecComponent::DestinationIpv6Prefix {
            offset: 32,
            prefix,
        }]);

        let encoded = encode_flowspec_nlri(&nlri);

        // Should start with length, then type 1, then prefix len, then offset
        assert!(encoded.len() > 4);
        assert_eq!(encoded[1], 1); // Type 1
        assert_eq!(encoded[2], 64); // /64
        assert_eq!(encoded[3], 32); // offset
    }

    #[test]
    fn test_value_encoding_through_operators() {
        // Test value encoding/decoding through public operator interfaces
        let op1 = NumericOperator::equal_to(0x1234);
        let byte = op1.to_byte();
        let parsed_op = NumericOperator::from_byte_and_value(byte, 0x1234).unwrap();
        assert_eq!(parsed_op.value, 0x1234);
        assert_eq!(parsed_op.value_length, 2);

        let op2 = BitmaskOperator::exact_match(0x12345678);
        let byte = op2.to_byte();
        let parsed_op = BitmaskOperator::from_byte_and_value(byte, 0x12345678).unwrap();
        assert_eq!(parsed_op.bitmask, 0x12345678);
        assert_eq!(parsed_op.value_length, 4);
    }

    #[test]
    fn test_prefix_component_ipv4_vs_ipv6_detection() {
        // Test prefix parsing with different address families
        let ipv4_data = vec![
            0x05, // Length: 5 bytes
            0x01, // Type 1: Destination Prefix
            0x18, // /24
            0xC0, 0x00, 0x02, // 192.0.2.0
        ];

        let nlri = parse_flowspec_nlri(&ipv4_data).unwrap();
        match &nlri.components[0] {
            FlowSpecComponent::DestinationPrefix(prefix) => {
                assert!(matches!(prefix.prefix, ipnet::IpNet::V4(_)));
            }
            _ => panic!("Expected destination prefix"),
        }
    }

    #[test]
    fn test_operator_encoding_through_nlri() {
        // Test operator encoding through the public NLRI interface
        // Create operators with proper end_of_list flags
        let mut op1 = NumericOperator::equal_to(255);
        op1.end_of_list = false;
        let mut op2 = NumericOperator::equal_to(65535);
        op2.end_of_list = false;
        let op3 = NumericOperator::equal_to(0xFFFFFFFF); // This one keeps end_of_list = true

        let mut bm_op1 = BitmaskOperator::exact_match(0xFF);
        bm_op1.end_of_list = false;
        let bm_op2 = BitmaskOperator::partial_match(0xFFFF); // This one keeps end_of_list = true

        let nlri = FlowSpecNlri::new(vec![
            FlowSpecComponent::IpProtocol(vec![op1, op2, op3]),
            FlowSpecComponent::TcpFlags(vec![bm_op1, bm_op2]),
        ]);

        let encoded = encode_flowspec_nlri(&nlri);
        let parsed = parse_flowspec_nlri(&encoded).unwrap();

        // Verify round-trip encoding worked
        assert_eq!(parsed.components.len(), 2);

        match &parsed.components[0] {
            FlowSpecComponent::IpProtocol(ops) => {
                assert_eq!(ops.len(), 3);
                assert_eq!(ops[0].value, 255);
                assert_eq!(ops[1].value, 65535);
                assert_eq!(ops[2].value, 0xFFFFFFFF);
            }
            _ => panic!("Expected IP protocol component"),
        }

        match &parsed.components[1] {
            FlowSpecComponent::TcpFlags(ops) => {
                assert_eq!(ops.len(), 2);
                assert_eq!(ops[0].bitmask, 0xFF);
                assert_eq!(ops[1].bitmask, 0xFFFF);
            }
            _ => panic!("Expected TCP flags component"),
        }
    }

    #[test]
    fn test_all_component_types_parsing() {
        // Test that all component type parsers work
        let test_cases = vec![
            (3, "IP Protocol"),
            (4, "Port"),
            (5, "Destination Port"),
            (6, "Source Port"),
            (7, "ICMP Type"),
            (8, "ICMP Code"),
            (10, "Packet Length"),
            (11, "DSCP"),
            (13, "Flow Label"),
        ];

        for (component_type, description) in test_cases {
            let data = vec![
                0x03,           // Length: 3 bytes
                component_type, // Component type
                0x81,           // end=1, and=0, len=00, eq=1
                0x06,           // Value
            ];

            let result = parse_flowspec_nlri(&data);
            assert!(
                result.is_ok(),
                "Failed to parse {}: {:?}",
                description,
                result
            );

            let nlri = result.unwrap();
            assert_eq!(nlri.components.len(), 1);
            assert_eq!(nlri.components[0].component_type(), component_type);
        }

        // Test bitmask component types
        let bitmask_cases = vec![(9, "TCP Flags"), (12, "Fragment")];

        for (component_type, description) in bitmask_cases {
            let data = vec![
                0x03,           // Length: 3 bytes
                component_type, // Component type
                0x81,           // end=1, and=0, len=00, not=0, match=1
                0x06,           // Value
            ];

            let result = parse_flowspec_nlri(&data);
            assert!(
                result.is_ok(),
                "Failed to parse {}: {:?}",
                description,
                result
            );

            let nlri = result.unwrap();
            assert_eq!(nlri.components.len(), 1);
            assert_eq!(nlri.components[0].component_type(), component_type);
        }
    }

    #[test]
    fn test_length_encoding_edge_cases() {
        use super::nlri::{encode_length, parse_length};

        // Test exact boundary at 240
        let mut data = Vec::new();
        encode_length(240, &mut data);
        assert_eq!(data, vec![0xF0, 0xF0]); // Extended encoding: 0xF0 + 240

        let mut offset = 0;
        let parsed = parse_length(&data, &mut offset).unwrap();
        assert_eq!(parsed, 240);

        // Test maximum value (4095)
        let mut data = Vec::new();
        encode_length(4095, &mut data);
        assert_eq!(data, vec![0xFF, 0xFF]); // Maximum extended encoding

        let mut offset = 0;
        let parsed = parse_length(&data, &mut offset).unwrap();
        assert_eq!(parsed, 4095);
    }

    #[test]
    fn test_invalid_value_length_error() {
        // This tests the InvalidValueLength error path that might be unreachable
        // due to bit masking, but we test it for completeness
        let data = vec![
            0x04, // Length: 4 bytes
            0x03, // Type 3: IP Protocol
            0xFF, // Invalid operator with impossible length encoding
            0x06, 0x00,
        ];

        // The actual error depends on how the parser handles the invalid operator
        let result = parse_flowspec_nlri(&data);
        assert!(result.is_err());
    }
}
