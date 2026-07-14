#[cfg(test)]
mod base_tests {

    use crate::variable_versions::Config;
    use crate::variable_versions::enterprise_registry::EnterpriseFieldRegistry;
    use crate::variable_versions::ipfix::lookup::IPFixField;
    use crate::{NetflowPacket, NetflowParser};
    use std::sync::Arc;

    use insta::assert_yaml_snapshot;

    // Verify that Unix timestamps are parsed identically via separate u32 fields and a single u64 field
    #[test]
    fn it_parses_unix_timestamp_correctly() {
        use nom::number::complete::{be_u32, be_u64};
        use std::time::Duration;

        let packet = [5, 0, 6, 7, 8, 9, 0, 1];
        let (remain, secs1) =
            be_u32::<&[u8], nom::error::Error<&[u8]>>(packet.as_slice()).unwrap();
        let (remain, nsecs1) = be_u32::<&[u8], nom::error::Error<&[u8]>>(remain).unwrap();
        assert_eq!(remain, &[] as &[u8]);

        let time1 = Duration::from_nanos(nsecs1 as u64) + Duration::from_secs(secs1 as u64);

        let (remain, secs_nsecs) =
            be_u64::<&[u8], nom::error::Error<&[u8]>>(packet.as_slice()).unwrap();
        assert_eq!(remain, &[] as &[u8]);
        let secs2 = (secs_nsecs >> 32) as u32 as u64;
        let nsecs2 = secs_nsecs as u32;

        let time2 = Duration::new(secs2, nsecs2);

        assert_eq!(secs1 as u64, secs2);
        assert_eq!(nsecs1, nsecs2);
        assert_eq!(time1, time2);
    }

    // Verify that a NetFlow v5 packet is parsed correctly from raw bytes
    #[test]
    fn it_parses_v5() {
        let packet = [
            0, 5, 0, 1, 3, 0, 4, 0, 5, 0, 6, 7, 8, 9, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 0, 1, 2, 3,
            4, 5, 6, 7, 8, 9, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 0, 1,
            2, 3, 4, 5, 6, 7, 8, 9, 0, 1, 2, 3, 4, 5, 6, 7,
        ];
        let parsed = NetflowParser::default().parse_bytes(&packet).packets;
        assert_yaml_snapshot!(parsed);
    }

    // Verify that a NetFlow v7 packet is parsed correctly from raw bytes
    #[test]
    fn it_parses_v7() {
        let packet = [
            0, 7, 0, 1, 3, 0, 4, 0, 5, 0, 6, 7, 8, 9, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 0, 1, 2, 3,
            4, 5, 6, 7, 8, 9, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 0, 1,
            2, 3, 4, 5, 6, 7, 8, 9, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 0, 1,
        ];
        let parsed = NetflowParser::default().parse_bytes(&packet).packets;
        assert_yaml_snapshot!(parsed);
    }

    // Verify that a NetFlow v9 packet with minimal template headers can be parsed
    #[test]
    fn can_read_v9_with_minimal_headers() {
        // Minimal valid v9 packet: 20-byte header + 12-byte template flowset
        // (template_id=256, 1 field: Ipv4SrcAddr/4 bytes).
        let hex = "00090001000000000000000000000000000000010000000c0100000100080004";

        let mut parser = NetflowParser::builder()
            .with_cache_size(100)
            .build()
            .unwrap();

        let packets = hex::decode(hex).unwrap();
        let v9 = parser.parse_bytes(&packets).packets;
        assert_yaml_snapshot!(v9);
    }

    // Verify that a NetFlow v9 options template is parsed correctly
    #[test]
    fn can_read_v9_with_options_template() {
        // Options template: template_id=256, 1 scope field (System/4), 1 option
        // field (ExportedMessageTotalCount/2), with 2 bytes of trailing padding.
        let hex =
            "00090001000000000000000000000000000000010001001401000004000400010004002900020000";

        let mut parser = NetflowParser::builder()
            .with_cache_size(100)
            .build()
            .unwrap();

        let packets = hex::decode(hex).unwrap();
        let v9 = parser.parse_bytes(&packets).packets;
        assert_yaml_snapshot!(v9);
    }

    // Verify that combined v9 options template, data template, and data records parse together
    #[test]
    fn can_read_v9_with_options_template_and_template() {
        // Three v9 messages in one buffer: options template, data template,
        // and one data record using template 256.
        let hex_hex0 =
            "00090001000000000000000000000000000000010001001401000004000400010004002900020000";
        let hex_hex1 = "00090001000000000000000000000000000000010000000c0100000100080004";
        let hex_hex2 = "000900010000000000000000000000000000000101000008c0a80001";

        let combined = format!("{}{}{}", hex_hex0, hex_hex1, hex_hex2);

        let mut parser = NetflowParser::builder()
            .with_cache_size(100)
            .build()
            .unwrap();

        let packets = hex::decode(combined).unwrap();
        let results = parser.parse_bytes(&packets).packets;
        assert_yaml_snapshot!(results);
    }

    // Verify that a v9 template packet is parsed and can be serialized back to bytes
    #[test]
    fn can_read_v9() {
        // Template
        let hex = "0009000100000e1061db09bd000000010000000100000028010000080001000400020004000a00040004000400080004000c0004000700020015000400050001000600010016000400100004";

        let mut parser = NetflowParser::builder()
            .with_cache_size(100)
            .build()
            .unwrap();

        let packets = hex::decode(hex).unwrap();
        let v9 = parser.parse_bytes(&packets).packets;
        if let Some(NetflowPacket::V9(v9_packet)) = v9.first() {
            assert_yaml_snapshot!(v9_packet.to_be_bytes().unwrap());
            // Just check that serialization works, don't assert equality
            // as the bytes may differ slightly due to padding or field ordering
        } else {
            panic!("Packet is not v9");
        }
    }

    // Verify that v9 data records are parsed correctly after a template has been cached
    #[test]
    fn can_read_v9_with_hex_data() {
        // Template: template_id=256 with 4 fields (InBytes/4, InPkts/4,
        // Ipv4SrcAddr/4, Ipv4DstAddr/4) — 16 bytes per data record.
        let hex = "00090001000000000000000000000000000000010000001801000004000100040002000400080004000c0004";

        let mut parser = NetflowParser::builder()
            .with_cache_size(100)
            .build()
            .unwrap();

        let packets = hex::decode(hex).unwrap();
        let _ = parser.parse_bytes(&packets).packets;

        // Data: one record matching template 256 (16 bytes).
        let hex_data =
            "0009000100000000000000000000000000000001010000140000006400000005c0a80001c0a80002";

        let packets = hex::decode(hex_data).unwrap();
        let v9 = parser.parse_bytes(&packets).packets;
        assert_yaml_snapshot!(v9);
    }

    // Verify that an IPFIX template packet is parsed and can be serialized back to bytes
    #[test]
    fn can_read_ipfix_template() {
        // Valid IPFIX template packet: Set ID=2 (IPFIX Template), template_id=256,
        // 3 fields: sourceIPv4Address(8) len 4, destinationIPv4Address(12) len 4,
        // protocolIdentifier(4) len 1.
        let hex = "000a002462a0b1b9000000086c6a7e11000200140100000300080004000c000400040001";

        let mut parser = NetflowParser::builder()
            .with_cache_size(100)
            .build()
            .unwrap();

        let packet = hex::decode(hex).unwrap();
        let ipfix = parser.parse_bytes(&packet).packets;
        if let Some(NetflowPacket::IPFix(ipfix_packet)) = ipfix.first() {
            assert!(
                !ipfix_packet.flowsets.is_empty(),
                "Parsed IPFIX packet should contain at least one flowset"
            );
            assert_yaml_snapshot!(ipfix_packet.to_be_bytes().unwrap());
        } else {
            panic!("Packet is not IPFix");
        }
    }

    // Verify that an IPFIX packet with template fields is parsed correctly
    #[test]
    fn can_read_ipfix() {
        let hex = "000a003062a0b1b9000000086c6a7e110001002400030008000100040002000400090001000d00010004000400080004000c00040005000100060001";

        let mut parser = NetflowParser::builder()
            .with_cache_size(100)
            .build()
            .unwrap();

        let packet = hex::decode(hex).unwrap();
        let ipfix = parser.parse_bytes(&packet).packets;
        assert_yaml_snapshot!(ipfix);
    }

    // Verify that an IPFIX options template with many fields is parsed without error
    #[test]
    fn options() {
        let hex_options_template = "000a00d46319088e0000036e8b7148d2000300b0000e001400070006000f0006001000060034000200350006008800020090000200910002009200020093000200990002009a0002009e0002009f000200a1000200a2000200a3000200a4000200a5000200aa000200ab000200ac000200ad000200b0000200b1000200b2000200b4000200b5000200b6000200b7000200b8000200b9000200bd000200be000200bf000200c0000200c1000400c2000200c3000200c4000200c5000200c6000200c7000200c8000200c9000200ca000200cb0002";

        let mut parser = NetflowParser::builder()
            .with_cache_size(100)
            .build()
            .unwrap();

        let packet = hex::decode(hex_options_template).unwrap();
        let result = parser.parse_bytes(&packet);
        assert!(
            !result.packets.is_empty(),
            "expected packets from options template"
        );
        assert!(
            result.error.is_none(),
            "unexpected error parsing options template"
        );
    }

    // Verify that a v9 template with multiple flowsets is parsed without error
    #[test]
    fn parses_v9_data_set() {
        let hex_template = "0009000300000e1061db09bd000000010000000100000028010000080001000400020004000a00040004000400080004000c0004000700020015000400050001000600010016000400100004";

        let mut parser = NetflowParser::builder()
            .with_cache_size(100)
            .build()
            .unwrap();

        let packet = hex::decode(hex_template).unwrap();
        let result = parser.parse_bytes(&packet);
        // This packet claims 3 flow sets but only contains template data.
        // The parser should handle it without panicking; verify any packets are V9.
        let v9_count = result.packets.iter().filter(|p| p.is_v9()).count();
        assert_eq!(
            v9_count,
            result.packets.len(),
            "all parsed packets should be V9"
        );
    }

    // Verify that IPFIX data records are parsed using a v9-style template definition
    #[test]
    fn parse_ipfix_with_v9_style_template() {
        let hex_template = "000a00b462a0b1bb000000a06c6a7e1100000064000200080001000400020004000800040012000400080004000c00040007000200150004000a000400040004000500010006000100100004000e00040016000400090001000d000100130004000b00020017000200010002000300020004000100b0000200b1000200b2000200b4000200b7000200b8000200ad000200ac00010038000200b9000200bd000200be000200c1000200c2000200c5000200c3000200c4000200c6000200c7000200c8000200c9000200ca000200cb000200ce00020000";

        let mut parser = NetflowParser::builder()
            .with_cache_size(100)
            .build()
            .unwrap();

        let packet = hex::decode(hex_template).unwrap();
        let _ = parser.parse_bytes(&packet).packets;

        let hex_data = "000a003062a0b1b9000000086c6a7e1100020020c0a80001c0a80002000100010000000100000005000000000000000006000200110001";

        let packet = hex::decode(hex_data).unwrap();
        let ipfix = parser.parse_bytes(&packet).packets;
        assert_yaml_snapshot!(ipfix);
    }

