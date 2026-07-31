use netflow_parser::variable_versions::{ipfix, v9};
use netflow_parser::{
    Config, ConfigError, DecodedOutputLimit, DecodedOutputLimits, InMemoryTemplateStore,
    IpfixField, NetflowError, NetflowPacket, NetflowParser, PendingFlowsConfig,
    TemplateProtocol, V9Field,
};
use std::sync::Arc;

fn v9_message(flowsets: &[Vec<u8>]) -> Vec<u8> {
    let mut packet = vec![
        0,
        9, // version
        0,
        flowsets.len() as u8, // current parser's declared count
        0,
        0,
        0,
        0, // sys_uptime
        0,
        0,
        0,
        0, // unix_secs
        0,
        0,
        0,
        1, // sequence
        0,
        0,
        0,
        1, // source_id
    ];
    for flowset in flowsets {
        packet.extend_from_slice(flowset);
    }
    packet
}

fn v9_template(template_id: u16, fields: &[(u16, u16)]) -> Vec<u8> {
    let length = 8 + fields.len() * 4;
    let mut set = Vec::with_capacity(length);
    set.extend_from_slice(&0u16.to_be_bytes());
    set.extend_from_slice(&(length as u16).to_be_bytes());
    set.extend_from_slice(&template_id.to_be_bytes());
    set.extend_from_slice(&(fields.len() as u16).to_be_bytes());
    for (field_type, field_length) in fields {
        set.extend_from_slice(&field_type.to_be_bytes());
        set.extend_from_slice(&field_length.to_be_bytes());
    }
    set
}

fn v9_options_template(template_id: u16) -> Vec<u8> {
    let mut set = Vec::new();
    set.extend_from_slice(&1u16.to_be_bytes());
    set.extend_from_slice(&18u16.to_be_bytes());
    set.extend_from_slice(&template_id.to_be_bytes());
    set.extend_from_slice(&4u16.to_be_bytes());
    set.extend_from_slice(&4u16.to_be_bytes());
    set.extend_from_slice(&1u16.to_be_bytes());
    set.extend_from_slice(&1u16.to_be_bytes());
    set.extend_from_slice(&2u16.to_be_bytes());
    set.extend_from_slice(&1u16.to_be_bytes());
    set
}

fn v9_data(template_id: u16, body: &[u8]) -> Vec<u8> {
    let mut set = Vec::with_capacity(body.len() + 4);
    set.extend_from_slice(&template_id.to_be_bytes());
    set.extend_from_slice(&((body.len() + 4) as u16).to_be_bytes());
    set.extend_from_slice(body);
    set
}

fn ipfix_message(sets: &[Vec<u8>]) -> Vec<u8> {
    let length = 16 + sets.iter().map(Vec::len).sum::<usize>();
    let mut packet = Vec::with_capacity(length);
    packet.extend_from_slice(&10u16.to_be_bytes());
    packet.extend_from_slice(&(length as u16).to_be_bytes());
    packet.extend_from_slice(&0u32.to_be_bytes());
    packet.extend_from_slice(&1u32.to_be_bytes());
    packet.extend_from_slice(&1u32.to_be_bytes());
    for set in sets {
        packet.extend_from_slice(set);
    }
    packet
}

fn ipfix_template(template_id: u16, field_type: u16, field_length: u16) -> Vec<u8> {
    ipfix_template_fields(template_id, &[(field_type, field_length)])
}

fn ipfix_template_fields(template_id: u16, fields: &[(u16, u16)]) -> Vec<u8> {
    let mut set = Vec::new();
    set.extend_from_slice(&2u16.to_be_bytes());
    set.extend_from_slice(&((8 + fields.len() * 4) as u16).to_be_bytes());
    set.extend_from_slice(&template_id.to_be_bytes());
    set.extend_from_slice(&(fields.len() as u16).to_be_bytes());
    for (field_type, field_length) in fields {
        set.extend_from_slice(&field_type.to_be_bytes());
        set.extend_from_slice(&field_length.to_be_bytes());
    }
    set
}

fn ipfix_options_template(template_id: u16) -> Vec<u8> {
    let mut set = Vec::new();
    set.extend_from_slice(&3u16.to_be_bytes());
    set.extend_from_slice(&18u16.to_be_bytes());
    set.extend_from_slice(&template_id.to_be_bytes());
    set.extend_from_slice(&2u16.to_be_bytes());
    set.extend_from_slice(&1u16.to_be_bytes());
    set.extend_from_slice(&1u16.to_be_bytes());
    set.extend_from_slice(&1u16.to_be_bytes());
    set.extend_from_slice(&2u16.to_be_bytes());
    set.extend_from_slice(&1u16.to_be_bytes());
    set
}

fn ipfix_data(template_id: u16, body: &[u8]) -> Vec<u8> {
    let mut set = Vec::with_capacity(body.len() + 4);
    set.extend_from_slice(&template_id.to_be_bytes());
    set.extend_from_slice(&((body.len() + 4) as u16).to_be_bytes());
    set.extend_from_slice(body);
    set
}

