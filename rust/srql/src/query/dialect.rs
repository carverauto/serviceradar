//! Analytics-store SQL dialect (OpenSpec add-analytics-store-drivers, task 4).
//!
//! The NIF is stateless: the Elixir caller supplies a table → driver map.
//! Absent/empty ⇒ postgres, and generated SQL is unchanged.

use super::cold::cold_table_for_entity;
use super::{QueryPlan, SqlDialect};
use crate::{
    error::{Result, ServiceError},
    parser::Entity,
    time::TimeRange,
};
use std::collections::HashMap;

/// Resolve the SQL dialect for `entity` from a table-name driver map.
///
/// Keys are physical table names (`timeseries_metrics`, `ocsf_network_activity`).
/// Unknown entities and missing keys stay postgres.
pub fn resolve(entity: &Entity, drivers: &HashMap<String, String>) -> SqlDialect {
    let Some(table) = cold_table_for_entity(entity) else {
        return SqlDialect::Postgres;
    };
    match drivers.get(table).map(|s| s.as_str()) {
        Some("pg_duckdb") | Some("duckdb") => SqlDialect::Duckdb,
        _ => SqlDialect::Postgres,
    }
}

/// Hive partition predicates for a resolved window (`_partition_date` on the
/// analytics-head view). Empty when the dialect is postgres or there is no window.
pub fn partition_predicates(plan: &QueryPlan) -> Vec<String> {
    if !plan.dialect.is_duckdb() {
        return Vec::new();
    }
    let Some(range) = plan.time_range.as_ref() else {
        return Vec::new();
    };
    date_predicates(range)
}

fn date_predicates(range: &TimeRange) -> Vec<String> {
    let start = range.start.date_naive();
    let end = range.end.date_naive();
    vec![
        format!("_partition_date >= DATE '{start}'"),
        format!("_partition_date <= DATE '{end}'"),
    ]
}

/// Pin duckdb page cursors to the resolved window so `time:last_24h` page 2
/// does not slide as `now` moves. Postgres keeps offset-only v2 cursors.
pub fn pinned_cursor_window(plan: &QueryPlan) -> Option<&TimeRange> {
    if plan.dialect.is_duckdb() {
        plan.time_range.as_ref()
    } else {
        None
    }
}

/// Fail closed on postgres-only shapes, remap jsonb, inject hive predicates.
pub fn apply_sql(plan: &QueryPlan, sql: String) -> Result<String> {
    if !plan.dialect.is_duckdb() {
        return Ok(sql);
    }

    if matches!(
        plan.entity,
        Entity::TimeseriesMetricInterfaceHourly | Entity::TimeseriesMetricDiskHourly
    ) {
        return Err(ServiceError::InvalidRequest(
            "hourly CAGG entities are not available on the pg_duckdb driver; query the raw entity"
                .into(),
        ));
    }

    if plan.rollup_stats.is_some() {
        return Err(ServiceError::InvalidRequest(
            "rollup_stats requires Timescale continuous aggregates; not supported in duckdb dialect"
                .into(),
        ));
    }

    if sql.to_ascii_uppercase().contains("DISTINCT ON") {
        return Err(ServiceError::InvalidRequest(
            "DISTINCT ON is not supported in duckdb dialect".into(),
        ));
    }

    let mut sql = remap_jsonb(sql);
    sql = inject_partition_predicates(
        &sql,
        &partition_predicates(plan),
        cold_table_for_entity(&plan.entity),
    );
    sql = pin_listing_order(plan, sql);
    Ok(sql)
}

fn pin_listing_order(plan: &QueryPlan, sql: String) -> String {
    if plan.stats.is_some() || plan.downsample.is_some() || plan.rollup_stats.is_some() {
        return sql;
    }
    if !matches!(
        plan.entity,
        Entity::TimeseriesMetrics | Entity::SnmpMetrics | Entity::RperfMetrics
    ) {
        return sql;
    }
    let upper = sql.to_ascii_uppercase();
    let Some(limit_at) = find_limit(&sql) else {
        return sql;
    };
    let extra = if upper.contains("GATEWAY_ID") {
        if upper.contains("NULLS") {
            return sql;
        }
        " NULLS LAST "
    } else {
        ", gateway_id ASC NULLS LAST, series_key ASC NULLS LAST "
    };
    format!("{}{}{}", &sql[..limit_at], extra, &sql[limit_at..])
}