    // Verify IPFIX gracefully handles a packet with template+data sets where the template
    // content may not fully parse. The parser must not panic on this input.
    #[test]
    fn parse_ipfix_with_partial_template_data() {
        let hex = "000a00f46319088e0000036e8b7148d20002002c7f0000017f000002006b006c00000001000000010000000000000000c60000000011020106005000506401a5fe006d0100020028e21c1a0ae21c1a0a170217000000020000000200000000000000000000000000000000000000000002002ce21c1a0ae21c1a0a017b017c000000030000000300000000000000000000000000000000000000000000";

        let mut parser = NetflowParser::builder()
            .with_cache_size(100)
            .build()
            .unwrap();

        let packet = hex::decode(hex).unwrap();
        let result = parser.parse_bytes(&packet);
        // Partially malformed IPFIX — parser must not silently skip; it should
        // produce at least one packet or report an error.
        assert!(
            !result.packets.is_empty() || result.error.is_some(),
            "parser should produce packets or an error, not silently skip"
        );
        for p in &result.packets {
            assert!(
                matches!(p, NetflowPacket::IPFix(_)),
                "expected IPFix packet type"
            );
        }
    }

    // Verify that v9 options template followed by a zeroed-out data record parses correctly
    #[test]
    fn options_no_data() {
        let hex = "0009000100000001639073f3000000010000000100010034010200210001000400020004000e000400160004001500040009000100070002001000040011000400180004000600010005000100b0000200b1000200b2000200b4000200b7000200b8000200ad000200ac00010038000200b9000200bd000200be000200c1000200c2000200c5000200c3000200c4000200c6000200c7000200c8000200c9000200ca000200cb000200ce000200";

        let mut parser = NetflowParser::builder()
            .with_cache_size(100)
            .build()
            .unwrap();

        let packet = hex::decode(hex).unwrap();
        let _ = parser.parse_bytes(&packet);

        let hex_data = "0009000100000002639073f300000002000000010102008400000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000";

        let packet = hex::decode(hex_data).unwrap();
        assert_yaml_snapshot!(parser.parse_bytes(&packet).packets);
    }

    // Verify that a V9 packet with template+data flowsets parses without panic.
    // The packet may be partially malformed, so we verify graceful handling.
    #[test]
    fn v9_data_with_template_in_same_packet() {
        let hex = "0009000200000005639073f3000000030000000100000020010000030001000400020004000a0004010000180a66130e0a66130f00000024";

        let mut parser = NetflowParser::builder()
            .with_cache_size(100)
            .build()
            .unwrap();

        let packet = hex::decode(hex).unwrap();
        let result = parser.parse_bytes(&packet);
        // Partially malformed V9 — parser must not silently skip; it should
        // produce at least one packet or report an error.
        assert!(
            !result.packets.is_empty() || result.error.is_some(),
            "parser should produce packets or an error, not silently skip"
        );
        for p in &result.packets {
            assert!(p.is_v9(), "all parsed packets should be V9");
        }
    }

    // Verify that v9 template followed by data in separate packets produces correct output
    #[test]
    fn v9_example_from_integration_test() {
        let hex_template = "000900020000000563b32ef1000000010000000100000024010000060001000400020004000a00040004000400080004000c000400010038010000020001000400020004";

        let hex_hex1 = "000900020000000663b32ef10000000200000001010000240a70090a0a70090b00000001000000010000000100000001000000030000000601000008192a80e3192a80e4";

        let _hex_hex2 = "000900020000000763b32ef10000000300000001010000240a700a050a700a0600000001000000010000000100000001000000030000000601000008192a80e3192a80e4";

        let mut parser = NetflowParser::builder()
            .with_cache_size(100)
            .build()
            .unwrap();

        let _ = parser.parse_bytes(&hex::decode(hex_template).unwrap());
        assert_yaml_snapshot!(parser.parse_bytes(&hex::decode(hex_hex1).unwrap()).packets);
    }

    // Verify that v9 multi-template data parsing works across sequential packets
    #[test]
    fn v9_example_from_integration_test_2() {
        let hex1 = "000900020000000563b32ef1000000010000000100000024010000060001000400020004000a00040004000400080004000c000400010038010000020001000400020004";

        let hex2 = "000900020000000663b32ef10000000200000001010000240a70090a0a70090b00000001000000010000000100000001000000030000000601000008192a80e3192a80e4";

        let mut parser = NetflowParser::builder()
            .with_cache_size(100)
            .build()
            .unwrap();

        let _ = parser.parse_bytes(&hex::decode(hex1).unwrap());
        assert_yaml_snapshot!(parser.parse_bytes(&hex::decode(hex2).unwrap()).packets);
    }

    // Verify that iter_packets completes without panic on a V9 template-only packet.
    // Template-only packets may yield zero data items through the iterator.
    #[test]
    fn test_v9_template_only_iter_packets() {
        let hex = "00090001000016236482f6f30000000000000000000000200100001a000100040002000400080004000400040021000200b0000200b1000200b2000200b4000200b7000200b8000200ad000200ac00010038000200b9000200bd000200be000200c1000200c2000200c5000200c3000200c4000200c6000200c7000200c8000200c9000200ca000200cb000200ce0002";

        let mut parser = NetflowParser::builder()
            .with_cache_size(100)
            .build()
            .unwrap();

        let packet = hex::decode(hex).unwrap();
        let mut iter = parser.iter_packets(&packet);
        // Consume the iterator fully and count items.
        // Template-only packets typically yield zero data items.
        let mut count = 0;
        let mut had_error = false;
        for item in &mut iter {
            match item {
                Ok(p) => {
                    count += 1;
                    assert!(p.is_v9(), "expected V9 packet type");
                }
                Err(_) => {
                    had_error = true;
                }
            }
        }
        // The iterator must have completed (not infinite-looped).
        assert!(
            iter.is_complete(),
            "iterator should be complete after full consumption"
        );
        // At least verify the parser engaged with the input (produced items or consumed it all).
        assert!(
            count > 0 || had_error || iter.remaining().is_empty(),
            "iterator should have processed the input"
        );
    }

    // Verify that iter_packets works and is_v5 can be called on each parsed packet
    #[test]
    fn test_packet_all_iter() {
        let hexes = vec![
            "00090001000016236482f6f30000000000000000000000200100001a000100040002000400080004000400040021000200b0000200b1000200b2000200b4000200b7000200b8000200ad000200ac00010038000200b9000200bd000200be000200c1000200c2000200c5000200c3000200c4000200c6000200c7000200c8000200c9000200ca000200cb000200ce0002",
        ];

        for hex in hexes {
            let mut parser = NetflowParser::builder()
                .with_cache_size(100)
                .build()
                .unwrap();

            let packet = hex::decode(hex).unwrap();
            let mut count = 0;
            for packet in parser.iter_packets(&packet).flatten() {
                count += 1;
                // Any packets produced should not be v5 (this is v9 data)
                assert!(!packet.is_v5(), "v9 packet should not be identified as v5");
            }
            // Template-only packets may not produce iterable data packets.
            // Verify iteration completed without panic.
            let _ = count;
        }
    }

    // Verify that a V9Parser can be created with custom config values for cache size and field count
    #[test]
    fn test_custom_parser_configuration() {
        use crate::variable_versions::v9::V9Parser;

        let config = Config {
            max_template_cache_size: 100,
            max_field_count: 10000,
            max_template_total_size: usize::from(u16::MAX),
            max_error_sample_size: 256,
            max_records_per_flowset:
                crate::variable_versions::config::DEFAULT_MAX_RECORDS_PER_FLOWSET,
            ttl_config: None,
            enterprise_registry: Arc::new(EnterpriseFieldRegistry::new()),
            pending_flows_config: None,
            template_store: None,
            template_store_scope: std::sync::Arc::from(""),
        };

        let parser = V9Parser::try_new(config).unwrap();
        assert_eq!(parser.max_template_cache_size, 100);
        assert_eq!(parser.max_field_count, 10000);
    }

    // Verify that a v9 template exceeding the max field count limit is rejected as invalid
    #[test]
    fn test_template_validation_field_count_limit() {
        use crate::variable_versions::v9::lookup::V9Field;
        use crate::variable_versions::v9::{Template, TemplateField, V9Parser};

        let config = Config {
            max_template_cache_size: 100,
            max_field_count: 2, // Very low limit for testing
            max_template_total_size: usize::from(u16::MAX),
            max_error_sample_size: 256,
            max_records_per_flowset:
                crate::variable_versions::config::DEFAULT_MAX_RECORDS_PER_FLOWSET,
            ttl_config: None,
            enterprise_registry: Arc::new(EnterpriseFieldRegistry::new()),
            pending_flows_config: None,
            template_store: None,
            template_store_scope: std::sync::Arc::from(""),
        };

        let parser = V9Parser::try_new(config).unwrap();

        // Template with 3 fields should fail validation
        let template = Template {
            template_id: 256,
            field_count: 3,
            fields: vec![
                TemplateField {
                    field_type_number: 1,
                    field_type: V9Field::InBytes,
                    field_length: 4,
                },
                TemplateField {
                    field_type_number: 2,
                    field_type: V9Field::InPkts,
                    field_length: 4,
                },
                TemplateField {
                    field_type_number: 8,
                    field_type: V9Field::Ipv4SrcAddr,
                    field_length: 4,
                },
            ],
        };

        assert!(!template.is_valid(&parser));
    }

    // Verify that a v9 template exceeding the max total size limit is rejected as invalid
    #[test]
    fn test_template_validation_total_size_limit() {
        use crate::variable_versions::v9::lookup::V9Field;
        use crate::variable_versions::v9::{Template, TemplateField, V9Parser};

        let config = Config {
            max_template_cache_size: 100,
            max_field_count: 10000,
            max_template_total_size: 10, // Very low limit for testing
            max_error_sample_size: 256,
            max_records_per_flowset:
                crate::variable_versions::config::DEFAULT_MAX_RECORDS_PER_FLOWSET,
            ttl_config: None,
            enterprise_registry: Arc::new(EnterpriseFieldRegistry::new()),
            pending_flows_config: None,
            template_store: None,
            template_store_scope: std::sync::Arc::from(""),
        };

        let parser = V9Parser::try_new(config).unwrap();

        // Template with total size > 10 should fail validation
        let template = Template {
            template_id: 256,
            field_count: 3,
            fields: vec![
                TemplateField {
                    field_type_number: 1,
                    field_type: V9Field::InBytes,
                    field_length: 4,
                },
                TemplateField {
                    field_type_number: 2,
                    field_type: V9Field::InPkts,
                    field_length: 4,
                },
                TemplateField {
                    field_type_number: 8,
                    field_type: V9Field::Ipv4SrcAddr,
                    field_length: 4,
                },
            ],
        };

        assert!(!template.is_valid(&parser));
    }

    // Verify that a v9 template with duplicate field type numbers is rejected as invalid
    #[test]
    fn test_template_validation_duplicate_fields() {
        use crate::variable_versions::v9::lookup::V9Field;
        use crate::variable_versions::v9::{Template, TemplateField, V9Parser};

        let config = Config {
            max_template_cache_size: 100,
            max_field_count: 10000,
            max_template_total_size: usize::from(u16::MAX),
            max_error_sample_size: 256,
            max_records_per_flowset:
                crate::variable_versions::config::DEFAULT_MAX_RECORDS_PER_FLOWSET,
            ttl_config: None,
            enterprise_registry: Arc::new(EnterpriseFieldRegistry::new()),
            pending_flows_config: None,
            template_store: None,
            template_store_scope: std::sync::Arc::from(""),
        };

        let parser = V9Parser::try_new(config).unwrap();

        // Template with duplicate field_type_number (1) should fail validation
        let template = Template {
            template_id: 256,
            field_count: 3,
            fields: vec![
                TemplateField {
                    field_type_number: 1,
                    field_type: V9Field::InBytes,
                    field_length: 4,
                },
                TemplateField {
                    field_type_number: 1, // Duplicate!
                    field_type: V9Field::InBytes,
                    field_length: 4,
                },
                TemplateField {
                    field_type_number: 8,
                    field_type: V9Field::Ipv4SrcAddr,
                    field_length: 4,
                },
            ],
        };

        assert!(!template.is_valid(&parser));
    }

