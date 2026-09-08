use super::{stats::parse_stats_spec, to_sql_and_params};
use crate::{
    parser::{Entity, Filter, FilterOp, FilterValue, OrderClause, OrderDirection},
    query::{BindParam, QueryPlan},
    time::TimeRange,
};
use chrono::{Duration as ChronoDuration, TimeZone, Utc};

#[test]
fn stats_count_interfaces_emits_count_query() {
    let plan = stats_plan("count() as interface_count");
    let spec = parse_stats_spec(plan.stats.as_ref().map(|s| s.as_raw()))
        .expect("stats parse should succeed")
        .expect("stats expected");
    assert_eq!(spec.alias, "interface_count");

    let (sql, _) = to_sql_and_params(&plan).expect("stats SQL should be generated");
    assert!(
        sql.to_lowercase().contains("count("),
        "unexpected stats SQL: {}",
        sql
    );
}

#[test]
fn interfaces_query_includes_error_metric_joins() {
    let plan = QueryPlan {
        entity: Entity::Interfaces,
        filters: vec![Filter {
            field: "device_id".into(),
            value: FilterValue::Scalar("dev-1".into()),
            op: FilterOp::Eq,
        }],
        order: vec![OrderClause {
            field: "timestamp".into(),
            direction: OrderDirection::Desc,
        }],
        limit: 10,
        offset: 0,
        time_range: None,
        stats: None,
        downsample: None,
        rollup_stats: None,
        other: false,
        include_deleted: false,
    };

    let (sql, _) = to_sql_and_params(&plan).expect("interfaces SQL should be generated");
    let lower = sql.to_lowercase();
    assert!(
        lower.contains("timeseries_metrics"),
        "expected timeseries_metrics join, got: {sql}"
    );
    assert!(
        lower.contains("ifinerrors"),
        "expected ifInErrors join, got: {sql}"
    );
    assert!(
        lower.contains("ifouterrors"),
        "expected ifOutErrors join, got: {sql}"
    );
    assert!(
        lower.find(" limit ").expect("expected limit")
            < lower
                .find("left join lateral")
                .expect("expected metric lateral join"),
        "expected pagination before error metric joins, got: {sql}"
    );
    assert!(
        lower.contains("tm.device_id = paged.device_id"),
        "expected timeseries join on paged rows, got: {sql}"
    );
    assert!(
        lower.contains("order by di.timestamp desc, di.device_id asc, di.interface_uid asc"),
        "expected stable historical interface ordering, got: {sql}"
    );
    assert!(
        lower.contains(
            "order by paged.timestamp desc, paged.device_id asc, paged.interface_uid asc"
        ),
        "expected stable outer interface ordering after metric joins, got: {sql}"
    );
}

#[test]
fn historical_interfaces_default_order_is_stable() {
    let plan = base_plan_with_filter(Filter {
        field: "device_id".into(),
        value: FilterValue::Scalar("dev-1".into()),
        op: FilterOp::Eq,
    });

    let (sql, _) = to_sql_and_params(&plan).expect("interfaces SQL should be generated");
    let lower = sql.to_lowercase();
    assert!(
        lower.contains(
            "order by di.timestamp desc, di.created_at desc, di.device_id asc, di.interface_uid asc"
        ),
        "expected stable default historical interface ordering, got: {sql}"
    );
    assert!(
        lower.contains(
            "order by paged.timestamp desc, paged.created_at desc, paged.device_id asc, paged.interface_uid asc"
        ),
        "expected stable outer default historical interface ordering, got: {sql}"
    );
}

