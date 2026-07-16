use super::stats_clauses::{build_lowered_text_clause, build_numeric_clause, build_text_clause};
use super::stats_expr::parse_stats_expressions;
use super::time::effective_timestamp_sql;
use crate::{
    error::{Result, ServiceError},
    jsonb::DbJson,
    parser::Filter,
    query::{BindParam, QueryPlan},
    time::TimeRange,
};
use chrono::{DateTime, Utc};
use diesel::deserialize::QueryableByName;
use diesel::pg::Pg;
use diesel::query_builder::{BoxedSqlQuery, SqlQuery};
use diesel::sql_query;
use diesel::sql_types::{Int4, Jsonb, Nullable, Text, Timestamptz};

#[derive(Debug, Clone)]
pub(super) struct LogsStatsSql {
    pub(super) sql: String,
    pub(super) binds: Vec<SqlBindValue>,
}

impl LogsStatsSql {
    pub(super) fn to_boxed_query(&self) -> BoxedSqlQuery<'_, Pg, SqlQuery> {
        let mut query = sql_query(rewrite_placeholders(&self.sql)).into_boxed::<Pg>();
        for bind in &self.binds {
            query = bind.apply(query);
        }
        query
    }
}

#[derive(Debug, QueryableByName)]
#[diesel(check_for_backend(diesel::pg::Pg))]
pub(super) struct LogsStatsPayload {
    #[diesel(sql_type = Nullable<Jsonb>)]
    pub(super) payload: Option<DbJson>,
}

#[derive(Debug, Clone)]
pub(super) enum SqlBindValue {
    Text(String),
    Int(i32),
    Timestamp(DateTime<Utc>),
}

impl SqlBindValue {
    fn apply<'a>(&self, query: BoxedSqlQuery<'a, Pg, SqlQuery>) -> BoxedSqlQuery<'a, Pg, SqlQuery> {
        match self {
            SqlBindValue::Text(value) => query.bind::<Text, _>(value.clone()),
            SqlBindValue::Int(value) => query.bind::<Int4, _>(*value),
            SqlBindValue::Timestamp(value) => query.bind::<Timestamptz, _>(*value),
        }
    }
}

pub(super) fn bind_param_from_stats(value: SqlBindValue) -> BindParam {
    match value {
        SqlBindValue::Text(value) => BindParam::Text(value),
        SqlBindValue::Int(value) => BindParam::Int(i64::from(value)),
        SqlBindValue::Timestamp(value) => BindParam::timestamptz(value),
    }
}

pub(super) fn build_stats_query(plan: &QueryPlan) -> Result<Option<LogsStatsSql>> {
    let stats_raw = match plan.stats.as_ref() {
        Some(raw) if !raw.as_raw().trim().is_empty() => raw.as_raw().trim(),
        _ => return Ok(None),
    };

    let expressions = parse_stats_expressions(stats_raw)?;
    if expressions.is_empty() {
        return Err(ServiceError::InvalidRequest(
            "stats expression required for logs queries".into(),
        ));
    }

    let mut binds = Vec::new();
    let mut clauses = Vec::new();

    if let Some(TimeRange { start, end }) = &plan.time_range {
        clauses.push(format!("{} >= ?", effective_timestamp_sql()));
        binds.push(SqlBindValue::Timestamp(*start));
        clauses.push(format!("{} <= ?", effective_timestamp_sql()));
        binds.push(SqlBindValue::Timestamp(*end));
    }

    for filter in &plan.filters {
        if let Some((clause, mut values)) = build_stats_filter_clause(filter)? {
            clauses.push(clause);
            binds.append(&mut values);
        }
    }

    let mut parts = Vec::new();
    for expr in expressions {
        parts.push(expr.to_sql_fragment());
    }

    let mut sql = String::from("SELECT jsonb_build_object(");
    sql.push_str(&parts.join(", "));
    sql.push_str(") AS payload\nFROM logs");
    if !clauses.is_empty() {
        sql.push_str("\nWHERE ");
        sql.push_str(&clauses.join(" AND "));
    }

    Ok(Some(LogsStatsSql { sql, binds }))
}

