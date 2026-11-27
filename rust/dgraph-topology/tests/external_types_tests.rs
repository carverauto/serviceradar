use dgraph_topology::{
    ExternalEdgeKind, ExternalEdgeWrite, ExternalNodeKind, ExternalNodeWrite,
    ExternalSnapshotWrite, clamp_max_hops, clamp_query_limit,
};

fn sample_node(id: &str, kind: ExternalNodeKind) -> ExternalNodeWrite {
    ExternalNodeWrite {
        id: id.to_string(),
        kind,
        asn: Some(64_512),
        label: Some(format!("node-{id}")),
        region: Some("us-east".to_string()),
        ip: None,
        rpki_state: Some("valid".to_string()),
        rtbh_active: Some(false),
        max_length: None,
        irr_status: None,
        metro: None,
        iata: None,
        country_code: Some("US".to_string()),
        outage_state: Some("up".to_string()),
        port_speed_mbps: None,
        ingestor: None,
        last_seen: "2026-11-25T00:00:00Z".to_string(),
        expires_at: Some("2026-11-25T00:15:00Z".to_string()),
    }
}

fn sample_edge(src: &str, dst: &str, kind: ExternalEdgeKind, avg_rtt_us: i64) -> ExternalEdgeWrite {
    ExternalEdgeWrite {
        src_id: src.to_string(),
        dst_id: dst.to_string(),
        kind,
        border_asn: Some(64_513),
        as_boundary_confidence: Some(0.95),
        avg_rtt_us: Some(avg_rtt_us),
        loss_pct: Some(0.0),
        port_speed_mbps: None,
        if_name: None,
        if_index: None,
        egress_source: None,
        ingestor: None,
        last_seen: "2026-11-25T00:00:00Z".to_string(),
        ttl_secs: Some(900),
        expires_at: Some("2026-11-25T00:15:00Z".to_string()),
    }
}

#[test]
fn external_node_kinds_parse_and_format_canonically() {
    for (raw, expected) in [
        ("Vantage", "Vantage"),
        ("transit_router", "TransitRouter"),
        ("IXP", "IXP"),
        ("facility", "Facility"),
        ("ASN", "ASN"),
        ("prefix", "Prefix"),
        ("anycast_pop", "AnycastPop"),
        ("saas_target", "SaasTarget"),
    ] {
        let parsed = ExternalNodeKind::parse(raw).expect("valid kind");
        assert_eq!(parsed.as_str(), expected);
    }
    assert!(ExternalNodeKind::parse("unknown_kind").is_none());
}

#[test]
fn external_edge_kinds_never_use_canonical_topology() {
    for (raw, expected) in [
        ("traceroute_hop", "TRACEROUTE_HOP"),
        ("border_handoff", "BORDER_HANDOFF"),
        ("as_rel_provider", "AS_REL_PROVIDER"),
        ("as_rel_peer", "AS_REL_PEER"),
        ("ixp_member", "IXP_MEMBER"),
        ("anycast_serves", "ANYCAST_SERVES"),
        ("egresses_to", "EGRESSES_TO"),
    ] {
        let parsed = ExternalEdgeKind::parse(raw).expect("valid edge kind");
        assert_eq!(parsed.as_str(), expected);
        assert_ne!(parsed.as_str(), "CANONICAL_TOPOLOGY");
    }
    assert!(ExternalEdgeKind::parse("canonical_topology").is_none());
}

#[test]
fn external_edge_link_key_collapses_across_rounds() {
    let e1 = sample_edge(
        "transit:192.0.2.1",
        "transit:198.51.100.1",
        ExternalEdgeKind::TracerouteHop,
        12_000,
    );
    let e2 = sample_edge(
        "transit:192.0.2.1",
        "transit:198.51.100.1",
        ExternalEdgeKind::TracerouteHop,
        18_500,
    );
    assert_eq!(e1.link_key(), e2.link_key());
    assert_eq!(
        e1.link_key(),
        "TRACEROUTE_HOP|transit:192.0.2.1|transit:198.51.100.1||"
    );
}

#[test]
fn snapshot_deduped_collapses_duplicate_nodes_and_edges() {
    let snap = ExternalSnapshotWrite {
        generated_at: "2026-11-25T00:00:00Z".to_string(),
        ttl_secs: 900,
        nodes: vec![
            sample_node("asn:64512", ExternalNodeKind::Asn),
            sample_node("asn:64512", ExternalNodeKind::Asn),
            sample_node("203.0.113.0/24", ExternalNodeKind::Prefix),
            sample_node("2001:db8:1::/48", ExternalNodeKind::Prefix),
        ],
        edges: vec![
            sample_edge(
                "asn:64512",
                "asn:64513",
                ExternalEdgeKind::AsRelProvider,
                1_000,
            ),
            sample_edge(
                "asn:64512",
                "asn:64513",
                ExternalEdgeKind::AsRelProvider,
                2_000,
            ),
        ],
    };

    let deduped = snap.deduped();
    assert_eq!(deduped.nodes.len(), 3);
    assert_eq!(deduped.edges.len(), 1);
    assert_eq!(deduped.edges[0].avg_rtt_us, Some(2_000));
}

#[test]
fn query_bounds_are_strictly_clamped() {
    assert_eq!(clamp_max_hops(0), 4);
    assert_eq!(clamp_max_hops(3), 3);
    assert_eq!(clamp_max_hops(99), 8);

    assert_eq!(clamp_query_limit(0), 50);
    assert_eq!(clamp_query_limit(25), 25);
    assert_eq!(clamp_query_limit(10_000), 200);
}
