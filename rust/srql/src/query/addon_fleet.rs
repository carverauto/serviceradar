//! SRQL execution for the derived native add-on fleet read model.

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
    Bool,
    Int,
}

fn ensure_entity(plan: &QueryPlan) -> Result<()> {
    if !matches!(plan.entity, Entity::AddonFleet) {
        return Err(ServiceError::InvalidRequest(
            "entity not supported by addon_fleet query".into(),
        ));
    }

    if plan.stats.is_some() {
        return Err(ServiceError::InvalidRequest(
            "addon_fleet does not support stats queries".into(),
        ));
    }

    Ok(())
}

fn build_sql(plan: &QueryPlan) -> Result<BuiltSql> {
    let mut where_parts = Vec::new();
    let mut binds = Vec::new();

    if let Some(TimeRange { start, end }) = &plan.time_range {
        where_parts.push("fleet.reported_at >= ? AND fleet.reported_at <= ?".to_string());
        binds.push(BindParam::timestamptz(*start));
        binds.push(BindParam::timestamptz(*end));
    }

    for filter in &plan.filters {
        where_parts.push(filter_condition(filter, &mut binds)?);
    }

    let where_sql = if where_parts.is_empty() {
        String::new()
    } else {
        format!(" WHERE {}", where_parts.join(" AND "))
    };

    binds.push(BindParam::Int(plan.limit));
    binds.push(BindParam::Int(plan.offset));

    Ok(BuiltSql {
        sql: format!(
            "SELECT to_jsonb(fleet) AS payload FROM platform.addon_fleet AS fleet{where_sql}{} LIMIT ? OFFSET ?",
            order_sql(&plan.order)?
        ),
        binds,
    })
}

fn filter_condition(filter: &Filter, binds: &mut Vec<BindParam>) -> Result<String> {
    let (field_sql, kind) = field_spec(filter.field.as_str()).ok_or_else(|| {
        ServiceError::InvalidRequest(format!(
            "unsupported filter field for addon_fleet: '{}'",
            filter.field
        ))
    })?;

    match kind {
        FieldKind::Text => text_condition(field_sql, filter, binds),
        FieldKind::Bool => bool_condition(field_sql, filter, binds),
        FieldKind::Int => integer_condition(field_sql, filter, binds),
    }
}

fn field_spec(field: &str) -> Option<(&'static str, FieldKind)> {
    match field {
        "agent_uid" => Some(("fleet.agent_uid", FieldKind::Text)),
        "agent_label" => Some(("fleet.agent_label", FieldKind::Text)),
        "addon_id" => Some(("fleet.addon_id", FieldKind::Text)),
        "addon_name" => Some(("fleet.addon_name", FieldKind::Text)),
        "assigned_version" => Some(("fleet.assigned_version", FieldKind::Text)),
        "observed_state" => Some(("fleet.observed_state", FieldKind::Text)),
        "observed_version" => Some(("fleet.observed_version", FieldKind::Text)),
        "category" => Some(("fleet.category", FieldKind::Text)),
        "reason_code" => Some(("fleet.reason_code", FieldKind::Text)),
        "rollout_state" => Some(("fleet.rollout_state", FieldKind::Text)),
        "update_policy" => Some(("fleet.update_policy", FieldKind::Text)),
        "package_status" => Some(("fleet.package_status", FieldKind::Text)),
        "degradation_reason" => Some(("fleet.degradation_reason", FieldKind::Text)),
        "assigned" => Some(("fleet.assigned", FieldKind::Bool)),
        "active" => Some(("fleet.active", FieldKind::Bool)),
        "evidence_age_seconds" => Some(("fleet.evidence_age_seconds", FieldKind::Int)),
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
        FilterOp::NotLike => {
            binds.push(BindParam::Text(filter.value.as_scalar()?.to_string()));
            Ok(format!("{field_sql} NOT ILIKE ?"))
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
        FilterOp::NotIn => {
            let values = filter.value.as_list()?.to_vec();
            if values.is_empty() {
                Ok("TRUE".into())
            } else {
                binds.push(BindParam::TextArray(values));
                Ok(format!("NOT ({field_sql} = ANY(?))"))
            }
        }
        _ => Err(ServiceError::InvalidRequest(format!(
            "unsupported operator for addon_fleet text filter: {:?}",
            filter.op
        ))),
    }
}

fn bool_condition(field_sql: &str, filter: &Filter, binds: &mut Vec<BindParam>) -> Result<String> {
    let value = parse_bool(filter.value.as_scalar()?)?;

    match filter.op {
        FilterOp::Eq => {
            binds.push(BindParam::Bool(value));
            Ok(format!("{field_sql} = ?"))
        }
        FilterOp::NotEq => {
            binds.push(BindParam::Bool(value));
            Ok(format!("{field_sql} <> ?"))
        }
        _ => Err(ServiceError::InvalidRequest(
            "addon_fleet boolean filters only support equality".into(),
        )),
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
                "addon_fleet evidence_age_seconds requires a scalar comparison".into(),
            ));
        }
    };

    let value = filter.value.as_scalar()?.parse::<i64>().map_err(|_| {
        ServiceError::InvalidRequest("expected integer evidence_age_seconds".into())
    })?;
    binds.push(BindParam::Int(value));
    Ok(format!("{field_sql} {operator} ?"))
}

fn parse_bool(raw: &str) -> Result<bool> {
    match raw.to_ascii_lowercase().as_str() {
        "true" | "1" | "yes" => Ok(true),
        "false" | "0" | "no" => Ok(false),
        _ => Err(ServiceError::InvalidRequest(format!(
            "expected boolean addon_fleet filter value: {raw}"
        ))),
    }
}

fn order_sql(order: &[OrderClause]) -> Result<String> {
    let clauses = order
        .iter()
        .map(|clause| {
            let column = order_column(clause.field.as_str()).ok_or_else(|| {
                ServiceError::InvalidRequest(format!(
                    "unsupported sort field for addon_fleet: '{}'",
                    clause.field
                ))
            })?;
            let direction = match clause.direction {
                OrderDirection::Asc => "ASC",
                OrderDirection::Desc => "DESC",
            };
            Ok(format!("{column} {direction}"))
        })
        .collect::<Result<Vec<_>>>()?;

    if clauses.is_empty() {
        Ok(" ORDER BY fleet.category ASC, fleet.agent_uid ASC, fleet.addon_id ASC".into())
    } else {
        Ok(format!(" ORDER BY {}", clauses.join(", ")))
    }
}

fn order_column(field: &str) -> Option<&'static str> {
    match field {
        "agent_uid" => Some("fleet.agent_uid"),
        "addon_id" => Some("fleet.addon_id"),
        "category" => Some("fleet.category"),
        "reason_code" => Some("fleet.reason_code"),
        "evidence_age_seconds" => Some("fleet.evidence_age_seconds"),
        "reported_at" | "time" | "timestamp" => Some("fleet.reported_at"),
        _ => None,
    }
}

fn rewrite_placeholders(sql: &str) -> String {
    let mut output = String::with_capacity(sql.len());
    let mut index = 1;

    for character in sql.chars() {
        if character == '?' {
            output.push('$');
            output.push_str(&index.to_string());
            index += 1;
        } else {
            output.push(character);
        }
    }

    output
}
