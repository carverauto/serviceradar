use netflow_parser::variable_versions::v9::FlowSetBody;
use netflow_parser::{
    InMemoryTemplateStore, NetflowPacket, NetflowParser, TemplateKind, TemplateStore,
    TemplateStoreKey, TtlConfig,
};
use std::sync::Arc;
use std::thread;
use std::time::Duration;

const TEMPLATE_ID: u16 = 256;
const STORE_SCOPE: &str = "v9-template-owner";

fn v9_header(count: u16) -> Vec<u8> {
    let mut packet = Vec::with_capacity(20);
    packet.extend_from_slice(&9u16.to_be_bytes());
    packet.extend_from_slice(&count.to_be_bytes());
    packet.extend_from_slice(&0u32.to_be_bytes());
    packet.extend_from_slice(&0u32.to_be_bytes());
    packet.extend_from_slice(&0u32.to_be_bytes());
    packet.extend_from_slice(&42u32.to_be_bytes());
    packet
}

fn flowset(id: u16, body: &[u8]) -> Vec<u8> {
    let mut bytes = Vec::with_capacity(4 + body.len());
    bytes.extend_from_slice(&id.to_be_bytes());
    bytes.extend_from_slice(&u16::try_from(4 + body.len()).unwrap().to_be_bytes());
    bytes.extend_from_slice(body);
    bytes
}

fn data_template() -> Vec<u8> {
    let mut body = Vec::with_capacity(8);
    body.extend_from_slice(&TEMPLATE_ID.to_be_bytes());
    body.extend_from_slice(&1u16.to_be_bytes());
    body.extend_from_slice(&1u16.to_be_bytes());
    body.extend_from_slice(&4u16.to_be_bytes());
    flowset(0, &body)
}

fn options_template() -> Vec<u8> {
    let mut body = Vec::with_capacity(16);
    body.extend_from_slice(&TEMPLATE_ID.to_be_bytes());
    body.extend_from_slice(&4u16.to_be_bytes());
    body.extend_from_slice(&4u16.to_be_bytes());
    body.extend_from_slice(&1u16.to_be_bytes());
    body.extend_from_slice(&4u16.to_be_bytes());
    body.extend_from_slice(&2u16.to_be_bytes());
    body.extend_from_slice(&4u16.to_be_bytes());
    flowset(1, &body)
}

fn data_flowset() -> Vec<u8> {
    flowset(TEMPLATE_ID, &[0, 0, 0, 1, 0, 0, 0, 2])
}

fn packet(flowsets: &[&[u8]]) -> Vec<u8> {
    let mut packet = v9_header(u16::try_from(flowsets.len()).unwrap());
    for flowset in flowsets {
        packet.extend_from_slice(flowset);
    }
    packet
}

fn parsed_v9(
    result: &netflow_parser::ParseResult,
) -> &netflow_parser::variable_versions::v9::V9 {
    assert!(result.error.is_none(), "{:?}", result.error);
    assert_eq!(result.packets.len(), 1);
    let NetflowPacket::V9(packet) = &result.packets[0] else {
        panic!("expected NetFlow v9 packet");
    };
    packet
}

#[test]
fn last_template_kind_owns_the_id_in_wire_order() {
    for options_last in [true, false] {
        let ordinary = data_template();
        let options = options_template();
        let data = data_flowset();
        let definitions = if options_last {
            [&ordinary[..], &options[..], &data[..]]
        } else {
            [&options[..], &ordinary[..], &data[..]]
        };

        let mut parser = NetflowParser::default();
        let result = parser.parse_bytes(&packet(&definitions));
        let v9 = parsed_v9(&result);

        if options_last {
            assert!(matches!(v9.flowsets[2].body, FlowSetBody::OptionsData(_)));
        } else {
            assert!(matches!(v9.flowsets[2].body, FlowSetBody::Data(_)));
        }

        let cache = parser.v9_cache_info();
        assert_eq!(cache.current_size, 1);
        assert_eq!(cache.num_caches, 2);
        assert_eq!(cache.metrics.insertions, 2);
        assert_eq!(cache.metrics.collisions, 1);
        assert_eq!(cache.metrics.evictions, 0);
    }
}

#[test]
fn template_store_retains_only_the_last_kind() {
    for options_last in [true, false] {
        let store = Arc::new(InMemoryTemplateStore::new());
        let builder = NetflowParser::builder()
            .with_template_store(store.clone())
            .with_template_store_scope(STORE_SCOPE);
        let mut writer = builder.clone().build().unwrap();

        let ordinary = data_template();
        let options = options_template();
        let definitions = if options_last {
            [&ordinary[..], &options[..]]
        } else {
            [&options[..], &ordinary[..]]
        };
        let result = writer.parse_bytes(&packet(&definitions));
        parsed_v9(&result);

        let data_key = TemplateStoreKey::new(STORE_SCOPE, TemplateKind::V9Data, TEMPLATE_ID);
        let options_key =
            TemplateStoreKey::new(STORE_SCOPE, TemplateKind::V9Options, TEMPLATE_ID);
        assert_eq!(store.get(&data_key).unwrap().is_some(), !options_last);
        assert_eq!(store.get(&options_key).unwrap().is_some(), options_last);

        let mut reader = builder.build().unwrap();
        let data = data_flowset();
        let result = reader.parse_bytes(&packet(&[&data]));
        let v9 = parsed_v9(&result);
        if options_last {
            assert!(matches!(v9.flowsets[0].body, FlowSetBody::OptionsData(_)));
        } else {
            assert!(matches!(v9.flowsets[0].body, FlowSetBody::Data(_)));
        }
        assert_eq!(reader.v9_cache_info().current_size, 1);
    }
}

#[test]
fn expired_opposite_kind_is_not_counted_as_a_collision() {
    let mut parser = NetflowParser::builder()
        .with_v9_ttl(TtlConfig::new(Duration::from_millis(1)))
        .build()
        .unwrap();

    let ordinary = data_template();
    parsed_v9(&parser.parse_bytes(&packet(&[&ordinary])));
    thread::sleep(Duration::from_millis(5));

    let options = options_template();
    parsed_v9(&parser.parse_bytes(&packet(&[&options])));

    let cache = parser.v9_cache_info();
    assert_eq!(cache.current_size, 1);
    assert_eq!(cache.metrics.insertions, 2);
    assert_eq!(cache.metrics.expired, 1);
    assert_eq!(cache.metrics.collisions, 0);
    assert_eq!(cache.metrics.evictions, 0);
}
