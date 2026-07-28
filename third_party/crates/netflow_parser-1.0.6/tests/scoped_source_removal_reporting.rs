use netflow_parser::{
    AutoScopedParser, AutoSourceKey, InMemoryTemplateStore, NetflowPacket, NetflowParser,
    RouterScopedParser, SourceRemovalCause, V9SourceKey,
};
use std::net::SocketAddr;
use std::sync::Arc;
use std::time::Duration;

const V5_PACKET: [u8; 72] = [
    0, 5, 0, 1, 3, 0, 4, 0, 5, 0, 6, 7, 8, 9, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 0, 1, 2, 3, 4, 5,
    6, 7, 8, 9, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 0, 1, 2, 3, 4, 5,
    6, 7, 8, 9, 0, 1, 2, 3, 4, 5, 6, 7,
];

fn v9_template_packet(source_id: u32, template_id: u16) -> Vec<u8> {
    let mut packet = Vec::new();
    packet.extend_from_slice(&9u16.to_be_bytes());
    packet.extend_from_slice(&1u16.to_be_bytes());
    packet.extend_from_slice(&0u32.to_be_bytes());
    packet.extend_from_slice(&0u32.to_be_bytes());
    packet.extend_from_slice(&0u32.to_be_bytes());
    packet.extend_from_slice(&source_id.to_be_bytes());
    packet.extend_from_slice(&0u16.to_be_bytes());
    packet.extend_from_slice(&12u16.to_be_bytes());
    packet.extend_from_slice(&template_id.to_be_bytes());
    packet.extend_from_slice(&1u16.to_be_bytes());
    packet.extend_from_slice(&1u16.to_be_bytes());
    packet.extend_from_slice(&4u16.to_be_bytes());
    packet
}

fn v9_data_packet(source_id: u32, template_id: u16, payload: &[u8]) -> Vec<u8> {
    let mut packet = Vec::new();
    packet.extend_from_slice(&9u16.to_be_bytes());
    packet.extend_from_slice(&1u16.to_be_bytes());
    packet.extend_from_slice(&0u32.to_be_bytes());
    packet.extend_from_slice(&0u32.to_be_bytes());
    packet.extend_from_slice(&0u32.to_be_bytes());
    packet.extend_from_slice(&source_id.to_be_bytes());
    packet.extend_from_slice(&template_id.to_be_bytes());
    packet.extend_from_slice(&((4 + payload.len()) as u16).to_be_bytes());
    packet.extend_from_slice(payload);
    packet
}

fn has_decoded_v9_data(packets: &[NetflowPacket]) -> bool {
    packets.iter().any(|packet| match packet {
        NetflowPacket::V9(v9) => v9.flowsets.iter().any(|flowset| {
            matches!(
                flowset.body,
                netflow_parser::variable_versions::v9::FlowSetBody::Data(_)
            )
        }),
        _ => false,
    })
}

fn empty_ipfix_packet(observation_domain_id: u32) -> Vec<u8> {
    let mut packet = Vec::new();
    packet.extend_from_slice(&10u16.to_be_bytes());
    packet.extend_from_slice(&16u16.to_be_bytes());
    packet.extend_from_slice(&0u32.to_be_bytes());
    packet.extend_from_slice(&0u32.to_be_bytes());
    packet.extend_from_slice(&observation_domain_id.to_be_bytes());
    packet
}

#[test]
fn router_parse_reports_exact_pressure_removal() {
    let mut parser = RouterScopedParser::<String>::new()
        .with_max_sources(1)
        .expect("valid limit");
    let _ = parser.parse_from_source("router-a".into(), &V5_PACKET);

    let mut removals = Vec::new();
    let result =
        parser.parse_from_source_with_reporter("router-b".into(), &V5_PACKET, &mut |removal| {
            removals.push(removal.clone());
            Ok(())
        });

    assert!(result.error.is_none());
    assert_eq!(removals.len(), 1);
    assert_eq!(removals[0].source, "router-a");
    assert_eq!(removals[0].cause, SourceRemovalCause::CapacityPressure);
    assert!(parser.get_parser(&"router-a".to_string()).is_none());
    assert!(parser.get_parser(&"router-b".to_string()).is_some());
    let metrics = parser.source_removal_metrics();
    assert_eq!(metrics.capacity_pressure, 1);
    assert_eq!(metrics.idle, 0);
    assert_eq!(metrics.capacity_reduced, 0);
}

