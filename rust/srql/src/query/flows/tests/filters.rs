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
                "23.138.124.17".to_string(),
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
    };

    let err = to_sql_and_params(&plan).expect_err("empty device_addr must be rejected");
    assert!(
        err.to_string().contains("at least one address"),
        "expected an explicit empty-scope error, got: {err}"
    );
}