fn ipfix_replay_boundary_body() -> Vec<u8> {
    // The replayed Set is 65,508 bytes: it fits after a 20-byte store-backed
    // trigger, but not after the smallest 28-byte on-wire Template message.
    let mut body = Vec::with_capacity(65_504);
    body.push(255);
    body.extend_from_slice(&65_501u16.to_be_bytes());
    body.resize(65_504, b'x');
    body
}

fn assert_limit(
    error: Option<NetflowError>,
    protocol: TemplateProtocol,
    limit: DecodedOutputLimit,
    configured: usize,
    attempted: usize,
) {
    assert!(matches!(
        error,
        Some(NetflowError::DecodedOutputLimitExceeded {
            protocol: actual_protocol,
            limit: actual_limit,
            configured: actual_configured,
            attempted: actual_attempted,
        }) if actual_protocol == protocol
            && actual_limit == limit
            && actual_configured == configured
            && actual_attempted == attempted
    ));
}

#[test]
fn v9_value_budget_is_cumulative_across_flowsets_and_exact() {
    let template = v9_template(256, &[(1, 1)]);

    let mut exact = NetflowParser::builder()
        .with_v9_max_decoded_field_values_per_message(4)
        .build()
        .unwrap();
    assert!(
        exact
            .parse_bytes(&v9_message(std::slice::from_ref(&template)))
            .is_ok()
    );
    let result =
        exact.parse_bytes(&v9_message(&[v9_data(256, &[1, 2]), v9_data(256, &[3, 4])]));
    assert!(result.is_ok(), "{:?}", result.error);

    let mut one_over = NetflowParser::builder()
        .with_v9_max_decoded_field_values_per_message(3)
        .build()
        .unwrap();
    assert!(one_over.parse_bytes(&v9_message(&[template])).is_ok());
    let result =
        one_over.parse_bytes(&v9_message(&[v9_data(256, &[1, 2]), v9_data(256, &[3, 4])]));
    assert!(result.packets.is_empty());
    assert_limit(
        result.error,
        TemplateProtocol::V9,
        DecodedOutputLimit::FieldValues,
        3,
        4,
    );
}

#[test]
fn v9_options_budget_counts_scope_and_option_values() {
    let mut parser = NetflowParser::builder()
        .with_v9_max_decoded_field_values_per_message(1)
        .build()
        .unwrap();
    assert!(
        parser
            .parse_bytes(&v9_message(&[v9_options_template(300)]))
            .is_ok()
    );
    let result = parser.parse_bytes(&v9_message(&[v9_data(300, &[1, 2])]));
    assert_limit(
        result.error,
        TemplateProtocol::V9,
        DecodedOutputLimit::FieldValues,
        1,
        2,
    );
}

#[test]
fn ipfix_value_budget_is_cumulative_across_sets_and_exact() {
    let template = ipfix_template(256, 1, 1);
    let mut parser = NetflowParser::builder()
        .with_ipfix_max_decoded_field_values_per_message(3)
        .build()
        .unwrap();
    assert!(parser.parse_bytes(&ipfix_message(&[template])).is_ok());

    let result = parser.parse_bytes(&ipfix_message(&[
        ipfix_data(256, &[1, 2]),
        ipfix_data(256, &[3, 4]),
    ]));
    assert!(result.packets.is_empty());
    assert_limit(
        result.error,
        TemplateProtocol::Ipfix,
        DecodedOutputLimit::FieldValues,
        3,
        4,
    );
}

#[test]
fn output_budgets_reset_between_messages() {
    let mut v9_parser = NetflowParser::builder()
        .with_v9_max_decoded_field_values_per_message(1)
        .build()
        .unwrap();
    assert!(
        v9_parser
            .parse_bytes(&v9_message(&[v9_template(256, &[(1, 1)])]))
            .is_ok()
    );
    for value in [1, 2] {
        let result = v9_parser.parse_bytes(&v9_message(&[v9_data(256, &[value])]));
        assert!(result.is_ok(), "{:?}", result.error);
    }

    let mut ipfix_parser = NetflowParser::builder()
        .with_ipfix_max_decoded_field_values_per_message(1)
        .build()
        .unwrap();
    assert!(
        ipfix_parser
            .parse_bytes(&ipfix_message(&[ipfix_template(256, 1, 1)]))
            .is_ok()
    );
    for value in [1, 2] {
        let result = ipfix_parser.parse_bytes(&ipfix_message(&[ipfix_data(256, &[value])]));
        assert!(result.is_ok(), "{:?}", result.error);
    }
}

#[test]
fn direct_v9_message_parser_resets_the_output_budget() {
    let mut config = Config::default();
    config.max_decoded_field_values_per_message = 1;
    let mut parser = v9::V9Parser::try_new(config).unwrap();

    let template = v9_message(&[v9_template(256, &[(1, 1)])]);
    assert!(v9::V9::parse(&template[2..], &mut parser).is_ok());

    for value in [1, 2] {
        let message = v9_message(&[v9_data(256, &[value])]);
        let (_, packet) = v9::V9::parse(&message[2..], &mut parser).unwrap();
        let records = packet
            .flowsets
            .iter()
            .filter_map(|flowset| match &flowset.body {
                v9::FlowSetBody::Data(data) => Some(data.fields.len()),
                _ => None,
            })
            .sum::<usize>();
        assert_eq!(records, 1);
    }

    let over_limit = v9_message(&[v9_data(256, &[3, 4])]);
    assert!(v9::V9::parse(&over_limit[2..], &mut parser).is_err());
}