#[test]
fn auto_iterator_reports_exact_v9_pressure_removal() {
    let mut parser = AutoScopedParser::new()
        .with_max_sources(1)
        .expect("valid limit");
    let source_a: SocketAddr = "192.0.2.1:2055".parse().unwrap();
    let source_b: SocketAddr = "192.0.2.2:2055".parse().unwrap();
    let packet_a = v9_template_packet(11, 256);
    let packet_b = v9_template_packet(22, 256);
    let _ = parser.parse_from_source(source_a, &packet_a);

    let mut removals = Vec::new();
    let iterator = parser
        .iter_packets_from_source_with_reporter(source_b, &packet_b, &mut |removal| {
            removals.push(removal.clone());
            Ok(())
        })
        .expect("iterator");
    let results: Vec<_> = iterator.collect();
    assert!(results.iter().all(Result::is_ok));

    assert_eq!(removals.len(), 1);
    assert_eq!(
        removals[0].source,
        AutoSourceKey::V9(V9SourceKey {
            addr: source_a,
            source_id: 11,
        })
    );
    assert_eq!(removals[0].cause, SourceRemovalCause::CapacityPressure);
    assert_eq!(parser.source_count(), 1);
}

#[test]
fn router_iterator_reports_exact_pressure_removal() {
    let mut parser = RouterScopedParser::<String>::new()
        .with_max_sources(1)
        .expect("valid limit");
    let _ = parser.parse_from_source("a".into(), &V5_PACKET);

    let mut removals = Vec::new();
    let iterator = parser
        .iter_packets_from_source_with_reporter("b".into(), &V5_PACKET, &mut |removal| {
            removals.push(removal.clone());
            Ok(())
        })
        .expect("iterator");
    assert_eq!(iterator.count(), 1);

    assert_eq!(removals.len(), 1);
    assert_eq!(removals[0].source, "a");
    assert_eq!(removals[0].cause, SourceRemovalCause::CapacityPressure);
}

#[test]
fn router_idle_prune_reports_every_removed_key() {
    let mut parser = RouterScopedParser::<String>::new();
    for source in ["a", "b", "c"] {
        let _ = parser.parse_from_source(source.to_string(), &V5_PACKET);
    }

    let mut removals = Vec::new();
    let count = parser.prune_idle_sources_with_reporter(Duration::ZERO, &mut |removal| {
        removals.push(removal.clone());
        Ok(())
    });

    assert_eq!(count, 3);
    assert_eq!(parser.source_count(), 0);
    assert_eq!(removals.len(), 3);
    assert!(
        removals
            .iter()
            .all(|removal| removal.cause == SourceRemovalCause::Idle)
    );
    let mut sources: Vec<_> = removals.into_iter().map(|removal| removal.source).collect();
    sources.sort();
    assert_eq!(sources, ["a", "b", "c"]);
    assert_eq!(parser.source_removal_metrics().idle, 3);
}

#[test]
fn auto_idle_prune_reports_all_source_key_variants() {
    let mut parser = AutoScopedParser::new()
        .with_max_sources(3)
        .expect("valid limit");
    let legacy_addr: SocketAddr = "192.0.2.10:2055".parse().unwrap();
    let v9_addr: SocketAddr = "192.0.2.11:2055".parse().unwrap();
    let ipfix_addr: SocketAddr = "192.0.2.12:2055".parse().unwrap();
    let _ = parser.parse_from_source(legacy_addr, &V5_PACKET);
    let _ = parser.parse_from_source(v9_addr, &v9_template_packet(7, 256));
    let _ = parser.parse_from_source(ipfix_addr, &empty_ipfix_packet(9));

    let mut removals = Vec::new();
    let count = parser.prune_idle_sources_with_reporter(Duration::ZERO, &mut |removal| {
        removals.push(removal.clone());
        Ok(())
    });

    assert_eq!(count, 3);
    assert!(removals.iter().any(|removal| {
        removal.source == AutoSourceKey::Legacy(legacy_addr)
            && removal.cause == SourceRemovalCause::Idle
    }));
    assert!(removals.iter().any(|removal| {
        removal.source
            == AutoSourceKey::V9(V9SourceKey {
                addr: v9_addr,
                source_id: 7,
            })
    }));
    assert!(removals.iter().any(|removal| {
        removal.source
            == AutoSourceKey::Ipfix(netflow_parser::IpfixSourceKey {
                addr: ipfix_addr,
                observation_domain_id: 9,
            })
    }));
}

