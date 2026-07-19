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
