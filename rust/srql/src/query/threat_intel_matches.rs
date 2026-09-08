//! SRQL `in:threat_intel_matches` — current IP/CIDR cache-to-indicator memberships.

use super::{bind_sql_param, BindParam, QueryPlan};
use crate::{
    error::{Result, ServiceError},
    jsonb::DbJson,
    parser::{Entity, Filter, FilterOp, OrderClause, OrderDirection, StatsSpec},
    time::TimeRange,
};
use diesel::deserialize::QueryableByName;
use diesel::pg::Pg;
use diesel::query_builder::{BoxedSqlQuery, SqlQuery};
use diesel::sql_query;
use diesel::sql_types::Jsonb;
use diesel_async::{AsyncPgConnection, RunQueryDsl};
use serde_json::Value;

const LIVE_CACHE: &str =
    "c.matched AND c.expires_at > NOW() AND (i.expires_at IS NULL OR i.expires_at > NOW())";
const STALE_CACHE: &str = "c.matched AND (c.expires_at <= NOW() OR i.expires_at <= NOW())";
const CONTAINMENT: &str = "c.ip::inet <<= i.indicator";

#[derive(Debug, QueryableByName)]
#[diesel(check_for_backend(diesel::pg::Pg))]
struct JsonPayload {
    #[diesel(sql_type = Jsonb)]
    payload: DbJson,
}

struct BuiltSql {
    sql: String,
    binds: Vec<BindParam>,
}

struct CountStats {
    alias: String,
    group_fields: Vec<String>,
}

pub(super) async fn execute(conn: &mut AsyncPgConnection, plan: &QueryPlan) -> Result<Vec<Value>> {
    // Execution goes through `to_sql_and_params`, not around it, so the SQL that
    // runs IS the SQL translate returns. Building it twice let the execute side
    // send the `?` form straight to Diesel, which does not translate `?` for
    // Postgres: `SqlQuery::walk_ast` pushes the query text verbatim and each
    // bind then appends its own `$n`. Because `?` is a valid Postgres operator
    // character (jsonb containment), the result was not an "unknown placeholder"
    // error but a syntax error at the NEXT token, naming neither the placeholder
    // nor the column. Measured: `ep.ip = ? ORDER BY` -> `syntax error at or near
    // "ORDER"`.
    let query = execution_query(plan)?;
    let rows: Vec<JsonPayload> = query
        .load::<JsonPayload>(conn)
        .await
        .map_err(|err| ServiceError::Internal(err.into()))?;
    Ok(rows
        .into_iter()
        .map(|row| serde_json::Value::from(row.payload))
        .collect())
}

pub(super) fn execution_query(plan: &QueryPlan) -> Result<BoxedSqlQuery<'static, Pg, SqlQuery>> {
    let (sql, binds) = to_sql_and_params(plan)?;
    let mut query = sql_query(sql).into_boxed::<Pg>();

    for bind in binds {
        query = bind_sql_param(query, bind)?;
    }

    Ok(query)
}

pub(super) fn to_sql_and_params(plan: &QueryPlan) -> Result<(String, Vec<BindParam>)> {
    let built = build_sql(plan)?;
    Ok((rewrite_placeholders(&built.sql), built.binds))
}

fn ensure_entity(plan: &QueryPlan) -> Result<()> {
    if !matches!(plan.entity, Entity::ThreatIntelMatches) {
        return Err(ServiceError::InvalidRequest(
            "entity not supported by threat_intel_matches query".into(),
        ));
    }
    if plan.downsample.is_some() {
        return Err(ServiceError::InvalidRequest(
            "threat_intel_matches does not support downsample queries".into(),
        ));
    }
    if plan.rollup_stats.is_some() {
        return Err(ServiceError::InvalidRequest(
            "threat_intel_matches does not support rollup_stats".into(),
        ));
    }
    Ok(())
}

