//! `in:otel_metrics` (span-derived samples, also spelled `metrics`) and
//! `in:otel_metric_points` (OTLP data points, also `metric_points`) in the
//! StarRocks dialect.
//!
//! With the warehouse enabled EventWriter writes both only to
//! `serviceradar.otel_metrics` / `serviceradar.otel_metric_points`
//! (`priv/starrocks/0021`), whose columns are those of the CNPG tables plus a
//! key `id`. This module answers the queries the CNPG builders
//! (`query/otel_metrics.rs`, `query/otel_metric_points.rs`) answer, with the
//! same rows:
//!
//! * `stats:` is `count() as <alias> [by <field>]`, parsed by the CNPG
//!   builders' own `parse_stats_spec`, so both backends accept the same
//!   grammar. A grouped count is ordered, limited and offset as CNPG orders it;
//!   an ungrouped count is one row.
//! * Time bounds are the closed `[start, end]` CNPG binds, at microsecond
//!   precision.
//! * Filters follow the CNPG row path and stats path separately, because they
//!   differ: a row-listing text negation keeps NULL rows, a stats one drops
//!   them, and the boolean negations do the opposite. A field or operator CNPG
//!   refuses is refused here too.
//! * Sort terms carry Postgres's NULL placement. Row listings then break ties
//!   on `timestamp` and `id`, and grouped counts on the group, where CNPG
//!   leaves ties in no particular order.
//!
//! `bucket:` and `rollup_stats:` have no OTel metrics translation on either
//! backend and are refused (`other:true` is refused when the plan is built).

use super::super::otel_metric_points::{self, PointsGroupField};
use super::super::otel_metrics::{self, MetricsGroupField};
use super::super::{PaginationMeta, QueryPlan, TranslateResponse, types::BindParam};
use super::{pg_order_sql, sql_literal, text_predicate};
use crate::{
    error::{Result, ServiceError},
    parser::{Entity, Filter, FilterOp, OrderClause, OrderDirection},
};

/// Row projection of `in:otel_metrics`: the columns the CNPG builder selects
/// (every column of `schema::otel_metrics`, in that order), which is what a
/// caller executing the translated SQL receives from either backend.
const SAMPLE_ROW_COLUMNS: &[&str] = &[
    "timestamp",
    "trace_id",
    "span_id",
    "service_name",
    "span_name",
    "span_kind",
    "duration_ms",
    "duration_seconds",
    "metric_type",
    "http_method",
    "http_route",
    "http_status_code",
    "grpc_service",
    "grpc_method",
    "grpc_status_code",
    "is_slow",
    "component",
    "level",
    "unit",
    "created_at",
    "ingest_identity",
    "ingest_agent_id",
    "ingest_partition",
];

/// Row projection of `in:otel_metric_points`: every column of
/// `schema::otel_metric_points`, in that order, as the CNPG builder selects them.
const POINT_ROW_COLUMNS: &[&str] = &[
    "timestamp",
    "metric_name",
    "metric_type",
    "unit",
    "temporality",
    "is_monotonic",
    "service_name",
    "attributes",
    "attributes_hash",
    "value",
    "count",
    "sum",
    "bucket_counts",
    "explicit_bounds",
    "start_time_unix_nano",
    "scope_name",
    "service_instance_id",
    "created_at",
    "ingest_identity",
    "ingest_agent_id",
    "ingest_partition",
];

/// Text filter fields of `otel_metrics` and their columns
/// (`otel_metrics::apply_filter`). The stats path accepts all of them except
/// `span_kind` and `level` (`otel_metrics::build_stats_filter_clause`).
const SAMPLE_TEXT_FIELDS: &[(&str, &str)] = &[
    ("trace_id", "trace_id"),
    ("span_id", "span_id"),
    ("service_name", "service_name"),
    ("service", "service_name"),
    ("span_name", "span_name"),
    ("span_kind", "span_kind"),
    ("metric_type", "metric_type"),
    ("type", "metric_type"),
    ("component", "component"),
    ("level", "level"),
    ("http_method", "http_method"),
    ("http_route", "http_route"),
    ("http_status_code", "http_status_code"),
    ("grpc_service", "grpc_service"),
    ("grpc_method", "grpc_method"),
    ("grpc_status_code", "grpc_status_code"),
    ("ingest_identity", "ingest_identity"),
    ("ingest_agent_id", "ingest_agent_id"),
    ("ingest_partition", "ingest_partition"),
];
const SAMPLE_ROW_ONLY_TEXT_FIELDS: &[&str] = &["span_kind", "level"];

