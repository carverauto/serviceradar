//! Shared SQL helpers for advisory catalog, CPE coordinate, and match entities.

use super::{bind_sql_param, BindParam, QueryPlan};
use crate::{
    error::{Result, ServiceError},
    jsonb::DbJson,
    parser::{Filter, FilterOp, FilterValue, OrderClause, OrderDirection, StatsSpec},
    time::TimeRange,
};
use diesel::deserialize::QueryableByName;
use diesel::pg::Pg;
use diesel::sql_query;
use diesel::sql_types::Jsonb;
use diesel_async::{AsyncPgConnection, RunQueryDsl};
use serde_json::Value;
use uuid::Uuid;

#[derive(Debug, QueryableByName)]
#[diesel(check_for_backend(diesel::pg::Pg))]
pub(super) struct JsonPayload {
    #[diesel(sql_type = Jsonb)]
    pub(super) payload: DbJson,
}

pub(super) struct BuiltSql {
    pub(super) sql: String,
    pub(super) binds: Vec<BindParam>,
}

#[derive(Debug, Clone)]
pub(super) struct CountStats {
    pub(super) alias: String,
    pub(super) group_fields: Vec<String>,
}

pub(super) async fn execute_json(
    conn: &mut AsyncPgConnection,
    built: BuiltSql,
) -> Result<Vec<Value>> {
    // BoxedSqlQuery sends SQL to Postgres verbatim. Rewrite the internal `?`
    // placeholders before execution; otherwise Postgres parses them as the
    // jsonb exists operator.
    let (sql, binds) = to_sql_and_params(built);
    let mut query = sql_query(&sql).into_boxed::<Pg>();
    for bind in binds {
        query = bind_sql_param(query, bind)?;
    }
    let rows: Vec<JsonPayload> = query
        .load::<JsonPayload>(conn)
        .await
        .map_err(|err| ServiceError::Internal(err.into()))?;
    Ok(rows
        .into_iter()
        .map(|row| serde_json::Value::from(row.payload))
        .collect())
}

pub(super) fn to_sql_and_params(built: BuiltSql) -> (String, Vec<BindParam>) {
    (rewrite_placeholders(&built.sql), built.binds)
}

pub(super) fn reject_downsample_and_rollup(plan: &QueryPlan, entity: &str) -> Result<()> {
    if plan.downsample.is_some() {
        return Err(ServiceError::InvalidRequest(format!(
            "{entity} does not support downsample queries"
        )));
    }
    if plan.rollup_stats.is_some() {
        return Err(ServiceError::InvalidRequest(format!(
            "{entity} does not support rollup_stats"
        )));
    }
    Ok(())
}

pub(super) fn has_filter(filters: &[Filter], names: &[&str]) -> bool {
    filters
        .iter()
        .any(|filter| names.iter().any(|name| filter.field == *name))
}

pub(super) fn parse_bool(raw: &str) -> Result<bool> {
    match raw.to_ascii_lowercase().as_str() {
        "true" | "t" | "yes" | "y" | "1" => Ok(true),
        "false" | "f" | "no" | "n" | "0" => Ok(false),
        other => Err(ServiceError::InvalidRequest(format!(
            "invalid boolean value '{other}'"
        ))),
    }
}

pub(super) fn parse_f64(raw: &str) -> Result<f64> {
    raw.parse::<f64>()
        .map_err(|_| ServiceError::InvalidRequest(format!("expected numeric filter value '{raw}'")))
}

pub(super) fn parse_i64(raw: &str) -> Result<i64> {
    raw.parse::<i64>()
        .map_err(|_| ServiceError::InvalidRequest(format!("expected integer filter value '{raw}'")))
}

pub(super) fn parse_uuid(raw: &str) -> Result<Uuid> {
    Uuid::parse_str(raw).map_err(|_| ServiceError::InvalidRequest(format!("invalid uuid '{raw}'")))
}

pub(super) fn uppercase_cve(raw: &str) -> String {
    raw.trim().to_ascii_uppercase()
}