fn build_sql(plan: &QueryPlan) -> Result<BuiltSql> {
    ensure_entity(plan)?;
    let stale = stale_requested(&plan.filters)?;
    let mut where_parts = vec![
        if stale {
            STALE_CACHE.to_string()
        } else {
            LIVE_CACHE.to_string()
        },
        CONTAINMENT.to_string(),
    ];
    let mut binds = Vec::new();

    if let Some(TimeRange { start, end }) = &plan.time_range {
        where_parts.push("c.looked_up_at >= ? AND c.looked_up_at <= ?".into());
        binds.push(BindParam::timestamptz(*start));
        binds.push(BindParam::timestamptz(*end));
    }

    for filter in &plan.filters {
        if matches!(filter.field.as_str(), "stale" | "status") {
            continue;
        }
        where_parts.push(filter_condition(filter, &mut binds)?);
    }

    let stats = parse_count_stats(plan.stats.as_ref())?;
    let from_sql = "FROM platform.ip_threat_intel_cache c \
         JOIN platform.threat_intel_indicators i ON c.ip::inet <<= i.indicator";
    let where_sql = format!(" WHERE {}", where_parts.join(" AND "));

    if let Some(stats) = stats {
        let groups = stats
            .group_fields
            .iter()
            .map(|field| {
                let expr = group_expr(field)?;
                Ok((field.clone(), expr))
            })
            .collect::<Result<Vec<_>>>()?;
        let select = if groups.is_empty() {
            format!(
                "SELECT jsonb_build_object('{}', COUNT(*)) AS payload",
                stats.alias
            )
        } else {
            let pairs = groups
                .iter()
                .map(|(key, expr)| format!("'{key}', {expr}"))
                .collect::<Vec<_>>()
                .join(", ");
            format!(
                "SELECT jsonb_build_object({pairs}, '{}', COUNT(*)) AS payload",
                stats.alias
            )
        };
        let group_by = if groups.is_empty() {
            String::new()
        } else {
            format!(
                " GROUP BY {}",
                groups
                    .iter()
                    .map(|(_, expr)| expr.to_string())
                    .collect::<Vec<_>>()
                    .join(", ")
            )
        };
        binds.push(BindParam::Int(plan.limit));
        binds.push(BindParam::Int(plan.offset));
        return Ok(BuiltSql {
            sql: format!("{select} {from_sql}{where_sql}{group_by} LIMIT ? OFFSET ?"),
            binds,
        });
    }

    binds.push(BindParam::Int(plan.limit));
    binds.push(BindParam::Int(plan.offset));
    Ok(BuiltSql {
        sql: format!(
            "SELECT jsonb_build_object(\
               'match_id', c.ip || ':' || i.id::text, \
               'match_kind', 'current', \
               'observed_ip', c.ip, \
               'indicator_id', i.id, \
               'indicator', host(i.indicator)::text || '/' || masklen(i.indicator)::text, \
               'indicator_type', i.indicator_type, \
               'source', i.source, \
               'label', i.label, \
               'severity', i.severity, \
               'confidence', i.confidence, \
               'evaluated_at', c.looked_up_at, \
               'cache_expires_at', c.expires_at, \
               'indicator_first_seen_at', i.first_seen_at, \
               'indicator_last_seen_at', i.last_seen_at, \
               'indicator_expires_at', i.expires_at, \
               'indicator_match_count', c.match_count, \
               'stale', (c.expires_at <= NOW() OR (i.expires_at IS NOT NULL AND i.expires_at <= NOW()))\
             ) AS payload \
             {from_sql}{where_sql}{} LIMIT ? OFFSET ?",
            order_sql(&plan.order)?
        ),
        binds,
    })
}

fn stale_requested(filters: &[Filter]) -> Result<bool> {
    for filter in filters {
        match filter.field.as_str() {
            "stale" => {
                if !matches!(filter.op, FilterOp::Eq) {
                    return Err(ServiceError::InvalidRequest(
                        "stale only supports equality".into(),
                    ));
                }
                return parse_bool(filter.value.as_scalar()?);
            }
            "status" => {
                if !matches!(filter.op, FilterOp::Eq) {
                    return Err(ServiceError::InvalidRequest(
                        "status only supports equality".into(),
                    ));
                }
                return match filter.value.as_scalar()?.to_ascii_lowercase().as_str() {
                    "stale" | "expired" => Ok(true),
                    "current" | "active" | "live" => Ok(false),
                    other => Err(ServiceError::InvalidRequest(format!(
                        "unsupported threat match status '{other}'"
                    ))),
                };
            }
            _ => {}
        }
    }
    Ok(false)
}