#[test]
fn direct_ipfix_message_parser_resets_and_enforces_the_output_budget() {
    let mut config = Config::default();
    config.max_decoded_field_values_per_message = 1;
    let mut parser = ipfix::IPFixParser::try_new(config).unwrap();

    let template = ipfix_message(&[ipfix_template(256, 1, 1)]);
    assert!(ipfix::IPFix::parse(&template[2..], &mut parser).is_ok());

    for value in [1, 2] {
        let message = ipfix_message(&[ipfix_data(256, &[value])]);
        let (_, packet) = ipfix::IPFix::parse(&message[2..], &mut parser).unwrap();
        let records = packet
            .flowsets
            .iter()
            .filter_map(|flowset| match &flowset.body {
                ipfix::FlowSetBody::Data(data) => Some(data.fields.len()),
                _ => None,
            })
            .sum::<usize>();
        assert_eq!(records, 1);
    }

    let over_limit = ipfix_message(&[ipfix_data(256, &[3, 4])]);
    assert!(ipfix::IPFix::parse(&over_limit[2..], &mut parser).is_err());
}

#[test]
fn ipfix_variable_field_payload_budget_excludes_length_prefix() {
    // interfaceName (82) is a String; 65535 selects RFC 7011 variable length.
    let template = ipfix_template(256, 82, u16::MAX);
    let mut exact = NetflowParser::builder()
        .with_ipfix_max_decoded_field_payload_bytes_per_message(4)
        .build()
        .unwrap();
    assert!(
        exact
            .parse_bytes(&ipfix_message(std::slice::from_ref(&template)))
            .is_ok()
    );
    assert!(
        exact
            .parse_bytes(&ipfix_message(&[ipfix_data(
                256,
                &[4, b't', b'e', b's', b't']
            )]))
            .is_ok()
    );

    let mut one_over = NetflowParser::builder()
        .with_ipfix_max_decoded_field_payload_bytes_per_message(4)
        .build()
        .unwrap();
    assert!(one_over.parse_bytes(&ipfix_message(&[template])).is_ok());
    let result = one_over.parse_bytes(&ipfix_message(&[ipfix_data(
        256,
        &[5, b't', b'e', b's', b't', b'!'],
    )]));
    assert_limit(
        result.error,
        TemplateProtocol::Ipfix,
        DecodedOutputLimit::FieldPayloadBytes,
        4,
        5,
    );
}

#[test]
fn v9_payload_budget_is_cumulative_across_flowsets() {
    let template = v9_template(256, &[(1, 2)]);
    let mut parser = NetflowParser::builder()
        .with_v9_max_decoded_field_payload_bytes_per_message(3)
        .build()
        .unwrap();
    assert!(parser.parse_bytes(&v9_message(&[template])).is_ok());
    let result =
        parser.parse_bytes(&v9_message(&[v9_data(256, &[0, 1]), v9_data(256, &[0, 2])]));
    assert_limit(
        result.error,
        TemplateProtocol::V9,
        DecodedOutputLimit::FieldPayloadBytes,
        3,
        4,
    );
}

#[test]
#[cfg(feature = "parse_unknown_fields")]
fn default_value_budget_rejects_many_tiny_materialized_fields() {
    let mut fields: Vec<(u16, u16)> = (1000..1064).map(|field| (field, 0)).collect();
    fields.push((1, 1));
    let mut parser = NetflowParser::default();
    assert!(
        parser
            .parse_bytes(&v9_message(&[v9_template(256, &fields)]))
            .is_ok()
    );
    let result = parser.parse_bytes(&v9_message(&[v9_data(256, &[1; 1009])]));
    assert_limit(
        result.error,
        TemplateProtocol::V9,
        DecodedOutputLimit::FieldValues,
        netflow_parser::DEFAULT_MAX_DECODED_FIELD_VALUES_PER_MESSAGE,
        65_585,
    );
}

#[test]
fn large_variable_value_is_rejected_before_payload_materialization() {
    let template = ipfix_template(256, 82, u16::MAX);
    let mut parser = NetflowParser::builder()
        .with_ipfix_max_decoded_field_payload_bytes_per_message(4095)
        .build()
        .unwrap();
    assert!(parser.parse_bytes(&ipfix_message(&[template])).is_ok());

    let mut body = Vec::with_capacity(4099);
    body.push(255);
    body.extend_from_slice(&4096u16.to_be_bytes());
    body.resize(4099, b'x');
    let result = parser.parse_bytes(&ipfix_message(&[ipfix_data(256, &body)]));
    assert_limit(
        result.error,
        TemplateProtocol::Ipfix,
        DecodedOutputLimit::FieldPayloadBytes,
        4095,
        4096,
    );
}

