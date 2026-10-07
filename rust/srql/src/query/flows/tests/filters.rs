use super::super::*;
use crate::parser::{Entity, Filter, FilterOp, FilterValue};
use chrono::Duration as ChronoDuration;
use chrono::{TimeZone, Utc};

#[test]
fn threat_matched_exists_against_live_cache() {
    let start = Utc.with_ymd_and_hms(2025, 1, 1, 0, 0, 0).unwrap();
    let end = start + ChronoDuration::hours(1);
    let plan = QueryPlan {
        entity: Entity::Flows,
        filters: vec![Filter {
            field: "threat_matched".into(),
            op: FilterOp::Eq,
            value: FilterValue::Scalar("true".to_string()),
        }],
        order: Vec::new(),
        limit: 100,
        offset: 0,
        time_range: Some(TimeRange { start, end }),
        stats: None,
        downsample: None,
        rollup_stats: None,
        other: false,
        include_deleted: false,
        exhaustive_window: false,
    };
    let (sql, _) = to_sql_and_params(&plan).expect("threat_matched sql");
    assert!(
        sql.contains("ip_threat_intel_cache"),
        "expected live-cache EXISTS, got {sql}"
    );
    assert!(
        sql.contains("src_endpoint_ip") && sql.contains("dst_endpoint_ip"),
        "expected either-endpoint match, got {sql}"
    );
}

#[test]
fn threat_indicator_excludes_expired_indicators() {
    let start = Utc.with_ymd_and_hms(2025, 1, 1, 0, 0, 0).unwrap();
    let end = start + ChronoDuration::hours(1);
    let plan = QueryPlan {
        entity: Entity::Flows,
        filters: vec![Filter {
            field: "threat_indicator".into(),
            op: FilterOp::Eq,
            value: FilterValue::Scalar("198.51.100.0/24".to_string()),
        }],
        order: Vec::new(),
        limit: 100,
        offset: 0,
        time_range: Some(TimeRange { start, end }),
        stats: None,
        downsample: None,
        rollup_stats: None,
        other: false,
        include_deleted: false,
        exhaustive_window: false,
    };
    let (sql, _) = to_sql_and_params(&plan).expect("threat_indicator sql");
    assert!(
        sql.contains("threat_intel_indicators"),
        "expected indicator join, got {sql}"
    );
    assert!(
        sql.contains("i.expires_at IS NULL OR i.expires_at > NOW()"),
        "expected active-indicator predicate, got {sql}"
    );
}

#[test]
fn unknown_filter_field_returns_error() {
    let start = Utc.with_ymd_and_hms(2025, 1, 1, 0, 0, 0).unwrap();
    let end = start + ChronoDuration::hours(1);
    let plan = QueryPlan {
        entity: Entity::Flows,
        filters: vec![Filter {
            field: "unknown_field".into(),
            op: FilterOp::Eq,
            value: FilterValue::Scalar("test".to_string()),
        }],
        order: Vec::new(),
        limit: 100,
        offset: 0,
        time_range: Some(TimeRange { start, end }),
        stats: None,
        downsample: None,
        rollup_stats: None,
        other: false,
        include_deleted: false,
        exhaustive_window: false,
    };

    let result = build_query(&plan);
    match result {
        Err(err) => {
            assert!(
                err.to_string().contains("unsupported filter field"),
                "error should mention unsupported filter field: {}",
                err
            );
        }
        Ok(_) => panic!("expected error for unknown filter field"),
    }
}

#[test]
fn builds_query_with_tag_filter() {
    let plan = QueryPlan {
        entity: Entity::Flows,
        filters: vec![Filter {
            field: "tag".into(),
            op: FilterOp::Eq,
            value: FilterValue::Scalar("site:austin".to_string()),
        }],
        order: Vec::new(),
        limit: 50,
        offset: 0,
        time_range: None,
        stats: None,
        downsample: None,
        rollup_stats: None,
        other: false,
        include_deleted: false,
        exhaustive_window: false,
    };

    let (sql, _params) = to_sql_and_params(&plan).expect("tag filter should translate");
    assert!(
        sql.contains("src_prefix_tags") && sql.contains("dst_prefix_tags"),
        "tag filter should match either side: {sql}"
    );
    assert!(
        sql.contains("@>") && sql.contains("site:austin"),
        "tag filter should use jsonb containment: {sql}"
    );
    assert!(
        sql.contains("COALESCE") && sql.contains("'[]'::jsonb"),
        "tag filter must COALESCE NULL columns so NOT tag keeps untagged rows: {sql}"
    );
}

