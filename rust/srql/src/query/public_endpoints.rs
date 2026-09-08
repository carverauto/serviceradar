//! SRQL for Kubernetes public endpoint inventory (`platform.public_endpoints_current`).

use super::{BindParam, QueryPlan, bind_sql_param};
use crate::{
    error::{Result, ServiceError},
    jsonb::DbJson,
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

#[derive(Debug, QueryableByName)]
#[diesel(check_for_backend(diesel::pg::Pg))]
struct JsonPayload {
    #[diesel(sql_type = Jsonb)]
    payload: DbJson,
}

pub(super) async fn execute(conn: &mut AsyncPgConnection, plan: &QueryPlan) -> Result<Vec<Value>> {
    ensure_entity(plan)?;
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
    ensure_entity(plan)?;
    let built = build_sql(plan)?;
    Ok((rewrite_placeholders(&built.sql), built.binds))
}

struct BuiltSql {
    sql: String,
    binds: Vec<BindParam>,
}

#[derive(Clone, Copy)]
enum FieldKind {
    Text,
    Int,
}

fn ensure_entity(plan: &QueryPlan) -> Result<()> {
    if !matches!(plan.entity, Entity::PublicEndpoints) {
        return Err(ServiceError::InvalidRequest(
            "entity not supported by public_endpoints query".into(),
        ));
    }
    if plan.stats.is_some() {
        return Err(ServiceError::InvalidRequest(
            "public_endpoints does not support stats queries".into(),
        ));
    }
    Ok(())
}

fn build_sql(plan: &QueryPlan) -> Result<BuiltSql> {
    let mut where_parts = vec!["ep.deleted_at IS NULL".to_string()];
    let mut binds = Vec::new();

    if let Some(TimeRange { start, end }) = &plan.time_range {
        where_parts.push("ep.observed_at >= ? AND ep.observed_at <= ?".to_string());
        binds.push(BindParam::timestamptz(*start));
        binds.push(BindParam::timestamptz(*end));
    }

    for filter in &plan.filters {
        where_parts.push(filter_condition(filter, &mut binds)?);
    }

    let where_sql = format!(" WHERE {}", where_parts.join(" AND "));
    binds.push(BindParam::Int(plan.limit));
    binds.push(BindParam::Int(plan.offset));

    Ok(BuiltSql {
        sql: format!(
            "SELECT to_jsonb(ep) AS payload \
             FROM platform.public_endpoints_current AS ep\
             {where_sql}{} LIMIT ? OFFSET ?",
            order_sql(&plan.order)?
        ),
        binds,
    })
}

fn filter_condition(filter: &Filter, binds: &mut Vec<BindParam>) -> Result<String> {
    let (field_sql, kind) = field_spec(filter.field.as_str()).ok_or_else(|| {
        ServiceError::InvalidRequest(format!(
            "unsupported filter field for public_endpoints: '{}'",
            filter.field
        ))
    })?;

    match kind {
        FieldKind::Text => text_condition(field_sql, filter, binds),
        FieldKind::Int => integer_condition(field_sql, filter, binds),
    }
}

fn field_spec(field: &str) -> Option<(&'static str, FieldKind)> {
    match field {
        "cluster_id" => Some(("ep.cluster_id", FieldKind::Text)),
        "ip" => Some(("ep.ip", FieldKind::Text)),
        "hostname" => Some(("ep.hostname", FieldKind::Text)),
        "protocol" => Some(("ep.protocol", FieldKind::Text)),
        "exposure_class" | "exposure" => Some(("ep.exposure_class", FieldKind::Text)),
        "namespace" => Some(("ep.namespace", FieldKind::Text)),
        "service_name" | "service" => Some(("ep.service_name", FieldKind::Text)),
        "gateway_name" | "gateway" => Some(("ep.gateway_name", FieldKind::Text)),
        "listener_name" | "listener" => Some(("ep.listener_name", FieldKind::Text)),
        "route_kind" => Some(("ep.route_kind", FieldKind::Text)),
        "route_name" | "route" => Some(("ep.route_name", FieldKind::Text)),
        "port" => Some(("ep.port", FieldKind::Int)),
        "service_target_port" | "target_port" => Some(("ep.service_target_port", FieldKind::Int)),
        _ => None,
    }
}

fn text_condition(field_sql: &str, filter: &Filter, binds: &mut Vec<BindParam>) -> Result<String> {
    match filter.op {
        FilterOp::Eq => {
            binds.push(BindParam::Text(filter.value.as_scalar()?.to_string()));
            Ok(format!("{field_sql} = ?"))
        }
        FilterOp::NotEq => {
            binds.push(BindParam::Text(filter.value.as_scalar()?.to_string()));
            Ok(format!("{field_sql} <> ?"))
        }
        FilterOp::Like => {
            binds.push(BindParam::Text(filter.value.as_scalar()?.to_string()));
            Ok(format!("{field_sql} ILIKE ?"))
        }
        FilterOp::In => {
            let values = filter.value.as_list()?.to_vec();
            if values.is_empty() {
                Ok("TRUE".into())
            } else {
                binds.push(BindParam::TextArray(values));
                Ok(format!("{field_sql} = ANY(?)"))
            }
        }
        _ => Err(ServiceError::InvalidRequest(format!(
            "unsupported operator for public_endpoints text filter: {:?}",
            filter.op
        ))),
    }
}

fn integer_condition(
    field_sql: &str,
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
            return Err(ServiceError::InvalidRequest(
                "public_endpoints port filters require a scalar comparison".into(),
            ));
        }
    };
    let value = filter
        .value
        .as_scalar()?
        .parse::<i64>()
        .map_err(|_| ServiceError::InvalidRequest("expected integer filter value".into()))?;
    binds.push(BindParam::Int(value));
    Ok(format!("{field_sql} {operator} ?"))
}

