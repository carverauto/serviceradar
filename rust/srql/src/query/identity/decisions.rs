//! `in:identity_decisions` -- every identity decision DIRE made without merging.
//!
//! When identity reconciliation blocks, declines or overrides a merge it writes
//! one row per distinct decision (kind, reason, subject, device set) and counts
//! repeats on it. This entity is how an operator or an MCP agent reads those
//! refusals without database credentials.
//!
//! `evidence` is projected whole: it is the decision's own record, written only
//! by identity reconciliation through its JSON-safe decision log, not a
//! free-form column shared with other writers.

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
    ("first_decided_at", "first_decided_at"),
    ("occurrence_count", "occurrence_count"),
    ("decision_kind", "decision_kind"),
    ("reason", "reason"),
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
    if !matches!(plan.entity, Entity::IdentityDecisions) {
        return Err(ServiceError::InvalidRequest(
            "entity not supported by identity_decisions query".into(),
        ));
    }
    reject_aggregations(plan, "identity_decisions")
}

fn build_sql(plan: &QueryPlan) -> Result<BuiltSql> {
    let mut binds = Vec::new();
    let mut where_parts: Vec<String> = Vec::new();

    if let Some(TimeRange { start, end }) = &plan.time_range {
        where_parts.push("d.last_decided_at >= ? AND d.last_decided_at <= ?".to_string());
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

    let sql = format!(
        "SELECT to_jsonb(sub) AS payload FROM (\
           SELECT d.id, d.decision_kind, d.reason, d.device_uids, \
                  cardinality(d.device_uids) AS device_count, d.subject, d.source, \
                  d.evidence, d.occurrence_count, d.first_decided_at, d.last_decided_at \
           FROM platform.identity_decisions d\
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
        "id" | "decision_id" => text_condition("d.id::text", filter, binds),
        "device" | "device_uid" | "device_id" | "uid" => {
            device_set_condition("d.device_uids", filter, binds)
        }
        "decision_kind" | "kind" => text_condition("d.decision_kind", filter, binds),
        "reason" => text_condition("d.reason", filter, binds),
        "subject" => text_condition("d.subject", filter, binds),
        "source" => text_condition("d.source", filter, binds),
        "occurrence_count" | "occurrences" => {
            numeric_condition("d.occurrence_count", filter, binds)
        }
        "device_count" => numeric_condition("cardinality(d.device_uids)", filter, binds),
        other => Err(ServiceError::InvalidRequest(format!(
            "unsupported identity_decisions filter '{other}'"
        ))),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::query::identity::tests_support::plan_for;

    #[test]
    fn projects_the_decision_and_its_evidence() {
        let (sql, _) = to_sql_and_params(&plan_for("in:identity_decisions limit:10")).unwrap();
        for column in [
            "d.decision_kind",
            "d.reason",
            "d.device_uids",
            "d.subject",
            "d.evidence",
            "d.occurrence_count",
            "d.last_decided_at",
        ] {
            assert!(sql.contains(column), "{column} missing from {sql}");
        }
        assert!(sql.contains("FROM platform.identity_decisions d"), "{sql}");
    }

    #[test]
    fn device_filter_uses_array_containment() {
        // `@>` is the operator the GIN index on device_uids serves; `= ANY(...)`
        // would scan the table.
        let (sql, binds) =
            to_sql_and_params(&plan_for("in:identity_decisions device:sr:aaa limit:5")).unwrap();
        assert!(sql.contains("d.device_uids @> ARRAY[$1]::text[]"), "{sql}");
        assert!(
            binds
                .iter()
                .any(|b| matches!(b, BindParam::Text(v) if v == "sr:aaa"))
        );
    }

    #[test]
    fn kind_and_time_filter() {
        let (sql, binds) = to_sql_and_params(&plan_for(
            "in:dire_decisions kind:policy_block time:last_24h",
        ))
        .unwrap();
        assert!(sql.contains("d.last_decided_at >= $"), "{sql}");
        assert!(sql.contains("d.decision_kind = $"), "{sql}");
        assert!(
            binds
                .iter()
                .any(|b| matches!(b, BindParam::Text(v) if v == "policy_block"))
        );
    }

    #[test]
    fn default_sort_is_most_recent_first() {
        let (sql, _) = to_sql_and_params(&plan_for("in:identity_decisions")).unwrap();
        assert!(sql.contains("ORDER BY last_decided_at DESC"), "{sql}");
    }

    #[test]
    fn unknown_filter_is_rejected() {
        let err = to_sql_and_params(&plan_for("in:identity_decisions nonsense:1")).unwrap_err();
        assert!(matches!(err, ServiceError::InvalidRequest(_)));
    }
}