#[test]
fn ipfix_native_and_embedded_options_count_every_value() {
    for template in [ipfix_options_template(300), {
        let mut embedded = v9_options_template(300);
        embedded[0..2].copy_from_slice(&1u16.to_be_bytes());
        embedded
    }] {
        let mut parser = NetflowParser::builder()
            .with_ipfix_max_decoded_field_values_per_message(1)
            .build()
            .unwrap();
        assert!(parser.parse_bytes(&ipfix_message(&[template])).is_ok());
        let result = parser.parse_bytes(&ipfix_message(&[ipfix_data(300, &[1, 2])]));
        assert_limit(
            result.error,
            TemplateProtocol::Ipfix,
            DecodedOutputLimit::FieldValues,
            1,
            2,
        );
    }
}

#[test]
fn ipfix_embedded_v9_data_uses_the_message_budget() {
    let mut parser = NetflowParser::builder()
        .with_ipfix_max_decoded_field_values_per_message(1)
        .build()
        .unwrap();
    let template = v9_template(256, &[(1, 1)]);
    assert!(parser.parse_bytes(&ipfix_message(&[template])).is_ok());
    let result = parser.parse_bytes(&ipfix_message(&[ipfix_data(256, &[1, 2])]));
    assert_limit(
        result.error,
        TemplateProtocol::Ipfix,
        DecodedOutputLimit::FieldValues,
        1,
        2,
    );
}

#[test]
fn pending_variable_preflight_uses_the_parser_padding_boundary() {
    let mut parser = NetflowParser::builder()
        .with_ipfix_pending_flows(PendingFlowsConfig::default())
        .with_ipfix_max_decoded_field_values_per_message(2)
        .build()
        .unwrap();

    // One complete one-byte varlen + one-byte fixed record, then one byte of
    // legal Set padding that is not a complete second record.
    assert!(
        parser
            .parse_bytes(&ipfix_message(&[ipfix_data(256, &[1, b'x', 7, 0])]))
            .is_ok()
    );
    assert_eq!(parser.ipfix_cache_info().pending_flow_count, 1);

    let template = ipfix_template_fields(256, &[(82, u16::MAX), (1, 1)]);
    let replay = parser.parse_bytes(&ipfix_message(&[template]));
    assert!(replay.is_ok(), "{:?}", replay.error);
    assert_eq!(parser.ipfix_cache_info().pending_flow_count, 0);
    let NetflowPacket::IPFix(packet) = &replay.packets[0] else {
        panic!("expected IPFIX packet")
    };
    assert!(packet.flowsets.len() >= 2, "pending flow was not appended");
}

#[test]
fn pending_replay_retains_a_temporarily_non_fitting_suffix() {
    let mut parser = NetflowParser::builder()
        .with_v9_pending_flows(PendingFlowsConfig::default())
        .with_v9_max_decoded_field_values_per_message(2)
        .build()
        .unwrap();

    assert!(
        parser
            .parse_bytes(&v9_message(&[v9_data(256, &[1, 2])]))
            .is_ok()
    );
    assert_eq!(parser.v9_cache_info().pending_flow_count, 1);

    let template = v9_template(256, &[(1, 1)]);
    let current = parser.parse_bytes(&v9_message(&[template.clone(), v9_data(256, &[3])]));
    assert!(current.is_ok(), "{:?}", current.error);
    assert_eq!(parser.v9_cache_info().pending_flow_count, 1);

    let replay = parser.parse_bytes(&v9_message(&[template]));
    assert!(replay.is_ok(), "{:?}", replay.error);
    assert_eq!(parser.v9_cache_info().pending_flow_count, 0);
    let NetflowPacket::V9(packet) = &replay.packets[0] else {
        panic!("expected v9 packet")
    };
    assert!(packet.flowsets.len() >= 2, "pending flow was not appended");
}

#[test]
fn pending_replay_appends_the_largest_fitting_fifo_prefix() {
    let mut parser = NetflowParser::builder()
        .with_v9_pending_flows(PendingFlowsConfig::default())
        .with_v9_max_decoded_field_values_per_message(2)
        .build()
        .unwrap();

    for value in [1, 2] {
        assert!(
            parser
                .parse_bytes(&v9_message(&[v9_data(256, &[value])]))
                .is_ok()
        );
    }
    assert_eq!(parser.v9_cache_info().pending_flow_count, 2);

    let template = v9_template(256, &[(1, 1)]);
    let first = parser.parse_bytes(&v9_message(&[template.clone(), v9_data(256, &[3])]));
    assert!(first.is_ok(), "{:?}", first.error);
    let NetflowPacket::V9(packet) = &first.packets[0] else {
        panic!("expected v9 packet")
    };
    assert_eq!(
        packet
            .flowsets
            .iter()
            .filter(|flowset| matches!(flowset.body, v9::FlowSetBody::Data(_)))
            .count(),
        2
    );
    let info = parser.v9_cache_info();
    assert_eq!(info.pending_flow_count, 1);
    assert_eq!(info.metrics.pending_replayed, 1);

    let second = parser.parse_bytes(&v9_message(&[template]));
    assert!(second.is_ok(), "{:?}", second.error);
    let info = parser.v9_cache_info();
    assert_eq!(info.pending_flow_count, 0);
    assert_eq!(info.metrics.pending_replayed, 2);
}