fn filter_condition(filter: &Filter, binds: &mut Vec<BindParam>) -> Result<String> {
    match filter.field.as_str() {
        "observed_ip" | "ip" => text_condition("c.ip", filter, binds),
        "source" => text_condition("i.source", filter, binds),
        "label" => text_condition("i.label", filter, binds),
        "indicator_id" => uuid_eq("i.id", filter, binds),
        "indicator" | "threat_indicator" => indicator_condition(filter, binds),
        "indicator_type" => text_condition("i.indicator_type", filter, binds),
        "match_kind" => {
            if !matches!(filter.op, FilterOp::Eq) {
                return Err(ServiceError::InvalidRequest(
                    "match_kind only supports equality".into(),
                ));
            }
            let value = filter.value.as_scalar()?.to_ascii_lowercase();
            if value != "current" {
                return Err(ServiceError::InvalidRequest(
                    "threat_intel_matches only returns match_kind:current".into(),
                ));
            }
            Ok("TRUE".into())
        }
        "severity" => int_condition("i.severity", filter, binds),
        "confidence" => int_condition("i.confidence", filter, binds),
        other => Err(ServiceError::InvalidRequest(format!(
            "unsupported filter field for threat_intel_matches: '{other}'"
        ))),
    }
}

fn indicator_condition(filter: &Filter, binds: &mut Vec<BindParam>) -> Result<String> {
    if !matches!(filter.op, FilterOp::Eq | FilterOp::In) {
        return Err(ServiceError::InvalidRequest(
            "indicator filter only supports equality and membership".into(),
        ));
    }
    let values = match &filter.value {
        crate::parser::FilterValue::Scalar(value) => vec![normalize_ip_or_cidr(value)?],
        crate::parser::FilterValue::List(values) => values
            .iter()
            .map(|value| normalize_ip_or_cidr(value))
            .collect::<Result<Vec<_>>>()?,
    };
    if values.is_empty() {
        return Ok("TRUE".into());
    }
    let cidr_like = values.iter().any(|value| value.contains('/'));
    if values.len() == 1 {
        let value = values.into_iter().next().unwrap();
        binds.push(BindParam::Text(value));
        if cidr_like {
            Ok("i.indicator = ?::cidr".into())
        } else {
            Ok("i.indicator >>= ?::inet".into())
        }
    } else {
        binds.push(BindParam::TextArray(values));
        if cidr_like {
            Ok("i.indicator = ANY(?::cidr[])".into())
        } else {
            Ok("i.indicator >>= ANY(?::inet[])".into())
        }
    }
}

fn normalize_ip_or_cidr(raw: &str) -> Result<String> {
    let trimmed = raw.trim();
    if trimmed.contains('/') {
        return super::flows::normalize_cidr_literal(trimmed);
    }
    trimmed
        .parse::<std::net::IpAddr>()
        .map(|ip| ip.to_string())
        .map_err(|_| {
            ServiceError::InvalidRequest(format!(
                "threat indicator must be an IP or CIDR, got '{raw}'"
            ))
        })
}

fn text_condition(column: &str, filter: &Filter, binds: &mut Vec<BindParam>) -> Result<String> {
    match filter.op {
        FilterOp::Eq => {
            binds.push(BindParam::Text(filter.value.as_scalar()?.to_string()));
            Ok(format!("{column} = ?"))
        }
        FilterOp::NotEq => {
            binds.push(BindParam::Text(filter.value.as_scalar()?.to_string()));
            Ok(format!("({column} IS NULL OR {column} <> ?)"))
        }
        FilterOp::Like => {
            binds.push(BindParam::Text(filter.value.as_scalar()?.to_string()));
            Ok(format!("{column} ILIKE ?"))
        }
        FilterOp::In => {
            let values = filter.value.as_list()?.to_vec();
            if values.is_empty() {
                Ok("TRUE".into())
            } else {
                binds.push(BindParam::TextArray(values));
                Ok(format!("{column} = ANY(?)"))
            }
        }
        _ => Err(ServiceError::InvalidRequest(format!(
            "unsupported operator for {column}"
        ))),
    }
}