/// Text filter fields of `otel_metric_points` (`otel_metric_points::apply_filter`
/// and `build_stats_filter_clause`, which accept the same set).
const POINT_TEXT_FIELDS: &[(&str, &str)] = &[
    ("metric_name", "metric_name"),
    ("service_name", "service_name"),
    ("service", "service_name"),
    ("metric_type", "metric_type"),
    ("type", "metric_type"),
    ("unit", "unit"),
    ("temporality", "temporality"),
    ("scope_name", "scope_name"),
    ("service_instance_id", "service_instance_id"),
    ("service_instance", "service_instance_id"),
    ("ingest_identity", "ingest_identity"),
    ("ingest_agent_id", "ingest_agent_id"),
    ("ingest_partition", "ingest_partition"),
];

#[derive(Clone, Copy)]
enum Table {
    Samples,
    Points,
}

/// Resolves a row `sort:` field to its column, or refuses it.
type SortColumn = fn(&str) -> Result<&'static str>;

impl Table {
    fn name(self) -> &'static str {
        match self {
            Table::Samples => "otel_metrics",
            Table::Points => "otel_metric_points",
        }
    }

    fn row_columns(self) -> &'static [&'static str] {
        match self {
            Table::Samples => SAMPLE_ROW_COLUMNS,
            Table::Points => POINT_ROW_COLUMNS,
        }
    }

    /// The CNPG row builder's sort-field list, shared so both refuse alike.
    fn sort_column(self) -> SortColumn {
        match self {
            Table::Samples => otel_metrics::row_sort_column,
            Table::Points => otel_metric_points::row_sort_column,
        }
    }
}

/// Whether a `sort:` field names the group of a grouped count.
type SortsByGroup = fn(&str) -> bool;