#[test]
fn pending_replay_drops_incomplete_fixed_entry_and_continues_fifo() {
    let mut parser = NetflowParser::builder()
        .with_v9_pending_flows(PendingFlowsConfig::default())
        .build()
        .unwrap();

    assert!(
        parser
            .parse_bytes(&v9_message(&[v9_data(256, &[1])]))
            .is_ok()
    );
    assert!(
        parser
            .parse_bytes(&v9_message(&[v9_data(256, &[2, 3])]))
            .is_ok()
    );
    assert_eq!(parser.v9_cache_info().pending_flow_count, 2);

    let replay = parser.parse_bytes(&v9_message(&[v9_template(256, &[(1, 2)])]));
    assert!(replay.is_ok(), "{:?}", replay.error);
    let info = parser.v9_cache_info();
    assert_eq!(info.pending_flow_count, 0);
    assert_eq!(info.metrics.pending_replay_failed, 1);
    assert_eq!(info.metrics.pending_replayed, 1);

    let NetflowPacket::V9(packet) = &replay.packets[0] else {
        panic!("expected v9 packet")
    };
    let data = packet
        .flowsets
        .iter()
        .filter_map(|flowset| match &flowset.body {
            v9::FlowSetBody::Data(data) => Some(data),
            _ => None,
        })
        .collect::<Vec<_>>();
    assert_eq!(data.len(), 1);
    assert_eq!(data[0].fields.len(), 1);
}

#[test]
fn pending_replay_drops_an_entry_that_can_never_fit_and_continues_fifo() {
    let mut v9_parser = NetflowParser::builder()
        .with_v9_pending_flows(PendingFlowsConfig::default())
        .with_v9_max_decoded_field_values_per_message(1)
        .build()
        .unwrap();

    for body in [&[1, 2][..], &[3][..]] {
        assert!(
            v9_parser
                .parse_bytes(&v9_message(&[v9_data(256, body)]))
                .is_ok()
        );
    }
    let replay = v9_parser.parse_bytes(&v9_message(&[v9_template(256, &[(1, 1)])]));
    assert!(replay.is_ok(), "{:?}", replay.error);
    let info = v9_parser.v9_cache_info();
    assert_eq!(info.pending_flow_count, 0);
    assert_eq!(info.metrics.pending_replay_failed, 1);
    assert_eq!(info.metrics.pending_replayed, 1);

    let NetflowPacket::V9(packet) = &replay.packets[0] else {
        panic!("expected v9 packet")
    };
    assert_eq!(
        packet
            .flowsets
            .iter()
            .filter(|flowset| matches!(flowset.body, v9::FlowSetBody::Data(_)))
            .count(),
        1
    );

    let mut ipfix_parser = NetflowParser::builder()
        .with_ipfix_pending_flows(PendingFlowsConfig::default())
        .with_ipfix_max_decoded_field_values_per_message(1)
        .build()
        .unwrap();

    for body in [&[1, 2][..], &[3][..]] {
        assert!(
            ipfix_parser
                .parse_bytes(&ipfix_message(&[ipfix_data(256, body)]))
                .is_ok()
        );
    }
    let replay = ipfix_parser.parse_bytes(&ipfix_message(&[ipfix_template(256, 1, 1)]));
    assert!(replay.is_ok(), "{:?}", replay.error);
    let info = ipfix_parser.ipfix_cache_info();
    assert_eq!(info.pending_flow_count, 0);
    assert_eq!(info.metrics.pending_replay_failed, 1);
    assert_eq!(info.metrics.pending_replayed, 1);

    let NetflowPacket::IPFix(packet) = &replay.packets[0] else {
        panic!("expected IPFIX packet")
    };
    assert_eq!(
        packet
            .flowsets
            .iter()
            .filter(|flowset| matches!(flowset.body, ipfix::FlowSetBody::Data(_)))
            .count(),
        1
    );
}