fn order_sql(order: &[OrderClause]) -> Result<String> {
    if order.is_empty() {
        return Ok(" ORDER BY ep.observed_at DESC".into());
    }
    let clauses = order
        .iter()
        .map(|clause| {
            let column = order_column(clause.field.as_str()).ok_or_else(|| {
                ServiceError::InvalidRequest(format!(
                    "unsupported sort field for public_endpoints: '{}'",
                    clause.field
                ))
            })?;
            let dir = match clause.direction {
                OrderDirection::Asc => "ASC",
                OrderDirection::Desc => "DESC",
            };
            Ok(format!("{column} {dir}"))
        })
        .collect::<Result<Vec<_>>>()?;
    Ok(format!(" ORDER BY {}", clauses.join(", ")))
}

fn order_column(field: &str) -> Option<&'static str> {
    match field {
        "observed_at" | "time" => Some("ep.observed_at"),
        "ip" => Some("ep.ip"),
        "hostname" => Some("ep.hostname"),
        "port" => Some("ep.port"),
        "namespace" => Some("ep.namespace"),
        "service_name" => Some("ep.service_name"),
        "cluster_id" => Some("ep.cluster_id"),
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
        query::{QueryRequest, build_query_plan},
    };

    fn plan(query: &str) -> QueryPlan {
        let request = QueryRequest {
            query: query.to_string(),
            limit: Some(25),
            cursor: None,
            direction: Default::default(),
            mode: None,
        };
        let ast = parser::parse(query).expect("parse public_endpoints query");
        build_query_plan(
            &AppConfig::embedded("postgres://srql-test".to_string()),
            &request,
            ast,
        )
        .expect("build public_endpoints plan")
    }

    #[test]
    fn translates_public_endpoints_ip_port() {
        let plan = plan("in:public_endpoints ip:23.138.124.7 port:22 limit:10");
        let (sql, binds) = to_sql_and_params(&plan).expect("sql");
        assert!(sql.contains("platform.public_endpoints_current"));
        assert!(sql.contains("ep.deleted_at IS NULL"));
        assert!(sql.contains("ep.ip = $"));
        assert!(sql.contains("ep.port = $"));
        assert!(binds.len() >= 4);
    }
}
