use super::super::stats::to_sql_and_params_stats;
use super::super::*;
use crate::parser::{Entity, Filter, FilterOp, FilterValue};
use chrono::{TimeZone, Utc};

#[test]
fn attributed_flows_translation_adds_event_type_and_attribution_filters() {
    let plan = QueryPlan {
        entity: Entity::AttributedFlows,
        filters: vec![
            Filter {
                field: "attribution_status".into(),
                op: FilterOp::Eq,
                value: FilterValue::Scalar("attributed".into()),
            },
            Filter {
                field: "process".into(),
                op: FilterOp::Like,
                value: FilterValue::Scalar("%redis%".into()),
            },
            Filter {
                field: "pod_namespace".into(),
                op: FilterOp::Eq,
                value: FilterValue::Scalar("demo".into()),
            },
        ],
        order: vec![OrderClause {
            field: "time".into(),
            direction: OrderDirection::Desc,
        }],
        limit: 50,
        offset: 0,
        time_range: Some(TimeRange {
            start: Utc.with_ymd_and_hms(2026, 6, 6, 0, 0, 0).unwrap(),
            end: Utc.with_ymd_and_hms(2026, 6, 7, 0, 0, 0).unwrap(),
        }),
        stats: None,
        downsample: None,
        rollup_stats: None,
        other: false,
        include_deleted: false,
    };

    let (sql, params) = to_sql_and_params(&plan).unwrap();

    assert!(sql.contains("ocsf_payload ->> 'event_type' = 'attributed_flow'"));
    assert!(sql.contains("ocsf_payload -> 'attribution' ->> 'pid'"));
    assert!(sql.contains("ocsf_payload -> 'attribution' ->> 'comm'"));
    assert!(sql.contains("ocsf_payload #>> '{attribution,workload_identity,pod_namespace}'"));
    assert_eq!(params.len(), 7);
}

#[test]
fn attributed_flows_can_filter_by_public_endpoint_owner() {
    let plan = QueryPlan {
        entity: Entity::AttributedFlows,
        filters: vec![
            Filter {
                field: "service_name".into(),
                op: FilterOp::Eq,
                value: FilterValue::Scalar("forgejo-ssh".into()),
            },
            Filter {
                field: "exposure_class".into(),
                op: FilterOp::Eq,
                value: FilterValue::Scalar("Gateway".into()),
            },
            Filter {
                field: "gateway_name".into(),
                op: FilterOp::Eq,
                value: FilterValue::Scalar("forgejo-gateway".into()),
            },
        ],
        order: vec![],
        limit: 20,
        offset: 0,
        time_range: Some(TimeRange {
            start: Utc.with_ymd_and_hms(2026, 8, 5, 0, 0, 0).unwrap(),
            end: Utc.with_ymd_and_hms(2026, 8, 6, 0, 0, 0).unwrap(),
        }),
        stats: None,
        downsample: None,
        rollup_stats: None,
        other: false,
        include_deleted: false,
    };

    let (sql, params) = to_sql_and_params(&plan).unwrap();

    assert!(sql.contains("ocsf_payload #>> '{attribution,public_endpoint,service_name}'"));
    assert!(sql.contains("ocsf_payload #>> '{attribution,public_endpoint,exposure_class}'"));
    assert!(sql.contains("ocsf_payload #>> '{attribution,public_endpoint,gateway_name}'"));
    // time range (2) + three text filters (3) + limit/offset (2)
    assert_eq!(params.len(), 7);
}

#[test]
fn attributed_flow_stats_stay_on_raw_table() {
    let plan = QueryPlan {
        entity: Entity::AttributedFlows,
        filters: vec![Filter {
            field: "attribution_status".into(),
            op: FilterOp::Eq,
            value: FilterValue::Scalar("unmatched".into()),
        }],
        order: vec![],
        limit: 1,
        offset: 0,
        time_range: Some(TimeRange {
            start: Utc.with_ymd_and_hms(2026, 6, 6, 0, 0, 0).unwrap(),
            end: Utc.with_ymd_and_hms(2026, 6, 7, 0, 0, 0).unwrap(),
        }),
        stats: Some(crate::parser::StatsSpec::from_raw("count(*) as total")),
        downsample: None,
        rollup_stats: None,
        other: false,
        include_deleted: false,
    };

    let (sql, params) = to_sql_and_params(&plan).unwrap();

    assert!(sql.contains("FROM ocsf_network_activity f"));
    assert!(!sql.contains("flow_traffic_1h"));
    assert!(sql.contains("f.ocsf_payload ->> 'event_type' = 'attributed_flow'"));
    assert_eq!(params.len(), 3);
}

#[test]
fn attributed_flow_stats_can_group_by_attribution_status() {
    let plan = QueryPlan {
        entity: Entity::AttributedFlows,
        filters: vec![],
        order: vec![OrderClause {
            field: "total".into(),
            direction: OrderDirection::Desc,
        }],
        limit: 10,
        offset: 0,
        time_range: Some(TimeRange {
            start: Utc.with_ymd_and_hms(2026, 6, 6, 0, 0, 0).unwrap(),
            end: Utc.with_ymd_and_hms(2026, 6, 7, 0, 0, 0).unwrap(),
        }),
        stats: Some(crate::parser::StatsSpec::from_raw(
            "count(*) as total, sum(bytes_total) as total_bytes by attribution_status",
        )),
        downsample: None,
        rollup_stats: None,
        other: false,
        include_deleted: false,
    };

    let (sql, params) = to_sql_and_params_stats(&plan).unwrap();

    assert!(sql.contains("'attribution_status', group_value_0"));
    assert!(sql.contains("f.ocsf_payload ->> 'event_type' = 'attributed_flow'"));
    assert!(sql.contains("CASE WHEN f.ocsf_payload -> 'attribution' ->> 'pid' IS NULL"));
    assert!(sql.contains("ORDER BY agg_value_0 DESC"));
    assert_eq!(params.len(), 2);
}
