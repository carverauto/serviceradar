//! SRQL for the OTel service catalog (`in:otel_services`).
//!
//! Reads `platform.otel_service_catalog`, one row per OTel `service.name` with
//! a last-seen timestamp per signal. This is CNPG control-plane state in both
//! storage modes; it has no StarRocks dataset.
//!
//! Access is narrowed here, not by the caller editing the query string. The
//! trusted caller supplies the signals it may view
//! ([`QueryRequest::permitted_signals`](super::QueryRequest)), and this module
//! is the only parser of `signal:`. The effective signals are the requested
//! `signal:` values, or the permitted set when there is none; every requested
//! value must be permitted. Everything derived from a row -- `signals`,
//! `last_seen`, the `time:` filter and the default ordering -- reads only the
//! effective signals' columns, and a per-signal field outside them is NULL, so
//! a narrowed query cannot disclose activity in a signal the caller may not
//! view. The stored `last_seen_at` column spans every signal and is therefore
//! never read.
//!
//! Errors: a missing permitted set, a requested signal that is not permitted,
//! and an empty effective set are `Forbidden`. A repeated or negated `signal:`
//! and an unknown signal name are `InvalidRequest`.

use super::{BindParam, QueryPlan, bind_sql_param};
use crate::{
    error::{Result, ServiceError},
    jsonb::DbJson,
    models::OtelServiceRow,
    parser::{Entity, Filter, FilterOp, OrderClause, OrderDirection},
    time::TimeRange,
};
use diesel::deserialize::QueryableByName;
use diesel::pg::Pg;
use diesel::query_builder::{BoxedSqlQuery, SqlQuery};
use diesel::sql_query;
use diesel::sql_types::Jsonb;
use diesel_async::{AsyncPgConnection, RunQueryDsl};
use serde_json::Value;

const TABLE: &str = "platform.otel_service_catalog";

/// Page size when the query names no `limit:`.
pub(crate) const DEFAULT_LIMIT: i64 = 50;
/// Largest page `limit:` may ask for; larger values are clamped.
pub(crate) const MAX_LIMIT: i64 = 500;

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
enum Signal {
    Logs,
    Traces,
    Metrics,
}

const ALL_SIGNALS: [Signal; 3] = [Signal::Logs, Signal::Traces, Signal::Metrics];

impl Signal {
    fn parse(raw: &str) -> Option<Self> {
        match raw.trim().to_ascii_lowercase().as_str() {
            "logs" => Some(Self::Logs),
            "traces" => Some(Self::Traces),
            "metrics" => Some(Self::Metrics),
            _ => None,
        }
    }

    fn name(self) -> &'static str {
        match self {
            Self::Logs => "logs",
            Self::Traces => "traces",
            Self::Metrics => "metrics",
        }
    }

    /// The catalog column holding this signal's last-seen time.
    fn column(self) -> &'static str {
        match self {
            Self::Logs => "logs_last_seen_at",
            Self::Traces => "traces_last_seen_at",
            Self::Metrics => "metrics_last_seen_at",
        }
    }

    /// The response field carrying this signal's last-seen time.
    fn output(self) -> &'static str {
        match self {
            Self::Logs => "logs_last_seen",
            Self::Traces => "traces_last_seen",
            Self::Metrics => "metrics_last_seen",
        }
    }
}