#[test]
fn router_resize_reports_each_capacity_reduction() {
    let mut parser = RouterScopedParser::<String>::new()
        .with_max_sources(4)
        .expect("valid limit");
    for source in ["a", "b", "c", "d"] {
        let _ = parser.parse_from_source(source.to_string(), &V5_PACKET);
    }

    let mut removals = Vec::new();
    parser = parser
        .with_max_sources_and_reporter(2, &mut |removal| {
            removals.push(removal.clone());
            Ok(())
        })
        .expect("valid resize");

    assert_eq!(parser.source_count(), 2);
    assert_eq!(
        removals
            .iter()
            .map(|removal| removal.source.as_str())
            .collect::<Vec<_>>(),
        ["a", "b"]
    );
    assert!(
        removals
            .iter()
            .all(|removal| removal.cause == SourceRemovalCause::CapacityReduced)
    );
    assert_eq!(parser.source_removal_metrics().capacity_reduced, 2);
}

#[test]
fn auto_resize_reports_every_existing_per_cache_removal() {
    let mut parser = AutoScopedParser::new()
        .with_max_sources(3)
        .expect("valid limit");
    let sources: [SocketAddr; 3] = [
        "198.51.100.1:2055".parse().unwrap(),
        "198.51.100.2:2055".parse().unwrap(),
        "198.51.100.3:2055".parse().unwrap(),
    ];
    for (source_id, source) in sources.into_iter().enumerate() {
        let _ = parser.parse_from_source(source, &v9_template_packet(source_id as u32, 256));
    }

    let mut removals = Vec::new();
    parser = parser
        .with_max_sources_and_reporter(1, &mut |removal| {
            removals.push(removal.clone());
            Ok(())
        })
        .expect("valid resize");

    assert_eq!(parser.source_count(), 1);
    assert_eq!(removals.len(), 2);
    assert!(
        removals
            .iter()
            .all(|removal| removal.cause == SourceRemovalCause::CapacityReduced)
    );
    assert_eq!(parser.source_removal_metrics().capacity_reduced, 2);
}

#[test]
fn auto_resize_enforces_global_limit_across_protocol_caches() {
    let mut parser = AutoScopedParser::new()
        .with_max_sources(6)
        .expect("valid limit");

    for source in ["198.51.100.10:2055", "198.51.100.11:2055"] {
        let source: SocketAddr = source.parse().unwrap();
        let _ = parser.parse_from_source(source, &V5_PACKET);
    }
    for (source, source_id) in [("198.51.100.20:2055", 20), ("198.51.100.21:2055", 21)] {
        let source: SocketAddr = source.parse().unwrap();
        let _ = parser.parse_from_source(source, &v9_template_packet(source_id, 256));
    }
    for (source, observation_domain_id) in
        [("198.51.100.30:2055", 30), ("198.51.100.31:2055", 31)]
    {
        let source: SocketAddr = source.parse().unwrap();
        let _ = parser.parse_from_source(source, &empty_ipfix_packet(observation_domain_id));
    }
    assert_eq!(parser.source_count(), 6);

    let mut removals = Vec::new();
    parser = parser
        .with_max_sources_and_reporter(2, &mut |removal| {
            removals.push(removal.clone());
            Ok(())
        })
        .expect("valid resize");

    assert_eq!(parser.source_count(), 2);
    assert_eq!(removals.len(), 4);
    assert!(
        removals
            .iter()
            .all(|removal| removal.cause == SourceRemovalCause::CapacityReduced)
    );
    assert_eq!(parser.source_removal_metrics().capacity_reduced, 4);
}