    // Verify that a well-formed v9 template with unique fields passes validation
    #[test]
    fn test_template_validation_valid_template() {
        use crate::variable_versions::v9::lookup::V9Field;
        use crate::variable_versions::v9::{Template, TemplateField, V9Parser};

        let config = Config {
            max_template_cache_size: 100,
            max_field_count: 10000,
            max_template_total_size: usize::from(u16::MAX),
            max_error_sample_size: 256,
            max_records_per_flowset:
                crate::variable_versions::config::DEFAULT_MAX_RECORDS_PER_FLOWSET,
            ttl_config: None,
            enterprise_registry: Arc::new(EnterpriseFieldRegistry::new()),
            pending_flows_config: None,
            template_store: None,
            template_store_scope: std::sync::Arc::from(""),
        };

        let parser = V9Parser::try_new(config).unwrap();

        // Valid template should pass all validations
        let template = Template {
            template_id: 256,
            field_count: 3,
            fields: vec![
                TemplateField {
                    field_type_number: 1,
                    field_type: V9Field::InBytes,
                    field_length: 4,
                },
                TemplateField {
                    field_type_number: 2,
                    field_type: V9Field::InPkts,
                    field_length: 4,
                },
                TemplateField {
                    field_type_number: 8,
                    field_type: V9Field::Ipv4SrcAddr,
                    field_length: 4,
                },
            ],
        };

        assert!(template.is_valid(&parser));
    }

    // Verify that an IPFIX template with duplicate field/enterprise pairs is rejected as invalid
    #[test]
    fn test_ipfix_template_validation_duplicate_fields() {
        use crate::variable_versions::ipfix::{IPFixParser, Template, TemplateField};

        let config = Config {
            max_template_cache_size: 100,
            max_field_count: 10000,
            max_template_total_size: usize::from(u16::MAX),
            max_error_sample_size: 256,
            max_records_per_flowset:
                crate::variable_versions::config::DEFAULT_MAX_RECORDS_PER_FLOWSET,
            ttl_config: None,
            enterprise_registry: Arc::new(EnterpriseFieldRegistry::new()),
            pending_flows_config: None,
            template_store: None,
            template_store_scope: std::sync::Arc::from(""),
        };

        let parser = IPFixParser::try_new(config).unwrap();

        // Template with duplicate (field_type_number, enterprise_number) pair should fail
        let template = Template {
            template_id: 256,
            field_count: 3,
            fields: vec![
                TemplateField {
                    field_type_number: 1,
                    field_length: 4,
                    enterprise_number: None,
                    field_type: IPFixField::new(1, None),
                },
                TemplateField {
                    field_type_number: 1, // Duplicate with same enterprise_number
                    field_length: 4,
                    enterprise_number: None,
                    field_type: IPFixField::new(1, None),
                },
                TemplateField {
                    field_type_number: 8,
                    field_length: 4,
                    enterprise_number: None,
                    field_type: IPFixField::new(8, None),
                },
            ],
        };

        assert!(!template.is_valid(&parser));
    }

    // Verify that an IPFIX template with same field type but different enterprise numbers is valid
    #[test]
    fn test_ipfix_template_validation_different_enterprises_ok() {
        use crate::variable_versions::ipfix::{IPFixParser, Template, TemplateField};

        let config = Config {
            max_template_cache_size: 100,
            max_field_count: 10000,
            max_template_total_size: usize::from(u16::MAX),
            max_error_sample_size: 256,
            max_records_per_flowset:
                crate::variable_versions::config::DEFAULT_MAX_RECORDS_PER_FLOWSET,
            ttl_config: None,
            enterprise_registry: Arc::new(EnterpriseFieldRegistry::new()),
            pending_flows_config: None,
            template_store: None,
            template_store_scope: std::sync::Arc::from(""),
        };

        let parser = IPFixParser::try_new(config).unwrap();

        // Same field_type_number but different enterprise_number should be OK
        let template = Template {
            template_id: 256,
            field_count: 3,
            fields: vec![
                TemplateField {
                    field_type_number: 1,
                    field_length: 4,
                    enterprise_number: None, // IANA (standard)
                    field_type: IPFixField::new(1, None),
                },
                TemplateField {
                    field_type_number: 1, // Same field_type_number but different enterprise
                    field_length: 4,
                    enterprise_number: Some(9), // Cisco
                    field_type: IPFixField::new(1, Some(9)),
                },
                TemplateField {
                    field_type_number: 8,
                    field_length: 4,
                    enterprise_number: None,
                    field_type: IPFixField::new(8, None),
                },
            ],
        };

        assert!(template.is_valid(&parser));
    }
}

#[cfg(test)]
mod restored_legacy_tests {
    use crate::variable_versions::ipfix::lookup::{IANAIPFixField, IPFixField};
    use crate::variable_versions::ipfix::{
        Template as IPFixTemplate, TemplateField as IPFixTemplateField,
    };
    use crate::variable_versions::ttl::TemplateWithTtl;
    use crate::variable_versions::v9::{
        Template as V9Template, TemplateField as V9TemplateField,
    };
    use crate::{NetflowPacket, NetflowParser};

    use insta::assert_yaml_snapshot;
    use std::sync::Arc;

    #[test]
    fn it_doesnt_allow_v5() {
        let packet = [
            0, 5, 0, 1, 3, 0, 4, 0, 5, 0, 6, 7, 8, 9, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 0, 1, 2, 3,
            4, 5, 6, 7, 8, 9, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 0, 1,
            2, 3, 4, 5, 6, 7, 8, 9, 0, 1, 2, 3, 4, 5, 6, 7,
        ];
        let mut parser = NetflowParser::builder()
            .with_allowed_versions(&[7, 9, 10])
            .build()
            .unwrap();
        assert_yaml_snapshot!(parser.parse_bytes(&packet).packets);
    }

    #[test]
    fn it_parses_v5_incomplete() {
        let packet = [0, 5, 0, 0, 1, 1, 1, 1];
        assert_yaml_snapshot!(NetflowParser::default().parse_bytes(&packet));
    }

    #[test]
    fn it_parses_v5_and_re_exports() {
        let packet = [
            0, 5, 0, 1, 3, 0, 4, 0, 5, 0, 6, 7, 8, 9, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 0, 1, 2, 3,
            4, 5, 6, 7, 8, 9, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 0, 1,
            2, 3, 4, 5, 6, 7, 8, 9, 0, 1, 2, 3, 4, 5, 6, 7,
        ];
        if let NetflowPacket::V5(v5) = NetflowParser::default()
            .parse_bytes(&packet)
            .packets
            .first()
            .unwrap()
        {
            assert_yaml_snapshot!(v5.to_be_bytes());
            assert_eq!(v5.to_be_bytes(), packet);
        }
    }

    #[test]
    fn it_creates_error() {
        let packet = [0, 9, 10, 11];
        assert_yaml_snapshot!(NetflowParser::default().parse_bytes(&packet));
    }

    #[test]
    fn it_doesnt_allow_v7() {
        let packet = [
            0, 7, 0, 1, 3, 0, 4, 0, 5, 0, 6, 7, 8, 9, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 0, 1, 2, 3,
            4, 5, 6, 7, 8, 9, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 0, 1,
            2, 3, 4, 5, 6, 7, 8, 9, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 0, 1,
        ];
        let mut parser = NetflowParser::builder()
            .with_allowed_versions(&[5, 9, 10])
            .build()
            .unwrap();
        assert_yaml_snapshot!(parser.parse_bytes(&packet).packets);
    }

    #[test]
    fn it_parses_v7_and_re_exports() {
        let packet = [
            0, 7, 0, 1, 3, 0, 4, 0, 5, 0, 6, 7, 8, 9, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 0, 1, 2, 3,
            4, 5, 6, 7, 8, 9, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 0, 1,
            2, 3, 4, 5, 6, 7, 8, 9, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 0, 1,
        ];
        if let NetflowPacket::V7(v7) = NetflowParser::default()
            .parse_bytes(&packet)
            .packets
            .first()
            .unwrap()
        {
            assert_yaml_snapshot!(v7.to_be_bytes());
            assert_eq!(v7.to_be_bytes(), packet);
        }
    }

    #[test]
    fn it_parses_v9() {
        let packet = [
            0, 9, 0, 2, 0, 0, 9, 9, 0, 1, 2, 3, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 16, 1, 2, 0,
            2, 0, 1, 0, 4, 0, 8, 0, 4, 1, 2, 0, 12, 9, 2, 3, 4, 9, 9, 9, 8,
        ];
        assert_yaml_snapshot!(NetflowParser::default().parse_bytes(&packet).packets);
    }

    #[test]
    fn it_doesnt_allow_v9() {
        let packet = [
            0, 9, 0, 2, 0, 0, 9, 9, 0, 1, 2, 3, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 16, 1, 2, 0,
            2, 0, 1, 0, 4, 0, 8, 0, 4, 1, 2, 0, 12, 9, 2, 3, 4, 9, 9, 9, 8,
        ];
        let mut parser = NetflowParser::builder()
            .with_allowed_versions(&[5, 7, 10])
            .build()
            .unwrap();
        assert_yaml_snapshot!(parser.parse_bytes(&packet).packets);
    }

    #[test]
    #[cfg(feature = "parse_unknown_fields")]
    fn it_parses_v9_ipv6flowlabel() {
        let templates_hex = "0009000400a21e176658cb4600000155000000080000004c0102001100080004000c0004000f000400070002000b0002000a0002000e000200fc000400fd000400020004000100040016000400150004000400010005000101000002003d0001000000540103001300080004000c0004000f000400070002000b000200060001000a0002000e000200fc000400fd000400020004000100040016000400150004000400010005000100d1000801000002003d00010000005401050013001b0010001c0010003e001000070002000b000200060001000a0002000e000200fc000400fd00040002000400010004001600040015000400040001000500010050000601000002003d00010000005801060014001b0010001c0010003e0010001f000300070002000b000200060001000a0002000e000200fc000400fd00040002000400010004001600040015000400040001000500010050000601000002003d0001";
        let packets_hex = "0009000200a3a50e6658cbab000001640000000801020066c0a8120a8d180c0200000000c2c00035000200000000000000000000000000010000005200a31e7700a31e771100080001c0a8120a8d180c02000000009e230035000200000000000000000000000000010000005200a3197b00a3197b110008000101060063fd010008000000002a20235f1f7b9379fd00000000000000b2f208fffe2011800000000000000000000000000000000001f676e2b5003500000200000000000000000000000000010000006600a3197b00a3197b1100109027e0436d86dd01";
        let combined = format!("{}{}", templates_hex, packets_hex);
        let packets = hex::decode(combined).unwrap();
        assert_yaml_snapshot!(NetflowParser::default().parse_bytes(&packets).packets);
    }