#[test]
fn negative_tag_filter_coalesces_null_columns() {
    let plan = QueryPlan {
        entity: Entity::Flows,
        filters: vec![Filter {
            field: "tag".into(),
            op: FilterOp::NotEq,
            value: FilterValue::Scalar("ti:otx".to_string()),
        }],
        order: Vec::new(),
        limit: 50,
        offset: 0,
        time_range: None,
        stats: None,
        downsample: None,
        rollup_stats: None,
        other: false,
        include_deleted: false,
        exhaustive_window: false,
    };

    let (sql, _params) = to_sql_and_params(&plan).expect("negative tag filter should translate");
    assert!(
        sql.contains("COALESCE") && sql.contains("ti:otx"),
        "negative tag filter must COALESCE NULL so untagged rows match: {sql}"
    );
    // Diesel not() wraps the predicate; ensure containment is still present.
    assert!(sql.contains("@>"), "containment predicate missing: {sql}");
}

#[test]
fn builds_query_with_directional_tag_and_cidr() {
    let start = Utc.with_ymd_and_hms(2025, 1, 1, 0, 0, 0).unwrap();
    let end = start + ChronoDuration::hours(1);
    let plan = QueryPlan {
        entity: Entity::Flows,
        filters: vec![
            Filter {
                field: "dst_tag".into(),
                op: FilterOp::Eq,
                value: FilterValue::Scalar("role:guest-wifi".to_string()),
            },
            Filter {
                field: "src_cidr".into(),
                op: FilterOp::Eq,
                value: FilterValue::Scalar("10.0.0.0/8".to_string()),
            },
        ],
        order: Vec::new(),
        limit: 50,
        offset: 0,
        time_range: Some(TimeRange { start, end }),
        stats: None,
        downsample: None,
        rollup_stats: None,
        other: false,
        include_deleted: false,
        exhaustive_window: false,
    };

    let (sql, _params) = to_sql_and_params(&plan).expect("composed filters should translate");
    assert!(
        sql.contains("dst_prefix_tags") && sql.contains("role:guest-wifi"),
        "dst_tag predicate missing: {sql}"
    );
    assert!(
        sql.contains("10.0.0.0/8") || sql.contains("<<= "),
        "cidr predicate missing: {sql}"
    );
}

#[test]
fn builds_query_with_near_filter() {
    let plan = QueryPlan {
        entity: Entity::Flows,
        filters: vec![Filter {
            field: "near".into(),
            op: FilterOp::Eq,
            value: FilterValue::Scalar("30.2672,-97.7431,50km".to_string()),
        }],
        order: Vec::new(),
        limit: 50,
        offset: 0,
        time_range: None,
        stats: None,
        downsample: None,
        rollup_stats: None,
        other: false,
        include_deleted: false,
        exhaustive_window: false,
    };

    let (sql, _params) = to_sql_and_params(&plan).expect("near filter should translate");
    assert!(
        sql.contains("ST_DWithin") && sql.contains("ip_geo_enrichment_cache"),
        "near filter should use geo cache ST_DWithin: {sql}"
    );
    assert!(
        sql.contains("src_endpoint_ip") && sql.contains("dst_endpoint_ip"),
        "near should match either side: {sql}"
    );
}