fn build_stats_filter_clause(filter: &Filter) -> Result<Option<(String, Vec<SqlBindValue>)>> {
    match filter.field.as_str() {
        "trace_id" => build_text_clause("trace_id", filter),
        "span_id" => build_text_clause("span_id", filter),
        "service_name" | "service" => build_text_clause("service_name", filter),
        "service_version" => build_text_clause("service_version", filter),
        "service_instance" => build_text_clause("service_instance", filter),
        "source" => build_text_clause("source", filter),
        "source_ip" => build_text_clause("source_ip", filter),
        "scope_name" => build_text_clause("scope_name", filter),
        "scope_version" => build_text_clause("scope_version", filter),
        "severity_text" | "severity" | "level" => {
            build_lowered_text_clause("severity_text", filter)
        }
        "event_name" => build_text_clause("event_name", filter),
        "body" | "message" => build_text_clause("body", filter),
        "ingest_identity" => build_text_clause("ingest_identity", filter),
        "ingest_agent_id" => build_text_clause("ingest_agent_id", filter),
        "ingest_partition" => build_text_clause("ingest_partition", filter),
        "severity_number" => build_numeric_clause("severity_number", filter),
        other => Err(ServiceError::InvalidRequest(format!(
            "unsupported filter field for logs stats: '{other}'"
        ))),
    }
}

pub(super) fn rewrite_placeholders(sql: &str) -> String {
    let mut rewritten = String::with_capacity(sql.len());
    let mut index = 1;
    for ch in sql.chars() {
        if ch == '?' {
            rewritten.push('$');
            rewritten.push_str(&index.to_string());
            index += 1;
        } else {
            rewritten.push(ch);
        }
    }
    rewritten
}

#[cfg(test)]
mod tests {
    use super::super::test_support::{data_plan, scalar_filter};
    use super::build_stats_query;
    use crate::parser::{Entity, Filter, FilterOp, FilterValue};
    use crate::query::QueryPlan;
    use crate::time::TimeRange;
    use chrono::{Duration as ChronoDuration, TimeZone, Utc};

    #[test]
    fn stats_query_counts_logs_for_service() {
        let plan = stats_plan(
            r#"count() as total, group_uniq_array(service_name) as services"#,
            "serviceradar-core",
        );
        let stats_sql = build_stats_query(&plan).expect("stats query should parse");
        let stats_sql = stats_sql.expect("stats SQL expected");

        let lower = stats_sql.sql.to_lowercase();
        assert!(
            lower.contains("count(") && lower.contains("jsonb_agg"),
            "unexpected stats SQL: {}",
            stats_sql.sql
        );
        assert!(
            lower.contains("jsonb_build_object('total'") && lower.contains("'services'"),
            "payload should be shaped as JSON object: {}",
            stats_sql.sql
        );
        assert_eq!(
            stats_sql.binds.len(),
            3,
            "time range + filter binds expected"
        );
    }

    #[test]
    fn stats_query_accepts_source_ip_filter() {
        let plan = stats_plan("count() as total", "10.208.254.4");
        let mut plan = plan;
        plan.filters[0].field = "source_ip".into();

        let stats_sql = build_stats_query(&plan)
            .expect("stats query should parse")
            .expect("stats SQL expected");

        assert!(stats_sql.sql.contains("source_ip = ?"), "{}", stats_sql.sql);
    }

    fn stats_plan(stats: &str, service_name: &str) -> QueryPlan {
        let start = Utc.with_ymd_and_hms(2025, 1, 1, 0, 0, 0).unwrap();
        let end = start + ChronoDuration::hours(24);
        QueryPlan {
            entity: Entity::Logs,
            filters: vec![Filter {
                field: "service_name".into(),
                op: FilterOp::Eq,
                value: FilterValue::Scalar(service_name.to_string()),
            }],
            order: Vec::new(),
            limit: 100,
            offset: 0,
            time_range: Some(TimeRange { start, end }),
            stats: Some(crate::parser::StatsSpec::from_raw(stats)),
            downsample: None,
            rollup_stats: None,
            other: false,
            include_deleted: false,
        }
    }

    #[test]
    fn event_name_stats_filter_is_supported() {
        let start = Utc.with_ymd_and_hms(2025, 1, 1, 0, 0, 0).unwrap();
        let end = start + ChronoDuration::hours(24);
        let mut plan = data_plan(vec![scalar_filter(
            "event_name",
            FilterOp::Eq,
            "device.reboot",
        )]);
        plan.time_range = Some(TimeRange { start, end });
        plan.stats = Some(crate::parser::StatsSpec::from_raw("count() as total"));

        let stats_sql = build_stats_query(&plan).expect("stats query should parse");
        let stats_sql = stats_sql.expect("stats SQL expected");
        assert!(
            stats_sql.sql.contains("event_name = ?"),
            "event_name stats filter should hit the column: {}",
            stats_sql.sql
        );
    }

