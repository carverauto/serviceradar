use netflow_parser::variable_versions::ipfix::FlowSetBody as IpfixFlowSetBody;
use netflow_parser::variable_versions::v9::lookup::V9Field;
use netflow_parser::variable_versions::v9::{
    Data, FlowSetBody as V9FlowSetBody, OptionsData, ScopeDataField,
};
use netflow_parser::{InMemoryTemplateStore, NetflowPacket, NetflowParser};
use std::sync::Arc;

const TEMPLATE_ID: u16 = 256;
const OPTIONS_TEMPLATE_ID: u16 = 257;

fn v9_packet(flowset_id: u16, body: &[u8], sequence: u32) -> Vec<u8> {
    let mut packet = Vec::with_capacity(24 + body.len());
    packet.extend_from_slice(&9u16.to_be_bytes());
    packet.extend_from_slice(&1u16.to_be_bytes());
    packet.extend_from_slice(&0u32.to_be_bytes());
    packet.extend_from_slice(&0u32.to_be_bytes());
    packet.extend_from_slice(&sequence.to_be_bytes());
    packet.extend_from_slice(&1u32.to_be_bytes());
    packet.extend_from_slice(&flowset_id.to_be_bytes());
    packet.extend_from_slice(&u16::try_from(4 + body.len()).unwrap().to_be_bytes());
    packet.extend_from_slice(body);
    packet
}

fn ipfix_message(set_id: u16, body: &[u8], sequence: u32) -> Vec<u8> {
    let mut message = Vec::with_capacity(20 + body.len());
    message.extend_from_slice(&10u16.to_be_bytes());
    message.extend_from_slice(&u16::try_from(20 + body.len()).unwrap().to_be_bytes());
    message.extend_from_slice(&0u32.to_be_bytes());
    message.extend_from_slice(&sequence.to_be_bytes());
    message.extend_from_slice(&1u32.to_be_bytes());
    message.extend_from_slice(&set_id.to_be_bytes());
    message.extend_from_slice(&u16::try_from(4 + body.len()).unwrap().to_be_bytes());
    message.extend_from_slice(body);
    message
}

fn repeated_template() -> Vec<u8> {
    let mut body = Vec::new();
    body.extend_from_slice(&TEMPLATE_ID.to_be_bytes());
    body.extend_from_slice(&2u16.to_be_bytes());
    for _ in 0..2 {
        body.extend_from_slice(&1u16.to_be_bytes());
        body.extend_from_slice(&4u16.to_be_bytes());
    }
    body
}

fn repeated_data() -> Vec<u8> {
    let mut body = Vec::new();
    body.extend_from_slice(&11u32.to_be_bytes());
    body.extend_from_slice(&22u32.to_be_bytes());
    body
}

fn repeated_options_template() -> Vec<u8> {
    let mut body = Vec::new();
    body.extend_from_slice(&OPTIONS_TEMPLATE_ID.to_be_bytes());
    body.extend_from_slice(&8u16.to_be_bytes());
    body.extend_from_slice(&8u16.to_be_bytes());
    for _ in 0..2 {
        body.extend_from_slice(&1u16.to_be_bytes());
        body.extend_from_slice(&4u16.to_be_bytes());
    }
    for _ in 0..2 {
        body.extend_from_slice(&42u16.to_be_bytes());
        body.extend_from_slice(&4u16.to_be_bytes());
    }
    body.extend_from_slice(&[0; 2]);
    body
}

fn repeated_options_data() -> Vec<u8> {
    let mut body = Vec::new();
    body.extend_from_slice(&[1, 2, 3, 4]);
    body.extend_from_slice(&[5, 6, 7, 8]);
    body.extend_from_slice(&33u32.to_be_bytes());
    body.extend_from_slice(&44u32.to_be_bytes());
    body
}

fn assert_repeated_data(data: &Data) {
    assert_eq!(data.fields.len(), 1);
    let record = &data.fields[0];
    assert_eq!(record.len(), 2);
    assert_eq!(record[0].0, V9Field::InBytes);
    assert_eq!(record[1].0, V9Field::InBytes);
    assert_eq!(u32::try_from(&record[0].1).unwrap(), 11);
    assert_eq!(u32::try_from(&record[1].1).unwrap(), 22);
}

fn assert_repeated_options_data(data: &OptionsData) {
    assert_eq!(data.fields.len(), 1);
    let record = &data.fields[0];
    assert_eq!(record.scope_fields.len(), 2);
    assert_eq!(
        record.scope_fields,
        [
            ScopeDataField::System(vec![1, 2, 3, 4]),
            ScopeDataField::System(vec![5, 6, 7, 8]),
        ]
    );
    assert_eq!(record.options_fields.len(), 2);
    assert_eq!(record.options_fields[0].0, V9Field::TotalFlowsExp);
    assert_eq!(record.options_fields[1].0, V9Field::TotalFlowsExp);
    assert_eq!(u32::try_from(&record.options_fields[0].1).unwrap(), 33);
    assert_eq!(u32::try_from(&record.options_fields[1].1).unwrap(), 44);
}