#[test]
fn near_composes_with_tag_filter() {
    let plan = QueryPlan {
        entity: Entity::Flows,
        filters: vec![
            Filter {
                field: "tag".into(),
                op: FilterOp::Eq,
                value: FilterValue::Scalar("ti:otx".to_string()),
            },
            Filter {
                field: "near".into(),
                op: FilterOp::Eq,
                value: FilterValue::Scalar("30.27,-97.74,50km".to_string()),
            },
        ],
        order: Vec::new(),
        limit: 50,
        offset: 0,
        time_range: None,
        stats: None,
        downsample: None,
        rollup_stats: None,
        other: false,
        include_deleted: false,
        exhaustive_window: false,
    };

    let (sql, _params) = to_sql_and_params(&plan).expect("composed filters should translate");
    assert!(
        sql.contains("@>") && sql.contains("ti:otx"),
        "tag missing: {sql}"
    );
    assert!(sql.contains("ST_DWithin"), "near missing: {sql}");
}

#[test]
fn rejects_invalid_near_literal() {
    let plan = QueryPlan {
        entity: Entity::Flows,
        filters: vec![Filter {
            field: "near".into(),
            op: FilterOp::Eq,
            value: FilterValue::Scalar("not-a-point".to_string()),
        }],
        order: Vec::new(),
        limit: 10,
        offset: 0,
        time_range: None,
        stats: None,
        downsample: None,
        rollup_stats: None,
        other: false,
        include_deleted: false,
        exhaustive_window: false,
    };

    let err = to_sql_and_params(&plan).expect_err("invalid near should fail");
    assert!(err.to_string().contains("near"), "unexpected error: {err}");
}

#[test]
fn rejects_invalid_tag_literal() {
    let plan = QueryPlan {
        entity: Entity::Flows,
        filters: vec![Filter {
            field: "tag".into(),
            op: FilterOp::Eq,
            value: FilterValue::Scalar("bad tag;drop".to_string()),
        }],
        order: Vec::new(),
        limit: 10,
        offset: 0,
        time_range: None,
        stats: None,
        downsample: None,
        rollup_stats: None,
        other: false,
        include_deleted: false,
        exhaustive_window: false,
    };

    let err = to_sql_and_params(&plan).expect_err("invalid tag should fail");
    assert!(
        err.to_string().contains("invalid tag"),
        "unexpected error: {err}"
    );
}

#[test]
fn builds_query_with_ip_filter() {
    let plan = QueryPlan {
        entity: Entity::Flows,
        filters: vec![Filter {
            field: "src_ip".into(),
            op: FilterOp::Eq,
            value: FilterValue::Scalar("10.0.0.1".to_string()),
        }],
        order: Vec::new(),
        limit: 50,
        offset: 0,
        time_range: None,
        stats: None,
        downsample: None,
        rollup_stats: None,
        other: false,
        include_deleted: false,
        exhaustive_window: false,
    };

    let result = build_query(&plan);
    assert!(result.is_ok(), "should build query with IP filter");
}

#[test]
fn builds_query_with_port_filter() {
    let plan = QueryPlan {
        entity: Entity::Flows,
        filters: vec![Filter {
            field: "dst_port".into(),
            op: FilterOp::Eq,
            value: FilterValue::Scalar("443".to_string()),
        }],
        order: Vec::new(),
        limit: 50,
        offset: 0,
        time_range: None,
        stats: None,
        downsample: None,
        rollup_stats: None,
        other: false,
        include_deleted: false,
        exhaustive_window: false,
    };

    let result = build_query(&plan);
    assert!(result.is_ok(), "should build query with port filter");
}

#[test]
fn builds_query_with_bidirectional_port_filter() {
    let plan = QueryPlan {
        entity: Entity::AttributedFlows,
        filters: vec![Filter {
            field: "port".into(),
            op: FilterOp::Eq,
            value: FilterValue::Scalar("22".to_string()),
        }],
        order: Vec::new(),
        limit: 50,
        offset: 0,
        time_range: None,
        stats: None,
        downsample: None,
        rollup_stats: None,
        other: false,
        include_deleted: false,
        exhaustive_window: false,
    };

    let (sql, _params) = to_sql_and_params(&plan).expect("bidirectional port filter should build");
    assert!(
        sql.contains("src_endpoint_port") && sql.contains("dst_endpoint_port"),
        "expected either-side port match in SQL: {sql}"
    );
}

