use super::enforce_list_limit;
use super::stats::{LogsStatsSql, SqlBindValue};
use crate::{
    error::{Result, ServiceError},
    parser::{Filter, FilterOp},
    query::QueryPlan,
    time::TimeRange,
};

/// Build a rollup_stats query against the logs_severity_stats_5m CAGG.
/// Returns None if rollup_stats is not set in the plan.
pub(super) fn build_rollup_stats_query(plan: &QueryPlan) -> Result<Option<LogsStatsSql>> {
    let stat_type = match plan.rollup_stats.as_ref() {
        Some(st) if !st.trim().is_empty() => st.trim(),
        _ => return Ok(None),
    };

    match stat_type {
        "severity" => build_severity_rollup_stats(plan),
        other => Err(ServiceError::InvalidRequest(format!(
            "unsupported rollup_stats type for logs: '{other}' (supported: severity)"
        ))),
    }
}

/// Query the logs_severity_stats_5m CAGG for severity counts.
fn build_severity_rollup_stats(plan: &QueryPlan) -> Result<Option<LogsStatsSql>> {
    let mut binds = Vec::new();
    let mut clauses = Vec::new();

    // Apply time range filter on bucket column
    if let Some(TimeRange { start, end }) = &plan.time_range {
        clauses.push("bucket >= ?".to_string());
        binds.push(SqlBindValue::Timestamp(*start));
        clauses.push("bucket < ?".to_string());
        binds.push(SqlBindValue::Timestamp(*end));
    }

    // Apply service_name filter if present
    for filter in &plan.filters {
        match filter.field.as_str() {
            "service_name" | "service" => {
                if let Some((clause, mut values)) =
                    build_rollup_text_clause("service_name", filter)?
                {
                    clauses.push(clause);
                    binds.append(&mut values);
                }
            }
            other => {
                return Err(ServiceError::InvalidRequest(format!(
                    "rollup_stats:severity only supports service_name filter, got: '{other}'"
                )));
            }
        }
    }

    // Build SQL to sum counts from the CAGG and return as JSON payload
    let mut sql = String::from(
        r#"SELECT jsonb_build_object(
    'total', COALESCE(SUM(total_count), 0)::bigint,
    'fatal', COALESCE(SUM(fatal_count), 0)::bigint,
    'error', COALESCE(SUM(error_count), 0)::bigint,
    'warning', COALESCE(SUM(warning_count), 0)::bigint,
    'info', COALESCE(SUM(info_count), 0)::bigint,
    'debug', COALESCE(SUM(debug_count), 0)::bigint
) AS payload
FROM logs_severity_stats_5m"#,
    );

    if !clauses.is_empty() {
        sql.push_str("\nWHERE ");
        sql.push_str(&clauses.join(" AND "));
    }

    Ok(Some(LogsStatsSql { sql, binds }))
}

/// Build text filter clause for rollup_stats queries.
fn build_rollup_text_clause(
    column: &str,
    filter: &Filter,
) -> Result<Option<(String, Vec<SqlBindValue>)>> {
    let mut binds = Vec::new();
    let clause = match filter.op {
        FilterOp::Eq => {
            binds.push(SqlBindValue::Text(filter.value.as_scalar()?.to_string()));
            format!("{column} = ?")
        }
        FilterOp::NotEq => {
            binds.push(SqlBindValue::Text(filter.value.as_scalar()?.to_string()));
            format!("{column} <> ?")
        }
        FilterOp::Like => {
            binds.push(SqlBindValue::Text(filter.value.as_scalar()?.to_string()));
            format!("{column} ILIKE ?")
        }
        FilterOp::NotLike => {
            binds.push(SqlBindValue::Text(filter.value.as_scalar()?.to_string()));
            format!("{column} NOT ILIKE ?")
        }
        FilterOp::In | FilterOp::NotIn => {
            let values = filter.value.as_list()?.to_vec();
            if values.is_empty() {
                return Ok(None);
            }
            enforce_list_limit(&filter.field, values.len())?;
            let mut placeholders = Vec::new();
            for value in values {
                placeholders.push("?".to_string());
                binds.push(SqlBindValue::Text(value));
            }
            let operator = if matches!(filter.op, FilterOp::In) {
                "IN"
            } else {
                "NOT IN"
            };
            format!("{column} {operator} ({})", placeholders.join(", "))
        }
        _ => {
            return Err(ServiceError::InvalidRequest(format!(
                "rollup_stats filter {column} does not support operator {:?}",
                filter.op
            )));
        }
    };

    Ok(Some((clause, binds)))
}