fn find_limit(sql: &str) -> Option<usize> {
    sql.to_ascii_uppercase().rfind("LIMIT")
}

fn remap_jsonb(sql: String) -> String {
    let sql = sql.replace("jsonb_build_object", "json_object");
    // pg_duckdb parses with PostgreSQL first. `DOUBLE` is only a shell type
    // there (`parse_type.c` / `42704`); `float8` is valid in both engines.
    let sql = sql.replace("::double precision", "::float8");
    let sql = sql.replace("::DOUBLE", "::float8");
    let sql = sql.replace("::jsonb", "::JSON");
    remap_jsonb_arrows(&sql)
}

fn remap_jsonb_arrows(sql: &str) -> String {
    let mut out = String::with_capacity(sql.len() + 16);
    let mut rest = sql;
    while let Some(idx) = rest.find("->>") {
        let before = &rest[..idx];
        let col_start = before
            .rfind(|c: char| !(c.is_ascii_alphanumeric() || c == '_' || c == '.'))
            .map(|i| i + 1)
            .unwrap_or(0);
        let col = &before[col_start..];
        let after = rest[idx + 3..].trim_start();
        if is_ident(col)
            && after.starts_with('\'')
            && let Some(end) = after[1..].find('\'')
        {
            let key = &after[1..1 + end];
            out.push_str(&before[..col_start]);
            // pg_duckdb parses with PostgreSQL first; json_extract_string is
            // DuckDB-only and fails at parse_func.c. `::JSON ->>` is valid in
            // both parsers. Parentheses keep coalesce(col->>'k', '') grouped.
            out.push('(');
            out.push_str(col);
            out.push_str("::JSON ->> '");
            out.push_str(key);
            out.push_str("')");
            rest = &after[1 + end + 1..];
            continue;
        }
        out.push_str(&rest[..=idx + 2]);
        rest = &rest[idx + 3..];
    }
    out.push_str(rest);
    out
}

fn is_ident(s: &str) -> bool {
    let mut chars = s.chars();
    matches!(chars.next(), Some(c) if c.is_ascii_alphabetic() || c == '_')
        && chars.all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '.')
}

fn inject_partition_predicates(sql: &str, predicates: &[String], table: Option<&str>) -> String {
    if predicates.is_empty() {
        return sql.to_string();
    }
    let extra = predicates.join(" AND ");
    let mut out = String::with_capacity(sql.len() + extra.len() + 16);
    let lower = sql.to_ascii_lowercase();
    let mut last = 0;
    let mut search_from = 0;
    while let Some(rel) = lower[search_from..].find("where") {
        let at = search_from + rel;
        let before_ok = at == 0
            || !sql.as_bytes()[at - 1].is_ascii_alphanumeric() && sql.as_bytes()[at - 1] != b'_';
        let after = at + 5;
        let after_ok = after == sql.len()
            || (!sql.as_bytes()[after].is_ascii_alphanumeric() && sql.as_bytes()[after] != b'_');
        if before_ok && after_ok && from_clause_is_base_table(sql, at, table) {
            out.push_str(&sql[last..after]);
            out.push(' ');
            out.push_str(&extra);
            out.push_str(" AND");
            last = after;
        }
        search_from = at + 5;
    }
    out.push_str(&sql[last..]);
    out
}

