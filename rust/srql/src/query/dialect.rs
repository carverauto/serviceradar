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
    sql = inject_partition_predicates(&sql, &partition_predicates(plan));
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
    let sql = sql.replace("::double precision", "::DOUBLE");
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
        if is_ident(col) && after.starts_with('\'') {
            if let Some(end) = after[1..].find('\'') {
                let key = &after[1..1 + end];
                out.push_str(&before[..col_start]);
                out.push_str("json_extract_string(");
                out.push_str(col);
                out.push_str(", '$.");
                out.push_str(key);
                out.push_str("')");
                rest = &after[1 + end + 1..];
                continue;
            }
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

fn inject_partition_predicates(sql: &str, predicates: &[String]) -> String {
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
        if before_ok && after_ok {
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
        );
        assert!(sql.contains("_partition_date >= DATE '2026-09-14' AND"));
        assert!(sql.contains("timestamp >= ?"));
    }

    #[test]
    fn remaps_jsonb_arrow() {
        let sql = remap_jsonb("coalesce(tags->>'core_id', '') AS series".into());
        assert_eq!(
            sql,
            "coalesce(json_extract_string(tags, '$.core_id'), '') AS series"
        );
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