    #[test]
    fn severity_stats_filter_lowers_both_sides() {
        let mut plan = data_plan(vec![scalar_filter("severity_text", FilterOp::Eq, "SEVERE")]);
        plan.stats = Some(crate::parser::StatsSpec::from_raw("count() as total"));

        let stats_sql = build_stats_query(&plan).expect("stats query should parse");
        let stats_sql = stats_sql.expect("stats SQL expected");
        assert!(
            stats_sql.sql.contains("lower(severity_text) = lower(?)"),
            "severity stats filter should lower both sides: {}",
            stats_sql.sql
        );
    }

    #[test]
    fn severity_stats_in_filter_lowers_placeholders() {
        let mut plan = data_plan(vec![Filter {
            field: "severity".into(),
            op: FilterOp::In,
            value: FilterValue::List(vec!["SEVERE".into(), "error".into()]),
        }]);
        plan.stats = Some(crate::parser::StatsSpec::from_raw("count() as total"));

        let stats_sql = build_stats_query(&plan).expect("stats query should parse");
        let stats_sql = stats_sql.expect("stats SQL expected");
        assert!(
            stats_sql
                .sql
                .contains("lower(severity_text) IN (lower(?), lower(?))"),
            "severity stats IN filter should lower each placeholder: {}",
            stats_sql.sql
        );
    }

    #[test]
    fn stats_query_accepts_message_filter() {
        let start = Utc.with_ymd_and_hms(2025, 1, 1, 0, 0, 0).unwrap();
        let end = start + ChronoDuration::hours(24);
        let plan = QueryPlan {
            entity: Entity::Logs,
            filters: vec![Filter {
                field: "message".into(),
                op: FilterOp::Like,
                value: FilterValue::Scalar("%earlyoom%".to_string()),
            }],
            order: Vec::new(),
            limit: 100,
            offset: 0,
            time_range: Some(TimeRange { start, end }),
            stats: Some(crate::parser::StatsSpec::from_raw("count() as total")),
            downsample: None,
            rollup_stats: None,
            other: false,
            include_deleted: false,
        };

        let stats_sql = build_stats_query(&plan).expect("stats query should parse");
        let stats_sql = stats_sql.expect("stats SQL expected");
        assert!(
            stats_sql.sql.to_lowercase().contains("body ilike"),
            "message filter should map to body: {}",
            stats_sql.sql
        );
        assert_eq!(
            stats_sql.binds.len(),
            3,
            "time range + message filter binds expected"
        );
    }

    #[test]
    fn stats_query_uses_effective_timestamp() {
        let start = Utc.with_ymd_and_hms(2025, 1, 1, 0, 0, 0).unwrap();
        let end = start + ChronoDuration::hours(24);
        let plan = QueryPlan {
            entity: Entity::Logs,
            filters: Vec::new(),
            order: Vec::new(),
            limit: 100,
            offset: 0,
            time_range: Some(TimeRange { start, end }),
            stats: Some(crate::parser::StatsSpec::from_raw("count() as total")),
            downsample: None,
            rollup_stats: None,
            other: false,
            include_deleted: false,
        };

        let stats_sql = build_stats_query(&plan).expect("stats query should parse");
        let stats_sql = stats_sql.expect("stats SQL expected");
        assert!(
            stats_sql
                .sql
                .contains("COALESCE(observed_timestamp, timestamp) >= ?"),
            "time filter should use effective timestamp: {}",
            stats_sql.sql
        );
        assert!(
            stats_sql
                .sql
                .contains("COALESCE(observed_timestamp, timestamp) <= ?"),
            "time filter should use effective timestamp: {}",
            stats_sql.sql
        );
    }

    #[test]
    fn unknown_stats_filter_field_returns_error() {
        let start = Utc.with_ymd_and_hms(2025, 1, 1, 0, 0, 0).unwrap();
        let end = start + ChronoDuration::hours(24);
        let plan = QueryPlan {
            entity: Entity::Logs,
            filters: vec![Filter {
                field: "unknown_field".into(),
                op: FilterOp::Eq,
                value: FilterValue::Scalar("test".to_string()),
            }],
            order: Vec::new(),
            limit: 100,
            offset: 0,
            time_range: Some(TimeRange { start, end }),
            stats: Some(crate::parser::StatsSpec::from_raw("count() as total")),
            downsample: None,
            rollup_stats: None,
            other: false,
            include_deleted: false,
        };

        let result = build_stats_query(&plan);
        match result {
            Err(err) => {
                assert!(
                    err.to_string().contains("unsupported filter field"),
                    "error should mention unsupported filter field: {}",
                    err
                );
            }
            Ok(_) => panic!("expected error for unknown stats filter field"),
        }
    }
}