#[test]
fn ipfix_pending_replay_classifies_entries_before_framing_pressure() {
    let template = ipfix_template(256, 82, u16::MAX);

    let mut parser = NetflowParser::builder()
        .with_ipfix_pending_flows(PendingFlowsConfig::default())
        .build()
        .unwrap();

    // This valid variable-length record can fill a standalone IPFIX message,
    // but no message containing the Set that triggers replay has room for it.
    let mut permanently_too_large = Vec::with_capacity(65_515);
    permanently_too_large.push(255);
    permanently_too_large.extend_from_slice(&65_512u16.to_be_bytes());
    permanently_too_large.resize(65_515, b'x');
    assert!(
        parser
            .parse_bytes(&ipfix_message(&[ipfix_data(256, &permanently_too_large)]))
            .is_ok()
    );
    assert!(
        parser
            .parse_bytes(&ipfix_message(&[ipfix_data(256, &[1, b'y'])]))
            .is_ok()
    );

    let replay = parser.parse_bytes(&ipfix_message(std::slice::from_ref(&template)));
    assert!(replay.is_ok(), "{:?}", replay.error);
    let info = parser.ipfix_cache_info();
    assert_eq!(info.pending_flow_count, 0);
    assert_eq!(info.metrics.pending_replay_failed, 1);
    assert_eq!(info.metrics.pending_replayed, 1);

    let mut parser = NetflowParser::builder()
        .with_ipfix_pending_flows(PendingFlowsConfig::default())
        .build()
        .unwrap();

    // The first entry is malformed. The second is valid but cannot fit while
    // the current message is full, so only the valid suffix must be retained.
    for body in [&[5, b'x'][..], &[1, b'y'][..]] {
        assert!(
            parser
                .parse_bytes(&ipfix_message(&[ipfix_data(256, body)]))
                .is_ok()
        );
    }
    let full_message = ipfix_message(&[template.clone(), ipfix_data(4, &vec![0; 65_503])]);
    assert_eq!(full_message.len(), usize::from(u16::MAX));
    let blocked = parser.parse_bytes(&full_message);
    assert!(blocked.is_ok(), "{:?}", blocked.error);
    let info = parser.ipfix_cache_info();
    assert_eq!(info.pending_flow_count, 1);
    assert_eq!(info.metrics.pending_replay_failed, 1);
    assert_eq!(info.metrics.pending_replayed, 0);

    let replay = parser.parse_bytes(&ipfix_message(&[template]));
    assert!(replay.is_ok(), "{:?}", replay.error);
    let info = parser.ipfix_cache_info();
    assert_eq!(info.pending_flow_count, 0);
    assert_eq!(info.metrics.pending_replay_failed, 1);
    assert_eq!(info.metrics.pending_replayed, 1);
}

#[test]
fn ipfix_no_store_drops_entry_that_cannot_fit_with_template_trigger() {
    let mut parser = NetflowParser::builder()
        .with_ipfix_pending_flows(PendingFlowsConfig::default())
        .build()
        .unwrap();

    let body = ipfix_replay_boundary_body();
    assert!(
        parser
            .parse_bytes(&ipfix_message(&[ipfix_data(256, &body)]))
            .is_ok()
    );

    let replay = parser.parse_bytes(&ipfix_message(&[ipfix_template(256, 82, u16::MAX)]));
    assert!(replay.is_ok(), "{:?}", replay.error);
    let info = parser.ipfix_cache_info();
    assert_eq!(info.pending_flow_count, 0);
    assert_eq!(info.metrics.pending_replay_failed, 1);
    assert_eq!(info.metrics.pending_replayed, 0);
}

#[test]
fn ipfix_store_restoration_replays_at_twenty_byte_boundary() {
    let store = Arc::new(InMemoryTemplateStore::new());
    let mut parser = NetflowParser::builder()
        .with_template_store(store.clone())
        .with_ipfix_pending_flows(PendingFlowsConfig::default())
        .build()
        .unwrap();

    let body = ipfix_replay_boundary_body();
    assert!(
        parser
            .parse_bytes(&ipfix_message(&[ipfix_data(256, &body)]))
            .is_ok()
    );

    let mut writer = NetflowParser::builder()
        .with_template_store(store)
        .build()
        .unwrap();
    assert!(
        writer
            .parse_bytes(&ipfix_message(&[ipfix_template(256, 82, u16::MAX)]))
            .is_ok()
    );

    let replay = parser.parse_bytes(&ipfix_message(&[ipfix_data(256, &[])]));
    assert!(replay.is_ok(), "{:?}", replay.error);
    let info = parser.ipfix_cache_info();
    assert_eq!(info.pending_flow_count, 0);
    assert_eq!(info.metrics.pending_replay_failed, 0);
    assert_eq!(info.metrics.pending_replayed, 1);
}

#[test]
fn pending_replay_rejects_max_record_truncated_prefixes() {
    let mut v9_parser = NetflowParser::builder()
        .with_v9_pending_flows(PendingFlowsConfig::default())
        .with_v9_max_records_per_flowset(1)
        .build()
        .unwrap();
    assert!(
        v9_parser
            .parse_bytes(&v9_message(&[v9_data(256, &[1, 2])]))
            .is_ok()
    );
    let replay = v9_parser.parse_bytes(&v9_message(&[v9_template(256, &[(1, 1)])]));
    assert!(replay.is_ok(), "{:?}", replay.error);
    let info = v9_parser.v9_cache_info();
    assert_eq!(info.pending_flow_count, 0);
    assert_eq!(info.metrics.pending_replay_failed, 1);
    assert_eq!(info.metrics.pending_replayed, 0);

    let mut ipfix_parser = NetflowParser::builder()
        .with_ipfix_pending_flows(PendingFlowsConfig::default())
        .with_ipfix_max_records_per_flowset(1)
        .build()
        .unwrap();
    assert!(
        ipfix_parser
            .parse_bytes(&ipfix_message(&[ipfix_data(256, &[1, b'x', 1, b'y'])]))
            .is_ok()
    );
    let replay = ipfix_parser.parse_bytes(&ipfix_message(&[ipfix_template(256, 82, u16::MAX)]));
    assert!(replay.is_ok(), "{:?}", replay.error);
    let info = ipfix_parser.ipfix_cache_info();
    assert_eq!(info.pending_flow_count, 0);
    assert_eq!(info.metrics.pending_replay_failed, 1);
    assert_eq!(info.metrics.pending_replayed, 0);
}