#[test]
fn reporter_errors_and_panics_do_not_interrupt_pressure_replacement() {
    let mut parser = RouterScopedParser::<String>::new()
        .with_max_sources(1)
        .expect("valid limit");
    let _ = parser.parse_from_source("a".into(), &V5_PACKET);

    let result = parser.parse_from_source_with_reporter("b".into(), &V5_PACKET, &mut |_| {
        Err(std::io::Error::other("report failed").into())
    });
    assert!(result.error.is_none());
    assert!(parser.get_parser(&"b".to_string()).is_some());
    assert_eq!(parser.source_removal_metrics().reporter_failures, 1);

    let result = parser.parse_from_source_with_reporter("c".into(), &V5_PACKET, &mut |_| {
        panic!("reporter panic")
    });
    assert!(result.error.is_none());
    assert!(parser.get_parser(&"c".to_string()).is_some());
    assert_eq!(parser.source_removal_metrics().reporter_failures, 2);
}

#[test]
fn unscopable_auto_source_never_evicts_or_reports() {
    let mut parser = AutoScopedParser::new()
        .with_max_sources(1)
        .expect("valid limit");
    let valid_source: SocketAddr = "203.0.113.1:2055".parse().unwrap();
    let malformed_source: SocketAddr = "203.0.113.2:2055".parse().unwrap();
    let _ = parser.parse_from_source(valid_source, &V5_PACKET);

    let mut removals = Vec::new();
    let result =
        parser.parse_from_source_with_reporter(malformed_source, &[0, 9], &mut |removal| {
            removals.push(removal.clone());
            Ok(())
        });

    assert!(result.error.is_some());
    assert!(removals.is_empty());
    assert_eq!(parser.source_count(), 1);
    assert_eq!(parser.source_removal_metrics().capacity_pressure, 0);
}

#[test]
fn existing_source_does_not_report_or_increment_removal_metrics() {
    let mut parser = RouterScopedParser::<String>::new()
        .with_max_sources(1)
        .expect("valid limit");
    let source = "a".to_string();
    let _ = parser.parse_from_source(source.clone(), &V5_PACKET);

    let mut removals = Vec::new();
    let result = parser.parse_from_source_with_reporter(source, &V5_PACKET, &mut |removal| {
        removals.push(removal.clone());
        Ok(())
    });

    assert!(result.error.is_none());
    assert!(removals.is_empty());
    assert_eq!(parser.source_removal_metrics(), Default::default());
}

#[test]
fn auto_pressure_reports_global_lru_across_protocol_caches() {
    let mut parser = AutoScopedParser::new()
        .with_max_sources(2)
        .expect("valid limit");
    let legacy_addr: SocketAddr = "203.0.113.10:2055".parse().unwrap();
    let v9_addr: SocketAddr = "203.0.113.11:2055".parse().unwrap();
    let ipfix_addr: SocketAddr = "203.0.113.12:2055".parse().unwrap();
    let _ = parser.parse_from_source(legacy_addr, &V5_PACKET);
    let _ = parser.parse_from_source(v9_addr, &v9_template_packet(17, 256));
    let _ = parser.parse_from_source(legacy_addr, &V5_PACKET);

    let mut removals = Vec::new();
    let _ = parser.parse_from_source_with_reporter(
        ipfix_addr,
        &empty_ipfix_packet(19),
        &mut |removal| {
            removals.push(removal.clone());
            Ok(())
        },
    );

    assert_eq!(removals.len(), 1);
    assert_eq!(
        removals[0].source,
        AutoSourceKey::V9(V9SourceKey {
            addr: v9_addr,
            source_id: 17,
        })
    );
    assert_eq!(parser.source_count(), 2);
}