fn int_condition(column: &str, filter: &Filter, binds: &mut Vec<BindParam>) -> Result<String> {
    let operator = match filter.op {
        FilterOp::Eq => "=",
        FilterOp::NotEq => "<>",
        FilterOp::Gt => ">",
        FilterOp::Gte => ">=",
        FilterOp::Lt => "<",
        FilterOp::Lte => "<=",
        _ => {
            return Err(ServiceError::InvalidRequest(format!(
                "{column} requires a scalar comparison"
            )));
        }
    };
    let value = filter
        .value
        .as_scalar()?
        .parse::<i64>()
        .map_err(|_| ServiceError::InvalidRequest(format!("expected integer for {column}")))?;
    binds.push(BindParam::Int(value));
    Ok(format!("{column} {operator} ?"))
}

fn uuid_eq(column: &str, filter: &Filter, binds: &mut Vec<BindParam>) -> Result<String> {
    if !matches!(filter.op, FilterOp::Eq) {
        return Err(ServiceError::InvalidRequest(format!(
            "{column} only supports equality"
        )));
    }
    let value = uuid::Uuid::parse_str(filter.value.as_scalar()?)
        .map_err(|_| ServiceError::InvalidRequest(format!("invalid uuid for {column}")))?;
    binds.push(BindParam::Uuid(value));
    Ok(format!("{column} = ?"))
}

fn parse_bool(raw: &str) -> Result<bool> {
    match raw.to_ascii_lowercase().as_str() {
        "true" | "t" | "yes" | "y" | "1" => Ok(true),
        "false" | "f" | "no" | "n" | "0" => Ok(false),
        other => Err(ServiceError::InvalidRequest(format!(
            "invalid boolean value '{other}'"
        ))),
    }
}

fn parse_count_stats(stats: Option<&StatsSpec>) -> Result<Option<CountStats>> {
    let Some(stats) = stats else {
        return Ok(None);
    };
    let tokens: Vec<&str> = stats.as_raw().split_whitespace().collect();
    if tokens.len() < 3
        || !tokens[0].eq_ignore_ascii_case("count()")
        || !tokens[1].eq_ignore_ascii_case("as")
    {
        return Err(ServiceError::InvalidRequest(
            "threat_intel_matches stats only support count() as <alias> [by <field>]".into(),
        ));
    }
    let alias = tokens[2]
        .trim_matches('"')
        .trim_matches('\'')
        .to_ascii_lowercase();
    let group_fields = if tokens.len() >= 5 {
        if !tokens[3].eq_ignore_ascii_case("by") {
            return Err(ServiceError::InvalidRequest(
                "expected 'by <field>' after stats alias".into(),
            ));
        }
        tokens[4]
            .split(',')
            .map(|field| field.trim().to_string())
            .filter(|field| !field.is_empty())
            .collect()
    } else if tokens.len() > 3 {
        return Err(ServiceError::InvalidRequest(
            "expected 'by <field>' after stats alias".into(),
        ));
    } else {
        Vec::new()
    };
    Ok(Some(CountStats {
        alias,
        group_fields,
    }))
}

fn group_expr(field: &str) -> Result<&'static str> {
    match field {
        "source" => Ok("i.source"),
        "severity" => Ok("i.severity"),
        "observed_ip" | "ip" => Ok("c.ip"),
        "indicator_type" => Ok("i.indicator_type"),
        other => Err(ServiceError::InvalidRequest(format!(
            "unsupported stats group field '{other}'"
        ))),
    }
}

