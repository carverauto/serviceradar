//! Control-plane audit events, distinct from OCSF events and findings.
use super::{
    BindParam, QueryPlan, bind_sql_param,
    identity::{JsonPayload, order_by, reject_aggregations, rewrite_placeholders, text_condition},
};
use crate::{
    error::{Result, ServiceError},
    parser::{Filter, FilterOp, FilterValue},
};
use diesel::{pg::Pg, sql_query};
use diesel_async::{AsyncPgConnection, RunQueryDsl};
use serde_json::Value;

const ORDERABLE: &[(&str, &str)] = &[
    ("occurred_at", "occurred_at"),
    ("time", "occurred_at"),
    ("id", "id"),
    ("kind", "kind"),
    ("severity", "severity"),
    ("actor_id", "actor_id"),
    ("ip", "ip"),
    ("route", "route"),
    ("correlation_id", "correlation_id"),
];

pub(super) async fn execute(conn: &mut AsyncPgConnection, plan: &QueryPlan) -> Result<Vec<Value>> {
    let (sql, binds) = to_sql_and_params(plan)?;
    let mut query = sql_query(&sql).into_boxed::<Pg>();
    for bind in binds {
        query = bind_sql_param(query, bind)?;
    }
    let rows: Vec<JsonPayload> = query
        .load(conn)
        .await
        .map_err(|err| ServiceError::Internal(err.into()))?;
    Ok(rows
        .into_iter()
        .map(|row| Value::from(row.payload))
        .collect())
}

pub(super) fn to_sql_and_params(plan: &QueryPlan) -> Result<(String, Vec<BindParam>)> {
    reject_aggregations(plan, "security_events")?;
    let mut binds = Vec::new();
    let mut conditions = Vec::new();
    if let Some(range) = &plan.time_range {
        conditions.push("occurred_at >= ? AND occurred_at <= ?".to_string());
        binds.push(BindParam::timestamptz(range.start));
        binds.push(BindParam::timestamptz(range.end));
    }
    for filter in &plan.filters {
        conditions.push(filter_condition(filter, &mut binds)?);
    }
    let where_sql = if conditions.is_empty() {
        String::new()
    } else {
        format!(" WHERE {}", conditions.join(" AND "))
    };
    let mut order = order_by(&plan.order, ORDERABLE, "occurred_at DESC, id DESC")?;
    if !plan.order.is_empty()
        && !plan
            .order
            .iter()
            .any(|clause| clause.field.eq_ignore_ascii_case("id"))
    {
        order.push_str(", id DESC");
    }
    binds.push(BindParam::Int(plan.limit));
    binds.push(BindParam::Int(plan.offset));
    let sql = format!(
        "SELECT to_jsonb(sub) AS payload FROM (SELECT id, occurred_at, kind, severity, \
         actor_id, ip, route, correlation_id, details, inserted_at, updated_at \
         FROM platform.security_events{where_sql} ORDER BY {order} LIMIT ? OFFSET ?) sub"
    );
    Ok((rewrite_placeholders(&sql), binds))
}

fn filter_condition(filter: &Filter, binds: &mut Vec<BindParam>) -> Result<String> {
    if !matches!(
        filter.op,
        FilterOp::Eq
            | FilterOp::NotEq
            | FilterOp::Like
            | FilterOp::NotLike
            | FilterOp::In
            | FilterOp::NotIn
    ) {
        return Err(ServiceError::InvalidRequest(format!(
            "unsupported security_events operator for '{}'",
            filter.field
        )));
    }
    match filter.field.to_ascii_lowercase().as_str() {
        "kind" => text_condition("kind", filter, binds),
        "severity" => text_condition("severity", filter, binds),
        "actor_id" => text_condition("actor_id", filter, binds),
        "ip" => text_condition("ip", filter, binds),
        "route" => text_condition("route", filter, binds),
        "correlation_id" => text_condition("correlation_id", filter, binds),
        "id" => text_condition("id::text", filter, binds),
        "search" => {
            let values = match &filter.value {
                FilterValue::Scalar(value) => std::slice::from_ref(value),
                FilterValue::List(values) => values.as_slice(),
            };
            let mut parts = Vec::new();
            for value in values {
                let pattern = format!(
                    "%{}%",
                    value
                        .replace('\\', "\\\\")
                        .replace('%', "\\%")
                        .replace('_', "\\_")
                );
                for column in ["actor_id", "ip", "route", "correlation_id"] {
                    binds.push(BindParam::Text(pattern.clone()));
                    parts.push(format!("COALESCE({column}, '') ILIKE ?"));
                }
            }
            let condition = format!("({})", parts.join(" OR "));
            if matches!(
                filter.op,
                FilterOp::NotEq | FilterOp::NotLike | FilterOp::NotIn
            ) {
                Ok(format!("NOT {condition}"))
            } else {
                Ok(condition)
            }
        }
        other => Err(ServiceError::InvalidRequest(format!(
            "unsupported security_events filter '{other}'"
        ))),
    }
}