#[test]
fn auto_pressure_reports_exact_ipfix_and_legacy_sources() {
    let ipfix_addr: SocketAddr = "203.0.113.20:2055".parse().unwrap();
    let legacy_addr: SocketAddr = "203.0.113.21:2055".parse().unwrap();

    let mut parser = AutoScopedParser::new()
        .with_max_sources(1)
        .expect("valid limit");
    let _ = parser.parse_from_source(ipfix_addr, &empty_ipfix_packet(23));
    let mut removals = Vec::new();
    let _ = parser.parse_from_source_with_reporter(legacy_addr, &V5_PACKET, &mut |removal| {
        removals.push(removal.clone());
        Ok(())
    });
    assert_eq!(
        removals[0].source,
        AutoSourceKey::Ipfix(netflow_parser::IpfixSourceKey {
            addr: ipfix_addr,
            observation_domain_id: 23,
        })
    );
    assert_eq!(removals[0].cause, SourceRemovalCause::CapacityPressure);

    let mut parser = AutoScopedParser::new()
        .with_max_sources(1)
        .expect("valid limit");
    let _ = parser.parse_from_source(legacy_addr, &V5_PACKET);
    let mut removals = Vec::new();
    let _ = parser.parse_from_source_with_reporter(
        ipfix_addr,
        &empty_ipfix_packet(23),
        &mut |removal| {
            removals.push(removal.clone());
            Ok(())
        },
    );
    assert_eq!(removals[0].source, AutoSourceKey::Legacy(legacy_addr));
    assert_eq!(removals[0].cause, SourceRemovalCause::CapacityPressure);
}

#[test]
fn auto_existing_source_does_not_report_or_increment_removal_metrics() {
    let mut parser = AutoScopedParser::new()
        .with_max_sources(1)
        .expect("valid limit");
    let source: SocketAddr = "203.0.113.30:2055".parse().unwrap();
    let packet = v9_template_packet(31, 256);
    let _ = parser.parse_from_source(source, &packet);

    let mut removals = Vec::new();
    let result = parser.parse_from_source_with_reporter(source, &packet, &mut |removal| {
        removals.push(removal.clone());
        Ok(())
    });

    assert!(result.error.is_none());
    assert!(removals.is_empty());
    assert_eq!(parser.source_removal_metrics(), Default::default());
}

#[test]
fn auto_pressure_reporting_preserves_existing_store_cleanup() {
    let store = Arc::new(InMemoryTemplateStore::new());
    let builder = NetflowParser::builder().with_template_store(store.clone());
    let mut parser = AutoScopedParser::try_with_builder(builder)
        .expect("valid builder")
        .with_max_sources(1)
        .expect("valid limit");
    let source_a: SocketAddr = "10.0.0.1:2055".parse().unwrap();
    let source_b: SocketAddr = "10.0.0.2:2055".parse().unwrap();
    let _ = parser.parse_from_source(source_a, &v9_template_packet(1, 256));
    assert_eq!(store.len(), 1);

    let mut removals = Vec::new();
    let _ = parser.parse_from_source_with_reporter(
        source_b,
        &v9_template_packet(2, 256),
        &mut |removal| {
            removals.push(removal.clone());
            Ok(())
        },
    );

    assert_eq!(removals.len(), 1);
    assert_eq!(store.len(), 1, "pressure cleanup must remain unchanged");
}

#[test]
fn auto_idle_reporting_preserves_existing_store_entries() {
    let store = Arc::new(InMemoryTemplateStore::new());
    let builder = NetflowParser::builder().with_template_store(store.clone());
    let mut parser = AutoScopedParser::try_with_builder(builder).expect("valid builder");
    let source: SocketAddr = "10.0.0.3:2055".parse().unwrap();
    let _ = parser.parse_from_source(source, &v9_template_packet(3, 256));

    let mut removals = Vec::new();
    let count = parser.prune_idle_sources_with_reporter(Duration::ZERO, &mut |removal| {
        removals.push(removal.clone());
        Ok(())
    });

    assert_eq!(count, 1);
    assert_eq!(removals.len(), 1);
    assert_eq!(store.len(), 1, "idle removal must not add store cleanup");
}