    #[test]
    fn it_parses_v9_and_re_exports() {
        let packet = [
            0, 9, 0, 2, 0, 0, 9, 9, 0, 1, 2, 3, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 16, 1, 2, 0,
            2, 0, 1, 0, 4, 0, 8, 0, 4, 1, 2, 0, 12, 9, 2, 3, 4, 9, 9, 9, 8,
        ];
        if let NetflowPacket::V9(v9) = NetflowParser::default()
            .parse_bytes(&packet)
            .packets
            .first()
            .unwrap()
        {
            assert_yaml_snapshot!(v9.to_be_bytes().unwrap());
            assert_eq!(v9.to_be_bytes().unwrap(), packet);
        }
    }

    #[test]
    fn it_parses_v9_no_data() {
        let packet = [
            0, 9, 0, 2, 0, 0, 9, 9, 0, 1, 2, 3, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 16, 1, 2, 0,
            2, 0, 1, 0, 4, 0, 8, 0, 4, 1, 2, 0, 4,
        ];
        assert_yaml_snapshot!(NetflowParser::default().parse_bytes(&packet).packets);
    }

    #[test]
    fn it_parses_v9_template_and_data_packet() {
        let hex = "000900090000cc99664728d80000000100000000000000480400001000080004000c000400160004001500040001000400020004000a0004000e0004003d00010088000100070002000b00020004000100060001003c000100050001000000400401000e00080004000c000400160004001500040001000400020004000a0004000e0004003d0001008800010020000200040001003c0001000500010000004808000010001b0010001c001000160004001500040001000400020004000a0004000e0004003d00010088000100070002000b00020004000100060001003c000100050001000000400801000e001b0010001c001000160004001500040001000400020004000a0004000e0004003d000100880001008b000200040001003c0001000500010001001a01000004000c000200040022000400230001005200100100001d000000000000000101616e7900000000000000000000000000080000cd200300d1ef3b2200fe3497fffeb7686e26064700303200000000000068155338000016050000a418000004bf0000000900000000000000000003e2d401bb0619060026064700303200000000000068155338200300d1ef3b2200fe3497fffeb7686e000016050000a418000000b4000000030000000000000000010301bbe2d406040600000000000000000000000000000000010000000000000000000000000000000100004f2c00004f2c0000003c00000001000000000000000000031f91aaea06140600000000040001009df0fb3dc0a801d700006308000076d500000b7200000018000000000000000000031466ac50061a0400c0a801d79df0fb3d00006308000076d500000e370000002100000000000000000103ac501466061e04005dd10e499df0fb3d00006308000076d6000004bd0000000b00000000000000000003ac501466061e04009df0fb3d5dd10e4900006308000076d6000005b90000000c000000000000000001031466ac50061a0400c0a80125c6fcce190000a9180000a9cd0000027b0000000900000000000000000003a34401bb06190400c6fcce19c0a801250000a9180000a9cd00000108000000060000000000000000010301bba34406150400";
        let packet = hex::decode(hex).unwrap();
        assert_yaml_snapshot!(NetflowParser::default().parse_bytes(&packet).packets);
    }

    #[test]
    #[cfg(feature = "parse_unknown_fields")]
    fn it_parses_multiple_packets() {
        let v9_packet = [
            0, 9, 0, 2, 0, 0, 9, 9, 0, 1, 2, 3, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 16, 1, 2, 0,
            2, 0, 1, 0, 4, 0, 8, 0, 4, 1, 2, 0, 12, 9, 2, 3, 4, 9, 9, 9, 8,
        ];
        let v7_packet = [
            0, 7, 0, 1, 3, 0, 4, 0, 5, 0, 6, 7, 8, 9, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 0, 1, 2, 3,
            4, 5, 6, 7, 8, 9, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 0, 1,
            2, 3, 4, 5, 6, 7, 8, 9, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 0, 1,
        ];
        let v5_packet = [
            0, 5, 0, 1, 3, 0, 4, 0, 5, 0, 6, 7, 8, 9, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 0, 1, 2, 3,
            4, 5, 6, 7, 8, 9, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 0, 1,
            2, 3, 4, 5, 6, 7, 8, 9, 0, 1, 2, 3, 4, 5, 6, 7,
        ];
        let ipfix_packet = [
            0, 10, 0, 64, 1, 2, 3, 4, 0, 0, 0, 0, 1, 2, 3, 4, 0, 2, 0, 20, 1, 0, 0, 3, 0, 8, 0,
            4, 0, 12, 0, 4, 0, 2, 0, 4, 1, 0, 0, 28, 1, 2, 3, 4, 1, 2, 3, 3, 1, 2, 3, 2, 0, 2,
            0, 2, 0, 1, 2, 3, 4, 5, 6, 7,
        ];
        let mut all = vec![];
        all.extend_from_slice(&v9_packet);
        all.extend_from_slice(&v5_packet);
        all.extend_from_slice(&v7_packet);
        all.extend_from_slice(&v9_packet);
        all.extend_from_slice(&ipfix_packet);
        all.extend_from_slice(&v5_packet);
        assert_yaml_snapshot!(NetflowParser::default().parse_bytes(&all).packets);
    }

    #[test]
    fn it_parses_v9_many_flows() {
        let packet = [
            0, 9, 0, 3, 0, 0, 9, 9, 0, 1, 2, 3, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 16, 1, 2, 0,
            2, 0, 1, 0, 4, 0, 8, 0, 4, 1, 2, 0, 20, 9, 2, 3, 4, 9, 9, 9, 8, 9, 2, 3, 4, 9, 9,
            9, 8,
        ];
        assert_yaml_snapshot!(NetflowParser::default().parse_bytes(&packet).packets);
    }

    #[test]
    fn it_parses_v9_options_template() {
        let packet = [
            0, 9, 0, 2, 0, 0, 9, 9, 0, 1, 2, 3, 0, 0, 0, 1, 0, 0, 0, 1, 0, 1, 0, 22, 1, 19, 0,
            4, 0, 8, 0, 2, 0, 2, 0, 34, 0, 2, 0, 36, 0, 1, 1, 19, 0, 9, 0, 2, 0, 100, 1,
        ];
        assert_yaml_snapshot!(NetflowParser::default().parse_bytes(&packet).packets);
    }

    #[test]
    fn it_parses_v9_data_cached_template() {
        let packet = [
            0, 9, 0, 1, 0, 0, 9, 9, 0, 1, 2, 3, 0, 0, 0, 1, 0, 0, 0, 1, 1, 2, 0, 12, 9, 2, 3,
            4, 9, 9, 9, 8,
        ];
        let fields = vec![
            V9TemplateField {
                field_type_number: 1,
                field_type: crate::variable_versions::v9::lookup::V9Field::InBytes,
                field_length: 4,
            },
            V9TemplateField {
                field_type_number: 8,
                field_type: crate::variable_versions::v9::lookup::V9Field::Ipv4SrcAddr,
                field_length: 4,
            },
        ];
        let template = V9Template {
            field_count: 2,
            template_id: 258,
            fields,
        };
        let mut parser = NetflowParser::default();
        let wrapped = TemplateWithTtl::new_without_ttl(Arc::new(template));
        parser.v9_parser.templates.put(258, wrapped);
        assert_yaml_snapshot!(parser.parse_bytes(&packet).packets);
    }

    #[test]
    fn it_parses_ipfix() {
        let packet = [
            0, 10, 0, 64, 1, 2, 3, 4, 0, 0, 0, 0, 1, 2, 3, 4, 0, 2, 0, 20, 1, 0, 0, 3, 0, 8, 0,
            4, 0, 12, 0, 4, 0, 2, 0, 4, 1, 0, 0, 28, 1, 2, 3, 4, 1, 2, 3, 3, 1, 2, 3, 2, 0, 2,
            0, 2, 0, 1, 2, 3, 4, 5, 6, 7,
        ];
        assert_yaml_snapshot!(NetflowParser::default().parse_bytes(&packet).packets);
    }

    #[test]
    fn it_doesnt_allow_ipfix() {
        let packet = [
            0, 10, 0, 64, 1, 2, 3, 4, 0, 0, 0, 0, 1, 2, 3, 4, 0, 2, 0, 20, 1, 0, 0, 3, 0, 8, 0,
            4, 0, 12, 0, 4, 0, 2, 0, 4, 1, 0, 0, 28, 1, 2, 3, 4, 1, 2, 3, 3, 1, 2, 3, 2, 0, 2,
            0, 2, 0, 1, 2, 3, 4, 5, 6, 7,
        ];
        let mut parser = NetflowParser::builder()
            .with_allowed_versions(&[5, 7, 9])
            .build()
            .unwrap();
        assert_yaml_snapshot!(parser.parse_bytes(&packet).packets);
    }

    #[test]
    fn it_parses_ipfix_and_re_exports() {
        let packet = [
            0, 10, 0, 64, 1, 2, 3, 4, 0, 0, 0, 0, 1, 2, 3, 4, 0, 2, 0, 20, 1, 0, 0, 3, 0, 8, 0,
            4, 0, 12, 0, 4, 0, 2, 0, 4, 1, 0, 0, 28, 1, 2, 3, 4, 1, 2, 3, 3, 1, 2, 3, 2, 0, 2,
            0, 2, 0, 1, 2, 3, 4, 5, 6, 7,
        ];
        if let NetflowPacket::IPFix(ipfix) = NetflowParser::default()
            .parse_bytes(&packet)
            .packets
            .first()
            .unwrap()
        {
            assert_yaml_snapshot!(ipfix.to_be_bytes().unwrap());
            assert_eq!(ipfix.to_be_bytes().unwrap(), packet);
        }
    }

    #[test]
    fn it_parses_0_length_fields_ipfix() {
        let packet = [
            0, 10, 0, 48, 1, 2, 3, 4, 0, 0, 0, 0, 1, 2, 3, 4, 0, 2, 0, 20, 1, 0, 0, 3, 0, 8, 0,
            4, 0, 12, 0, 4, 0, 65, 0, 0, 1, 0, 0, 12, 1, 2, 3, 4, 1, 2, 3, 4,
        ];
        assert_yaml_snapshot!(NetflowParser::default().parse_bytes(&packet).packets);
    }

    #[test]
    fn it_parses_ipfix_data_cached_template() {
        let packet = [
            0, 10, 0, 26, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 0, 1, 2, 0, 10, 0, 8, 0, 0, 1, 1,
        ];
        let fields = vec![
            IPFixTemplateField {
                field_type_number: 2,
                field_type: IPFixField::IANA(IANAIPFixField::PacketDeltaCount),
                field_length: 2,
                enterprise_number: None,
            },
            IPFixTemplateField {
                field_type_number: 8,
                field_type: IPFixField::IANA(IANAIPFixField::SourceIpv4address),
                field_length: 4,
                enterprise_number: None,
            },
        ];
        let template = IPFixTemplate {
            field_count: 2,
            template_id: 258,
            fields,
        };
        let mut parser = NetflowParser::default();
        let wrapped = TemplateWithTtl::new_without_ttl(Arc::new(template));
        parser.ipfix_parser.templates.put(258, wrapped);
        assert_yaml_snapshot!(parser.parse_bytes(&packet).packets);
    }

    #[test]
    fn it_parses_ipfix_with_no_template_fields() {
        let packet = [
            0, 10, 0, 26, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 0, 1, 2, 0, 10, 0, 8, 0, 0, 1, 1,
        ];
        let template = IPFixTemplate {
            field_count: 2,
            template_id: 258,
            fields: vec![],
        };
        let mut parser = NetflowParser::default();
        let wrapped = TemplateWithTtl::new_without_ttl(Arc::new(template));
        parser.ipfix_parser.templates.put(258, wrapped);
        assert_yaml_snapshot!(parser.parse_bytes(&packet).packets);
    }