#[cfg(test)]
mod tests {
    use super::build_rollup_stats_query;
    use crate::parser::{Entity, Filter, FilterOp, FilterValue};
    use crate::query::QueryPlan;
    use crate::time::TimeRange;
    use chrono::{Duration as ChronoDuration, TimeZone, Utc};

    #[test]
    fn rollup_stats_severity_builds_cagg_query() {
        let start = Utc.with_ymd_and_hms(2025, 1, 1, 0, 0, 0).unwrap();
        let end = start + ChronoDuration::hours(24);
        let plan = QueryPlan {
            entity: Entity::Logs,
            filters: Vec::new(),
            order: Vec::new(),
            limit: 100,
            offset: 0,
            time_range: Some(TimeRange { start, end }),
            stats: None,
            downsample: None,
            rollup_stats: Some("severity".to_string()),
            other: false,
            include_deleted: false,
        };

        let result = build_rollup_stats_query(&plan).expect("should build rollup_stats query");
        let sql = result.expect("severity rollup_stats should return SQL");

        let lower = sql.sql.to_lowercase();
        assert!(
            lower.contains("logs_severity_stats_5m"),
            "should query the CAGG: {}",
            sql.sql
        );
        assert!(
            lower.contains("sum(total_count)") && lower.contains("sum(fatal_count)"),
            "should sum counts: {}",
            sql.sql
        );
        assert!(
            lower.contains("jsonb_build_object"),
            "should return JSON payload: {}",
            sql.sql
        );
        assert_eq!(sql.binds.len(), 2, "should have time range binds");
    }

    #[test]
    fn rollup_stats_severity_with_service_filter() {
        let start = Utc.with_ymd_and_hms(2025, 1, 1, 0, 0, 0).unwrap();
        let end = start + ChronoDuration::hours(24);
        let plan = QueryPlan {
            entity: Entity::Logs,
            filters: vec![Filter {
                field: "service_name".into(),
                op: FilterOp::Eq,
                value: FilterValue::Scalar("core".to_string()),
            }],
            order: Vec::new(),
            limit: 100,
            offset: 0,
            time_range: Some(TimeRange { start, end }),
            stats: None,
            downsample: None,
            rollup_stats: Some("severity".to_string()),
            other: false,
            include_deleted: false,
        };

        let result = build_rollup_stats_query(&plan).expect("should build rollup_stats query");
        let sql = result.expect("severity rollup_stats should return SQL");

        let lower = sql.sql.to_lowercase();
        assert!(
            lower.contains("service_name = ?"),
            "should filter by service_name: {}",
            sql.sql
        );
        assert_eq!(sql.binds.len(), 3, "should have time range + service binds");
    }

    #[test]
    fn rollup_stats_unknown_type_returns_error() {
        let start = Utc.with_ymd_and_hms(2025, 1, 1, 0, 0, 0).unwrap();
        let end = start + ChronoDuration::hours(24);
        let plan = QueryPlan {
            entity: Entity::Logs,
            filters: Vec::new(),
            order: Vec::new(),
            limit: 100,
            offset: 0,
            time_range: Some(TimeRange { start, end }),
            stats: None,
            downsample: None,
            rollup_stats: Some("unknown".to_string()),
            other: false,
            include_deleted: false,
        };

        let result = build_rollup_stats_query(&plan);
        match result {
            Err(err) => {
                assert!(
                    err.to_string().contains("unsupported rollup_stats type"),
                    "error should mention unsupported type: {}",
                    err
                );
            }
            Ok(_) => panic!("expected error for unknown rollup_stats type"),
        }
    }
}
