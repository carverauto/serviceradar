//! `in:deduplication_tasks` -- the device sets DIRE could not reconcile, waiting
//! for an operator (merge, mark distinct, or dismiss).
//!
//! One row per candidate device set for the set's whole life: a repeat decision
//! about the set counts on its task rather than opening another. Read-only here;
//! operators resolve tasks in the web UI, which calls the core actions.

use super::{
    BuiltSql, JsonPayload, device_set_condition, numeric_condition, order_by, reject_aggregations,
    rewrite_placeholders, text_condition,
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
    ("last_decided_at", "last_decided_at"),
    ("time", "last_decided_at"),
    ("opened_at", "opened_at"),
    ("resolved_at", "resolved_at"),
    ("occurrence_count", "occurrence_count"),
    ("device_count", "device_count"),
    ("status", "status"),
    ("category", "category"),
];

pub(in crate::query) async fn execute(
    conn: &mut AsyncPgConnection,
    plan: &QueryPlan,
) -> Result<Vec<Value>> {
    // Execute exactly the SQL translate returns; see device_revival_audit.
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
    if !matches!(plan.entity, Entity::DeduplicationTasks) {
        return Err(ServiceError::InvalidRequest(
            "entity not supported by deduplication_tasks query".into(),
        ));
    }
    reject_aggregations(plan, "deduplication_tasks")
}

fn build_sql(plan: &QueryPlan) -> Result<BuiltSql> {
    let mut binds = Vec::new();
    let mut where_parts: Vec<String> = Vec::new();

    if let Some(TimeRange { start, end }) = &plan.time_range {
        where_parts.push("t.last_decided_at >= ? AND t.last_decided_at <= ?".to_string());
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

    let order_sql = order_by(&plan.order, ORDERABLE, "last_decided_at DESC, id DESC")?;

    binds.push(BindParam::Int(plan.limit));
    binds.push(BindParam::Int(plan.offset));

    // `candidate_key` is an internal digest of the device set and is not projected.
    let sql = format!(
        "SELECT to_jsonb(sub) AS payload FROM (\
           SELECT t.id, t.status, t.device_uids, cardinality(t.device_uids) AS device_count, \
                  t.category, t.last_decision_kind, t.last_reason, t.evidence, \
                  t.occurrence_count, t.opened_at, t.last_decided_at, t.resolved_at, \
                  t.resolved_by, t.merged_into, t.resolution_note \
           FROM platform.identity_deduplication_tasks t\
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
        "id" | "task_id" => text_condition("t.id::text", filter, binds),
        "device" | "device_uid" | "device_id" | "uid" => {
            device_set_condition("t.device_uids", filter, binds)
        }
        "status" => text_condition("t.status", filter, binds),
        "category" => text_condition("t.category", filter, binds),
        "last_decision_kind" | "decision_kind" | "kind" => {
            text_condition("t.last_decision_kind", filter, binds)
        }
        "last_reason" | "reason" => text_condition("t.last_reason", filter, binds),
        "resolved_by" => text_condition("t.resolved_by", filter, binds),
        "merged_into" | "survivor" => text_condition("t.merged_into", filter, binds),
        "occurrence_count" | "occurrences" => {
            numeric_condition("t.occurrence_count", filter, binds)
        }
        "device_count" => numeric_condition("cardinality(t.device_uids)", filter, binds),
        other => Err(ServiceError::InvalidRequest(format!(
            "unsupported deduplication_tasks filter '{other}'"
        ))),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::query::identity::tests_support::plan_for;

    #[test]
    fn projects_the_task_and_its_resolution() {
        let (sql, _) = to_sql_and_params(&plan_for("in:deduplication_tasks limit:10")).unwrap();
        for column in [
            "t.status",
            "t.device_uids",
            "t.category",
            "t.last_reason",
            "t.evidence",
            "t.occurrence_count",
            "t.resolved_by",
            "t.merged_into",
            "t.resolution_note",
        ] {
            assert!(sql.contains(column), "{column} missing from {sql}");
        }
        assert!(!sql.contains("candidate_key"), "{sql}");
    }

    #[test]
    fn open_tasks_for_a_device() {
        let (sql, binds) = to_sql_and_params(&plan_for(
            "in:dedup_tasks status:open device:sr:aaa limit:5",
        ))
        .unwrap();
        assert!(sql.contains("t.status = $1"), "{sql}");
        assert!(sql.contains("t.device_uids @> ARRAY[$2]::text[]"), "{sql}");
        assert!(
            binds
                .iter()
                .any(|b| matches!(b, BindParam::Text(v) if v == "sr:aaa"))
        );
    }

    #[test]
    fn device_list_matches_any_member() {
        let (sql, binds) =
            to_sql_and_params(&plan_for("in:deduplication_tasks device:(sr:aaa,sr:bbb)")).unwrap();
        assert!(sql.contains("t.device_uids && $1::text[]"), "{sql}");
        assert!(
            binds
                .iter()
                .any(|b| matches!(b, BindParam::TextArray(v) if v.len() == 2))
        );
    }

    #[test]
    fn default_sort_is_most_recent_decision_first() {
        let (sql, _) = to_sql_and_params(&plan_for("in:deduplication_tasks")).unwrap();
        assert!(sql.contains("ORDER BY last_decided_at DESC"), "{sql}");
    }

    #[test]
    fn unknown_filter_is_rejected() {
        let err =
            to_sql_and_params(&plan_for("in:deduplication_tasks candidate_key:x")).unwrap_err();
        assert!(matches!(err, ServiceError::InvalidRequest(_)));
    }
}