    #[test]
    fn it_raises_error_when_parsing_v9_with_no_template_fields() {
        let packet = [
            0, 9, 0, 26, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 0, 1, 2, 0, 10, 0, 8, 0, 0, 1, 1,
        ];
        let template = V9Template {
            field_count: 2,
            template_id: 258,
            fields: vec![],
        };
        let mut parser = NetflowParser::default();
        let wrapped = TemplateWithTtl::new_without_ttl(Arc::new(template));
        parser.v9_parser.templates.put(258, wrapped);
        assert_yaml_snapshot!(parser.parse_bytes(&packet));
    }

    #[test]
    #[cfg(feature = "parse_unknown_fields")]
    fn it_parses_v9_with_multiple_options_data() {
        let hex = "00090026cfe9ee444b4f72ba0146d3ce000000000000005c0100001500150004001600040001000400020004000a0002000e000200080004000c0004000400010005000100070002000b00020030000100330001000f0004000d00010009000100060001003d00010011000200100002000000540102001300150004001600040001000400020004000a0002000e000200080004000c0004000400010005000100070002000b00020030000100330001000f0004000d00010009000100060001003d00010001002c01010014000c0001000400020004000300040004000400050004002a000400290004002200040000010001e4cfea00f0cfea0094000007d3000057c5000400020a0000570c00006706a00eb812b900360a0000241c05160000c00017cfea00f0cfea0094000007d300002cf7000400020a00002a0c0000be11c0cd9451a500f20a00000907091100005e0077cfea00f0cfea0094000007d30000c42d000400020a0000620c00000a010070fc917a00b70a0000550c161100004500b6cfea00f0cfea0094000007d300004268000400020a00001d0c0000d90610d3037c9400870a0000361214180000030003cfea00f0cfea0094000007d300000efc000400020a0000090c00003e01a05eb7df0700230a000028151d0400002e003ecfea00f0cfea0094000007d30000f36a000400020a00002e0c00009511a04645c8f8005f0a000059040c1b0000c10014cfea00f0cfea0094000007d300003800000400020a00002d0c00009111a07cd085b0008b0a00003e131c1000004600b8cfea00f0cfea0094000007d300004945000400020a00001b0c0000c401a077ef88e5009a0a0000451d021000003e00a3cfea00f0cfea0094000007d300008479000400020a00003a0c0000b711c0b837c8f4005f0a000059040c1b0000c20006cfea00f0cfea0094000007d300001d1e000400020a0000110c00007a0610b0afd42e007a0a00003811151100004c007f010001e4cfea00f0cfea0094000007d300010bc4000400020a0000110c00007e06108c85965d00b80a00004f0a1c1000004200c6cfea00f0cfea0094000007d3000009a6000400020a0000040c00001901c08e5090d000b20a0000540e110200008e00afcfea00f0cfea0094000007d300007244000400020a0000400c0000e501c082408428008f0a000039151a1a00006b0078cfea00f0cfea0094000007d30000c6ed000400020a0000640c0000020100093a19f4002a0a0000320f0f02000066006acfea00f0cfea0094000007d30000a056000400020a00003d0c0000af110031e5526c00f70a00000b050f02000067006ecfea00f0cfea0094000007d30000ae95000400020a00004b0c0000c101a05cdee51300290a00003011111b0000ac0055cfea00f0cfea0094000007d30000d569000400020a0000560c00006a11a04644c914005f0a000058040c1b0000be0011cfea00f0cfea0094000007d3000044f9000400020a00001f0c0000d00610bb6fc328004f0a0000520d121b0000980033cfea00f0cfea0094000007d30000e6b4000400020a00001e0c0000de0610ecf2317a00530a00006003041a00009200a1cfea00f0cfea0094000007d3000065fe000400020a0000620c00000b0100667fa99c00fd0a00000301031000005a0074010001e4cfea00f0cfea0094000007d30000dcb2000400020a00004e0c00004c11c0ac5ef45f001b0a0000120e121b0000c20013cfea00f0cfea0094000007d300003387000400020a0000310c0000840610bda6bf9300430a00004d09191a0000680070cfea00f0cfea0094000007d30000a9e3000400020a0000460c0000d6061093b8bba100c70a00001d1a0c1b00009d0047cfea00f0cfea0094000007d30001141d000400020a0000160c000058110048fcd902006d0a0000481a0c1b0000a10045cfea00f0cfea0094000007d30001209a000400020a0000040c00001901c08a339c1800a70a00005b06091100004e0088cfea00f0cfea0094000007d300011f4c000400020a00000b0c00002d0610a8cafba700020a0000030103100000520093cfea00f0cfea0094000007d30000ef5b000400020a0000220c0000fa01003be54c3900d40a00003210100200008200b9cfea00f0cfea0094000007d3000046ae000400020a00001b0c0000cd06a00f0a131100370a0000231c07160000a70063cfea00f0cfea0094000007d300009833000400020a0000360c0000880610fa1d0544000d0a00000907091100005f006ccfea00f0cfea0094000007d30000ba2b000400020a00003f0c0000df01c0a630e74e003a0a000020190d0200008b00a8010100a400000064000000c80000012c00000190000001f43c66c4a30202610a0000006400000064000000c80000012c00000190000001f43c66c4a30202610a0000006400000064000000c80000012c00000190000001f43c66c4a30202610a0000006400000064000000c80000012c00000190000001f43c66c4a30202610a0000006400000064000000c80000012c00000190000001f43c66c4a30202610a00000064";
        let packet = hex::decode(hex).unwrap();
        assert_yaml_snapshot!(NetflowParser::default().parse_bytes(&packet).packets);
    }

    #[test]
    fn it_parses_ipfix_options_template() {
        let packet = [
            0, 10, 0, 44, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 2, 0, 3, 0, 28, 1, 4, 0, 3, 0, 1,
            128, 123, 0, 4, 0, 0, 0, 2, 0, 41, 0, 2, 0, 42, 0, 2, 0, 0,
        ];
        assert_yaml_snapshot!(NetflowParser::default().parse_bytes(&packet).packets);
    }

    #[test]
    #[cfg(feature = "parse_unknown_fields")]
    fn it_parses_ipfix_options_template_with_data() {
        let packet = [
            0, 10, 0, 64, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 2, 0, 3, 0, 28, 1, 4, 0, 3, 0, 1,
            128, 123, 0, 4, 0, 0, 0, 2, 0, 41, 0, 2, 0, 42, 0, 2, 0, 0, 1, 4, 0, 20, 0, 0, 0,
            1, 1, 20, 20, 20, 0, 0, 0, 2, 20, 20, 30, 30,
        ];
        assert_yaml_snapshot!(NetflowParser::default().parse_bytes(&packet).packets);
    }

    #[test]
    fn it_parses_ipfix_enterprise_bit_in_non_options_template() {
        let packet = [
            0, 10, 0, 42, 99, 138, 252, 49, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2, 0, 26, 1, 4, 0, 2,
            128, 103, 255, 255, 24, 77, 128, 103, 255, 255, 0, 0, 24, 77, 129, 64, 0, 4, 0, 0,
            24, 77,
        ];
        assert_yaml_snapshot!(NetflowParser::default().parse_bytes(&packet).packets);
    }

    #[test]
    #[cfg(feature = "parse_unknown_fields")]
    fn it_parses_ipfix_enterprise_bit_template_and_data() {
        let template_packet = [
            0x00, 0x0a, 0x00, 0xf4, 0x5b, 0x3b, 0x54, 0x85, 0x00, 0x00, 0x86, 0xc7, 0x00, 0x00,
            0x03, 0x00, 0x00, 0x02, 0x00, 0xe4, 0x01, 0x0c, 0x00, 0x22, 0xaf, 0xcc, 0x00, 0x04,
            0x00, 0x00, 0x00, 0x09, 0xaf, 0xcd, 0x00, 0x04, 0x00, 0x00, 0x00, 0x09, 0xaf, 0xd0,
            0x00, 0x02, 0x00, 0x00, 0x00, 0x09, 0xaf, 0xd1, 0x00, 0x02, 0x00, 0x00, 0x00, 0x09,
            0x00, 0xea, 0x00, 0x04, 0x00, 0x0a, 0x00, 0x04, 0x00, 0xef, 0x00, 0x01, 0xaf, 0xd2,
            0x00, 0x04, 0x00, 0x00, 0x00, 0x09, 0x00, 0x5f, 0x00, 0x04, 0x00, 0x0e, 0x00, 0x04,
            0x00, 0x30, 0x00, 0x01, 0xa4, 0x24, 0x00, 0x01, 0x00, 0x00, 0x00, 0x09, 0xa4, 0x25,
            0x00, 0x01, 0x00, 0x00, 0x00, 0x09, 0xa4, 0x8d, 0xff, 0xff, 0x00, 0x00, 0x00, 0x09,
            0xaf, 0xcb, 0xff, 0xff, 0x00, 0x00, 0x00, 0x09, 0x00, 0x16, 0x00, 0x04, 0x00, 0x15,
            0x00, 0x04, 0x01, 0x16, 0x00, 0x04, 0x00, 0xe8, 0x00, 0x08, 0x01, 0x2b, 0x00, 0x08,
            0x00, 0xe7, 0x00, 0x08, 0x01, 0x2a, 0x00, 0x08, 0xa4, 0x57, 0x00, 0x04, 0x00, 0x00,
            0x00, 0x09, 0xa4, 0x4c, 0x00, 0x04, 0x00, 0x00, 0x00, 0x09, 0xa4, 0x54, 0x00, 0x04,
            0x00, 0x00, 0x00, 0x09, 0xa4, 0x67, 0x00, 0x04, 0x00, 0x00, 0x00, 0x09, 0xa4, 0x64,
            0x00, 0x04, 0x00, 0x00, 0x00, 0x09, 0xa4, 0x34, 0x00, 0x04, 0x00, 0x00, 0x00, 0x09,
            0xa4, 0x61, 0x00, 0x04, 0x00, 0x00, 0x00, 0x09, 0xa4, 0x5a, 0x00, 0x04, 0x00, 0x00,
            0x00, 0x09, 0xa4, 0x5b, 0x00, 0x04, 0x00, 0x00, 0x00, 0x09, 0xa4, 0x5d, 0x00, 0x04,
            0x00, 0x00, 0x00, 0x09, 0xa4, 0x39, 0x00, 0x04, 0x00, 0x00, 0x00, 0x09, 0xa4, 0x38,
            0x00, 0x04, 0x00, 0x00, 0x00, 0x09,
        ];
        let data_packet = [
            0x00, 0x0a, 0x00, 0xbc, 0x5b, 0x3b, 0x54, 0x7c, 0x00, 0x00, 0x86, 0xc6, 0x00, 0x00,
            0x03, 0x00, 0x01, 0x0c, 0x00, 0xac, 0x0a, 0xd1, 0x65, 0x42, 0x0a, 0x00, 0x00, 0xf1,
            0xc0, 0xe0, 0x00, 0x50, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x0d, 0x01, 0x8d,
            0xc3, 0x3f, 0xe0, 0x03, 0x00, 0x00, 0x50, 0x00, 0x00, 0x00, 0x0a, 0x09, 0x10, 0x00,
            0x0b, 0x2f, 0x44, 0x6f, 0x63, 0x4c, 0x69, 0x62, 0x31, 0x00, 0x00, 0x01, 0x1a, 0x03,
            0x00, 0x00, 0x50, 0x34, 0x02, 0x70, 0x6f, 0x72, 0x74, 0x61, 0x6c, 0x2e, 0x6d, 0x65,
            0x64, 0x73, 0x69, 0x67, 0x72, 0x6f, 0x75, 0x70, 0x2e, 0x72, 0x75, 0x21, 0xa0, 0xe2,
            0x7b, 0x21, 0xa2, 0x97, 0xbe, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x18, 0x40, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x0f, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        ];
        let mut parser = NetflowParser::default();
        let mut result = parser.parse_bytes(&template_packet).packets;
        result.append(&mut parser.parse_bytes(&data_packet).packets);
        assert_yaml_snapshot!(result);
    }

