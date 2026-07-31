use netflow_parser::variable_versions::ipfix::FlowSetBody;
use netflow_parser::{
    InMemoryTemplateStore, NetflowPacket, NetflowParser, TemplateKind, TemplateStore,
    TemplateStoreKey, TtlConfig,
};
use std::sync::Arc;
use std::thread;
use std::time::Duration;

const TEMPLATE_ID: u16 = 256;
const STORE_SCOPE: &str = "ipfix-template-owner";

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum DefinitionKind {
    IpfixData,
    IpfixOptions,
    V9Data,
    V9Options,
}

const DEFINITION_KINDS: [DefinitionKind; 4] = [
    DefinitionKind::IpfixData,
    DefinitionKind::IpfixOptions,
    DefinitionKind::V9Data,
    DefinitionKind::V9Options,
];

impl DefinitionKind {
    fn store_kind(self) -> TemplateKind {
        match self {
            Self::IpfixData => TemplateKind::IpfixData,
            Self::IpfixOptions => TemplateKind::IpfixOptions,
            Self::V9Data => TemplateKind::IpfixV9Data,
            Self::V9Options => TemplateKind::IpfixV9Options,
        }
    }
}

fn set(id: u16, body: &[u8]) -> Vec<u8> {
    let mut bytes = Vec::with_capacity(4 + body.len());
    bytes.extend_from_slice(&id.to_be_bytes());
    bytes.extend_from_slice(&u16::try_from(4 + body.len()).unwrap().to_be_bytes());
    bytes.extend_from_slice(body);
    bytes
}

fn data_template_body(template_id: u16) -> Vec<u8> {
    let mut body = Vec::with_capacity(12);
    body.extend_from_slice(&template_id.to_be_bytes());
    body.extend_from_slice(&2u16.to_be_bytes());
    body.extend_from_slice(&1u16.to_be_bytes());
    body.extend_from_slice(&4u16.to_be_bytes());
    body.extend_from_slice(&2u16.to_be_bytes());
    body.extend_from_slice(&4u16.to_be_bytes());
    body
}

fn ipfix_options_template_body(template_id: u16) -> Vec<u8> {
    let mut body = Vec::with_capacity(14);
    body.extend_from_slice(&template_id.to_be_bytes());
    body.extend_from_slice(&2u16.to_be_bytes());
    body.extend_from_slice(&1u16.to_be_bytes());
    body.extend_from_slice(&1u16.to_be_bytes());
    body.extend_from_slice(&4u16.to_be_bytes());
    body.extend_from_slice(&2u16.to_be_bytes());
    body.extend_from_slice(&4u16.to_be_bytes());
    body
}

fn v9_options_template_body(template_id: u16) -> Vec<u8> {
    let mut body = Vec::with_capacity(14);
    body.extend_from_slice(&template_id.to_be_bytes());
    body.extend_from_slice(&4u16.to_be_bytes());
    body.extend_from_slice(&4u16.to_be_bytes());
    body.extend_from_slice(&1u16.to_be_bytes());
    body.extend_from_slice(&4u16.to_be_bytes());
    body.extend_from_slice(&2u16.to_be_bytes());
    body.extend_from_slice(&4u16.to_be_bytes());
    body
}

fn definition(kind: DefinitionKind) -> Vec<u8> {
    definition_with_id(kind, TEMPLATE_ID)
}

fn definition_with_id(kind: DefinitionKind, template_id: u16) -> Vec<u8> {
    match kind {
        DefinitionKind::IpfixData => set(2, &data_template_body(template_id)),
        DefinitionKind::IpfixOptions => set(3, &ipfix_options_template_body(template_id)),
        DefinitionKind::V9Data => set(0, &data_template_body(template_id)),
        DefinitionKind::V9Options => set(1, &v9_options_template_body(template_id)),
    }
}

fn data_set() -> Vec<u8> {
    data_set_with_id(TEMPLATE_ID)
}

fn data_set_with_id(template_id: u16) -> Vec<u8> {
    set(template_id, &[0, 0, 0, 1, 0, 0, 0, 2])
}