#[test]
fn builds_query_with_wildcard_port_filter() {
    let plan = QueryPlan {
        entity: Entity::Flows,
        filters: vec![Filter {
            field: "dst_port".into(),
            op: FilterOp::Like,
            value: FilterValue::Scalar("%443%".to_string()),
        }],
        order: Vec::new(),
        limit: 50,
        offset: 0,
        time_range: None,
        stats: None,
        downsample: None,
        rollup_stats: None,
        other: false,
        include_deleted: false,
        exhaustive_window: false,
    };

    let result = build_query(&plan);
    assert!(
        result.is_ok(),
        "should build query with wildcard port filter"
    );
}

#[test]
fn rejects_non_integer_port_with_eq() {
    let plan = QueryPlan {
        entity: Entity::Flows,
        filters: vec![Filter {
            field: "dst_port".into(),
            op: FilterOp::Eq,
            value: FilterValue::Scalar("abc".to_string()),
        }],
        order: Vec::new(),
        limit: 50,
        offset: 0,
        time_range: None,
        stats: None,
        downsample: None,
        rollup_stats: None,
        other: false,
        include_deleted: false,
        exhaustive_window: false,
    };

    let result = build_query(&plan);
    match result {
        Err(err) => assert!(
            err.to_string().contains("dst_port must be an integer"),
            "error should mention integer requirement: {}",
            err
        ),
        Ok(_) => panic!("expected error for non-integer port filter"),
    }
}

#[test]
fn wildcard_port_filter_binds_text_param() {
    let plan = QueryPlan {
        entity: Entity::Flows,
        filters: vec![Filter {
            field: "dst_port".into(),
            op: FilterOp::Like,
            value: FilterValue::Scalar("%443%".to_string()),
        }],
        order: Vec::new(),
        limit: 50,
        offset: 0,
        time_range: None,
        stats: None,
        downsample: None,
        rollup_stats: None,
        other: false,
        include_deleted: false,
        exhaustive_window: false,
    };

    let (_, params) = to_sql_and_params(&plan).expect("should build SQL for wildcard port");
    let has_wildcard = params.iter().any(|param| match param {
        BindParam::Text(value) => value == "%443%",
        _ => false,
    });
    assert!(has_wildcard, "expected wildcard port to bind text param");
}

#[test]
fn device_addr_matches_either_endpoint_or_the_sampler() {
    // `device_id:` resolves the same address set with correlated
    // ARRAY(SELECT ...) subqueries, and the planner cannot estimate selectivity
    // through those InitPlans -- it drops the endpoint indexes and filters the
    // whole time window. Binding the resolved addresses as values instead lets
    // it build a BitmapOr over the existing src/dst/sampler indexes.
    let plan = QueryPlan {
        entity: Entity::Flows,
        filters: vec![Filter {
            field: "device_addr".into(),
            op: FilterOp::In,
            value: FilterValue::List(vec![
                "192.168.10.1".to_string(),
                "198.51.100.17".to_string(),
            ]),
        }],
        order: Vec::new(),
        limit: 50,
        offset: 0,
        time_range: None,
        stats: None,
        downsample: None,
        rollup_stats: None,
        other: false,
        include_deleted: false,
        exhaustive_window: false,
    };

    let (sql, params) = to_sql_and_params(&plan).expect("device_addr should build SQL");

    assert!(sql.contains("src_endpoint_ip"), "missing src side: {sql}");
    assert!(sql.contains("dst_endpoint_ip"), "missing dst side: {sql}");
    assert!(
        sql.contains("sampler_address"),
        "sampler side is the whole point -- an exporting device's own flows are \
         matched by sampler_address, not by endpoint: {sql}"
    );

    // Three binds, one per side. A mismatch here shifts the LIMIT/OFFSET binds.
    let bound = params
        .iter()
        .filter(|param| matches!(param, BindParam::TextArray(_)))
        .count();
    assert_eq!(bound, 3, "expected one array bind per side, got {bound}");
}