    #[test]
    fn it_parses_ipfix_scappy_example() {
        let hex_template = "000a0074583de05700000ecf00000000000200640133001700080004000c0004000500010004000100070002000b000200200002000a0004001000040011000400120004000e000400010004000200040016000400150004000f000400090001000d000100060001003c00010098000800990008";
        let packet = hex::decode(hex_template).unwrap();
        let mut parser = NetflowParser::default();
        let mut result = parser.parse_bytes(&packet).packets;
        let hex_data = "000a0060583de05900000ee400000000013300504601730132004701003d0000000000000000033b0000000200000003cc2a6e65000003560000052000000009b3f906eeb3fbaf3ccc2a6ebd1818000400000158b1b138ff00000158b1b3e14d";
        let packet = hex::decode(hex_data).unwrap();
        result.append(&mut parser.parse_bytes(&packet).packets);
        assert_yaml_snapshot!(result);
    }

    #[test]
    fn it_parses_ipfix_scappy_example_options_template() {
        let hex_template =
            "000a0028583de05700000ecf00000000000300180134000300010005000200240002002500020000";
        let packet = hex::decode(hex_template).unwrap();
        let mut parser = NetflowParser::default();
        let result = parser.parse_bytes(&packet).packets;
        assert_yaml_snapshot!(result);
    }

    #[test]
    fn it_parses_ipfix_with_v9_options_template_packet() {
        let hex = "000a00736800a129000186a0000000000001000e04e8000100060022000404e80008000000010002002c0102000900080004000c000400070002000b00020004000100020004000100040016000400150004010200214646010178780101303980090600000064077359406800a1296800a129";
        let packet = hex::decode(hex).unwrap();
        assert_yaml_snapshot!(NetflowParser::default().parse_bytes(&packet).packets);
    }

    #[test]
    fn it_parses_ipfix_mixed_enteprise_and_non_enterprise_fields() {
        let hex_template = "000a00845b3b5496005e9d61000004000002007401080016afcc000400000009afcd0004000000090004000100c3000100c00001afd100020000000900ea0004005f0004003a0002000a000400ef0001a424000100000009000e0004a4250001000000090016000400150004011600040117000800e80008012b000800e70008012a0008";
        let packet = hex::decode(hex_template).unwrap();
        let mut parser = NetflowParser::default();
        let mut result = parser.parse_bytes(&packet).packets;
        let hex_data = "000a05745b3b5424005e996700000400010805640a65ff010a0a1c391100ff0807000000000d00025e00000000000001100000001400ef92fb5cef93cb9400000000000000000000003500000000000000000000000000000000000000000002eff9000000000000009bac1fff01ac1fff011100fe0ec9000000000d00000100000000000101100000000100ef92fb60ef93e4040000000000000000000000780000000000000000000000000000000000000000000008a000000000000000b80ad016760a6516fb11043d44f6000000000d00000100000000000101100000000400ef92fb64ef93be3400000000000000000000003b00000000000000000000000000000000000000000000006000000000000000060a0097dc0a65975f11003cdffb000000000d00000100000000000101100000000400ef92fbaaef93e4fa00000000000000000000003b000000000000000000000000000000000000000000003ba000000000000000180a6516fb0a19161211007e1389000000000d00000100000000000401100000001400ef92fbaeef93e4c000000000000000000000003b0000000000000000000000000000000000000000000016f0000000000000016fe0000005ac1fff015900010000000000000100005900000000000102100000000000ef92fbe0ef93dbb60000000000000000000000500000000000000000000000000000001700000000000000000000000000000000ac1ffe65ac1ffe651130ff0ec9000000000d00000100000000000001100000000100ef92fc52ef93e50000000000000000000000003c000000000000000000000000000000000000000000000ee8000000000000013ee0000005ac1ffafc5930010000000000000100005901220000001402100000000000ef92fc5cef93db9c00000000000000000000000000000000000000000000000000000007000000000000000000000000000000000ad0160d0a6516fb11043d44f6000000000d00000100000000000101100000000400ef92fc5eef93bf1a0000000000000000000000320000000000000000000000000000000000000000000002e40000000000000041e0000005ac1ffe1b5930010000000000000100005900000000000102100000000000ef92fc66ef93d6ee00000000000000000000000000000000000000000000000000000007000000000000000000000000000000000a6466740acd970911007d0d3d000000000d00000101220000001402100000001100ef92fcacef93c48a0000000000000000000000ef00000000000000e10000000000000008000000000000006000000000000000080ad0167c0a6516fb11043d44f6000000000d00000100000000000101100000000400ef92fcc8ef93bf9a00000000000000000000003b0000000000000000000000000000000000000000000000600000000000000006ac1ffe65ac1ffe011130ff0ec8000000000d00000100000000000001100000000100ef92fcecef93df3e00000000000000000000003c00000000000000000000000000000000000000000000022800000000000000170a01162f0a6516fb11083d44f6000000000d00000100000000000101100000000400ef92fcf8ef93c00e00000000000000000000003200000000000000000000000000000000000000000000030400000000000000430a650a0c0a0097b301003c0000000000000d0001df00000000000102100000000400ef92fd0eef93e2320000000000000000000000000000000000000000000000000000001300000000000000000000000000000000ac1fff01ac1ffe651100ff0ec8000000000d00000100000000000101100000000000ef92fd34ef93e3ac00000000000000000000003b0000000000000000000000000000000000000000000006600000000000000044";
        let packet = hex::decode(hex_data).unwrap();
        result.append(&mut parser.parse_bytes(&packet).packets);
        assert_yaml_snapshot!(result);
    }

    #[test]
    fn it_parses_ipfix_multiple_templates() {
        let hex = "000a05b4542bf40f0001f2c100000000000205a401000017008a00040090000400940008808100040000173f808500040000173f003c00010004000100d2000200080004000c000400070002000b0002000200080001000800060001808400080000173f009a0008009b0008000a0004000e0004809700040000173f80c000100000173f80c100010000173f01010018008a00040090000400940008808100040000173f808500040000173f003c00010004000100d2000200080004000c000400070002000b0002000200080001000800060001808400080000173f009a0008009b0008808000040000173f000e0004000a0004809700040000173f80c000100000173f80c100010000173f01020025008a00040090000400940008808100040000173f808500040000173f003c00010004000100d2000200080004000c000400070002000b0002000200080001000800060001808400080000173f009a0008009b0008000a0004000e0004809700040000173f80ab00040000173f809e00080000173f80aa00080000173f80c000100000173f80c100010000173f8082ffff0000173f8083ffff0000173f808cffff0000173f808dffff0000173f808effff0000173f808fffff0000173f80b7ffff0000173f80b9ffff0000173f80baffff0000173f80beffff0000173f80cdffff0000173f01030017008a00040090000400940008808100040000173f808500040000173f003c00010004000100d20002001b0010001c001000070002000b0002000200080001000800060001808400080000173f009a0008009b0008000a0004000e0004809700040000173f80c000100000173f80c100010000173f01040018008a00040090000400940008808100040000173f808500040000173f003c00010004000100d20002001b0010001c001000070002000b0002000200080001000800060001808400080000173f009a0008009b0008808000040000173f000e0004000a0004809700040000173f80c000100000173f80c100010000173f01050025008a00040090000400940008808100040000173f808500040000173f003c00010004000100d20002001b0010001c001000070002000b0002000200080001000800060001808400080000173f009a0008009b0008000a0004000e0004809700040000173f80ab00040000173f809e00080000173f80aa00080000173f80c000100000173f80c100010000173f8082ffff0000173f8083ffff0000173f808cffff0000173f808dffff0000173f808effff0000173f808fffff0000173f80b7ffff0000173f80b9ffff0000173f80baffff0000173f80beffff0000173f80cdffff0000173f01060026008a00040090000400940008808100040000173f808500040000173f003c00010004000100d2000200080004000c000400070002000b0002000200080001000800060001808400080000173f009a0008009b0008000a0004000e0004809000020000173f809100080000173f809200080000173f809300080000173f809700040000173f80a100040000173f80a200040000173f809900080000173f809c00080000173f809d00080000173f809f00080000173f80a000080000173f80a900080000173f80b600040000173f80b7ffff0000173f80bbffff0000173f80bcffff0000173f80bdffff0000173f01070026008a00040090000400940008808100040000173f808500040000173f003c00010004000100d20002001b0010001c001000070002000b0002000200080001000800060001808400080000173f009a0008009b0008000a0004000e0004809000020000173f809100080000173f809200080000173f809300080000173f809700040000173f80a100040000173f80a200040000173f809900080000173f809c00080000173f809d00080000173f809f00080000173f80a000080000173f80a900080000173f80b600040000173f80b7ffff0000173f80bbffff0000173f80bcffff0000173f80bdffff0000173f";
        let packet = hex::decode(hex).unwrap();
        assert_yaml_snapshot!(NetflowParser::default().parse_bytes(&packet).packets);
    }