/// Hive predicates belong on the parquet scan, not on CTE filters that no
/// longer project `_partition_date` (counter-rate downsample has three WHEREs).
fn from_clause_is_base_table(sql: &str, where_at: usize, table: Option<&str>) -> bool {
    let Some(table) = table else {
        return true;
    };
    let head = sql[..where_at].to_ascii_lowercase();
    let Some(from_rel) = head.rfind("from") else {
        return false;
    };
    let from_at = from_rel;
    let from_before_ok = from_at == 0
        || !head.as_bytes()[from_at - 1].is_ascii_alphanumeric()
            && head.as_bytes()[from_at - 1] != b'_';
    if !from_before_ok {
        return false;
    }
    head[from_at..].contains(table)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::parser::Entity;
    use chrono::{TimeZone, Utc};

    #[test]
    fn empty_map_is_postgres() {
        assert_eq!(
            resolve(&Entity::TimeseriesMetrics, &HashMap::new()),
            SqlDialect::Postgres
        );
        assert_eq!(
            resolve(
                &Entity::Devices,
                &HashMap::from([("timeseries_metrics".into(), "pg_duckdb".into())])
            ),
            SqlDialect::Postgres
        );
    }

    #[test]
    fn flipped_table_is_duckdb() {
        let drivers = HashMap::from([("timeseries_metrics".into(), "pg_duckdb".into())]);
        assert_eq!(
            resolve(&Entity::TimeseriesMetrics, &drivers),
            SqlDialect::Duckdb
        );
        assert_eq!(resolve(&Entity::SnmpMetrics, &drivers), SqlDialect::Duckdb);
        assert_eq!(resolve(&Entity::Flows, &drivers), SqlDialect::Postgres);
    }

    #[test]
    fn injects_partition_predicates_after_where() {
        let sql = inject_partition_predicates(
            "SELECT 1 FROM timeseries_metrics WHERE timestamp >= ?",
            &["_partition_date >= DATE '2026-09-14'".into()],
            Some("timeseries_metrics"),
        );
        assert!(sql.contains("_partition_date >= DATE '2026-09-14' AND"));
        assert!(sql.contains("timestamp >= ?"));
    }

    #[test]
    fn partition_predicates_skip_cte_filters() {
        let sql = inject_partition_predicates(
            "SELECT 1 FROM timeseries_metrics WHERE ts >= $1), rate_data AS (\n SELECT 1 FROM ordered_data WHERE prev IS NOT NULL\n) SELECT 1 FROM rate_data WHERE rate IS NOT NULL",
            &["_partition_date >= DATE '2026-09-14'".into()],
            Some("timeseries_metrics"),
        );
        assert_eq!(
            sql.matches("_partition_date >= DATE '2026-09-14'").count(),
            1
        );
        assert!(sql.contains("FROM timeseries_metrics WHERE _partition_date"));
        assert!(sql.contains("FROM ordered_data WHERE prev IS NOT NULL"));
        assert!(sql.contains("FROM rate_data WHERE rate IS NOT NULL"));
    }

    #[test]
    fn remaps_jsonb_arrow() {
        let sql = remap_jsonb("coalesce(tags->>'core_id', '') AS series".into());
        assert_eq!(sql, "coalesce((tags::JSON ->> 'core_id'), '') AS series");
    }

    #[test]
    fn remaps_double_precision_to_float8() {
        let sql = remap_jsonb(
            "THEN ((metadata::JSON ->> 'max_counter_rate_per_second'))::double precision".into(),
        );
        assert!(sql.contains("::float8"), "{sql}");
        assert!(!sql.contains("::DOUBLE"), "{sql}");
        assert!(!sql.contains("::double precision"), "{sql}");
    }

    #[test]
    fn distinct_on_fails_closed() {
        let plan = QueryPlan {
            entity: Entity::TimeseriesMetrics,
            filters: Vec::new(),
            order: Vec::new(),
            limit: 10,
            offset: 0,
            time_range: Some(TimeRange {
                start: Utc.with_ymd_and_hms(2026, 9, 14, 0, 0, 0).unwrap(),
                end: Utc.with_ymd_and_hms(2026, 9, 15, 0, 0, 0).unwrap(),
            }),
            stats: None,
            downsample: None,
            rollup_stats: None,
            other: false,
            include_deleted: false,
            dialect: SqlDialect::Duckdb,
        };
        let err = apply_sql(
            &plan,
            "SELECT DISTINCT ON (series) series FROM timeseries_metrics WHERE true".into(),
        )
        .unwrap_err();
        assert!(err.to_string().contains("DISTINCT ON"));
    }
}
