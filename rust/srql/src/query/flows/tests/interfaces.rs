use super::super::stats::to_sql_and_params_stats;
use super::super::*;
use crate::parser::{Entity, Filter, FilterOp, FilterValue};
use chrono::Duration as ChronoDuration;
use chrono::{TimeZone, Utc};

#[test]
fn translate_grouped_stats_exporter_name_includes_cache_table() {
    let start = Utc.with_ymd_and_hms(2025, 1, 1, 0, 0, 0).unwrap();
    let end = start + ChronoDuration::hours(1);

    let plan = QueryPlan {
        entity: Entity::Flows,
        filters: Vec::new(),
        order: Vec::new(),
        limit: 100,
        offset: 0,
        time_range: Some(TimeRange { start, end }),
        stats: Some(crate::parser::StatsSpec::from_raw(
            "count(*) as total_flows by exporter_name",
        )),
        downsample: None,
        rollup_stats: None,
        other: false,
        include_deleted: false,
    };

    let (sql, _params) = to_sql_and_params_stats(&plan).unwrap();
    assert!(
        sql.contains("netflow_exporter_cache"),
        "expected exporter cache in SQL, got: {sql}"
    );
}

#[test]
fn translate_grouped_stats_in_if_name_includes_cache_table() {
    let start = Utc.with_ymd_and_hms(2025, 1, 1, 0, 0, 0).unwrap();
    let end = start + ChronoDuration::hours(1);

    let plan = QueryPlan {
        entity: Entity::Flows,
        filters: Vec::new(),
        order: Vec::new(),
        limit: 100,
        offset: 0,
        time_range: Some(TimeRange { start, end }),
        stats: Some(crate::parser::StatsSpec::from_raw(
            "count(*) as total_flows by in_if_name",
        )),
        downsample: None,
        rollup_stats: None,
        other: false,
        include_deleted: false,
    };

    let (sql, _params) = to_sql_and_params_stats(&plan).unwrap();
    assert!(
        sql.contains("netflow_interface_cache"),
        "expected interface cache in SQL, got: {sql}"
    );
}

#[test]
fn translate_grouped_stats_can_scope_by_snmp_interface_indices() {
    let plan = QueryPlan {
        entity: Entity::Flows,
        filters: vec![Filter {
            field: "input_snmp".into(),
            op: FilterOp::Eq,
            value: FilterValue::Scalar("12".into()),
        }],
        order: vec![OrderClause {
            field: "bytes_total".into(),
            direction: OrderDirection::Desc,
        }],
        limit: 10,
        offset: 0,
        time_range: Some(TimeRange {
            start: Utc.with_ymd_and_hms(2026, 6, 6, 0, 0, 0).unwrap(),
            end: Utc.with_ymd_and_hms(2026, 6, 6, 1, 0, 0).unwrap(),
        }),
        stats: Some(crate::parser::StatsSpec::from_raw(
            "sum(bytes_total) as bytes_total by sampler_address,input_snmp,output_snmp",
        )),
        downsample: None,
        rollup_stats: None,
        other: false,
        include_deleted: false,
    };

    let (sql, params) = to_sql_and_params(&plan).unwrap();

    assert!(
        sql.contains("'{connection_info,input_snmp}'"),
        "expected input_snmp extraction in SQL: {sql}"
    );
    assert!(
        sql.contains("'{connection_info,output_snmp}'"),
        "expected output_snmp extraction in SQL: {sql}"
    );
    assert!(
        sql.contains("GREATEST(COALESCE(f.sampling_rate, 1), 1)"),
        "expected sampled byte weighting in SQL: {sql}"
    );
    assert_eq!(params.len(), 3);
}

#[test]
fn translate_device_id_filter_includes_exporter_and_alias_scope() {
    let plan = QueryPlan {
        entity: Entity::Flows,
        filters: vec![Filter {
            field: "device_id".into(),
            op: FilterOp::Eq,
            value: FilterValue::Scalar("sr:device-1".to_string()),
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

    let (sql, _params) = to_sql_and_params(&plan).expect("device filter should translate");
    assert!(
        sql.contains("netflow_exporter_cache"),
        "expected exporter scope in SQL: {sql}"
    );
    assert!(
        sql.contains("device_alias_states"),
        "expected alias scope in SQL: {sql}"
    );
    assert!(
        sql.contains("ocsf_devices"),
        "expected device IP scope in SQL: {sql}"
    );
}

#[test]
fn translate_stats_device_id_filter_includes_exporter_and_alias_scope() {
    let start = Utc.with_ymd_and_hms(2025, 1, 1, 0, 0, 0).unwrap();
    let end = start + ChronoDuration::hours(1);

    let plan = QueryPlan {
        entity: Entity::Flows,
        filters: vec![Filter {
            field: "device_id".into(),
            op: FilterOp::Eq,
            value: FilterValue::Scalar("sr:device-1".to_string()),
        }],
        order: Vec::new(),
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

    let (sql, _params) =
        to_sql_and_params_stats(&plan).expect("stats device filter should translate");
    assert!(
        sql.contains("netflow_exporter_cache"),
        "expected exporter scope in stats SQL: {sql}"
    );
    assert!(
        sql.contains("device_alias_states"),
        "expected alias scope in stats SQL: {sql}"
    );
    assert!(
        sql.contains("ocsf_devices"),
        "expected device IP scope in stats SQL: {sql}"
    );
}