pub(super) fn cve_eq_values(filter: &Filter) -> Result<Vec<String>> {
    match &filter.value {
        FilterValue::Scalar(value) => Ok(vec![uppercase_cve(value)]),
        FilterValue::List(values) => Ok(values.iter().map(|value| uppercase_cve(value)).collect()),
    }
}

pub(super) fn parse_count_stats(stats: Option<&StatsSpec>) -> Result<Option<CountStats>> {
    let Some(stats) = stats else {
        return Ok(None);
    };
    let raw = stats.as_raw().trim();
    if raw.is_empty() {
        return Ok(None);
    }
    let tokens: Vec<&str> = raw.split_whitespace().collect();
    if tokens.len() < 3
        || !tokens[0].eq_ignore_ascii_case("count()")
        || !tokens[1].eq_ignore_ascii_case("as")
    {
        return Err(ServiceError::InvalidRequest(
            "advisory stats only support count() as <alias> [by <field>[,<field>]]".into(),
        ));
    }
    let alias = tokens[2]
        .trim_matches('"')
        .trim_matches('\'')
        .to_ascii_lowercase();
    if alias.is_empty()
        || alias
            .chars()
            .any(|ch| !ch.is_ascii_alphanumeric() && ch != '_')
    {
        return Err(ServiceError::InvalidRequest(
            "stats alias must be alphanumeric".into(),
        ));
    }
    let group_fields = if tokens.len() >= 5 {
        if !tokens[3].eq_ignore_ascii_case("by") {
            return Err(ServiceError::InvalidRequest(
                "expected 'by <field>' after stats alias".into(),
            ));
        }
        tokens[4..]
            .join(" ")
            .split(',')
            .map(|field| {
                field
                    .trim()
                    .trim_matches('"')
                    .trim_matches('\'')
                    .to_string()
            })
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

pub(super) fn is_selective_coordinate_query(filters: &[Filter]) -> bool {
    let mut has_vendor = false;
    let mut has_product = false;
    for filter in filters {
        match filter.field.as_str() {
            "cve" | "cve_id"
                if has_positive_exact_value(filter) || has_selective_like_pattern(filter) =>
            {
                return true;
            }
            "advisory_ref" if has_positive_exact_value(filter) => return true,
            "value" | "cpe"
                if has_positive_exact_value(filter) || has_selective_like_pattern(filter) =>
            {
                return true;
            }
            "cpe_vendor" if has_positive_exact_value(filter) => has_vendor = true,
            "cpe_product" if has_positive_exact_value(filter) => has_product = true,
            _ => {}
        }
    }
    has_vendor && has_product
}

fn has_positive_exact_value(filter: &Filter) -> bool {
    match (&filter.op, &filter.value) {
        (FilterOp::Eq, FilterValue::Scalar(value)) => !value.trim().is_empty(),
        (FilterOp::In, FilterValue::List(values)) => !values.is_empty(),
        _ => false,
    }
}

fn has_selective_like_pattern(filter: &Filter) -> bool {
    if !matches!(filter.op, FilterOp::Like) {
        return false;
    }

    let Ok(pattern) = filter.value.as_scalar() else {
        return false;
    };

    pattern
        .split(['%', '_'])
        .any(|literal| literal.chars().count() >= 3)
}

pub(super) fn text_condition(
    column: &str,
    filter: &Filter,
    binds: &mut Vec<BindParam>,
    uppercase: bool,
) -> Result<String> {
    let map_scalar = |value: &str| {
        if uppercase {
            uppercase_cve(value)
        } else {
            value.to_string()
        }
    };
    match filter.op {
        FilterOp::Eq => {
            binds.push(BindParam::Text(map_scalar(filter.value.as_scalar()?)));
            Ok(format!("{column} = ?"))
        }
        FilterOp::NotEq => {
            binds.push(BindParam::Text(map_scalar(filter.value.as_scalar()?)));
            Ok(format!("({column} IS NULL OR {column} <> ?)"))
        }
        FilterOp::Like => {
            binds.push(BindParam::Text(filter.value.as_scalar()?.to_string()));
            Ok(format!("{column} ILIKE ?"))
        }
        FilterOp::NotLike => {
            binds.push(BindParam::Text(filter.value.as_scalar()?.to_string()));
            Ok(format!("({column} IS NULL OR {column} NOT ILIKE ?)"))
        }
        FilterOp::In => {
            let values: Vec<String> = filter
                .value
                .as_list()?
                .iter()
                .map(|v| map_scalar(v))
                .collect();
            if values.is_empty() {
                return Ok("TRUE".into());
            }
            binds.push(BindParam::TextArray(values));
            Ok(format!("{column} = ANY(?)"))
        }
        FilterOp::NotIn => {
            let values: Vec<String> = filter
                .value
                .as_list()?
                .iter()
                .map(|v| map_scalar(v))
                .collect();
            if values.is_empty() {
                return Ok("TRUE".into());
            }
            binds.push(BindParam::TextArray(values));
            Ok(format!("({column} IS NULL OR {column} <> ALL(?))"))
        }
        _ => Err(ServiceError::InvalidRequest(format!(
            "unsupported operator for text filter {column}: {:?}",
            filter.op
        ))),
    }
}

pub(super) fn bool_condition(
    column: &str,
    filter: &Filter,
    binds: &mut Vec<BindParam>,
) -> Result<String> {
    if !matches!(filter.op, FilterOp::Eq | FilterOp::NotEq) {
        return Err(ServiceError::InvalidRequest(format!(
            "{column} only supports equality"
        )));
    }
    let value = parse_bool(filter.value.as_scalar()?)?;
    binds.push(BindParam::Bool(value));
    Ok(if matches!(filter.op, FilterOp::Eq) {
        format!("{column} = ?")
    } else {
        format!("{column} <> ?")
    })
}

pub(super) fn numeric_condition(
    column: &str,
    filter: &Filter,
    binds: &mut Vec<BindParam>,
) -> Result<String> {
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
    let value = parse_f64(filter.value.as_scalar()?)?;
    binds.push(BindParam::Float(value));
    Ok(format!("{column} {operator} ?"))
}

pub(super) fn integer_condition(
    column: &str,
    filter: &Filter,
    binds: &mut Vec<BindParam>,
) -> Result<String> {
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
    let value = parse_i64(filter.value.as_scalar()?)?;
    binds.push(BindParam::Int(value));
    Ok(if matches!(filter.op, FilterOp::NotEq) {
        format!("({column} IS NULL OR {column} {operator} ?)")
    } else {
        format!("{column} {operator} ?")
    })
}

pub(super) fn timestamptz_condition(
    column: &str,
    filter: &Filter,
    binds: &mut Vec<BindParam>,
) -> Result<String> {
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
    let raw = filter.value.as_scalar()?;
    let value = chrono::DateTime::parse_from_rfc3339(raw)
        .map(|value| value.with_timezone(&chrono::Utc))
        .map_err(|_| {
            ServiceError::InvalidRequest(format!("expected RFC3339 timestamp filter value '{raw}'"))
        })?;
    binds.push(BindParam::timestamptz(value));
    Ok(if matches!(filter.op, FilterOp::NotEq) {
        format!("({column} IS NULL OR {column} {operator} ?)")
    } else {
        format!("{column} {operator} ?")
    })
}

pub(super) fn uuid_condition(
    column: &str,
    filter: &Filter,
    binds: &mut Vec<BindParam>,
) -> Result<String> {
    if !matches!(filter.op, FilterOp::Eq | FilterOp::NotEq) {
        return Err(ServiceError::InvalidRequest(format!(
            "{column} only supports equality"
        )));
    }
    let value = parse_uuid(filter.value.as_scalar()?)?;
    binds.push(BindParam::Uuid(value));
    Ok(if matches!(filter.op, FilterOp::Eq) {
        format!("{column} = ?")
    } else {
        format!("({column} IS NULL OR {column} <> ?)")
    })
}

pub(super) fn time_clause(column: &str, range: &TimeRange, binds: &mut Vec<BindParam>) -> String {
    binds.push(BindParam::timestamptz(range.start));
    binds.push(BindParam::timestamptz(range.end));
    format!("{column} >= ? AND {column} <= ?")
}

pub(super) fn order_sql(
    order: &[OrderClause],
    default_sql: &str,
    resolve: impl Fn(&str) -> Option<&'static str>,
    entity: &str,
) -> Result<String> {
    if order.is_empty() {
        return Ok(format!(" ORDER BY {default_sql}"));
    }
    let clauses = order
        .iter()
        .map(|clause| {
            let column = resolve(clause.field.as_str()).ok_or_else(|| {
                ServiceError::InvalidRequest(format!(
                    "unsupported sort field for {entity}: '{}'",
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

pub(super) fn stats_select(alias: &str, groups: &[(&str, &str)]) -> String {
    if groups.is_empty() {
        return format!("SELECT jsonb_build_object('{alias}', COUNT(*)) AS payload");
    }
    let pairs = groups
        .iter()
        .map(|(key, expr)| format!("'{key}', {expr}"))
        .collect::<Vec<_>>()
        .join(", ");
    format!("SELECT jsonb_build_object({pairs}, '{alias}', COUNT(*)) AS payload")
}

pub(super) fn stats_order_sql(groups: &[(&str, &str)]) -> String {
    if groups.is_empty() {
        return " ORDER BY COUNT(*) DESC".into();
    }
    let group_order = groups
        .iter()
        .map(|(_, expr)| format!("{expr} ASC NULLS LAST"))
        .collect::<Vec<_>>()
        .join(", ");
    format!(" ORDER BY COUNT(*) DESC, {group_order}")
}

pub(super) fn rewrite_placeholders(sql: &str) -> String {
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
pub(super) fn plan_for_query(query: &str) -> QueryPlan {
    use crate::{config::AppConfig, parser, query::QueryRequest};
    let request = QueryRequest {
        query: query.to_string(),
        limit: Some(25),
        cursor: None,
        direction: Default::default(),
        mode: None,
    };
    let ast = parser::parse(query).expect("parse advisory query");
    super::build_query_plan(
        &AppConfig::embedded("postgres://srql-test".to_string()),
        &request,
        ast,
    )
    .expect("build advisory plan")
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::parser::{Filter, FilterOp, FilterValue};

    #[test]
    fn uppercase_cve_folds_input() {
        assert_eq!(uppercase_cve(" cve-2024-1234 "), "CVE-2024-1234");
    }

    #[test]
    fn coordinate_stats_require_a_selective_filter() {
        assert!(!is_selective_coordinate_query(&[]));
        assert!(is_selective_coordinate_query(&[Filter {
            field: "cve".into(),
            op: FilterOp::Eq,
            value: FilterValue::Scalar("CVE-2024-1234".into()),
        }]));
        assert!(!is_selective_coordinate_query(&[Filter {
            field: "cve".into(),
            op: FilterOp::NotEq,
            value: FilterValue::Scalar("CVE-2024-1234".into()),
        }]));
        assert!(!is_selective_coordinate_query(&[Filter {
            field: "cpe".into(),
            op: FilterOp::NotLike,
            value: FilterValue::Scalar("%nginx%".into()),
        }]));
        assert!(!is_selective_coordinate_query(&[Filter {
            field: "cpe".into(),
            op: FilterOp::Like,
            value: FilterValue::Scalar("%".into()),
        }]));
        assert!(is_selective_coordinate_query(&[Filter {
            field: "cpe".into(),
            op: FilterOp::Like,
            value: FilterValue::Scalar("%nginx%".into()),
        }]));
        assert!(!is_selective_coordinate_query(&[Filter {
            field: "cpe_vendor".into(),
            op: FilterOp::Eq,
            value: FilterValue::Scalar("nginx".into()),
        }]));
        assert!(is_selective_coordinate_query(&[
            Filter {
                field: "cpe_vendor".into(),
                op: FilterOp::Eq,
                value: FilterValue::Scalar("nginx".into()),
            },
            Filter {
                field: "cpe_product".into(),
                op: FilterOp::Eq,
                value: FilterValue::Scalar("nginx".into()),
            }
        ]));
    }
}