#[test]
fn netflow_v9_preserves_repeated_template_fields_in_wire_order() {
    let mut parser = NetflowParser::default();
    let template = parser.parse_bytes(&v9_packet(0, &repeated_template(), 1));
    assert!(template.error.is_none(), "{:?}", template.error);

    let data = parser.parse_bytes(&v9_packet(TEMPLATE_ID, &repeated_data(), 2));
    assert!(data.error.is_none(), "{:?}", data.error);
    let Some(NetflowPacket::V9(packet)) = data.packets.first() else {
        panic!("expected v9 packet");
    };
    let V9FlowSetBody::Data(data) = &packet.flowsets[0].body else {
        panic!("expected v9 data");
    };
    assert_repeated_data(data);
}

#[test]
fn netflow_v9_preserves_repeated_options_fields_in_wire_order() {
    let mut parser = NetflowParser::default();
    let template = parser.parse_bytes(&v9_packet(1, &repeated_options_template(), 1));
    assert!(template.error.is_none(), "{:?}", template.error);

    let data = parser.parse_bytes(&v9_packet(OPTIONS_TEMPLATE_ID, &repeated_options_data(), 2));
    assert!(data.error.is_none(), "{:?}", data.error);
    let Some(NetflowPacket::V9(packet)) = data.packets.first() else {
        panic!("expected v9 packet");
    };
    let V9FlowSetBody::OptionsData(data) = &packet.flowsets[0].body else {
        panic!("expected v9 options data");
    };
    assert_repeated_options_data(data);
}

#[test]
fn ipfix_preserves_repeated_fields_in_embedded_v9_templates() {
    let mut parser = NetflowParser::default();
    let template = parser.parse_bytes(&ipfix_message(0, &repeated_template(), 1));
    assert!(template.error.is_none(), "{:?}", template.error);

    let data = parser.parse_bytes(&ipfix_message(TEMPLATE_ID, &repeated_data(), 2));
    assert!(data.error.is_none(), "{:?}", data.error);
    let Some(NetflowPacket::IPFix(packet)) = data.packets.first() else {
        panic!("expected IPFIX message");
    };
    let IpfixFlowSetBody::V9Data(data) = &packet.flowsets[0].body else {
        panic!("expected embedded v9 data");
    };
    assert_repeated_data(data);
}

#[test]
fn ipfix_preserves_repeated_options_fields_in_embedded_v9_templates() {
    let mut parser = NetflowParser::default();
    let template = parser.parse_bytes(&ipfix_message(1, &repeated_options_template(), 1));
    assert!(template.error.is_none(), "{:?}", template.error);

    let data = parser.parse_bytes(&ipfix_message(
        OPTIONS_TEMPLATE_ID,
        &repeated_options_data(),
        2,
    ));
    assert!(data.error.is_none(), "{:?}", data.error);
    let Some(NetflowPacket::IPFix(packet)) = data.packets.first() else {
        panic!("expected IPFIX message");
    };
    let IpfixFlowSetBody::V9OptionsData(data) = &packet.flowsets[0].body else {
        panic!("expected embedded v9 options data");
    };
    assert_repeated_options_data(data);
}

#[test]
fn template_store_preserves_repeated_v9_fields() {
    let store = Arc::new(InMemoryTemplateStore::new());
    {
        let mut writer = NetflowParser::builder()
            .with_template_store(store.clone())
            .build()
            .unwrap();
        let result = writer.parse_bytes(&v9_packet(0, &repeated_template(), 1));
        assert!(result.error.is_none(), "{:?}", result.error);
    }

    let mut reader = NetflowParser::builder()
        .with_template_store(store)
        .build()
        .unwrap();
    let result = reader.parse_bytes(&v9_packet(TEMPLATE_ID, &repeated_data(), 2));
    assert!(result.error.is_none(), "{:?}", result.error);
    let Some(NetflowPacket::V9(packet)) = result.packets.first() else {
        panic!("expected v9 packet");
    };
    let V9FlowSetBody::Data(data) = &packet.flowsets[0].body else {
        panic!("expected v9 data");
    };
    assert_repeated_data(data);
}

#[test]
fn template_store_preserves_repeated_v9_options_fields() {
    let store = Arc::new(InMemoryTemplateStore::new());
    {
        let mut writer = NetflowParser::builder()
            .with_template_store(store.clone())
            .build()
            .unwrap();
        let result = writer.parse_bytes(&v9_packet(1, &repeated_options_template(), 1));
        assert!(result.error.is_none(), "{:?}", result.error);
    }

    let mut reader = NetflowParser::builder()
        .with_template_store(store)
        .build()
        .unwrap();
    let result =
        reader.parse_bytes(&v9_packet(OPTIONS_TEMPLATE_ID, &repeated_options_data(), 2));
    assert!(result.error.is_none(), "{:?}", result.error);
    let Some(NetflowPacket::V9(packet)) = result.packets.first() else {
        panic!("expected v9 packet");
    };
    let V9FlowSetBody::OptionsData(data) = &packet.flowsets[0].body else {
        panic!("expected v9 options data");
    };
    assert_repeated_options_data(data);
}