#[test]
fn device_addr_rejects_an_empty_address_list() {
    // Must NOT behave like the bare `ip:` list filter, which drops an empty list
    // and thereby widens the query to every flow in the window. For a device
    // scope that would show one device another device's traffic, so this is
    // rejected outright rather than silently widened.
    let plan = QueryPlan {
        entity: Entity::Flows,
        filters: vec![Filter {
            field: "device_addr".into(),
            op: FilterOp::In,
            value: FilterValue::List(Vec::new()),
        }],
        order: Vec::new(),
        limit: 50,
        offset: 0,
        time_range: None,
        stats: None,
        downsample: None,
        rollup_stats: None,
        other: false,
        include_deleted: false,
        exhaustive_window: false,
    };

    let err = to_sql_and_params(&plan).expect_err("empty device_addr must be rejected");
    assert!(
        err.to_string().contains("at least one address"),
        "expected an explicit empty-scope error, got: {err}"
    );
}

// The request compiler owns backend selection; these filters are emitted by
// the flow detail link and the device flow facet/top-N controls.
#[test]
fn flow_detail_and_device_filters_compile_for_both_backends() {
    let cases = [
        ("proto", "6", "protocol_num"),
        ("src_ip", "192.0.2.10", "src_endpoint_ip"),
        ("dst_ip", "198.51.100.20", "dst_endpoint_ip"),
        ("src_port", "42000", "src_endpoint_port"),
        ("dst_port", "443", "dst_endpoint_port"),
        ("protocol_num", "6", "protocol_num"),
        ("src_endpoint_ip", "192.0.2.10", "src_endpoint_ip"),
        ("dst_endpoint_ip", "198.51.100.20", "dst_endpoint_ip"),
        ("dst_endpoint_port", "443", "dst_endpoint_port"),
        ("protocol_name", "TCP", "protocol_name"),
        ("protocol_group", "tcp", "protocol_num"),
        ("direction_label", "ingress", "direction_label"),
        ("dst_service_label", "https", "dst_service_label"),
        ("app", "https", "app"),
        ("sampler_address", "192.0.2.1", "sampler_address"),
        ("flow_source", "netflow", "flow_source"),
        ("collector", "netflow", "flow_source"),
        ("event_type", "network_activity", "event_type"),
        ("pid", "42", "pid"),
        ("container_id", "example-container", "container_id"),
        ("agent_id", "agent-example", "agent_id"),
        ("pod_name", "example-pod", "workload_identity"),
        ("pod_namespace", "example", "workload_identity"),
        ("pod_uid", "pod-example", "workload_identity"),
        ("container_name", "example-container", "workload_identity"),
        ("image", "example/image", "workload_identity"),
        ("runtime_source", "example-runtime", "workload_identity"),
        ("service_name", "example-service", "public_endpoint"),
        ("gateway_name", "example-gateway", "public_endpoint"),
        ("exposure_class", "public", "public_endpoint"),
        ("public_endpoint_namespace", "example", "public_endpoint"),
        ("route_name", "example-route", "public_endpoint"),
    ];
    for mode in [Some("starrocks"), Some("starrocks_raw"), None] {
        for (field, value, column) in cases {
            let response = compile_filter_request(&format!("{field}:\"{value}\""), mode);
            let predicate = response.sql.split_once(" WHERE ").expect("WHERE").1;
            assert!(predicate.contains(column), "{mode:?} {field}: {predicate}");
            if mode.is_some() {
                assert!(predicate.contains(&format!("'{value}'")), "{predicate}");
            } else if matches!(
                field,
                "proto" | "protocol_num" | "src_port" | "dst_port" | "dst_endpoint_port"
            ) {
                assert!(response.params.iter().any(|param| matches!(param, crate::query::BindParam::Int(n) if n.to_string() == value)), "{field}: {:?}", response.params);
            } else {
                assert!(response.params.iter().any(|param| matches!(param, crate::query::BindParam::Text(text) if text == value)), "{field}: {:?}", response.params);
            }
        }
        let details = compile_filter_request(
            "src_ip:192.0.2.10 dst_ip:198.51.100.20 src_port:42000 dst_port:443 proto:6",
            mode,
        );
        let predicate = details.sql.split(" WHERE ").nth(1).expect("WHERE");
        for column in [
            "src_endpoint_ip",
            "dst_endpoint_ip",
            "src_endpoint_port",
            "dst_endpoint_port",
            "protocol_num",
        ] {
            assert!(predicate.contains(column), "{mode:?}: {predicate}");
        }
    }
}