#[test]
fn pending_replay_preserves_valid_fixed_and_variable_padding() {
    let mut v9_parser = NetflowParser::builder()
        .with_v9_pending_flows(PendingFlowsConfig::default())
        .build()
        .unwrap();
    assert!(
        v9_parser
            .parse_bytes(&v9_message(&[v9_data(256, &[1, 2, 3, 4, 0, 0])]))
            .is_ok()
    );
    let replay = v9_parser.parse_bytes(&v9_message(&[v9_template(256, &[(1, 4)])]));
    assert!(replay.is_ok(), "{:?}", replay.error);
    let NetflowPacket::V9(packet) = &replay.packets[0] else {
        panic!("expected v9 packet")
    };
    let data = packet
        .flowsets
        .iter()
        .find_map(|flowset| match &flowset.body {
            v9::FlowSetBody::Data(data) => Some(data),
            _ => None,
        })
        .expect("expected replayed v9 data");
    assert_eq!(data.fields.len(), 1);
    assert_eq!(data.padding, [0, 0]);

    let mut ipfix_parser = NetflowParser::builder()
        .with_ipfix_pending_flows(PendingFlowsConfig::default())
        .build()
        .unwrap();
    // One variable-length byte, one fixed byte, then legal short padding.
    assert!(
        ipfix_parser
            .parse_bytes(&ipfix_message(&[ipfix_data(256, &[1, b'x', 7, 0])]))
            .is_ok()
    );
    let replay = ipfix_parser.parse_bytes(&ipfix_message(&[ipfix_template_fields(
        256,
        &[(82, u16::MAX), (1, 1)],
    )]));
    assert!(replay.is_ok(), "{:?}", replay.error);
    let info = ipfix_parser.ipfix_cache_info();
    assert_eq!(info.pending_flow_count, 0);
    assert_eq!(info.metrics.pending_replay_failed, 0);
    assert_eq!(info.metrics.pending_replayed, 1);
    let NetflowPacket::IPFix(packet) = &replay.packets[0] else {
        panic!("expected IPFIX packet")
    };
    let data = packet
        .flowsets
        .iter()
        .filter_map(|flowset| match &flowset.body {
            ipfix::FlowSetBody::Data(data) => Some(data),
            _ => None,
        })
        .collect::<Vec<_>>();
    assert_eq!(data.len(), 1);
    for replayed in data {
        assert_eq!(replayed.fields.len(), 1);
        assert_eq!(replayed.fields[0].len(), 2);
        assert_eq!(replayed.padding, [0]);
    }
}

#[test]
fn pending_replay_rejects_every_incomplete_body_kind() {
    let mut v9_parser = NetflowParser::builder()
        .with_v9_pending_flows(PendingFlowsConfig::default())
        .build()
        .unwrap();
    assert!(
        v9_parser
            .parse_bytes(&v9_message(&[v9_data(300, &[1])]))
            .is_ok()
    );
    let replay = v9_parser.parse_bytes(&v9_message(&[v9_options_template(300)]));
    assert!(replay.is_ok(), "{:?}", replay.error);
    assert_eq!(v9_parser.v9_cache_info().metrics.pending_replay_failed, 1);

    for template in [
        ipfix_template(300, 1, 2),
        ipfix_options_template(300),
        v9_template(300, &[(1, 2)]),
        v9_options_template(300),
    ] {
        let mut parser = NetflowParser::builder()
            .with_ipfix_pending_flows(PendingFlowsConfig::default())
            .build()
            .unwrap();
        assert!(
            parser
                .parse_bytes(&ipfix_message(&[ipfix_data(300, &[1])]))
                .is_ok()
        );
        let replay = parser.parse_bytes(&ipfix_message(&[template]));
        assert!(replay.is_ok(), "{:?}", replay.error);
        let info = parser.ipfix_cache_info();
        assert_eq!(info.pending_flow_count, 0);
        assert_eq!(info.metrics.pending_replay_failed, 1);
        assert_eq!(info.metrics.pending_replayed, 0);
    }
}

#[test]
fn ipfix_pending_replay_continues_after_a_same_id_template_does_not_match() {
    let mut parser = NetflowParser::builder()
        .with_ipfix_pending_flows(PendingFlowsConfig::default())
        .build()
        .unwrap();

    assert!(
        parser
            .parse_bytes(&ipfix_message(&[ipfix_data(300, &[1, 2])]))
            .is_ok()
    );
    assert_eq!(parser.ipfix_cache_info().pending_flow_count, 1);

    // The first lookup candidate needs three bytes and cannot decode the
    // queued body. The later same-ID options template is the matching owner.
    let replay = parser.parse_bytes(&ipfix_message(&[
        ipfix_template(300, 1, 3),
        ipfix_options_template(300),
    ]));
    assert!(replay.is_ok(), "{:?}", replay.error);
    assert_eq!(parser.ipfix_cache_info().pending_flow_count, 0);
    assert_eq!(parser.ipfix_cache_info().metrics.pending_replayed, 1);

    let NetflowPacket::IPFix(packet) = &replay.packets[0] else {
        panic!("expected IPFIX packet")
    };
    assert!(
        packet
            .flowsets
            .iter()
            .any(|flowset| { matches!(flowset.body, ipfix::FlowSetBody::OptionsData(_)) })
    );
}