#[test]
fn auto_resize_reporting_preserves_existing_store_entries() {
    let store = Arc::new(InMemoryTemplateStore::new());
    let builder = NetflowParser::builder().with_template_store(store.clone());
    let mut parser = AutoScopedParser::try_with_builder(builder)
        .expect("valid builder")
        .with_max_sources(3)
        .expect("valid limit");
    for source_id in 1..=3 {
        let source: SocketAddr = format!("10.0.1.{source_id}:2055").parse().unwrap();
        let _ = parser.parse_from_source(source, &v9_template_packet(source_id, 256));
    }
    assert_eq!(store.len(), 3);

    let mut removals = Vec::new();
    parser = parser
        .with_max_sources_and_reporter(1, &mut |removal| {
            removals.push(removal.clone());
            Ok(())
        })
        .expect("valid resize");

    assert_eq!(parser.source_count(), 1);
    assert_eq!(removals.len(), 2);
    assert_eq!(store.len(), 3, "resize must not add store cleanup");
}

#[test]
fn router_pressure_reporting_preserves_shared_store_entry() {
    let store = Arc::new(InMemoryTemplateStore::new());
    let builder = NetflowParser::builder().with_template_store(store.clone());
    let mut parser = RouterScopedParser::<String>::try_with_builder(builder)
        .expect("valid builder")
        .with_max_sources(2)
        .expect("valid limit");
    let _ = parser.parse_from_source("a".into(), &v9_template_packet(1, 256));
    let _ = parser.parse_from_source("b".into(), &v9_template_packet(2, 256));

    let mut removals = Vec::new();
    let _ = parser.parse_from_source_with_reporter("c".into(), &V5_PACKET, &mut |removal| {
        removals.push(removal.clone());
        Ok(())
    });
    assert_eq!(removals[0].source, "a");
    assert_eq!(store.len(), 1, "reporting must not add Router cleanup");

    let mut replica = NetflowParser::builder()
        .with_template_store(store)
        .build()
        .expect("valid replica");
    let result = replica.parse_bytes(&v9_data_packet(2, 256, &[0, 0, 0, 42]));
    assert!(has_decoded_v9_data(&result.packets));
}

#[test]
fn router_idle_reporting_preserves_shared_store_entry() {
    let store = Arc::new(InMemoryTemplateStore::new());
    let builder = NetflowParser::builder().with_template_store(store.clone());
    let mut parser =
        RouterScopedParser::<String>::try_with_builder(builder).expect("valid builder");
    let _ = parser.parse_from_source("a".into(), &v9_template_packet(1, 256));
    let _ = parser.parse_from_source("b".into(), &v9_template_packet(2, 256));

    let mut removals = Vec::new();
    let count = parser.prune_idle_sources_with_reporter(Duration::ZERO, &mut |removal| {
        removals.push(removal.clone());
        Ok(())
    });

    assert_eq!(count, 2);
    assert_eq!(removals.len(), 2);
    assert_eq!(store.len(), 1, "idle reporting must not add Router cleanup");
}

#[test]
fn router_resize_reporting_preserves_shared_store_entry() {
    let store = Arc::new(InMemoryTemplateStore::new());
    let builder = NetflowParser::builder().with_template_store(store.clone());
    let mut parser = RouterScopedParser::<String>::try_with_builder(builder)
        .expect("valid builder")
        .with_max_sources(3)
        .expect("valid limit");
    for source in ["a", "b", "c"] {
        let _ = parser.parse_from_source(source.into(), &v9_template_packet(1, 256));
    }

    let mut removals = Vec::new();
    parser = parser
        .with_max_sources_and_reporter(1, &mut |removal| {
            removals.push(removal.clone());
            Ok(())
        })
        .expect("valid resize");

    assert_eq!(parser.source_count(), 1);
    assert_eq!(removals.len(), 2);
    assert_eq!(
        store.len(),
        1,
        "resize reporting must not add Router cleanup"
    );
}

#[test]
fn explicit_removal_transfers_parser_without_reporting() {
    let store = Arc::new(InMemoryTemplateStore::new());
    let builder = NetflowParser::builder().with_template_store(store.clone());
    let mut parser =
        RouterScopedParser::<String>::try_with_builder(builder).expect("valid builder");
    let source = "a".to_string();
    let _ = parser.parse_from_source(source.clone(), &v9_template_packet(1, 256));

    let removed = parser.remove_source(&source);

    assert!(removed.is_some());
    assert_eq!(store.len(), 1);
    assert_eq!(parser.source_removal_metrics(), Default::default());
}
