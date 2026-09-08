use super::super::stats::to_sql_and_params_stats;
use super::super::*;
use crate::parser::{Entity, Filter, FilterOp, FilterValue};
use chrono::Duration as ChronoDuration;
use chrono::{TimeZone, Utc};

#[test]
fn multi_group_by_requires_time_window() {
    let plan = QueryPlan {
        entity: Entity::Flows,
        filters: Vec::new(),
        order: Vec::new(),
        limit: 100,
        offset: 0,
        time_range: None,
        stats: Some(crate::parser::StatsSpec::from_raw(
            "sum(bytes_total) as total_bytes by src_endpoint_ip, dst_endpoint_ip",
        )),
        downsample: None,
        rollup_stats: None,
        other: false,
        include_deleted: false,
    };

    let err = to_sql_and_params_stats(&plan).unwrap_err();
    assert!(
        err.to_string().contains("require an explicit time window"),
        "expected time window guardrail error, got: {err}"
    );
}

#[test]
fn translate_grouped_stats_uses_agg_value_for_order_and_includes_filters() {
    let start = Utc.with_ymd_and_hms(2025, 1, 1, 0, 0, 0).unwrap();
    let end = start + ChronoDuration::hours(1);

    let plan = QueryPlan {
        entity: Entity::Flows,
        filters: vec![
            Filter {
                field: "src_ip".into(),
                op: FilterOp::Eq,
                value: FilterValue::Scalar("10.0.0.1".to_string()),
            },
            Filter {
                field: "proto".into(),
                op: FilterOp::Eq,
                value: FilterValue::Scalar("6".to_string()),
            },
        ],
        order: vec![OrderClause {
            field: "total_bytes".into(),
            direction: OrderDirection::Desc,
        }],
        limit: 10,
        offset: 0,
        time_range: Some(TimeRange { start, end }),
        stats: Some(crate::parser::StatsSpec::from_raw(
            "sum(bytes_total) as total_bytes by src_endpoint_ip",
        )),
        downsample: None,
        rollup_stats: None,
        other: false,
        include_deleted: false,
    };

    let (sql, params) = to_sql_and_params_stats(&plan).unwrap();
    assert!(
        sql.contains("WHERE f.time >="),
        "should include time filter"
    );
    assert!(
        sql.contains("f.src_endpoint_ip = $3"),
        "should include src_endpoint_ip filter with binds"
    );
    assert!(
        sql.contains("f.protocol_num::bigint = $4"),
        "should include proto filter with binds"
    );
    assert!(
        sql.contains("ORDER BY agg_value_0 DESC"),
        "should order by first aggregate expression, not JSON alias"
    );
    assert_eq!(params.len(), 4, "expected time + 2 filter binds");
}

#[test]
fn other_rollup_rejects_non_additive_flow_aggregates() {
    let start = Utc.with_ymd_and_hms(2025, 1, 1, 0, 0, 0).unwrap();
    let end = start + ChronoDuration::hours(1);

    let plan = QueryPlan {
        entity: Entity::Flows,
        filters: Vec::new(),
        order: vec![OrderClause {
            field: "avg_bytes".into(),
            direction: OrderDirection::Desc,
        }],
        limit: 10,
        offset: 0,
        time_range: Some(TimeRange { start, end }),
        stats: Some(crate::parser::StatsSpec::from_raw(
            "avg(bytes_total) as avg_bytes by src_endpoint_ip",
        )),
        downsample: None,
        rollup_stats: None,
        other: true,
        include_deleted: false,
    };

    let err = to_sql_and_params_stats(&plan).unwrap_err();
    assert!(
        err.to_string().contains("sum(...) and count(...)"),
        "expected additive aggregate error, got: {err}"
    );
}

#[test]
fn other_rollup_rejects_ungrouped_flow_stats_after_parsing() {
    let start = Utc.with_ymd_and_hms(2025, 1, 1, 0, 0, 0).unwrap();
    let end = start + ChronoDuration::hours(1);

    let plan = QueryPlan {
        entity: Entity::Flows,
        filters: Vec::new(),
        order: vec![OrderClause {
            field: "total_bytes".into(),
            direction: OrderDirection::Desc,
        }],
        limit: 10,
        offset: 0,
        time_range: Some(TimeRange { start, end }),
        stats: Some(crate::parser::StatsSpec::from_raw(
            "sum(bytes_total) as total_bytes",
        )),
        downsample: None,
        rollup_stats: None,
        other: true,
        include_deleted: false,
    };

    let err = to_sql_and_params_stats(&plan).unwrap_err();
    assert!(
        err.to_string().contains("requires grouped flow stats"),
        "expected parsed grouped-stats error, got: {err}"
    );
}

#[test]
fn stats_device_addr_rejects_an_empty_address_list() {
    // Regression: `build_stats_text_filter` renders an empty `In` as `1=1`, so
    // delegating an empty address set here produced `(1=1 OR 1=1 OR 1=1)` --
    // every flow in the window. A device's stat cards would have totalled the
    // whole fleet's traffic, which is worse than showing nothing because it is
    // plausible. The row path rejects this for an unrelated reason (bind arity),
    // so only a stats-path test covers it.
    let start = Utc.with_ymd_and_hms(2025, 1, 1, 0, 0, 0).unwrap();
    let end = start + ChronoDuration::hours(1);

    let plan = QueryPlan {
        entity: Entity::Flows,
        filters: vec![Filter {
            field: "device_addr".into(),
            op: FilterOp::In,
            value: FilterValue::List(Vec::new()),
        }],
        order: Vec::new(),
        limit: 100,
        offset: 0,
        time_range: Some(TimeRange { start, end }),
        stats: Some(crate::parser::StatsSpec::from_raw(
            "sum(bytes_total) as total_bytes",
        )),
        downsample: None,
        rollup_stats: None,
        other: false,
        include_deleted: false,
    };

    let err = to_sql_and_params_stats(&plan).expect_err("empty device_addr must be rejected");
    assert!(
        err.to_string().contains("at least one address"),
        "expected an explicit empty-scope error, got: {err}"
    );
}

#[test]
fn stats_device_addr_matches_either_endpoint_or_the_sampler() {
    let start = Utc.with_ymd_and_hms(2025, 1, 1, 0, 0, 0).unwrap();
    let end = start + ChronoDuration::hours(1);

    let plan = QueryPlan {
        entity: Entity::Flows,
        filters: vec![Filter {
            field: "device_addr".into(),
            op: FilterOp::In,
            value: FilterValue::List(vec!["192.168.6.1".into(), "192.168.7.1".into()]),
        }],
        order: Vec::new(),
        limit: 100,
        offset: 0,
        time_range: Some(TimeRange { start, end }),
        stats: Some(crate::parser::StatsSpec::from_raw(
            "sum(bytes_total) as total_bytes",
        )),
        downsample: None,
        rollup_stats: None,
        other: false,
        include_deleted: false,
    };

    let (sql, _params) = to_sql_and_params_stats(&plan).expect("device_addr stats must translate");
    // The sampler arm is the point: once an exporter resolves to its device,
    // scoping on the endpoints alone drops every sampler-attributed flow, which
    // is exactly how a router's stat cards read zero.
    assert!(sql.contains("f.src_endpoint_ip"), "missing src arm: {sql}");
    assert!(sql.contains("f.dst_endpoint_ip"), "missing dst arm: {sql}");
    assert!(
        sql.contains("f.sampler_address"),
        "missing sampler arm: {sql}"
    );
}