    #[test]
    fn it_parses_ipfix_multiple_flow_records() {
        let hex0: &'static str = "000a058c542bf40f0001f2c1000000000002057c010a000400900004808100040000173f80a8ffff0000173f80a3ffff0000173f010b000400900004808100040000173f80a4ffff0000173f80a5ffff0000173f010d0019008a00040090000400940008808100040000173f808500040000173f003c0001003d0001000400010006000100080004000c000400070002000b00020002000800010008808400080000173f009a0008009b0008000a0004000e0004809700040000173f80ae00010000173f80ad00010000173f00d2000280b2ffff0000173f010e001d008a00040090000400940008808100040000173f808500040000173f003c0001003d0001000400010006000100080004000c000400070002000b00020002000800010008808400080000173f009a0008009b0008000a0004000e0004809700040000173f809200080000173f809300080000173f80ae00010000173f00d2000100d2000280b400080000173f80b500080000173f80b3ffff0000173f010f001a008a00040090000400940008808500040000173f003c00010004000100d2000200080004000c000400070002000b000280c800100000173f80f700040000173f80f800100000173f80f900080000173f80d100040000173f80cb00040000173f80ca00020000173f80d000020000173f80c000100000173f80c100010000173f80c9ffff0000173f80ccffff0000173f80faffff0000173f80cfffff0000173f80d2ffff0000173f01100020008a00040090000400940008808500040000173f003c00010004000100d2000280c800100000173f80f700040000173f80f800100000173f80f900080000173f80d600010000173f80d700040000173f80d800040000173f80d900040000173f80db00020000173f80dc00020000173f80dd00040000173f80de00040000173f80f300040000173f80f400040000173f80fe00040000173f80ff00040000173f810000040000173f810100040000173f810200040000173f810300040000173f810400040000173f810500020000173f810600020000173f810700020000173f810800020000173f01110017008a00040090000400940008808500040000173f003c00010004000100d2000280c800100000173f80f700040000173f80f800100000173f80f900080000173f80df00040000173f80e000040000173f80e100040000173f80e200040000173f80e300040000173f80e400040000173f80e500040000173f80e600040000173f80e700040000173f80e800040000173f80e900040000173f80ea00040000173f01120016008a00040090000400940008808500040000173f003c00010004000100d2000200080004000c000400070002000b000280c800100000173f80f700040000173f80f800100000173f80f900080000173f80eb00020000173f80ec00040000173f80ed00020000173f80ef00040000173f80f500040000173f80eeffff0000173f80f6ffff0000173f0113000e008a00040090000400940008808500040000173f003c00010004000100d2000280c800100000173f80f700040000173f80f800100000173f80f900080000173f80f000020000173f80f500040000173f80f100040000173f0114000c008a00040090000400940008808500040000173f003c00010004000100d2000280c800100000173f80f700040000173f80f800100000173f80f900080000173f80f200040000173f01150005008a00040090000480fb00010000173f80fc00080000173f80fd00080000173f01160018008a00040090000400940008808100040000173f808500040000173f003c00010004000100d2000200080004000c000400070002000b0002000200080001000800060001808400080000173f009a0008009b0008000a0004000e0004809700040000173f80c000100000173f80c100010000173f80cdffff0000173f";
        let hex1: &'static str = "000a05b4542bf40f0001f2c100000000000205a401000017008a00040090000400940008808100040000173f808500040000173f003c00010004000100d2000200080004000c000400070002000b0002000200080001000800060001808400080000173f009a0008009b0008000a0004000e0004809700040000173f80c000100000173f80c100010000173f01010018008a00040090000400940008808100040000173f808500040000173f003c00010004000100d2000200080004000c000400070002000b0002000200080001000800060001808400080000173f009a0008009b0008808000040000173f000e0004000a0004809700040000173f80c000100000173f80c100010000173f01020025008a00040090000400940008808100040000173f808500040000173f003c00010004000100d2000200080004000c000400070002000b0002000200080001000800060001808400080000173f009a0008009b0008000a0004000e0004809700040000173f80ab00040000173f809e00080000173f80aa00080000173f80c000100000173f80c100010000173f8082ffff0000173f8083ffff0000173f808cffff0000173f808dffff0000173f808effff0000173f808fffff0000173f80b7ffff0000173f80b9ffff0000173f80baffff0000173f80beffff0000173f80cdffff0000173f01030017008a00040090000400940008808100040000173f808500040000173f003c00010004000100d20002001b0010001c001000070002000b0002000200080001000800060001808400080000173f009a0008009b0008000a0004000e0004809700040000173f80c000100000173f80c100010000173f01040018008a00040090000400940008808100040000173f808500040000173f003c00010004000100d20002001b0010001c001000070002000b0002000200080001000800060001808400080000173f009a0008009b0008808000040000173f000e0004000a0004809700040000173f80c000100000173f80c100010000173f01050025008a00040090000400940008808100040000173f808500040000173f003c00010004000100d20002001b0010001c001000070002000b0002000200080001000800060001808400080000173f009a0008009b0008000a0004000e0004809700040000173f80ab00040000173f809e00080000173f80aa00080000173f80c000100000173f80c100010000173f8082ffff0000173f8083ffff0000173f808cffff0000173f808dffff0000173f808effff0000173f808fffff0000173f80b7ffff0000173f80b9ffff0000173f80baffff0000173f80beffff0000173f80cdffff0000173f01060026008a00040090000400940008808100040000173f808500040000173f003c00010004000100d2000200080004000c000400070002000b0002000200080001000800060001808400080000173f009a0008009b0008000a0004000e0004809000020000173f809100080000173f809200080000173f809300080000173f809700040000173f80a100040000173f80a200040000173f809900080000173f809c00080000173f809d00080000173f809f00080000173f80a000080000173f80a900080000173f80b600040000173f80b7ffff0000173f80bbffff0000173f80bcffff0000173f80bdffff0000173f01070026008a00040090000400940008808100040000173f808500040000173f003c00010004000100d20002001b0010001c001000070002000b0002000200080001000800060001808400080000173f009a0008009b0008000a0004000e0004809000020000173f809100080000173f809200080000173f809300080000173f809700040000173f80a100040000173f80a200040000173f809900080000173f809c00080000173f809d00080000173f809f00080000173f80a000080000173f80a900080000173f80b600040000173f80b7ffff0000173f80bbffff0000173f80bcffff0000173f80bdffff0000173f";
        let hex2 = "000a04c1542bf41b0001f2c1000000000115001d00853ad3000000000100000000000000050000000000000000010201b100853ad30000000000000000001f247900016fa8001f247904060000ac12813dac129f63c99c01bb00000000000000030000000000000331180000000005022000d7d6729b000b8303d7d6729b000badf7000000018000000300002526000000000000000000000000000000000000000000505600d72b21541bf42b54f7ad0b0001102f76706e2f696e6465782e68746d6c0001000100044745540024696e742d6170702d6e65747363616c65722d31302d312d6578742e6c6162322e6e657400494d6f7a696c6c612f352e30202857696e646f7773204e5420362e313b20574f5736343b2072763a33322e3029204765636b6f2f32303130303130312046697265666f782f33322e30000100010001000100010000853ad30000000000000000001f247900016fa8001f247904060000ac12813dac129f63c99c01bb00000000000000010000000000000028100000000005022000d7d6729b000bbd8ad7d6729b000bbd8a000000018000000300002526000000000000000000000000000000000000000000505600d72b21541bf42b54f7ad0b0001010001000100010001000100010001000100010001000101007600853ad30000000000000000001f247a00016fa8001f247904060000ac129f63ac12813d01bbc99c00000000000000070000000000001b05180000000041002000d7d6729b000b8303d7d6729b000bb1d70000000300000001800000030000252600505600d72b21541bf42b54f7ad0b0001010201f700853ad30000000000000000001f247900016fa9001f247904060000ac12813dac129f63c99c01bb000000000000000100000000000001e2180000000005022000d7d6729b000c369dd7d6729b000c369d000000018000000300002526000000000000000000000000000000000000000000505600d72b21541bf42b549d360c00011c2f76706e2f696d616765732f636178746f6e7374796c652e6373730001003b68747470733a2f2f696e742d6170702d6e65747363616c65722d31302d312d6578742e6c6162322e6e65742f76706e2f696e6465782e68746d6c00044745540024696e742d6170702d6e65747363616c65722d31302d312d6578742e6c6162322e6e657400494d6f7a696c6c612f352e30202857696e646f7773204e5420362e313b20574f5736343b2072763a33322e3029204765636b6f2f32303130303130312046697265666f782f33322e30000100010001000100010000853ad30000000000000000001f247900016fa9001f247904060000ac12813dac129f63c99c01bb00000000000000030000000000000078100000000005022000d7d6729b000c3e6dd7d6729b000c4a18000000018000000300002526000000000000000000000000000000000000000000505600d72b21541bf42b549d360c0001010001000100010001000100010001000100010001000101007600853ad30000000000000000001f247a00016fa9001f247904060000ac129f63ac12813d01bbc99c000000000000000f00000000000055d0180000000041302000d7d6729b000c369dd7d6729b000c3e6d0000000200000001800000030000252600505600d72b21541bf42b549d360c0001";

        let mut parser = NetflowParser::default();

        let _ = parser.parse_bytes(&hex::decode(hex0).unwrap());
        let _ = parser.parse_bytes(&hex::decode(hex1).unwrap());

        assert_yaml_snapshot!(parser.parse_bytes(&hex::decode(hex2).unwrap()).packets);
    }
}

#[cfg(test)]
mod malformed_packet_tests {
    use crate::NetflowParser;

    // Empty input should return empty packets with no error and no panic.
    #[test]
    fn test_empty_input() {
        let mut parser = NetflowParser::default();
        let result = parser.parse_bytes(&[]);
        assert!(
            result.packets.is_empty(),
            "empty input should produce no packets"
        );
        assert!(
            result.error.is_none(),
            "empty input should produce no error"
        );
    }

    // A single byte is too short to contain a version number (2 bytes).
    // The parser should not panic and should return an error.
    #[test]
    fn test_single_byte() {
        let mut parser = NetflowParser::default();
        let result = parser.parse_bytes(&[0]);
        assert!(
            result.packets.is_empty(),
            "single byte should produce no packets"
        );
        assert!(
            result.error.is_some(),
            "single byte should produce an error"
        );
    }

    // Version 99 is not a recognized NetFlow/IPFIX version.
    // The parser should return an error without panicking.
    #[test]
    fn test_unknown_version() {
        let mut parser = NetflowParser::default();
        // Version = 99 (0x00, 0x63), followed by 18 zero bytes to form a 20-byte packet
        let mut packet = vec![0x00, 0x63];
        packet.extend_from_slice(&[0u8; 18]);
        let result = parser.parse_bytes(&packet);
        assert!(
            result.error.is_some(),
            "unknown version 99 should produce an error"
        );
    }

    // V5 header is 24 bytes. Providing version=5 plus only 10 bytes (12 total)
    // is a truncated header. The parser should not panic.
    #[test]
    fn test_v5_truncated_header() {
        let mut parser = NetflowParser::default();
        // Version 5 (0x00, 0x05) + 10 bytes of zeros = 12 bytes total (less than 24-byte header)
        let mut packet = vec![0x00, 0x05];
        packet.extend_from_slice(&[0u8; 10]);
        let result = parser.parse_bytes(&packet);
        // Should return an error and no valid packets
        assert!(
            result.packets.is_empty(),
            "truncated V5 header should not produce valid packets"
        );
        assert!(
            result.error.is_some(),
            "truncated V5 header should produce an error"
        );
    }

    // V5 header with count=30 but only enough data for about 1 flow record.
    // Each V5 flow record is 48 bytes; 24 (header) + 48 = 72 bytes for 1 record.
    // We provide 72 bytes but claim count=30.
    #[test]
    fn test_v5_count_exceeds_data() {
        let mut parser = NetflowParser::default();
        // Build a V5 packet: version=5, count=30
        let mut packet = vec![0x00, 0x05]; // version 5
        packet.extend_from_slice(&[0x00, 0x1E]); // count = 30
        packet.extend_from_slice(&[0u8; 20]); // rest of 24-byte header
        packet.extend_from_slice(&[0u8; 48]); // 1 flow record (48 bytes)
        // Total = 72 bytes, but count claims 30 records (would need 24 + 30*48 = 1464 bytes)
        let result = parser.parse_bytes(&packet);
        // V5 parser returns error for insufficient data when count exceeds available records
        assert!(
            result.packets.is_empty(),
            "V5 with count exceeding data should produce no valid packets"
        );
        assert!(
            result.error.is_some(),
            "V5 with count exceeding data should produce an error"
        );
    }

    // V5 header with count=0. No flow records should be parsed.
    #[test]
    fn test_v5_count_zero() {
        let mut parser = NetflowParser::default();
        // Build a V5 packet: version=5, count=0
        let mut packet = vec![0x00, 0x05]; // version 5
        packet.extend_from_slice(&[0x00, 0x00]); // count = 0
        packet.extend_from_slice(&[0u8; 20]); // rest of 24-byte header
        let result = parser.parse_bytes(&packet);
        // V5 rejects count=0 at parse time
        assert!(
            result.packets.is_empty(),
            "V5 with count=0 should produce no packets"
        );
        assert!(
            result.error.is_some(),
            "V5 with count=0 should produce an error"
        );
    }