#[test]
fn latest_interfaces_query_defers_error_metric_joins_until_after_dedupe() {
    let plan = QueryPlan {
        entity: Entity::Interfaces,
        filters: vec![
            Filter {
                field: "device_id".into(),
                value: FilterValue::Scalar("dev-1".into()),
                op: FilterOp::Eq,
            },
            Filter {
                field: "latest".into(),
                value: FilterValue::Scalar("true".into()),
                op: FilterOp::Eq,
            },
        ],
        order: vec![OrderClause {
            field: "if_name".into(),
            direction: OrderDirection::Asc,
        }],
        limit: 10,
        offset: 0,
        time_range: None,
        stats: None,
        downsample: None,
        rollup_stats: None,
        other: false,
        include_deleted: false,
    };

    let (sql, _) = to_sql_and_params(&plan).expect("interfaces SQL should be generated");
    let lower = sql.to_lowercase();

    assert!(
        lower.contains("from (select * from (select distinct on"),
        "expected latest pagination subquery, got: {sql}"
    );
    assert!(
        lower.contains("ifs.device_id = di.device_id"),
        "expected interface settings join before latest dedupe, got: {sql}"
    );
    assert!(
        lower.find(" limit ").expect("expected limit")
            < lower
                .find("left join lateral")
                .expect("expected metric lateral join"),
        "expected pagination before latest error metric joins, got: {sql}"
    );
    assert!(
        lower.contains("tm.device_id = paged.device_id"),
        "expected timeseries join on paged latest rows, got: {sql}"
    );
    assert!(
        !lower.contains("tm.device_id = latest.device_id")
            && !lower.contains("tm.device_id = di.device_id"),
        "expected no pre-page timeseries join, got: {sql}"
    );
    assert!(
        lower.contains("order by latest.if_name asc limit"),
        "latest interfaces should keep the existing outer order shape, got: {sql}"
    );
}

#[test]
fn interfaces_mac_filter_normalizes_exact_match() {
    let plan = base_plan_with_filter(Filter {
        field: "mac".into(),
        value: FilterValue::Scalar("0E-EA-14-32-D2-78".into()),
        op: FilterOp::Eq,
    });

    let (sql, binds) = to_sql_and_params(&plan).expect("mac SQL should be generated");
    assert!(
        sql.contains("regexp_replace"),
        "expected mac normalization in SQL, got: {sql}"
    );

    match binds.as_slice().first() {
        Some(BindParam::Text(value)) => assert_eq!(value, "0eea1432d278"),
        other => panic!("unexpected binds: {other:?}"),
    }
}

#[test]
fn interfaces_mac_filter_preserves_wildcards() {
    let plan = base_plan_with_filter(Filter {
        field: "mac".into(),
        value: FilterValue::Scalar("%0e:ea:14:32:d2:78%".into()),
        op: FilterOp::Like,
    });

    let (sql, binds) = to_sql_and_params(&plan).expect("mac LIKE SQL should be generated");
    assert!(
        sql.to_lowercase().contains("like"),
        "expected LIKE clause for mac filter, got: {sql}"
    );

    match binds.as_slice().first() {
        Some(BindParam::Text(value)) => assert_eq!(value, "%0eea1432d278%"),
        other => panic!("unexpected binds: {other:?}"),
    }
}

fn stats_plan(stats: &str) -> QueryPlan {
    let start = Utc.with_ymd_and_hms(2025, 1, 1, 0, 0, 0).unwrap();
    let end = start + ChronoDuration::hours(1);
    QueryPlan {
        entity: Entity::Interfaces,
        filters: vec![Filter {
            field: "device_id".into(),
            value: FilterValue::Scalar("dev-1".into()),
            op: FilterOp::Eq,
        }],
        order: vec![OrderClause {
            field: "timestamp".into(),
            direction: OrderDirection::Desc,
        }],
        limit: 50,
        offset: 0,
        time_range: Some(TimeRange { start, end }),
        stats: Some(crate::parser::StatsSpec::from_raw(stats)),
        downsample: None,
        rollup_stats: None,
        other: false,
        include_deleted: false,
    }
}

fn base_plan_with_filter(filter: Filter) -> QueryPlan {
    QueryPlan {
        entity: Entity::Interfaces,
        filters: vec![filter],
        order: vec![],
        limit: 25,
        offset: 0,
        time_range: None,
        stats: None,
        downsample: None,
        rollup_stats: None,
        other: false,
        include_deleted: false,
    }
}