#[test]
fn v9_pending_replay_continues_after_a_same_id_template_does_not_match() {
    let mut parser = NetflowParser::builder()
        .with_v9_pending_flows(PendingFlowsConfig::default())
        .build()
        .unwrap();

    assert!(
        parser
            .parse_bytes(&v9_message(&[v9_data(300, &[1, 2])]))
            .is_ok()
    );
    assert_eq!(parser.v9_cache_info().pending_flow_count, 1);

    let replay = parser.parse_bytes(&v9_message(&[
        v9_template(300, &[(1, 3)]),
        v9_options_template(300),
    ]));
    assert!(replay.is_ok(), "{:?}", replay.error);
    assert_eq!(parser.v9_cache_info().pending_flow_count, 0);
    assert_eq!(parser.v9_cache_info().metrics.pending_replayed, 1);

    let NetflowPacket::V9(packet) = &replay.packets[0] else {
        panic!("expected v9 packet")
    };
    assert!(
        packet
            .flowsets
            .iter()
            .any(|flowset| matches!(flowset.body, v9::FlowSetBody::OptionsData(_)))
    );
}

#[test]
fn zero_output_limits_are_rejected() {
    assert!(
        NetflowParser::builder()
            .with_max_decoded_field_values_per_message(0)
            .build()
            .is_err()
    );
    assert!(
        NetflowParser::builder()
            .with_max_decoded_field_payload_bytes_per_message(0)
            .build()
            .is_err()
    );

    let mut config = Config::default();
    config.max_decoded_field_values_per_message = 0;
    assert_eq!(
        v9::V9Parser::try_new(config).unwrap_err(),
        ConfigError::InvalidDecodedFieldValueLimit(0)
    );

    let mut config = Config::default();
    config.max_decoded_field_payload_bytes_per_message = 0;
    assert_eq!(
        v9::V9Parser::try_new(config).unwrap_err(),
        ConfigError::InvalidDecodedFieldPayloadByteLimit(0)
    );

    let mut config = Config::default();
    config.max_decoded_field_values_per_message = 0;
    assert_eq!(
        ipfix::IPFixParser::try_new(config).unwrap_err(),
        ConfigError::InvalidDecodedFieldValueLimit(0)
    );

    let mut config = Config::default();
    config.max_decoded_field_payload_bytes_per_message = 0;
    assert_eq!(
        ipfix::IPFixParser::try_new(config).unwrap_err(),
        ConfigError::InvalidDecodedFieldPayloadByteLimit(0)
    );
}

#[test]
fn low_level_data_and_options_companions_apply_explicit_bounds() {
    let limits = DecodedOutputLimits::new(16, 1, 16).unwrap();

    let v9_template = v9::Template {
        template_id: 256,
        field_count: 1,
        fields: vec![v9::TemplateField {
            field_type_number: 1,
            field_type: V9Field::from(1),
            field_length: 1,
        }],
    };
    assert!(v9::Data::parse_with_limits(&[1], &v9_template, limits).is_ok());
    assert!(v9::Data::parse_with_limits(&[1, 2], &v9_template, limits).is_err());

    let v9_options = v9::OptionsTemplate {
        template_id: 300,
        options_scope_length: 4,
        options_length: 4,
        scope_fields: vec![v9::OptionsTemplateScopeField {
            field_type_number: 1,
            field_type: v9::lookup::ScopeFieldType::from(1),
            field_length: 1,
        }],
        option_fields: vec![v9::TemplateField {
            field_type_number: 1,
            field_type: V9Field::from(1),
            field_length: 1,
        }],
    };
    assert!(v9::OptionsData::parse_with_limits(&[1, 2], &v9_options, limits).is_err());

    let ipfix_data = ipfix::Template {
        template_id: 256,
        field_count: 1,
        fields: vec![ipfix::TemplateField {
            field_type_number: 1,
            field_length: 1,
            enterprise_number: None,
            field_type: IpfixField::new(1, None),
        }],
    };
    assert!(ipfix::Data::parse_with_limits(&[1, 2], &ipfix_data, limits).is_err());

    let ipfix_options = ipfix::OptionsTemplate {
        template_id: 300,
        field_count: 2,
        scope_field_count: 1,
        fields: vec![
            ipfix::TemplateField {
                field_type_number: 1,
                field_length: 1,
                enterprise_number: None,
                field_type: IpfixField::new(1, None),
            },
            ipfix::TemplateField {
                field_type_number: 2,
                field_length: 1,
                enterprise_number: None,
                field_type: IpfixField::new(2, None),
            },
        ],
    };
    assert!(ipfix::OptionsData::parse_with_limits(&[1, 2], &ipfix_options, limits).is_err());
}