    // V9 header is 20 bytes. Providing only 10 bytes after the version is truncated.
    #[test]
    fn test_v9_truncated_header() {
        let mut parser = NetflowParser::default();
        // Version 9 (0x00, 0x09) + 8 bytes = 10 total (less than 20-byte header)
        let mut packet = vec![0x00, 0x09];
        packet.extend_from_slice(&[0u8; 8]);
        let result = parser.parse_bytes(&packet);
        assert!(
            result.error.is_some(),
            "truncated V9 header must produce an error"
        );
    }

    // V9 with a flowset whose length field is 0.
    // A zero-length flowset could cause an infinite loop if not handled.
    #[test]
    fn test_v9_flowset_length_zero() {
        let mut parser = NetflowParser::default();
        // V9 header: version=9, count=1, sysuptime=0, unix_secs=0, sequence=0, source_id=0
        let mut packet = vec![
            0x00, 0x09, // version 9
            0x00, 0x01, // count = 1
            0x00, 0x00, 0x00, 0x00, // sys_uptime
            0x00, 0x00, 0x00, 0x00, // unix_secs
            0x00, 0x00, 0x00, 0x00, // sequence
            0x00, 0x00, 0x00, 0x00, // source_id
        ];
        // Flowset with id=0 (template), length=0 (malformed)
        packet.extend_from_slice(&[0x00, 0x00, 0x00, 0x00]);
        let result = parser.parse_bytes(&packet);
        // Must not infinite loop or panic; zero-length flowset must produce an error
        assert!(
            result.error.is_some(),
            "V9 with zero-length flowset must produce an error"
        );
    }

    // V9 with a flowset length larger than the remaining bytes in the packet.
    #[test]
    fn test_v9_flowset_length_exceeds_packet() {
        let mut parser = NetflowParser::default();
        let mut packet = vec![
            0x00, 0x09, // version 9
            0x00, 0x01, // count = 1
            0x00, 0x00, 0x00, 0x00, // sys_uptime
            0x00, 0x00, 0x00, 0x00, // unix_secs
            0x00, 0x00, 0x00, 0x00, // sequence
            0x00, 0x00, 0x00, 0x00, // source_id
        ];
        // Flowset with id=0 (template), length=9999 (far exceeds remaining data)
        packet.extend_from_slice(&[0x00, 0x00, 0x27, 0x0F]);
        // Only 4 bytes of flowset data actually present
        let result = parser.parse_bytes(&packet);
        assert!(
            result.error.is_some(),
            "V9 with flowset length exceeding packet must produce an error"
        );
    }

    // IPFIX header includes a length field that should match the actual packet size.
    // Here we set it to a wrong value.
    #[test]
    fn test_ipfix_length_field_wrong() {
        let mut parser = NetflowParser::default();
        // IPFIX header: version=10, length=9999 (wrong), export_time, sequence, observation_domain
        let packet = vec![
            0x00, 0x0A, // version 10 (IPFIX)
            0x27, 0x0F, // length = 9999 (actual packet is only 16 bytes)
            0x00, 0x00, 0x00, 0x00, // export_time
            0x00, 0x00, 0x00, 0x00, // sequence_number
            0x00, 0x00, 0x00, 0x00, // observation_domain_id
        ];
        let result = parser.parse_bytes(&packet);
        // Parser should handle the length mismatch without panicking
        assert!(
            result.error.is_some(),
            "IPFIX with wrong length field must produce an error"
        );
    }

    // IPFIX with a flowset whose length field is less than 4 (the minimum set header size).
    #[test]
    fn test_ipfix_flowset_length_less_than_4() {
        let mut parser = NetflowParser::default();
        // IPFIX header (16 bytes) + a flowset with length < 4
        let mut packet = vec![
            0x00, 0x0A, // version 10
            0x00, 0x14, // length = 20 (16 header + 4 flowset header)
            0x00, 0x00, 0x00, 0x00, // export_time
            0x00, 0x00, 0x00, 0x00, // sequence_number
            0x00, 0x00, 0x00, 0x00, // observation_domain_id
        ];
        // Flowset: set_id=2 (template), length=2 (less than minimum 4)
        packet.extend_from_slice(&[0x00, 0x02, 0x00, 0x02]);
        let result = parser.parse_bytes(&packet);
        // The parser handles the malformed flowset gracefully without panicking.
        // Any packets produced should be IPFIX type.
        for p in &result.packets {
            assert!(
                matches!(p, crate::NetflowPacket::IPFix(_)),
                "any packets from IPFIX input should be IPFIX type"
            );
        }
    }

    // V9 with a flowset ID in the reserved range (2-255).
    // Flowset IDs 0=template, 1=options template, 256+=data. IDs 2-255 are reserved.
    #[test]
    fn test_v9_reserved_flowset_id() {
        let mut parser = NetflowParser::default();
        let mut packet = vec![
            0x00, 0x09, // version 9
            0x00, 0x01, // count = 1
            0x00, 0x00, 0x00, 0x00, // sys_uptime
            0x00, 0x00, 0x00, 0x00, // unix_secs
            0x00, 0x00, 0x00, 0x00, // sequence
            0x00, 0x00, 0x00, 0x00, // source_id
        ];
        // Flowset with reserved ID=100 (0x0064), length=8
        packet.extend_from_slice(&[0x00, 0x64, 0x00, 0x08]);
        packet.extend_from_slice(&[0x00, 0x00, 0x00, 0x00]); // 4 bytes of padding
        let result = parser.parse_bytes(&packet);
        // Parser should handle reserved flowset IDs gracefully per RFC 3954,
        // skipping them without error (IDs 2-255 are reserved).
        assert!(
            result.error.is_none(),
            "V9 reserved flowset IDs should be skipped without error"
        );
        for p in &result.packets {
            assert!(p.is_v9(), "any packets should be V9");
        }
    }

    // 100 bytes of all zeros. Version 0 is not a valid NetFlow version.
    #[test]
    fn test_all_zeros() {
        let mut parser = NetflowParser::default();
        let packet = vec![0u8; 100];
        let result = parser.parse_bytes(&packet);
        assert!(
            result.error.is_some(),
            "all-zeros packet (version 0) should produce an error"
        );
    }

    // Maximum version number 0xFFFF is not a valid NetFlow/IPFIX version.
    #[test]
    fn test_max_version_number() {
        let mut parser = NetflowParser::default();
        let mut packet = vec![0xFF, 0xFF]; // version = 65535
        packet.extend_from_slice(&[0u8; 18]);
        let result = parser.parse_bytes(&packet);
        assert!(
            result.error.is_some(),
            "version 0xFFFF should produce an error"
        );
    }

    // V7 header with count=0. No flow records should be parsed.
    #[test]
    fn test_v7_count_zero() {
        let mut parser = NetflowParser::default();
        // Build a V7 packet: version=7, count=0, rest of 24-byte header zeroed
        let mut packet = vec![0x00, 0x07]; // version 7
        packet.extend_from_slice(&[0x00, 0x00]); // count = 0
        packet.extend_from_slice(&[0u8; 20]); // rest of 24-byte header
        let result = parser.parse_bytes(&packet);
        assert!(
            result.packets.is_empty(),
            "V7 with count=0 should produce no packets"
        );
    }

    // IPFIX with a flowset using a reserved set ID (e.g., 5).
    // Set IDs 0-1 are reserved in IPFIX, 2=template, 3=options template, 4+ reserved until 256.
    #[test]
    fn test_ipfix_reserved_flowset_id() {
        let mut parser = NetflowParser::default();
        let mut packet = vec![
            0x00, 0x0A, // version 10 (IPFIX)
            0x00, 0x18, // length = 24 (16 header + 8 flowset)
            0x00, 0x00, 0x00, 0x00, // export_time
            0x00, 0x00, 0x00, 0x00, // sequence_number
            0x00, 0x00, 0x00, 0x00, // observation_domain_id
        ];
        // Flowset with reserved set ID=5, length=8
        packet.extend_from_slice(&[0x00, 0x05, 0x00, 0x08]);
        packet.extend_from_slice(&[0x00, 0x00, 0x00, 0x00]); // 4 bytes of padding
        let result = parser.parse_bytes(&packet);
        // Reserved set ID should be handled gracefully (Empty), not panic
        assert!(
            result.error.is_none(),
            "IPFIX reserved set ID should not produce a parse error"
        );
    }

    // IPFIX template with field_count=0 is a template withdrawal.
    // The parser should handle it gracefully.
    #[test]
    fn test_ipfix_template_withdrawal() {
        let mut parser = NetflowParser::default();
        // IPFIX header (16 bytes) + template set with a withdrawal (field_count=0)
        let mut packet = vec![
            0x00, 0x0A, // version 10 (IPFIX)
            0x00, 0x18, // length = 24 (16 header + 8 template set)
            0x00, 0x00, 0x00, 0x00, // export_time
            0x00, 0x00, 0x00, 0x00, // sequence_number
            0x00, 0x00, 0x00, 0x00, // observation_domain_id
        ];
        // Template set: set_id=2, length=8, template_id=256, field_count=0 (withdrawal)
        packet.extend_from_slice(&[0x00, 0x02, 0x00, 0x08]); // set_id=2, length=8
        packet.extend_from_slice(&[0x01, 0x00, 0x00, 0x00]); // template_id=256, field_count=0
        let result = parser.parse_bytes(&packet);
        // Template withdrawal (field_count=0) should be handled gracefully
        assert!(
            result.error.is_none(),
            "IPFIX template withdrawal should not produce a parse error"
        );
    }

    // Sending the same V9 template twice should not record a collision metric.
    #[test]
    fn test_template_reregistration_same_definition() {
        use std::sync::Arc;
        use std::sync::atomic::{AtomicUsize, Ordering};

        let collision_count = Arc::new(AtomicUsize::new(0));
        let cc = collision_count.clone();

        let mut parser = NetflowParser::builder()
            .with_cache_size(100)
            .on_template_event(move |event| {
                if matches!(event, crate::TemplateEvent::Collision { .. }) {
                    cc.fetch_add(1, Ordering::SeqCst);
                }
                Ok(())
            })
            .build()
            .unwrap();

        // V9 template packet: version=9, count=1, template with id=256, 1 field (InBytes, len=4)
        let template_packet = vec![
            0x00, 0x09, // version 9
            0x00, 0x01, // count = 1
            0x00, 0x00, 0x00, 0x00, // sys_uptime
            0x00, 0x00, 0x00, 0x00, // unix_secs
            0x00, 0x00, 0x00, 0x00, // sequence
            0x00, 0x00, 0x00, 0x00, // source_id
            // Template flowset: flowset_id=0, length=16 (4 header + 4 template header + 4 field + 4 padding)
            0x00, 0x00, 0x00, 0x10, // flowset_id=0, length=16
            0x01, 0x00, 0x00, 0x01, // template_id=256, field_count=1
            0x00, 0x01, 0x00, 0x04, // field_type=1 (InBytes), field_length=4
            0x00, 0x00, 0x00, 0x00, // padding to reach length=16
        ];

        // Send the same template twice
        let _ = parser.parse_bytes(&template_packet);
        let _ = parser.parse_bytes(&template_packet);

        assert_eq!(
            collision_count.load(Ordering::SeqCst),
            0,
            "Re-registering the same template definition should not record a collision"
        );
    }
}