/// A parsed `count() as <alias> [by <field>]`: the alias, and the group
/// column with the sort fields that resolve to it.
struct CountSpec {
    alias: String,
    group: Option<(&'static str, SortsByGroup)>,
}

pub(super) fn translate(plan: &QueryPlan, database: &str) -> Result<TranslateResponse> {
    let table = match plan.entity {
        Entity::OtelMetrics => Table::Samples,
        Entity::OtelMetricPoints => Table::Points,
        _ => {
            return Err(ServiceError::Internal(anyhow::anyhow!(
                "the StarRocks OTel metrics dialect was handed {:?}",
                plan.entity
            )));
        }
    };
    refuse_unimplemented_features(plan, table)?;

    let from = format!("{database}.{}", table.name());
    let (mut predicates, params) = time_bounds(plan);
    let stats = plan
        .stats
        .as_ref()
        .map(|stats| stats.as_raw().trim())
        .filter(|raw| !raw.is_empty());
    for filter in &plan.filters {
        let predicate = match (table, stats.is_some()) {
            (Table::Samples, false) => sample_row_filter(filter)?,
            (Table::Samples, true) => sample_stats_filter(filter)?,
            (Table::Points, false) => point_row_filter(filter)?,
            (Table::Points, true) => point_stats_filter(filter)?,
        };
        predicates.extend(predicate);
    }
    let where_sql = if predicates.is_empty() {
        String::new()
    } else {
        format!(" WHERE {}", predicates.join(" AND "))
    };

    let sql = match stats {
        Some(raw) => count_sql(plan, &from, &where_sql, &count_spec(table, raw)?),
        None => rows_sql(plan, &from, &where_sql, table)?,
    };

    Ok(TranslateResponse {
        sql,
        params,
        pagination: PaginationMeta {
            next_cursor: None,
            prev_cursor: None,
            limit: Some(plan.limit),
        },
        viz: None,
    })
}

fn refuse_unimplemented_features(plan: &QueryPlan, table: Table) -> Result<()> {
    otel_metrics::refuse_unsupported_clauses(plan, table.name())
}

fn count_spec(table: Table, raw: &str) -> Result<CountSpec> {
    Ok(match table {
        Table::Samples => {
            let spec = otel_metrics::parse_stats_spec(raw)?;
            CountSpec {
                alias: spec.alias,
                group: spec.group_field.map(|field| match field {
                    MetricsGroupField::ServiceName => (
                        field.column(),
                        otel_metrics::is_service_sort_field as SortsByGroup,
                    ),
                }),
            }
        }
        Table::Points => {
            let spec = otel_metric_points::parse_stats_spec(raw)?;
            CountSpec {
                alias: spec.alias,
                group: spec.group_field.map(|field| {
                    let matches: SortsByGroup = match field {
                        PointsGroupField::MetricName => {
                            |name| PointsGroupField::MetricName.matches_order_field(name)
                        }
                        PointsGroupField::ServiceName => {
                            |name| PointsGroupField::ServiceName.matches_order_field(name)
                        }
                    };
                    (field.column(), matches)
                }),
            }
        }
    })
}

fn quoted(column: &str) -> String {
    format!("`{column}`")
}

/// `[start, end]`, the bounds CNPG binds, as naive UTC `DATETIME` literals with
/// microseconds. No `time:` means no bound, as on CNPG.
fn time_bounds(plan: &QueryPlan) -> (Vec<String>, Vec<BindParam>) {
    let Some(range) = &plan.time_range else {
        return (Vec::new(), Vec::new());
    };
    let literal = |value: chrono::DateTime<chrono::Utc>| {
        format!("'{}'", value.format("%Y-%m-%d %H:%M:%S%.6f"))
    };
    (
        vec![
            format!("`timestamp` >= {}", literal(range.start)),
            format!("`timestamp` <= {}", literal(range.end)),
        ],
        vec![
            BindParam::timestamptz(range.start),
            BindParam::timestamptz(range.end),
        ],
    )
}

fn column_for(fields: &[(&str, &'static str)], field: &str) -> Option<&'static str> {
    fields
        .iter()
        .find(|(name, _)| *name == field)
        .map(|(_, column)| *column)
}

fn unsupported_filter(table: Table, field: &str, stats: bool) -> ServiceError {
    let path = if stats { " stats" } else { "" };
    ServiceError::InvalidRequest(format!(
        "unsupported filter field for {}{path}: '{field}'",
        table.name()
    ))
}

/// `is_slow` / `is_monotonic`: equality only. On the row path a negation is
/// Diesel's `<>`, which drops NULL rows; on the stats path it keeps them.
fn bool_predicate(
    column: &str,
    filter: &Filter,
    parse: fn(&str) -> Result<bool>,
    keep_null_on_negation: bool,
) -> Result<String> {
    let value = parse(filter.value.as_scalar()?)?;
    let literal = if value { "TRUE" } else { "FALSE" };
    let column = quoted(column);
    match filter.op {
        FilterOp::Eq => Ok(format!("{column} = {literal}")),
        FilterOp::NotEq if keep_null_on_negation => {
            Ok(format!("({column} IS NULL OR {column} <> {literal})"))
        }
        FilterOp::NotEq => Ok(format!("{column} <> {literal}")),
        _ => Err(ServiceError::InvalidRequest(format!(
            "{} filter only supports equality",
            filter.field
        ))),
    }
}

/// `otel_metrics::apply_filter`.
fn sample_row_filter(filter: &Filter) -> Result<Option<String>> {
    let field = filter.field.as_str();
    if let Some(column) = column_for(SAMPLE_TEXT_FIELDS, field) {
        return text_predicate(column, filter, true);
    }
    match field {
        "is_slow" => bool_predicate("is_slow", filter, otel_metrics::parse_bool, false).map(Some),
        _ => Err(unsupported_filter(Table::Samples, field, false)),
    }
}

/// `otel_metrics::build_stats_filter_clause`.
fn sample_stats_filter(filter: &Filter) -> Result<Option<String>> {
    let field = filter.field.as_str();
    if let Some(column) = column_for(SAMPLE_TEXT_FIELDS, field)
        .filter(|_| !SAMPLE_ROW_ONLY_TEXT_FIELDS.contains(&field))
    {
        return text_predicate(column, filter, false);
    }
    match field {
        "is_slow" => bool_predicate("is_slow", filter, otel_metrics::parse_bool, true).map(Some),
        _ => Err(unsupported_filter(Table::Samples, field, true)),
    }
}

/// `otel_metric_points::apply_filter`.
fn point_row_filter(filter: &Filter) -> Result<Option<String>> {
    let field = filter.field.as_str();
    if let Some(column) = column_for(POINT_TEXT_FIELDS, field) {
        return text_predicate(column, filter, true);
    }
    match field {
        // `ILIKE` / `NOT ILIKE` on the raw column: NULL attributes match neither.
        "attributes" => attributes_predicate(filter, "`attributes`"),
        "is_monotonic" => bool_predicate(
            "is_monotonic",
            filter,
            otel_metric_points::parse_bool,
            false,
        ),
        "value" => value_predicate(filter),
        _ => Err(unsupported_filter(Table::Points, field, false)),
    }
    .map(Some)
}

/// `otel_metric_points::build_stats_filter_clause`.
fn point_stats_filter(filter: &Filter) -> Result<Option<String>> {
    let field = filter.field.as_str();
    if let Some(column) = column_for(POINT_TEXT_FIELDS, field) {
        return text_predicate(column, filter, false);
    }
    match field {
        // NULL attributes read as '' here, so a negation keeps them.
        "attributes" => attributes_predicate(filter, "COALESCE(`attributes`, '')"),
        "is_monotonic" => {
            bool_predicate("is_monotonic", filter, otel_metric_points::parse_bool, true)
        }
        "value" => value_predicate(filter),
        _ => Err(unsupported_filter(Table::Points, field, true)),
    }
    .map(Some)
}

fn attributes_predicate(filter: &Filter, expr: &str) -> Result<String> {
    let pattern = sql_literal(&otel_metric_points::attributes_pattern(filter)?.to_lowercase());
    match filter.op {
        FilterOp::Eq | FilterOp::Like => Ok(format!("LOWER({expr}) LIKE {pattern}")),
        FilterOp::NotEq | FilterOp::NotLike => Ok(format!("LOWER({expr}) NOT LIKE {pattern}")),
        _ => Err(ServiceError::InvalidRequest(
            "attributes filter only supports substring matching".into(),
        )),
    }
}

/// `value`: ordered comparisons; `<>` drops NULL values on both paths.
fn value_predicate(filter: &Filter) -> Result<String> {
    let value = otel_metric_points::parse_f64(filter.value.as_scalar()?)?;
    let op = match filter.op {
        FilterOp::Eq => "=",
        FilterOp::NotEq => "<>",
        FilterOp::Gt => ">",
        FilterOp::Gte => ">=",
        FilterOp::Lt => "<",
        FilterOp::Lte => "<=",
        _ => {
            return Err(ServiceError::InvalidRequest(
                "value filter does not support this operator".into(),
            ));
        }
    };
    // `{:?}` keeps a fractional part and exponent, so the literal is a DOUBLE.
    Ok(format!("`value` {op} {value:?}"))
}

/// The CNPG row builders' `apply_ordering`: the requested terms, newest first
/// when there are none, then `timestamp` (unless requested) and `id` as tie
/// breaks in the direction of the first term.
fn rows_sql(plan: &QueryPlan, from: &str, where_sql: &str, table: Table) -> Result<String> {
    let (columns, sort_column) = (table.row_columns(), table.sort_column());
    let mut terms = Vec::with_capacity(plan.order.len() + 2);
    for clause in &plan.order {
        terms.push(sort_term(sort_column(clause.field.as_str())?, clause));
    }
    let tie = plan
        .order
        .first()
        .map_or(OrderDirection::Desc, |clause| clause.direction);
    let sorts_by_time = plan
        .order
        .iter()
        .any(|clause| sort_column(clause.field.as_str()).ok() == Some("timestamp"));
    if !sorts_by_time {
        terms.push(format!("`timestamp` {}", pg_order_sql(tie)));
    }
    terms.push(format!("`id` {}", pg_order_sql(tie)));

    let select = columns
        .iter()
        .map(|column| quoted(column))
        .collect::<Vec<_>>()
        .join(", ");
    Ok(format!(
        "SELECT {select} FROM {from}{where_sql} ORDER BY {} LIMIT {} OFFSET {}",
        terms.join(", "),
        plan.limit,
        plan.offset
    ))
}

fn sort_term(column: &str, clause: &OrderClause) -> String {
    format!("{} {}", quoted(column), pg_order_sql(clause.direction))
}

/// The CNPG `build_stats_query`: a grouped count is one row per group, sorted
/// by the count or the group (other sort fields are skipped; with none left,
/// largest count first) and limited; an ungrouped count is one row.
fn count_sql(plan: &QueryPlan, from: &str, where_sql: &str, spec: &CountSpec) -> String {
    let alias = quoted(&spec.alias);
    let Some((column, is_group_field)) = spec.group else {
        return format!("SELECT COUNT(*) AS {alias} FROM {from}{where_sql}");
    };
    let group = quoted(column);
    let mut terms = Vec::new();
    for clause in &plan.order {
        if clause.field.eq_ignore_ascii_case(&spec.alias) {
            terms.push(format!("{alias} {}", pg_order_sql(clause.direction)));
        } else if is_group_field(clause.field.as_str()) {
            terms.push(format!("{group} {}", pg_order_sql(clause.direction)));
        }
    }
    if terms.is_empty() {
        terms.push(format!("{alias} {}", pg_order_sql(OrderDirection::Desc)));
    }
    if !terms.iter().any(|term| term.starts_with(&group)) {
        terms.push(format!("{group} {}", pg_order_sql(OrderDirection::Asc)));
    }
    format!(
        "SELECT {group}, COUNT(*) AS {alias} FROM {from}{where_sql} GROUP BY {group} ORDER BY {} LIMIT {} OFFSET {}",
        terms.join(", "),
        plan.limit,
        plan.offset
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::parser;
    use crate::query::{QueryDirection, QueryRequest, build_query_plan};

    const DB: &str = "serviceradar";

    fn plan(query: &str) -> QueryPlan {
        let config = crate::config::AppConfig::embedded("postgres://example/db".to_string());
        let request = QueryRequest {
            query: query.to_string(),
            limit: None,
            cursor: None,
            direction: QueryDirection::Next,
            mode: Some("starrocks".into()),
            permitted_signals: None,
        };
        build_query_plan(&config, &request, parser::parse(query).expect("parse")).expect("plan")
    }

    fn compile(query: &str) -> String {
        super::super::translate(&plan(query), DB)
            .unwrap_or_else(|err| panic!("{query} must compile for StarRocks: {err}"))
            .sql
    }

    fn refused(query: &str) -> ServiceError {
        match super::super::translate(&plan(query), DB) {
            Ok(compiled) => panic!("{query} must be refused, compiled to: {}", compiled.sql),
            Err(err) => err,
        }
    }

    /// The CNPG half of the same query, through the entity builders that serve
    /// it when the warehouse is off.
    fn cnpg(query: &str) -> Result<String> {
        let plan = plan(query);
        match plan.entity {
            Entity::OtelMetrics => otel_metrics::to_sql_and_params(&plan),
            Entity::OtelMetricPoints => otel_metric_points::to_sql_and_params(&plan),
            _ => unreachable!("not an OTel metrics query: {query}"),
        }
        .map(|(sql, _)| sql)
    }

    /// The queries the product issues (logs page metrics tab and OTLP view,
    /// metric detail, Analytics slow spans, telemetry onboarding).
    const PRODUCT_QUERIES: &[&str] = &[
        "in:otel_metrics time:last_24h sort:timestamp:desc",
        "in:otel_metrics is_slow:true sort:timestamp:desc",
        "in:otel_metrics time:last_24h is_slow:true sort:duration_ms:desc limit:25",
        r#"in:otel_metrics span_id:"0123456789abcdef" time:last_24h sort:timestamp:desc"#,
        r#"in:otel_metrics time:last_1h service_name:"checkout" span_name:"GET /cart" metric_type:"http" sort:timestamp:desc limit:20"#,
        r#"in:otel_metric_points time:last_24h stats:"count() as points by metric_name" sort:points:desc limit:100"#,
        "in:otel_metric_points time:last_24h sort:timestamp:desc limit:250",
        r#"in:otel_metric_points metric_name:"http.server.duration" sort:timestamp:desc limit:500"#,
        r#"in:otel_metric_points service_name:"checkout" time:last_15m limit:1"#,
    ];

    #[test]
    fn every_product_query_compiles_on_both_backends() {
        for query in PRODUCT_QUERIES {
            let sql = compile(query);
            assert!(
                sql.contains(" FROM serviceradar.otel_metrics")
                    || sql.contains(" FROM serviceradar.otel_metric_points"),
                "{query}: {sql}"
            );
            assert!(!sql.contains("::"), "no Postgres casts: {sql}");
            assert!(!sql.contains("jsonb"), "no Postgres payload: {sql}");
            assert!(!sql.contains("ILIKE"), "no Postgres ILIKE: {sql}");
            cnpg(query).unwrap_or_else(|err| panic!("{query} must compile for CNPG: {err}"));
        }
    }

    /// The column names of a SELECT list, from either dialect's quoting.
    fn select_columns(sql: &str) -> Vec<String> {
        let select = sql
            .strip_prefix("SELECT ")
            .and_then(|rest| rest.split(" FROM ").next())
            .expect("select list");
        select
            .split(", ")
            .map(|column| {
                column
                    .rsplit('.')
                    .next()
                    .unwrap_or(column)
                    .trim_matches(|c| c == '`' || c == '"')
                    .to_string()
            })
            .collect()
    }

    #[test]
    fn listings_project_exactly_the_columns_cnpg_selects() {
        for query in ["in:otel_metrics limit:5", "in:metric_points limit:5"] {
            let warehouse = select_columns(&compile(query));
            let relational = select_columns(&cnpg(query).expect("cnpg"));
            assert_eq!(warehouse, relational, "{query}");
            assert!(
                !warehouse.iter().any(|column| column == "id"),
                "the warehouse key is not a CNPG column"
            );
        }
    }

    #[test]
    fn the_slowest_spans_are_listed_slowest_first() {
        let sql = compile(PRODUCT_QUERIES[2]);
        assert!(sql.contains("WHERE `timestamp` >= '"), "{sql}");
        assert!(sql.contains(" AND `is_slow` = TRUE"), "{sql}");
        assert!(
            sql.ends_with(
                "ORDER BY `duration_ms` DESC NULLS FIRST, `timestamp` DESC NULLS FIRST, `id` DESC NULLS FIRST LIMIT 25 OFFSET 0"
            ),
            "{sql}"
        );
        let relational = cnpg(PRODUCT_QUERIES[2]).expect("cnpg");
        assert!(
            relational.contains(r#"ORDER BY "platform"."otel_metrics"."duration_ms" DESC"#)
                || relational.contains(r#"ORDER BY "otel_metrics"."duration_ms" DESC"#),
            "CNPG sorts by duration too: {relational}"
        );
    }

    #[test]
    fn a_listing_with_no_sort_is_newest_first() {
        let sql = compile("in:otel_metrics limit:5");
        assert!(
            sql.ends_with(
                "ORDER BY `timestamp` DESC NULLS FIRST, `id` DESC NULLS FIRST LIMIT 5 OFFSET 0"
            ),
            "{sql}"
        );
    }

    #[test]
    fn time_bounds_are_closed_as_on_cnpg() {
        let sql = compile("in:otel_metric_points time:last_1h limit:5");
        assert!(sql.contains("`timestamp` >= '"), "{sql}");
        assert!(sql.contains("`timestamp` <= '"), "{sql}");
    }

    #[test]
    fn metric_names_are_counted_busiest_first() {
        let sql = compile(PRODUCT_QUERIES[5]);
        assert!(
            sql.starts_with(
                "SELECT `metric_name`, COUNT(*) AS `points` FROM serviceradar.otel_metric_points WHERE "
            ),
            "{sql}"
        );
        assert!(
            sql.ends_with(
                "GROUP BY `metric_name` ORDER BY `points` DESC NULLS FIRST, `metric_name` ASC NULLS LAST LIMIT 100 OFFSET 0"
            ),
            "{sql}"
        );
    }

    #[test]
    fn an_ungrouped_count_is_one_row() {
        assert_eq!(
            compile(r#"in:otel_metrics is_slow:true stats:"count() as slow""#),
            "SELECT COUNT(*) AS `slow` FROM serviceradar.otel_metrics WHERE `is_slow` = TRUE"
        );
    }

    #[test]
    fn negations_keep_or_drop_null_rows_as_each_cnpg_path_does() {
        // Text: the row path keeps NULLs, the stats path drops them.
        assert!(
            compile("in:otel_metrics !service_name:checkout limit:5")
                .contains("(`service_name` IS NULL OR `service_name` <> 'checkout')")
        );
        assert!(
            compile(
                r#"in:otel_metrics !service_name:checkout stats:"count() as n by service_name""#
            )
            .contains("WHERE `service_name` <> 'checkout'")
        );
        // Booleans: the other way round.
        assert!(
            compile("in:otel_metrics !is_slow:true limit:5").contains("WHERE `is_slow` <> TRUE")
        );
        assert!(
            compile(r#"in:otel_metrics !is_slow:true stats:"count() as n""#)
                .contains("(`is_slow` IS NULL OR `is_slow` <> TRUE)")
        );
        // Attributes: NULL matches neither on rows, reads as '' in stats.
        assert!(
            compile("in:otel_metric_points !attributes:slack limit:5")
                .contains("LOWER(`attributes`) NOT LIKE '%slack%'")
        );
        assert!(
            compile(r#"in:otel_metric_points !attributes:slack stats:"count() as n""#)
                .contains("LOWER(COALESCE(`attributes`, '')) NOT LIKE '%slack%'")
        );
    }

    #[test]
    fn like_is_case_insensitive_and_values_are_escaped() {
        let sql = compile("in:otel_metrics service_name:%Cart% limit:5");
        assert!(sql.contains("LOWER(`service_name`) LIKE '%cart%'"), "{sql}");
        let sql = compile(r#"in:otel_metrics service_name:"o'brien" limit:5"#);
        assert!(sql.contains("`service_name` = 'o''brien'"), "{sql}");
    }

    #[test]
    fn value_filters_compare_double_literals() {
        let sql = compile("in:otel_metric_points value:>1 limit:5");
        assert!(sql.contains("`value` > 1.0"), "{sql}");
        assert!(matches!(
            refused("in:otel_metric_points value:>inf limit:5"),
            ServiceError::InvalidRequest(_)
        ));
    }

    #[test]
    fn a_stats_alias_that_is_not_an_identifier_is_refused_on_both_backends() {
        let query = r#"in:otel_metric_points stats:"count() as x'||pg_sleep(1)||' by metric_name""#;
        assert!(matches!(refused(query), ServiceError::InvalidRequest(_)));
        assert!(cnpg(query).is_err());
    }

    #[test]
    fn clauses_without_an_otel_translation_are_refused() {
        for query in [
            "in:otel_metrics rollup_stats:summary",
            "in:otel_metric_points bucket:5m limit:5",
        ] {
            assert!(
                matches!(refused(query), ServiceError::InvalidRequest(_)),
                "{query}"
            );
        }
    }

    /// Both backends accept and refuse the same OTel metrics queries.
    #[test]
    fn both_backends_accept_the_same_queries() {
        let mut corpus: Vec<String> = PRODUCT_QUERIES.iter().map(|q| q.to_string()).collect();
        // trace and span ids are validated as hex before either builder runs.
        let values = |field: &str| match field {
            "trace_id" => [
                "0123456789abcdef0123456789abcdef",
                "%abc%",
                "(0123456789abcdef0123456789abcdef,fedcba9876543210fedcba9876543210)",
            ],
            "span_id" => [
                "0123456789abcdef",
                "%abc%",
                "(0123456789abcdef,fedcba9876543210)",
            ],
            _ => ["edge-a", "%edge%", "(edge-a,edge-b)"],
        };
        for (field, _) in SAMPLE_TEXT_FIELDS {
            for value in values(field) {
                corpus.push(format!("in:otel_metrics {field}:{value} limit:5"));
                corpus.push(format!(
                    "in:otel_metrics !{field}:{value} stats:\"count() as n by service_name\" limit:5"
                ));
            }
        }
        for (field, _) in POINT_TEXT_FIELDS {
            for value in ["edge-a", "%edge%", "(edge-a,edge-b)"] {
                corpus.push(format!("in:otel_metric_points {field}:{value} limit:5"));
                corpus.push(format!(
                    "in:otel_metric_points !{field}:{value} stats:\"count() as n by metric_name\" limit:5"
                ));
            }
        }
        for sort in [
            "timestamp",
            "service_name",
            "service",
            "metric_type",
            "type",
            "duration_ms",
            "span_name",
            "value",
        ] {
            corpus.push(format!("in:otel_metrics sort:{sort}:asc limit:5"));
        }
        for sort in ["timestamp", "value", "metric_name", "service_name"] {
            corpus.push(format!("in:otel_metric_points sort:{sort}:desc limit:5"));
        }
        corpus.extend(
            [
                "in:otel_metrics is_slow:maybe limit:5",
                "in:otel_metrics is_slow:>1 limit:5",
                "in:otel_metrics is_slow:false stats:\"count() as n\"",
                "in:otel_metrics unknown_field:x limit:5",
                "in:otel_metrics duration_ms:>5 limit:5",
                "in:otel_metrics stats:\"count() as n by span_name\"",
                "in:otel_metrics stats:\"sum(duration_ms) as n\"",
                "in:otel_metrics stats:\"count() as n by service\" sort:service:asc limit:5",
                "in:otel_metrics stats:\"count() as n by name\" sort:unknown:asc limit:5",
                "in:otel_metric_points is_monotonic:true limit:5",
                "in:otel_metric_points is_monotonic:yes stats:\"count() as n by service_name\"",
                "in:otel_metric_points attributes:slack limit:5",
                "in:otel_metric_points attributes:%slack% stats:\"count() as n\"",
                "in:otel_metric_points attributes:(a,b) limit:5",
                "in:otel_metric_points value:3.5 limit:5",
                "in:otel_metric_points value:abc limit:5",
                "in:otel_metric_points value:%3% limit:5",
                "in:otel_metric_points value:<=0 stats:\"count() as n by metric_name\"",
                "in:otel_metric_points stats:\"count() as n by name\" sort:name:asc limit:5",
                "in:otel_metric_points stats:\"count() as n by unit\"",
                "in:otel_metric_points stats:\"count() n\"",
                "in:metric_points stats:\"count() as N by service\" sort:n:asc limit:5",
            ]
            .map(String::from),
        );

        let mut mismatches = Vec::new();
        for query in &corpus {
            let warehouse = super::super::translate(&plan(query), DB);
            let relational = cnpg(query);
            if warehouse.is_ok() != relational.is_ok() {
                mismatches.push(format!(
                    "{query}\n  starrocks: {:?}\n  cnpg: {:?}",
                    warehouse.map(|c| c.sql),
                    relational
                ));
            }
        }
        assert!(mismatches.is_empty(), "{}", mismatches.join("\n"));
    }
}