fn order_sql(order: &[OrderClause]) -> Result<String> {
    if order.is_empty() {
        return Ok(" ORDER BY c.looked_up_at DESC, c.ip ASC, i.id ASC".into());
    }
    let clauses = order
        .iter()
        .map(|clause| {
            let column = order_column(clause.field.as_str()).ok_or_else(|| {
                ServiceError::InvalidRequest(format!(
                    "unsupported sort field for threat_intel_matches: '{}'",
                    clause.field
                ))
            })?;
            let dir = match clause.direction {
                OrderDirection::Asc => "ASC",
                OrderDirection::Desc => "DESC",
            };
            Ok(format!("{column} {dir} NULLS LAST"))
        })
        .collect::<Result<Vec<_>>>()?;
    Ok(format!(" ORDER BY {}", clauses.join(", ")))
}

fn order_column(field: &str) -> Option<&'static str> {
    match field {
        "evaluated_at" | "looked_up_at" | "time" => Some("c.looked_up_at"),
        "observed_ip" | "ip" => Some("c.ip"),
        "indicator_id" => Some("i.id"),
        "source" => Some("i.source"),
        "severity" => Some("i.severity"),
        "confidence" => Some("i.confidence"),
        _ => None,
    }
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
        query::{build_query_plan, QueryRequest},
    };

    fn plan(query: &str) -> QueryPlan {
        let request = QueryRequest {
            query: query.to_string(),
            limit: Some(25),
            cursor: None,
            direction: Default::default(),
            mode: None,
        };
        let ast = parser::parse(query).expect("parse threat_intel_matches query");
        build_query_plan(
            &AppConfig::embedded("postgres://srql-test".to_string()),
            &request,
            ast,
        )
        .expect("build threat_intel_matches plan")
    }

    #[test]
    fn translates_current_otx_matches() {
        let plan =
            plan("in:threat_intel_matches source:alienvault_otx sort:evaluated_at:desc limit:100");
        let (sql, binds) = to_sql_and_params(&plan).expect("sql");
        assert!(sql.contains("platform.ip_threat_intel_cache"));
        assert!(sql.contains("platform.threat_intel_indicators"));
        assert!(sql.contains("c.ip::inet <<= i.indicator"));
        assert!(sql.contains("c.matched"));
        assert!(sql.contains("evaluated_at"));
        assert!(sql.contains("i.source = $"));
        assert!(binds
            .iter()
            .any(|bind| matches!(bind, BindParam::Text(value) if value == "alienvault_otx")));
        assert!(!sql.contains("observed_at"));
    }

    #[test]
    fn default_excludes_expired_rows() {
        let plan = plan("in:threat_intel_matches limit:10");
        let (sql, _) = to_sql_and_params(&plan).expect("sql");
        assert!(sql.contains("c.expires_at > NOW()"));
        assert!(sql.contains("i.expires_at IS NULL OR i.expires_at > NOW()"));
    }

    #[test]
    fn stale_filter_labels_expired_rows() {
        let plan = plan("in:threat_intel_matches stale:true limit:10");
        let (sql, _) = to_sql_and_params(&plan).expect("sql");
        assert!(sql.contains("c.expires_at <= NOW() OR i.expires_at <= NOW()"));
        assert!(sql.contains("'stale'"));
    }

    #[test]
    fn rejects_rollup_stats() {
        let mut plan = plan("in:threat_intel_matches limit:1");
        plan.rollup_stats = Some("foo".into());
        let err = to_sql_and_params(&plan).expect_err("rollup");
        assert!(err.to_string().contains("rollup_stats"));
    }

    #[test]
    fn rejects_unknown_filter() {
        let err = parser::parse("in:threat_intel_matches nope:1")
            .and_then(|ast| {
                build_query_plan(
                    &AppConfig::embedded("postgres://srql-test".to_string()),
                    &QueryRequest {
                        query: "in:threat_intel_matches nope:1".into(),
                        limit: Some(1),
                        cursor: None,
                        direction: Default::default(),
                        mode: None,
                    },
                    ast,
                )
            })
            .and_then(|plan| to_sql_and_params(&plan))
            .expect_err("unknown");
        assert!(err.to_string().contains("unsupported filter field"));
    }

    #[test]
    fn stats_by_source() {
        let plan = plan("in:threat_intel_matches stats:count() as n by source");
        let (sql, _) = to_sql_and_params(&plan).expect("sql");
        assert!(sql.contains("COUNT(*)"));
        assert!(sql.contains("GROUP BY i.source"));
    }
}