fn withdrawal(kind: DefinitionKind, template_id: u16) -> Vec<u8> {
    let mut body = Vec::with_capacity(6);
    body.extend_from_slice(&template_id.to_be_bytes());
    body.extend_from_slice(&0u16.to_be_bytes());
    match kind {
        DefinitionKind::IpfixData | DefinitionKind::V9Data => set(2, &body),
        DefinitionKind::IpfixOptions | DefinitionKind::V9Options => {
            body.extend_from_slice(&0u16.to_be_bytes());
            set(3, &body)
        }
    }
}

fn message(sets: &[&[u8]]) -> Vec<u8> {
    let body_len = sets.iter().map(|set| set.len()).sum::<usize>();
    let mut bytes = Vec::with_capacity(16 + body_len);
    bytes.extend_from_slice(&10u16.to_be_bytes());
    bytes.extend_from_slice(&u16::try_from(16 + body_len).unwrap().to_be_bytes());
    bytes.extend_from_slice(&0u32.to_be_bytes());
    bytes.extend_from_slice(&0u32.to_be_bytes());
    bytes.extend_from_slice(&42u32.to_be_bytes());
    for set in sets {
        bytes.extend_from_slice(set);
    }
    bytes
}

fn parsed_ipfix(
    result: &netflow_parser::ParseResult,
) -> &netflow_parser::variable_versions::ipfix::Ipfix {
    assert!(result.error.is_none(), "{:?}", result.error);
    assert_eq!(result.packets.len(), 1);
    let NetflowPacket::IPFix(packet) = &result.packets[0] else {
        panic!("expected IPFIX message");
    };
    packet
}

fn assert_data_kind(body: &FlowSetBody, expected: DefinitionKind) {
    let matches = match expected {
        DefinitionKind::IpfixData => matches!(body, FlowSetBody::Data(_)),
        DefinitionKind::IpfixOptions => matches!(body, FlowSetBody::OptionsData(_)),
        DefinitionKind::V9Data => matches!(body, FlowSetBody::V9Data(_)),
        DefinitionKind::V9Options => matches!(body, FlowSetBody::V9OptionsData(_)),
    };
    assert!(matches, "expected {expected:?}, got {body:?}");
}

fn assert_no_template(result: &netflow_parser::ParseResult) {
    let packet = parsed_ipfix(result);
    assert!(
        matches!(packet.flowsets[0].body, FlowSetBody::NoTemplate(_)),
        "expected missing template, got {:?}",
        packet.flowsets[0].body
    );
}

#[test]
fn last_definition_owns_the_id_across_all_ipfix_template_kinds() {
    for first in DEFINITION_KINDS {
        for last in DEFINITION_KINDS {
            if first == last {
                continue;
            }

            let first_definition = definition(first);
            let last_definition = definition(last);
            let data = data_set();
            let mut parser = NetflowParser::default();
            let result =
                parser.parse_bytes(&message(&[&first_definition, &last_definition, &data]));
            let packet = parsed_ipfix(&result);
            assert_data_kind(&packet.flowsets[2].body, last);

            let cache = parser.ipfix_cache_info();
            assert_eq!(cache.current_size, 1, "{first:?} -> {last:?}");
            assert_eq!(cache.num_caches, 4);
            assert_eq!(cache.metrics.insertions, 2);
            assert_eq!(cache.metrics.collisions, 1, "{first:?} -> {last:?}");
            assert_eq!(cache.metrics.evictions, 0);
        }
    }
}

#[test]
fn template_store_retains_only_the_last_ipfix_template_kind() {
    for first in DEFINITION_KINDS {
        for last in DEFINITION_KINDS {
            if first == last {
                continue;
            }

            let store = Arc::new(InMemoryTemplateStore::new());
            let builder = NetflowParser::builder()
                .with_template_store(store.clone())
                .with_template_store_scope(STORE_SCOPE);
            let mut writer = builder.clone().build().unwrap();

            let first_definition = definition(first);
            let last_definition = definition(last);
            let result = writer.parse_bytes(&message(&[&first_definition, &last_definition]));
            parsed_ipfix(&result);

            for candidate in DEFINITION_KINDS {
                let key =
                    TemplateStoreKey::new(STORE_SCOPE, candidate.store_kind(), TEMPLATE_ID);
                assert_eq!(
                    store.get(&key).unwrap().is_some(),
                    candidate == last,
                    "{first:?} -> {last:?}: unexpected store state for {candidate:?}"
                );
            }

            let mut reader = builder.build().unwrap();
            let data = data_set();
            let result = reader.parse_bytes(&message(&[&data]));
            let packet = parsed_ipfix(&result);
            assert_data_kind(&packet.flowsets[0].body, last);
            assert_eq!(reader.ipfix_cache_info().current_size, 1);
        }
    }
}