#[test]
fn flow_interface_and_process_aliases_compile_for_both_backends() {
    for mode in [Some("starrocks"), Some("starrocks_raw"), None] {
        for (field, canonical, value) in [
            ("in_if_index", "input_snmp", "7"),
            ("out_if_index", "output_snmp", "9"),
            ("status", "attribution_status", "attributed"),
            ("process_pid", "pid", "42"),
            ("process", "comm", "worker"),
            ("process_name", "comm", "worker"),
            ("redacted_cmdline", "cmdline", "worker"),
            ("namespace", "pod_namespace", "example"),
            ("image_ref", "image", "example/image"),
            ("uid", "device_id", "device-example"),
        ] {
            let alias = compile_filter_request(&format!("{field}:\"{value}\""), mode);
            let canonical = compile_filter_request(&format!("{canonical}:\"{value}\""), mode);
            assert_eq!(alias.sql, canonical.sql, "{mode:?} {field}");
            assert_eq!(
                serde_json::to_value(alias.params).unwrap(),
                serde_json::to_value(canonical.params).unwrap(),
                "{mode:?} {field}"
            );
        }
    }
}

#[test]
fn flow_endpoint_and_catalog_filters_compile_for_both_backends() {
    for mode in [Some("starrocks"), Some("starrocks_raw"), None] {
        for (filter, contract) in [
            ("ip:192.0.2.10", "src_endpoint_ip"),
            ("endpoint_ip:198.51.100.20", "dst_endpoint_ip"),
            ("port:443", "src_endpoint_port"),
            ("endpoint_port:443", "dst_endpoint_port"),
            ("cidr:192.0.2.0/24", "dst_endpoint_ip"),
            ("src_tag:site:example", "src_prefix_tags"),
            ("dst_tag:site:example", "dst_prefix_tags"),
            ("tag:site:example", "src_prefix_tags"),
            ("near:12.34,56.78,5km", "ST_DWithin"),
            ("src_near:12.34,56.78,5km", "ST_DWithin"),
            ("dst_near:12.34,56.78,5km", "ST_DWithin"),
            ("threat_matched:true", "ip_threat_intel_cache"),
            ("threat_matched:false", "ip_threat_intel_cache"),
            ("threat_source:example_feed", "ip_threat_intel_cache"),
            ("threat_observed_ip:192.0.2.10", "ip_threat_intel_cache"),
            (
                "threat_indicator:198.51.100.0/24",
                "threat_intel_indicators",
            ),
            ("threat_indicator:198.51.100.20", "threat_intel_indicators"),
            ("threat_severity:>3", "max_severity"),
        ] {
            let response = compile_filter_request(filter, mode);
            let predicate = response.sql.split_once(" WHERE ").expect("WHERE").1;
            let contract = if mode.is_some() && filter.starts_with("cidr:") {
                "dst_ip_hex"
            } else {
                contract
            };
            assert!(
                predicate.contains(contract),
                "{mode:?} {filter}: {predicate}"
            );
            if mode.is_some() && (filter.contains("near:") || filter.starts_with("threat_")) {
                assert!(
                    predicate.contains("cnpg_platform.native_query("),
                    "{predicate}"
                );
                assert!(predicate.contains("COALESCE("), "{predicate}");
            }
        }
    }
}

fn compile_filter_request(filters: &str, mode: Option<&str>) -> crate::query::TranslateResponse {
    let config = crate::config::AppConfig::embedded("postgres://unused/db".into());
    let request = serde_json::from_value(serde_json::json!({
        "query": format!("in:flows time:[2000-01-01T00:00:00Z,2000-01-02T00:00:00Z] {filters} sort:time:desc limit:5"),
        "mode": mode,
    })).expect("request");
    crate::query::translate_request(&config, request)
        .unwrap_or_else(|error| panic!("{mode:?} {filters}: {error}"))
}
