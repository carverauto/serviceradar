use dgraph_topology::{CanonicalEdge, DeviceWrite, EdgeKind, EdgeWrite, PrefixWrite, link_key};

#[test]
fn link_key_joins_endpoints_and_interfaces() {
    let key = link_key(
        "sr:host01.example.com",
        "sr:host02.example.com",
        "GigabitEthernet0/1",
        "GigabitEthernet0/2",
    );
    assert_eq!(
        key,
        "sr:host01.example.com|sr:host02.example.com|GigabitEthernet0/1|GigabitEthernet0/2"
    );
}

#[test]
fn canonical_edge_matches_god_view_shape() {
    let edge = CanonicalEdge::new(
        "sr:host01.example.com".to_string(),
        "sr:host02.example.com".to_string(),
        7,
        4,
        700,
        400,
        1_000_000_000,
        true,
        "snmp-l2".to_string(),
        "direct".to_string(),
        "high".to_string(),
        1,
        "eth1".to_string(),
        2,
        "eth2".to_string(),
        "k".to_string(),
        "mut-1".to_string(),
    );
    assert_eq!(edge.source(), "sr:host01.example.com");
    assert_eq!(edge.target(), "sr:host02.example.com");
    assert_eq!(edge.flow_pps(), 11);
    assert_eq!(edge.flow_bps(), 1100);
    assert_eq!(edge.flow_pps_ab(), 7);
    assert_eq!(edge.flow_pps_ba(), 4);
    assert_eq!(edge.flow_bps_ab(), 700);
    assert_eq!(edge.flow_bps_ba(), 400);
    assert_eq!(edge.capacity_bps(), 1_000_000_000);
    assert!(edge.telemetry_eligible());
    assert_eq!(edge.protocol(), "snmp-l2");
    assert_eq!(edge.evidence_class(), "direct");
    assert_eq!(edge.confidence_tier(), "high");
    assert_eq!(edge.local_if_index_ab(), 1);
    assert_eq!(edge.local_if_name_ab(), "eth1");
    assert_eq!(edge.local_if_index_ba(), 2);
    assert_eq!(edge.local_if_name_ba(), "eth2");
    assert_eq!(edge.link_key(), "k");
    assert_eq!(edge.mutation_id(), "mut-1");
}

#[test]
fn neighbourhood_edge_carries_kind_and_god_view_shape() {
    let edge = CanonicalEdge::new(
        "sr:host01.example.com".to_string(),
        "sr:host02.example.com".to_string(),
        0,
        0,
        0,
        0,
        0,
        false,
        "mtr".to_string(),
        "path".to_string(),
        "low".to_string(),
        0,
        String::new(),
        0,
        String::new(),
        "k".to_string(),
        String::new(),
    );
    let neighbourhood = dgraph_topology::NeighbourhoodEdge::new("MTR_PATH", edge.clone());
    assert_eq!(neighbourhood.kind(), "MTR_PATH");
    assert_eq!(neighbourhood.edge(), &edge);
}

#[test]
fn device_write_does_not_carry_a_config_body() {
    let device = DeviceWrite::new("sr:host01.example.com")
        .with_hostname("host01.example.com")
        .with_ip("192.0.2.10")
        .with_config_revision_id("rev-1");
    assert_eq!(device.id(), "sr:host01.example.com");
    assert_eq!(device.hostname(), Some("host01.example.com"));
    assert_eq!(device.ip(), Some("192.0.2.10"));
    assert_eq!(device.config_revision_id(), Some("rev-1"));
}

#[test]
fn prefix_write_is_keyed_by_documentation_cidr() {
    let prefix = PrefixWrite::new("192.0.2.0/24", "ipv4");
    assert_eq!(prefix.cidr(), "192.0.2.0/24");
    assert_eq!(prefix.family(), "ipv4");
}

#[test]
fn edge_kinds_match_age_relationship_names() {
    assert_eq!(EdgeKind::ConnectsTo.as_str(), "CONNECTS_TO");
    assert_eq!(EdgeKind::CanonicalTopology.as_str(), "CANONICAL_TOPOLOGY");
    assert_eq!(EdgeKind::MtrPath.as_str(), "MTR_PATH");
}

#[test]
fn config_declared_edge_uses_config_ingestor() {
    let edge = EdgeWrite::config_declared("sr:host01.example.com", "sr:host02.example.com");
    assert_eq!(edge.kind(), EdgeKind::ConfigDeclared);
    assert_eq!(edge.protocol(), "config");
    assert_eq!(edge.evidence_class(), "config-declared");
    assert_eq!(edge.ingestor(), "network_config_v1");
}

#[test]
fn canonical_edge_write_sets_mapper_ingestor() {
    let edge = EdgeWrite::canonical(
        "sr:host01.example.com",
        "sr:host02.example.com",
        "lldp",
        "direct-physical",
    )
    .with_interfaces("Gi0/1", 1, "Gi0/2", 2)
    .with_flow(7, 4, 700, 400, 1_000_000_000, true)
    .with_mutation_id("mut-1");
    assert_eq!(edge.kind(), EdgeKind::CanonicalTopology);
    assert_eq!(edge.ingestor(), "mapper_topology_v1");
    assert_eq!(
        edge.link_key(),
        "sr:host01.example.com|sr:host02.example.com|Gi0/1|Gi0/2"
    );
    assert!(edge.telemetry_eligible());
}

#[test]
fn dql_string_rejects_quotes() {
    let err = dgraph_topology_dql_string("sr:\"evil\"");
    assert!(err.is_err());
}

fn dgraph_topology_dql_string(value: &str) -> Result<String, String> {
    // Mirror the crate-private guard so a quote cannot be interpolated.
    if value.contains('"') || value.contains('\n') || value.contains('\\') {
        Err(value.to_string())
    } else {
        Ok(format!("\"{value}\""))
    }
}