#[test]
fn expired_opposite_ipfix_kind_is_not_counted_as_a_collision() {
    let mut parser = NetflowParser::builder()
        .with_ipfix_ttl(TtlConfig::new(Duration::from_millis(1)))
        .build()
        .unwrap();

    let first_definition = definition(DefinitionKind::IpfixData);
    parsed_ipfix(&parser.parse_bytes(&message(&[&first_definition])));
    thread::sleep(Duration::from_millis(5));

    let last_definition = definition(DefinitionKind::V9Options);
    parsed_ipfix(&parser.parse_bytes(&message(&[&last_definition])));

    let cache = parser.ipfix_cache_info();
    assert_eq!(cache.current_size, 1);
    assert_eq!(cache.metrics.insertions, 2);
    assert_eq!(cache.metrics.expired, 1);
    assert_eq!(cache.metrics.collisions, 0);
    assert_eq!(cache.metrics.evictions, 0);
}

#[test]
fn native_individual_withdrawal_removes_v9_style_owner() {
    for owner in [DefinitionKind::V9Data, DefinitionKind::V9Options] {
        let mut parser = NetflowParser::default();
        let template = definition(owner);
        parsed_ipfix(&parser.parse_bytes(&message(&[&template])));
        assert!(parser.has_ipfix_template(TEMPLATE_ID));

        let withdrawal = withdrawal(owner, TEMPLATE_ID);
        parsed_ipfix(&parser.parse_bytes(&message(&[&withdrawal])));
        assert!(!parser.has_ipfix_template(TEMPLATE_ID));

        let data = data_set();
        assert_no_template(&parser.parse_bytes(&message(&[&data])));
    }
}

#[test]
fn native_withdraw_all_removes_both_encodings_of_the_template_class() {
    for (withdrawn, survivor) in [
        (
            [DefinitionKind::IpfixData, DefinitionKind::V9Data],
            DefinitionKind::V9Options,
        ),
        (
            [DefinitionKind::IpfixOptions, DefinitionKind::V9Options],
            DefinitionKind::V9Data,
        ),
    ] {
        let store = Arc::new(InMemoryTemplateStore::new());
        let mut parser = NetflowParser::builder()
            .with_template_store(store.clone())
            .with_template_store_scope(STORE_SCOPE)
            .build()
            .unwrap();
        let definitions = [
            definition_with_id(withdrawn[0], 256),
            definition_with_id(withdrawn[1], 257),
            definition_with_id(survivor, 258),
        ];
        for definition in &definitions {
            parsed_ipfix(&parser.parse_bytes(&message(&[definition])));
        }
        assert_eq!(parser.ipfix_cache_info().current_size, 3);

        let withdraw_all_id = match withdrawn[0] {
            DefinitionKind::IpfixData => 2,
            DefinitionKind::IpfixOptions => 3,
            _ => unreachable!(),
        };
        let withdraw_all = withdrawal(withdrawn[0], withdraw_all_id);
        parsed_ipfix(&parser.parse_bytes(&message(&[&withdraw_all])));

        assert!(!parser.has_ipfix_template(256));
        assert!(!parser.has_ipfix_template(257));
        assert!(parser.has_ipfix_template(258));
        assert_eq!(parser.ipfix_cache_info().current_size, 1);

        for (kind, template_id) in [(withdrawn[0], 256), (withdrawn[1], 257)] {
            let key = TemplateStoreKey::new(STORE_SCOPE, kind.store_kind(), template_id);
            assert!(store.get(&key).unwrap().is_none());
            let data = data_set_with_id(template_id);
            assert_no_template(&parser.parse_bytes(&message(&[&data])));
        }
        let survivor_key = TemplateStoreKey::new(STORE_SCOPE, survivor.store_kind(), 258);
        assert!(store.get(&survivor_key).unwrap().is_some());
        let data = data_set_with_id(258);
        let result = parser.parse_bytes(&message(&[&data]));
        assert_data_kind(&parsed_ipfix(&result).flowsets[0].body, survivor);
    }
}
