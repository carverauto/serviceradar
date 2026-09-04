//! `in:device_revival_audit` -- every time a soft-deleted device came back.
//!
//! Clearing `deleted_at` also clears `deleted_by` and `deleted_reason`, so a
//! revived device is otherwise indistinguishable from one never deleted. The
//! trigger behind this table captures the tombstone the revival is about to
//! destroy; this entity is how an operator reads it without psql.

use super::{
    BuiltSql, JsonPayload, order_by, reject_aggregations, rewrite_placeholders, text_condition,
};
use crate::{
    error::{Result, ServiceError},
    parser::{Entity, Filter},
    query::{BindParam, QueryPlan, bind_sql_param},
    time::TimeRange,
};
use diesel::pg::Pg;
use diesel::sql_query;
use diesel_async::{AsyncPgConnection, RunQueryDsl};
use serde_json::Value;

const ORDERABLE: &[(&str, &str)] = &[
    ("revived_at", "revived_at"),
    ("time", "revived_at"),
    ("previous_deleted_at", "previous_deleted_at"),
    ("device_uid", "device_uid"),
];

pub(in crate::query) async fn execute(
    conn: &mut AsyncPgConnection,
    plan: &QueryPlan,
) -> Result<Vec<Value>> {
    // Execution goes through `to_sql_and_params`, not around it, so the SQL that
    // runs is by construction the SQL that translate returns. They used to be
    // built separately, and the execute side passed `?` straight to Diesel --
    // which does not translate it for Postgres, where `?` is a valid operator
    // character. `col = ? OR ...` then parsed as a prefix operator and failed as
    // "syntax error at or near OR", naming neither the placeholder nor the
    // column. A test comparing the two paths could not have caught it; removing
    // the second path does.
    let (sql, binds) = to_sql_and_params(plan)?;
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
        .map(|row| Value::from(row.payload))
        .collect())
}

pub(in crate::query) fn to_sql_and_params(plan: &QueryPlan) -> Result<(String, Vec<BindParam>)> {
    ensure_entity(plan)?;
    let built = build_sql(plan)?;
    Ok((rewrite_placeholders(&built.sql), built.binds))
}

fn ensure_entity(plan: &QueryPlan) -> Result<()> {
    if !matches!(plan.entity, Entity::DeviceRevivalAudit) {
        return Err(ServiceError::InvalidRequest(
            "entity not supported by device_revival_audit query".into(),
        ));
    }
    reject_aggregations(plan, "device_revival_audit")
}

fn build_sql(plan: &QueryPlan) -> Result<BuiltSql> {
    let mut binds = Vec::new();
    let mut where_parts: Vec<String> = Vec::new();

    if let Some(TimeRange { start, end }) = &plan.time_range {
        where_parts.push("ra.revived_at >= ? AND ra.revived_at <= ?".to_string());
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

    let order_sql = order_by(&plan.order, ORDERABLE, "revived_at DESC, event_id DESC")?;

    binds.push(BindParam::Int(plan.limit));
    binds.push(BindParam::Int(plan.offset));

    let sql = format!(
        "SELECT to_jsonb(sub) AS payload FROM (\
           SELECT ra.event_id, ra.device_uid, ra.previous_deleted_at, ra.previous_deleted_by, \
                  ra.previous_deleted_reason, ra.revived_at, ra.revived_by_application \
           FROM platform.device_revival_audit ra\
           {where_sql} \
           ORDER BY {order_sql} \
           LIMIT ? OFFSET ?\
         ) sub"
    );

    Ok(BuiltSql { sql, binds })
}

fn filter_condition(filter: &Filter, binds: &mut Vec<BindParam>) -> Result<String> {
    let field = filter.field.to_ascii_lowercase();
    match field.as_str() {
        "device_uid" | "device_id" | "device" | "uid" => {
            text_condition("ra.device_uid", filter, binds)
        }
        "revived_by_application" | "application" => {
            text_condition("ra.revived_by_application", filter, binds)
        }
        "previous_deleted_by" | "deleted_by" => {
            text_condition("ra.previous_deleted_by", filter, binds)
        }
        "previous_deleted_reason" | "deleted_reason" | "reason" => {
            text_condition("ra.previous_deleted_reason", filter, binds)
        }
        other => Err(ServiceError::InvalidRequest(format!(
            "unsupported device_revival_audit filter '{other}'"
        ))),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::query::identity::tests_support::plan_for;

    #[test]
    fn projects_the_tombstone_the_revival_destroyed() {
        let (sql, _) = to_sql_and_params(&plan_for("in:revivals limit:10")).unwrap();
        assert!(sql.contains("previous_deleted_by"), "{sql}");
        assert!(sql.contains("previous_deleted_reason"), "{sql}");
        assert!(sql.contains("revived_by_application"), "{sql}");
    }

    #[test]
    fn device_lookup_is_bound() {
        let (sql, binds) = to_sql_and_params(&plan_for(
            "in:device_revival_audit device_uid:sr:aaa limit:5",
        ))
        .unwrap();
        assert!(sql.contains("ra.device_uid = $"), "{sql}");
        assert!(
            binds
                .iter()
                .any(|b| matches!(b, BindParam::Text(v) if v == "sr:aaa"))
        );
    }

    #[test]
    fn time_filters_revived_at() {
        let (sql, _) = to_sql_and_params(&plan_for("in:revivals time:last_24h limit:10")).unwrap();
        assert!(sql.contains("ra.revived_at >= $"), "{sql}");
        assert!(sql.contains("ra.revived_at <= $"), "{sql}");
    }

    #[test]
    fn unknown_filter_is_rejected() {
        let err = to_sql_and_params(&plan_for("in:revivals nonsense:1")).unwrap_err();
        assert!(matches!(err, ServiceError::InvalidRequest(_)));
    }
}
