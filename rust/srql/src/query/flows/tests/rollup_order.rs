use super::super::stats::to_sql_and_params_stats;
use super::super::*;
use crate::parser::Entity;
use chrono::Duration as ChronoDuration;
use chrono::{TimeZone, Utc};

#[test]
fn translate_grouped_stats_supports_sorting_by_secondary_aggregation_alias() {
    let start = Utc.with_ymd_and_hms(2025, 1, 1, 0, 0, 0).unwrap();
    let end = start + ChronoDuration::hours(1);

    let plan = QueryPlan {
        entity: Entity::Flows,
        filters: Vec::new(),
        order: vec![OrderClause {
            field: "packets_total".into(),
            direction: OrderDirection::Desc,
        }],
        limit: 10,
        offset: 0,
        time_range: Some(TimeRange { start, end }),
        stats: Some(crate::parser::StatsSpec::from_raw(
            "sum(bytes_total) as bytes_total, sum(packets_total) as packets_total by src_endpoint_ip",
        )),
        downsample: None,
        rollup_stats: None,
        other: false,
        include_deleted: false,
    };

    let (sql, _params) = to_sql_and_params_stats(&plan).unwrap();
    assert!(
        sql.contains("agg_value_0") && sql.contains("agg_value_1"),
        "expected SQL to include two aggregate columns, got: {sql}"
    );
    assert!(
        sql.contains("ORDER BY agg_value_1 DESC"),
        "expected order by packets_total alias mapped to agg_value_1, got: {sql}"
    );
}

#[test]
fn translate_grouped_stats_other_rollup_ranks_full_result_and_sums_tail() {
    let start = Utc.with_ymd_and_hms(2025, 1, 1, 0, 0, 0).unwrap();
    let end = start + ChronoDuration::hours(1);

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
            "sum(bytes_total) as bytes_total, sum(packets_total) as packets_total by src_endpoint_ip",
        )),
        downsample: None,
        rollup_stats: None,
        other: true,
        include_deleted: false,
    };

    let (sql, _params) = to_sql_and_params_stats(&plan).unwrap();

    assert!(
        sql.contains("WITH grouped AS"),
        "expected grouped CTE: {sql}"
    );
    assert!(
        sql.contains("ranked AS")
            && sql
                .contains("ROW_NUMBER() OVER (ORDER BY agg_value_0 DESC, group_value_0 ASC) AS rn"),
        "expected deterministic ranked CTE: {sql}"
    );
    assert!(
        sql.contains("WHERE rn <= 10"),
        "expected top-N filter: {sql}"
    );
    assert!(
        sql.contains("UNION ALL") && sql.contains("WHERE rn > 10"),
        "expected tail union: {sql}"
    );
    assert!(
        sql.contains("'src_endpoint_ip', NULL")
            && sql.contains("'bytes_total', COALESCE(SUM(agg_value_0), 0)")
            && sql.contains("'packets_total', COALESCE(SUM(agg_value_1), 0)")
            && sql.contains("'__other__', true"),
        "expected Other JSON payload: {sql}"
    );
    assert!(
        sql.contains("ORDER BY sort_rn"),
        "expected final sort to keep Other last: {sql}"
    );
}
