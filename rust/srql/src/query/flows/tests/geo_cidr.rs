use super::super::stats::to_sql_and_params_stats;
use super::super::*;
use crate::parser::{Entity, Filter, FilterOp, FilterValue};
use chrono::{TimeZone, Utc};

#[test]
fn country_iso2_filter_does_not_shift_limit_offset_binds() {
    let plan = QueryPlan {
        entity: Entity::Flows,
        filters: vec![Filter {
            field: "dst_country_iso2".into(),
            op: FilterOp::Eq,
            value: FilterValue::Scalar("US".to_string()),
        }],
        order: vec![OrderClause {
            field: "time".into(),
            direction: OrderDirection::Desc,
        }],
        limit: 5,
        offset: 0,
        time_range: Some(TimeRange {
            start: chrono::Utc::now() - chrono::Duration::hours(1),
            end: chrono::Utc::now(),
        }),
        stats: None,
        downsample: None,
        rollup_stats: None,
        other: false,
        include_deleted: false,
    };

    let (sql, params) = to_sql_and_params(&plan).expect("should translate country filter");
    // Ensure we still have limit/offset binds present and typed correctly.
    assert!(sql.contains("LIMIT $3"), "expected LIMIT bind placeholder");
    assert!(
        sql.contains("OFFSET $4"),
        "expected OFFSET bind placeholder"
    );
    assert_eq!(params.len(), 4, "expected start/end + limit/offset params");
    assert!(matches!(params[2], BindParam::Int(5)));
    assert!(matches!(params[3], BindParam::Int(0)));
}

#[test]
fn country_iso2_filter_ignores_expired_geo_cache_rows() {
    let plan = QueryPlan {
        entity: Entity::Flows,
        filters: vec![Filter {
            field: "src_country_iso2".into(),
            op: FilterOp::Eq,
            value: FilterValue::Scalar("US".to_string()),
        }],
        order: Vec::new(),
        limit: 5,
        offset: 0,
        time_range: None,
        stats: None,
        downsample: None,
        rollup_stats: None,
        other: false,
        include_deleted: false,
    };

    let (sql, _params) = to_sql_and_params(&plan).expect("should translate country filter");
    assert!(
        sql.contains("(g.expires_at IS NULL OR g.expires_at > now())"),
        "expected geo cache expiry predicate in SQL: {sql}"
    );
}

#[test]
fn country_iso2_stats_joins_ignore_expired_geo_cache_rows() {
    let plan = QueryPlan {
        entity: Entity::Flows,
        filters: Vec::new(),
        order: Vec::new(),
        limit: 100,
        offset: 0,
        time_range: Some(TimeRange {
            start: Utc.with_ymd_and_hms(2025, 1, 1, 0, 0, 0).unwrap(),
            end: Utc.with_ymd_and_hms(2025, 1, 1, 1, 0, 0).unwrap(),
        }),
        stats: Some(crate::parser::StatsSpec::from_raw(
            "sum(bytes_total) as bytes_total by src_country_iso2,dst_country_iso2",
        )),
        downsample: None,
        rollup_stats: None,
        other: false,
        include_deleted: false,
    };

    let (sql, _params) = to_sql_and_params_stats(&plan).expect("should translate country stats");
    assert!(
        sql.contains("(src_geo.expires_at IS NULL OR src_geo.expires_at > now())"),
        "expected source geo cache expiry predicate in SQL: {sql}"
    );
    assert!(
        sql.contains("(dst_geo.expires_at IS NULL OR dst_geo.expires_at > now())"),
        "expected destination geo cache expiry predicate in SQL: {sql}"
    );
}

#[test]
fn cidr_filter_does_not_shift_limit_offset_binds() {
    let plan = QueryPlan {
        entity: Entity::Flows,
        filters: vec![Filter {
            field: "src_cidr".into(),
            op: FilterOp::Eq,
            value: FilterValue::Scalar("192.168.0.0/16".to_string()),
        }],
        order: vec![OrderClause {
            field: "time".into(),
            direction: OrderDirection::Desc,
        }],
        limit: 5,
        offset: 0,
        time_range: Some(TimeRange {
            start: chrono::Utc::now() - chrono::Duration::hours(1),
            end: chrono::Utc::now(),
        }),
        stats: None,
        downsample: None,
        rollup_stats: None,
        other: false,
        include_deleted: false,
    };

    let (sql, params) = to_sql_and_params(&plan).expect("should translate cidr filter");
    assert!(sql.contains("LIMIT $3"), "expected LIMIT bind placeholder");
    assert!(
        sql.contains("OFFSET $4"),
        "expected OFFSET bind placeholder"
    );
    assert_eq!(params.len(), 4, "expected start/end + limit/offset params");
    assert!(matches!(params[2], BindParam::Int(5)));
    assert!(matches!(params[3], BindParam::Int(0)));
}

#[test]
fn translate_grouped_stats_conversation_group_by_uses_canonical_endpoints() {
    let start = Utc.with_ymd_and_hms(2025, 1, 1, 0, 0, 0).unwrap();
    let end = start + chrono::Duration::hours(1);

    let plan = QueryPlan {
        entity: Entity::Flows,
        filters: Vec::new(),
        order: vec![OrderClause {
            field: "bytes_total".into(),
            direction: OrderDirection::Desc,
        }],
        limit: 10,
        offset: 0,
        time_range: Some(TimeRange { start, end }),
        stats: Some(crate::parser::StatsSpec::from_raw(
            "sum(bytes_total) as bytes_total, sum(packets_total) as packets_total by conversation_a_ip, conversation_b_ip",
        )),
        downsample: None,
        rollup_stats: None,
        other: false,
        include_deleted: false,
    };

    let (sql, _params) = to_sql_and_params_stats(&plan).unwrap();
    assert!(
        sql.contains("FROM ocsf_network_activity f"),
        "canonical conversation grouping must use raw flows, got: {sql}"
    );
    assert!(
        sql.contains("'conversation_a_ip', group_value_0")
            && sql.contains("'conversation_b_ip', group_value_1"),
        "expected canonical conversation JSON keys, got: {sql}"
    );
    assert!(
        sql.contains("CASE WHEN COALESCE(NULLIF(src_endpoint_ip, ''), 'Unknown') <=")
            && sql.contains("ELSE COALESCE(NULLIF(dst_endpoint_ip, ''), 'Unknown') END"),
        "expected unordered endpoint expression, got: {sql}"
    );
    assert!(
        sql.contains("ORDER BY agg_value_0 DESC"),
        "expected sort by bytes_total aggregate, got: {sql}"
    );
}
