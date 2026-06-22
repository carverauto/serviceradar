use super::super::*;
use crate::parser::{Entity, Filter, FilterOp, FilterValue};
use chrono::Duration as ChronoDuration;
use chrono::{TimeZone, Utc};

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