#[derive(Debug, QueryableByName)]
#[diesel(check_for_backend(diesel::pg::Pg))]
struct StatsPayload {
    #[diesel(sql_type = Jsonb)]
    payload: DbJson,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Mode {
    Data,
    Stats,
}

struct BuiltSql {
    sql: String,
    binds: Vec<BindParam>,
    mode: Mode,
}

pub(super) async fn execute(
    conn: &mut AsyncPgConnection,
    plan: &QueryPlan,
    permitted_signals: Option<&[String]>,
) -> Result<Vec<Value>> {
    // Execution binds exactly what translation returns, so the SQL that runs is
    // the SQL a translate caller sees.
    let built = build_sql(plan, permitted_signals)?;
    let mode = built.mode;
    let mut query: BoxedSqlQuery<'static, Pg, SqlQuery> =
        sql_query(rewrite_placeholders(&built.sql)).into_boxed::<Pg>();
    for bind in built.binds {
        query = bind_sql_param(query, bind)?;
    }

    match mode {
        Mode::Data => {
            let rows: Vec<OtelServiceRow> = query
                .load::<OtelServiceRow>(conn)
                .await
                .map_err(|err| ServiceError::Internal(err.into()))?;
            Ok(rows.into_iter().map(OtelServiceRow::into_json).collect())
        }
        Mode::Stats => {
            let rows: Vec<StatsPayload> = query
                .load::<StatsPayload>(conn)
                .await
                .map_err(|err| ServiceError::Internal(err.into()))?;
            Ok(rows
                .into_iter()
                .map(|row| Value::from(row.payload))
                .collect())
        }
    }
}

pub(super) fn to_sql_and_params(
    plan: &QueryPlan,
    permitted_signals: Option<&[String]>,
) -> Result<(String, Vec<BindParam>)> {
    let built = build_sql(plan, permitted_signals)?;
    Ok((rewrite_placeholders(&built.sql), built.binds))
}

fn build_sql(plan: &QueryPlan, permitted_signals: Option<&[String]>) -> Result<BuiltSql> {
    if !matches!(plan.entity, Entity::OtelServices) {
        return Err(ServiceError::InvalidRequest(
            "entity not supported by otel_services query".into(),
        ));
    }

    // Access first: without a trusted permitted set nothing else about the
    // query is evaluated.
    let signals = effective_signals(&plan.filters, permitted_signals)?;

    if plan.downsample.is_some() {
        return Err(ServiceError::InvalidRequest(
            "otel_services does not support downsampling".into(),
        ));
    }
    if plan.rollup_stats.is_some() {
        return Err(ServiceError::InvalidRequest(
            "otel_services does not support rollup_stats".into(),
        ));
    }
    let stats_alias = parse_stats_alias(plan)?;

    let last_seen = last_seen_expr(&signals);
    let mut where_parts = vec![presence_clause(&signals)];
    let mut binds = Vec::new();

    if let Some(TimeRange { start, end }) = &plan.time_range {
        where_parts.push(format!("{last_seen} >= ? AND {last_seen} <= ?"));
        binds.push(BindParam::timestamptz(*start));
        binds.push(BindParam::timestamptz(*end));
    }

    for filter in &plan.filters {
        match filter.field.as_str() {
            // Resolved by `effective_signals`.
            "signal" => {}
            "service_name" => where_parts.push(service_name_condition(filter, &mut binds)?),
            other => {
                return Err(ServiceError::InvalidRequest(format!(
                    "unsupported filter field for otel_services: '{other}'"
                )));
            }
        }
    }

    let where_sql = where_parts.join(" AND ");

    if let Some(alias) = stats_alias {
        return Ok(BuiltSql {
            sql: format!(
                "SELECT jsonb_build_object('{alias}', COUNT(*)) AS payload \
                 FROM {TABLE} WHERE {where_sql}"
            ),
            binds,
            mode: Mode::Stats,
        });
    }

    let per_signal = ALL_SIGNALS
        .iter()
        .map(|signal| {
            if signals.contains(signal) {
                format!("{} AS {}", signal.column(), signal.output())
            } else {
                format!("NULL::timestamptz AS {}", signal.output())
            }
        })
        .collect::<Vec<_>>()
        .join(", ");

    let order_sql = order_sql(&plan.order, &last_seen)?;
    binds.push(BindParam::Int(plan.limit));
    binds.push(BindParam::Int(plan.offset));

    Ok(BuiltSql {
        sql: format!(
            "SELECT service_name, {signals_sql} AS signals, {last_seen} AS last_seen, \
             {per_signal} FROM {TABLE} WHERE {where_sql} ORDER BY {order_sql} \
             LIMIT ? OFFSET ?",
            signals_sql = signals_expr(&signals),
        ),
        binds,
        mode: Mode::Data,
    })
}

/// The signals this query may read: the requested `signal:` values, or the
/// permitted set when there is no `signal:`. Returned sorted and deduplicated.
fn effective_signals(filters: &[Filter], permitted: Option<&[String]>) -> Result<Vec<Signal>> {
    let permitted = permitted.ok_or_else(|| {
        ServiceError::Forbidden(
            "otel_services requires a trusted permitted-signal set, and none was supplied".into(),
        )
    })?;
    // Unknown entries grant nothing; they can only narrow the set.
    let mut permitted: Vec<Signal> = permitted.iter().filter_map(|s| Signal::parse(s)).collect();
    permitted.sort();
    permitted.dedup();

    let mut signal_filters = filters.iter().filter(|filter| filter.field == "signal");
    let requested = match (signal_filters.next(), signal_filters.next()) {
        (None, _) => None,
        (Some(_), Some(_)) => {
            return Err(ServiceError::InvalidRequest(
                "signal may appear at most once; use a list such as signal:(logs,traces)".into(),
            ));
        }
        (Some(filter), None) => Some(requested_signals(filter)?),
    };

    let effective = match requested {
        None => permitted,
        Some(requested) => {
            if let Some(denied) = requested.iter().find(|signal| !permitted.contains(signal)) {
                return Err(ServiceError::Forbidden(format!(
                    "signal '{}' is not permitted",
                    denied.name()
                )));
            }
            requested
        }
    };

    if effective.is_empty() {
        return Err(ServiceError::Forbidden(
            "no observability signal is permitted".into(),
        ));
    }
    Ok(effective)
}

fn requested_signals(filter: &Filter) -> Result<Vec<Signal>> {
    let raw: Vec<&str> = match filter.op {
        FilterOp::Eq => vec![filter.value.as_scalar()?],
        FilterOp::In => filter.value.as_list()?.iter().map(String::as_str).collect(),
        FilterOp::NotEq | FilterOp::NotIn | FilterOp::NotLike => {
            return Err(ServiceError::InvalidRequest(
                "negated signal filters are not supported".into(),
            ));
        }
        _ => {
            return Err(ServiceError::InvalidRequest(format!(
                "unsupported operator for signal filter: {:?}",
                filter.op
            )));
        }
    };

    let mut signals = raw
        .into_iter()
        .map(|value| {
            Signal::parse(value).ok_or_else(|| {
                ServiceError::InvalidRequest(format!(
                    "unknown signal '{value}' (expected logs, traces or metrics)"
                ))
            })
        })
        .collect::<Result<Vec<_>>>()?;
    signals.sort();
    signals.dedup();
    Ok(signals)
}

fn presence_clause(signals: &[Signal]) -> String {
    let parts = signals
        .iter()
        .map(|signal| format!("{} IS NOT NULL", signal.column()))
        .collect::<Vec<_>>();
    format!("({})", parts.join(" OR "))
}

/// `GREATEST` ignores NULLs, so this is the most recent effective signal and is
/// NULL only when none of them has been seen, which `presence_clause` excludes.
fn last_seen_expr(signals: &[Signal]) -> String {
    match signals {
        [only] => only.column().to_string(),
        _ => format!(
            "GREATEST({})",
            signals
                .iter()
                .map(|signal| signal.column())
                .collect::<Vec<_>>()
                .join(", ")
        ),
    }
}

fn signals_expr(signals: &[Signal]) -> String {
    let parts = signals
        .iter()
        .map(|signal| {
            format!(
                "CASE WHEN {} IS NOT NULL THEN '{}' END",
                signal.column(),
                signal.name()
            )
        })
        .collect::<Vec<_>>();
    format!("array_remove(ARRAY[{}]::text[], NULL)", parts.join(", "))
}

fn service_name_condition(filter: &Filter, binds: &mut Vec<BindParam>) -> Result<String> {
    let column = "service_name";
    let clause = match filter.op {
        FilterOp::Eq => {
            binds.push(BindParam::Text(filter.value.as_scalar()?.to_string()));
            format!("{column} = ?")
        }
        FilterOp::NotEq => {
            binds.push(BindParam::Text(filter.value.as_scalar()?.to_string()));
            format!("{column} <> ?")
        }
        FilterOp::Like => {
            binds.push(BindParam::Text(filter.value.as_scalar()?.to_string()));
            format!("{column} ILIKE ?")
        }
        FilterOp::NotLike => {
            binds.push(BindParam::Text(filter.value.as_scalar()?.to_string()));
            format!("{column} NOT ILIKE ?")
        }
        FilterOp::In => {
            binds.push(BindParam::TextArray(filter.value.as_list()?.to_vec()));
            format!("{column} = ANY(?)")
        }
        FilterOp::NotIn => {
            binds.push(BindParam::TextArray(filter.value.as_list()?.to_vec()));
            format!("{column} <> ALL(?)")
        }
        _ => {
            return Err(ServiceError::InvalidRequest(format!(
                "unsupported operator for otel_services service_name filter: {:?}",
                filter.op
            )));
        }
    };
    Ok(clause)
}

fn order_sql(order: &[OrderClause], last_seen: &str) -> Result<String> {
    let mut clauses = Vec::new();
    let mut orders_by_name = false;

    for clause in order {
        let column = match clause.field.as_str() {
            "last_seen" => last_seen,
            "service_name" => {
                orders_by_name = true;
                "service_name"
            }
            other => {
                return Err(ServiceError::InvalidRequest(format!(
                    "unsupported sort field for otel_services: '{other}' \
                     (expected service_name or last_seen)"
                )));
            }
        };
        let direction = match clause.direction {
            OrderDirection::Asc => "ASC",
            OrderDirection::Desc => "DESC",
        };
        clauses.push(format!("{column} {direction}"));
    }

    if clauses.is_empty() {
        clauses.push(format!("{last_seen} DESC"));
    }
    // service_name is the key, so it makes every page boundary deterministic.
    if !orders_by_name {
        clauses.push("service_name ASC".to_string());
    }
    Ok(clauses.join(", "))
}

/// `stats:"count() as <alias>"` is the only aggregation.
fn parse_stats_alias(plan: &QueryPlan) -> Result<Option<String>> {
    let raw = match plan.stats.as_ref().map(|stats| stats.as_raw().trim()) {
        Some(raw) if !raw.is_empty() => raw,
        _ => return Ok(None),
    };

    let tokens: Vec<&str> = raw.split_whitespace().collect();
    let [expr, as_kw, alias] = tokens.as_slice() else {
        return Err(ServiceError::InvalidRequest(
            "otel_services stats only support 'count() as <alias>'".into(),
        ));
    };
    if !expr.eq_ignore_ascii_case("count()") || !as_kw.eq_ignore_ascii_case("as") {
        return Err(ServiceError::InvalidRequest(
            "otel_services stats only support 'count() as <alias>'".into(),
        ));
    }

    let alias = alias.trim_matches('"').trim_matches('\'').to_lowercase();
    if alias.is_empty()
        || alias
            .chars()
            .any(|ch| !ch.is_ascii_alphanumeric() && ch != '_')
    {
        return Err(ServiceError::InvalidRequest(
            "stats alias must be alphanumeric".into(),
        ));
    }
    Ok(Some(alias))
}

fn rewrite_placeholders(sql: &str) -> String {
    let mut out = String::with_capacity(sql.len() + 8);
    let mut idx = 1u32;
    for ch in sql.chars() {
        if ch == '?' {
            out.push('$');
            out.push_str(&idx.to_string());
            idx += 1;
        } else {
            out.push(ch);
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{
        config::AppConfig,
        parser,
        query::{QueryDirection, QueryRequest, build_query_plan, translate_request},
    };

    fn config() -> AppConfig {
        AppConfig::embedded("postgres://srql-test".to_string())
    }

    fn request(query: &str, permitted: Option<&[&str]>) -> QueryRequest {
        QueryRequest {
            query: query.to_string(),
            limit: None,
            cursor: None,
            direction: QueryDirection::Next,
            mode: None,
            permitted_signals: permitted
                .map(|signals| signals.iter().map(|signal| signal.to_string()).collect()),
        }
    }

    fn translate(query: &str, permitted: Option<&[&str]>) -> Result<(String, Vec<BindParam>)> {
        let response = translate_request(&config(), request(query, permitted))?;
        Ok((response.sql, response.params))
    }

    fn translate_ok(query: &str, permitted: &[&str]) -> (String, Vec<BindParam>) {
        translate(query, Some(permitted)).unwrap_or_else(|err| panic!("{query}: {err}"))
    }

    fn plan(query: &str) -> QueryPlan {
        let ast = parser::parse(query).expect("parse");
        build_query_plan(&config(), &request(query, None), ast).expect("plan")
    }

    const ALL: &[&str] = &["logs", "traces", "metrics"];
    const LOGS_ONLY: &[&str] = &["logs"];

    fn assert_forbidden(result: Result<(String, Vec<BindParam>)>, query: &str) {
        match result {
            Err(err @ ServiceError::Forbidden(_)) => {
                assert!(err.to_string().starts_with("forbidden: "), "{err}");
            }
            other => panic!("{query}: expected Forbidden, got {other:?}"),
        }
    }

    fn assert_invalid(result: Result<(String, Vec<BindParam>)>, query: &str) {
        assert!(
            matches!(result, Err(ServiceError::InvalidRequest(_))),
            "{query}: expected InvalidRequest, got {result:?}"
        );
    }

    /// The stored service-wide `last_seen_at` spans every signal; it must never
    /// be read by a query that is narrowed to some of them.
    fn assert_no_service_wide_last_seen(sql: &str) {
        let stripped = sql
            .replace("logs_last_seen_at", "")
            .replace("traces_last_seen_at", "")
            .replace("metrics_last_seen_at", "");
        assert!(!stripped.contains("last_seen_at"), "{sql}");
    }

    #[test]
    fn unscoped_query_uses_the_whole_permitted_set() {
        let (sql, params) = translate_ok("in:otel_services", ALL);
        assert_eq!(
            sql,
            "SELECT service_name, array_remove(ARRAY[\
             CASE WHEN logs_last_seen_at IS NOT NULL THEN 'logs' END, \
             CASE WHEN traces_last_seen_at IS NOT NULL THEN 'traces' END, \
             CASE WHEN metrics_last_seen_at IS NOT NULL THEN 'metrics' END]::text[], NULL) \
             AS signals, \
             GREATEST(logs_last_seen_at, traces_last_seen_at, metrics_last_seen_at) AS last_seen, \
             logs_last_seen_at AS logs_last_seen, traces_last_seen_at AS traces_last_seen, \
             metrics_last_seen_at AS metrics_last_seen \
             FROM platform.otel_service_catalog \
             WHERE (logs_last_seen_at IS NOT NULL OR traces_last_seen_at IS NOT NULL \
             OR metrics_last_seen_at IS NOT NULL) \
             ORDER BY GREATEST(logs_last_seen_at, traces_last_seen_at, metrics_last_seen_at) DESC, \
             service_name ASC LIMIT $1 OFFSET $2"
        );
        assert!(matches!(
            params.as_slice(),
            [BindParam::Int(DEFAULT_LIMIT), BindParam::Int(0)]
        ));
        assert_no_service_wide_last_seen(&sql);
    }

    #[test]
    fn logs_only_caller_never_reads_other_signals() {
        let (sql, _) = translate_ok("in:otel_services time:last_2h", LOGS_ONLY);
        assert!(
            sql.contains("SELECT service_name, array_remove(ARRAY[CASE WHEN logs_last_seen_at IS NOT NULL THEN 'logs' END]::text[], NULL) AS signals, logs_last_seen_at AS last_seen, logs_last_seen_at AS logs_last_seen, NULL::timestamptz AS traces_last_seen, NULL::timestamptz AS metrics_last_seen"),
            "{sql}"
        );
        assert!(
            sql.contains(
                "WHERE (logs_last_seen_at IS NOT NULL) AND logs_last_seen_at >= $1 AND logs_last_seen_at <= $2"
            ),
            "{sql}"
        );
        assert!(
            sql.contains("ORDER BY logs_last_seen_at DESC, service_name ASC"),
            "{sql}"
        );
        assert!(!sql.contains("traces_last_seen_at"), "{sql}");
        assert!(!sql.contains("metrics_last_seen_at"), "{sql}");
        assert_no_service_wide_last_seen(&sql);
    }

    #[test]
    fn signal_filter_narrows_within_the_permitted_set() {
        let (sql, _) = translate_ok("in:otel_services signal:traces", ALL);
        assert!(sql.contains("traces_last_seen_at AS last_seen"), "{sql}");
        assert!(sql.contains("NULL::timestamptz AS logs_last_seen"), "{sql}");
        assert!(
            sql.contains("NULL::timestamptz AS metrics_last_seen"),
            "{sql}"
        );
        assert!(
            sql.contains("WHERE (traces_last_seen_at IS NOT NULL)"),
            "{sql}"
        );

        let (sql, _) = translate_ok("in:otel_services signal:(metrics,logs)", ALL);
        assert!(
            sql.contains("GREATEST(logs_last_seen_at, metrics_last_seen_at) AS last_seen"),
            "{sql}"
        );
        assert!(
            sql.contains(
                "WHERE (logs_last_seen_at IS NOT NULL OR metrics_last_seen_at IS NOT NULL)"
            ),
            "{sql}"
        );
        assert!(
            sql.contains("NULL::timestamptz AS traces_last_seen"),
            "{sql}"
        );
    }

    #[test]
    fn differently_cased_keys_and_values_resolve_identically() {
        let lower = translate_ok("in:otel_services signal:traces", ALL);
        let upper = translate_ok("in:otel_services SIGNAL:TRACES", ALL);
        assert_eq!(lower.0, upper.0);

        assert_forbidden(
            translate("in:otel_services SIGNAL:traces", Some(LOGS_ONLY)),
            "SIGNAL:traces",
        );
    }

    #[test]
    fn service_name_filter_forms() {
        let cases = [
            ("service_name:checkout", "service_name = $1"),
            ("!service_name:checkout", "service_name <> $1"),
            ("service_name:%pay%", "service_name ILIKE $1"),
            ("!service_name:%pay%", "service_name NOT ILIKE $1"),
            ("service_name:(checkout,billing)", "service_name = ANY($1)"),
            (
                "!service_name:(checkout,billing)",
                "service_name <> ALL($1)",
            ),
        ];
        for (filter, expected) in cases {
            let query = format!("in:otel_services {filter}");
            let (sql, params) = translate_ok(&query, LOGS_ONLY);
            assert!(sql.contains(expected), "{query}: {sql}");
            match (&params[0], filter.contains('(')) {
                (BindParam::TextArray(values), true) => {
                    assert_eq!(values, &["checkout".to_string(), "billing".to_string()]);
                }
                (BindParam::Text(_), false) => {}
                (other, _) => panic!("{query}: unexpected first bind {other:?}"),
            }
        }
    }

    #[test]
    fn a_percent_inside_a_list_value_stays_literal() {
        let (sql, params) = translate_ok(r#"in:otel_services service_name:("50%off")"#, ALL);
        assert!(sql.contains("service_name = ANY($1)"), "{sql}");
        assert!(!sql.contains("ILIKE"), "{sql}");
        assert!(
            matches!(&params[0], BindParam::TextArray(values) if values == &["50%off".to_string()])
        );
    }

    #[test]
    fn sort_fields() {
        let (sql, _) = translate_ok("in:otel_services sort:service_name:asc", LOGS_ONLY);
        assert!(sql.contains("ORDER BY service_name ASC LIMIT"), "{sql}");

        let (sql, _) = translate_ok("in:otel_services sort:last_seen:asc", LOGS_ONLY);
        assert!(
            sql.contains("ORDER BY logs_last_seen_at ASC, service_name ASC LIMIT"),
            "{sql}"
        );

        assert_invalid(
            translate("in:otel_services sort:first_seen:desc", Some(ALL)),
            "sort:first_seen",
        );
    }

    #[test]
    fn limit_defaults_to_50_and_clamps_at_500() {
        assert_eq!(plan("in:otel_services").limit, DEFAULT_LIMIT);
        assert_eq!(plan("in:otel_services limit:20").limit, 20);
        assert_eq!(plan("in:otel_services limit:5000").limit, MAX_LIMIT);

        let (_, params) = translate_ok("in:otel_services limit:5000", ALL);
        assert!(matches!(
            params.as_slice(),
            [BindParam::Int(MAX_LIMIT), BindParam::Int(0)]
        ));
    }

    #[test]
    fn count_stats_share_the_row_filters() {
        let (sql, params) = translate_ok(
            r#"in:otel_services signal:traces service_name:%pay% stats:"count() as total""#,
            ALL,
        );
        assert_eq!(
            sql,
            "SELECT jsonb_build_object('total', COUNT(*)) AS payload \
             FROM platform.otel_service_catalog \
             WHERE (traces_last_seen_at IS NOT NULL) AND service_name ILIKE $1"
        );
        assert!(matches!(params.as_slice(), [BindParam::Text(v)] if v == "%pay%"));

        assert_invalid(
            translate(r#"in:otel_services stats:"sum(x) as total""#, Some(ALL)),
            "sum stats",
        );
    }

    #[test]
    fn missing_permitted_set_fails_closed() {
        for query in [
            "in:otel_services",
            "in:otel_services signal:logs",
            r#"in:otel_services stats:"count() as total""#,
        ] {
            assert_forbidden(translate(query, None), query);
        }
    }

    #[test]
    fn signals_outside_the_permitted_set_are_forbidden() {
        for query in [
            "in:otel_services signal:traces",
            "in:otel_services signal:(logs,traces)",
        ] {
            assert_forbidden(translate(query, Some(LOGS_ONLY)), query);
        }
        assert_forbidden(translate("in:otel_services", Some(&[])), "empty set");
        // Unknown permitted entries grant nothing.
        assert_forbidden(
            translate("in:otel_services", Some(&["everything"])),
            "unknown permitted entry",
        );
    }

    #[test]
    fn malformed_signal_forms_are_invalid_requests() {
        for query in [
            "in:otel_services signal:logs signal:traces",
            "in:otel_services signal:logs signal:logs",
            "in:otel_services !signal:logs",
            "in:otel_services !signal:(logs,traces)",
            "in:otel_services signal:spans",
            "in:otel_services signal:(logs,spans)",
            "in:otel_services signal:>logs",
        ] {
            assert_invalid(translate(query, Some(LOGS_ONLY)), query);
        }
    }

    #[test]
    fn unsupported_filters_and_shapes_are_rejected() {
        for query in [
            "in:otel_services first_seen:2026-01-01",
            "in:otel_services service_name:>a",
            "in:otel_services bucket:5m",
            "in:otel_services rollup_stats:summary",
        ] {
            assert_invalid(translate(query, Some(ALL)), query);
        }
    }

    #[test]
    fn standalone_server_json_cannot_supply_the_permitted_set() {
        let body = r#"{"query":"in:otel_services signal:logs","permitted_signals":["logs","traces","metrics"]}"#;
        let request: QueryRequest = serde_json::from_str(body).expect("deserialize");
        assert!(request.permitted_signals.is_none());

        let result =
            translate_request(&config(), request).map(|response| (response.sql, response.params));
        assert_forbidden(result, "json body");

        let reserialized = serde_json::to_value(QueryRequest {
            permitted_signals: Some(vec!["logs".into()]),
            ..request_from_json(body)
        })
        .expect("serialize");
        assert!(reserialized.get("permitted_signals").is_none());
    }

    fn request_from_json(body: &str) -> QueryRequest {
        serde_json::from_str(body).expect("deserialize")
    }

    #[test]
    fn warehouse_modes_never_compile_otel_services() {
        for mode in ["starrocks", "starrocks_raw"] {
            let mut req = request("in:otel_services", Some(ALL));
            req.mode = Some(mode.to_string());
            let result = translate_request(&config(), req);
            assert!(
                matches!(result, Err(ServiceError::NotImplemented(_))),
                "{mode}: {result:?}"
            );
        }
    }

    #[test]
    fn parser_accepts_only_the_otel_services_name() {
        assert!(matches!(
            plan("in:otel_services").entity,
            Entity::OtelServices
        ));
        assert!(parser::parse("in:observability_services").is_err());
        // Monitored service checks keep their own entity, table and access.
        assert!(matches!(
            parser::parse("in:services").expect("parse").entity,
            Entity::Services
        ));
        let (sql, _) = translate("in:services", None).expect("in:services needs no signal set");
        assert!(sql.contains("service_status"), "{sql}");
        assert!(!sql.contains("otel_service_catalog"), "{sql}");
    }
}
