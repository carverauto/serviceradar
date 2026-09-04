//! `in:identity_reconciliation_runs` -- one row per scheduled sweep.

use super::{
    BuiltSql, JsonPayload, bool_condition, numeric_condition, order_by, reject_aggregations,
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
    ("started_at", "started_at"),
    ("time", "started_at"),
    ("completed_at", "completed_at"),
    ("duration_ms", "duration_ms"),
    ("merges", "merges"),
    ("errors", "errors"),
    ("blocked_components", "blocked_components"),
    ("largest_blocked_component", "largest_blocked_component"),
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
    if !matches!(plan.entity, Entity::IdentityReconciliationRuns) {
        return Err(ServiceError::InvalidRequest(
            "entity not supported by identity_reconciliation_runs query".into(),
        ));
    }
    reject_aggregations(plan, "identity_reconciliation_runs")
}

fn build_sql(plan: &QueryPlan) -> Result<BuiltSql> {
    let mut binds = Vec::new();
    let mut where_parts: Vec<String> = Vec::new();

    if let Some(TimeRange { start, end }) = &plan.time_range {
        where_parts.push("r.started_at >= ? AND r.started_at <= ?".to_string());
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

    let order_sql = order_by(&plan.order, ORDERABLE, "started_at DESC")?;

    binds.push(BindParam::Int(plan.limit));
    binds.push(BindParam::Int(plan.offset));

    let sql = format!(
        "SELECT to_jsonb(sub) AS payload FROM (\
           SELECT r.run_id, r.started_at, r.completed_at, r.duration_ms, r.status, \
                  r.error_summary, r.duplicate_identifier_count, r.duplicate_components, \
                  r.mergeable_components, r.blocked_components, r.blocked_devices, \
                  r.largest_blocked_component, r.merges, r.errors, r.max_merges_configured, \
                  r.merge_cap_reached, r.blocked_component_devices, r.trigger, r.job_schedule_id \
           FROM platform.identity_reconciliation_runs r\
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
        "run_id" | "run" => text_condition("r.run_id::text", filter, binds),
        "status" => text_condition("r.status", filter, binds),
        "trigger" => text_condition("r.trigger", filter, binds),
        "merge_cap_reached" | "capped" => bool_condition("r.merge_cap_reached", filter, binds),
        "merges" => numeric_condition("r.merges", filter, binds),
        "errors" => numeric_condition("r.errors", filter, binds),
        "blocked_components" => numeric_condition("r.blocked_components", filter, binds),
        "blocked_devices" => numeric_condition("r.blocked_devices", filter, binds),
        "largest_blocked_component" => {
            numeric_condition("r.largest_blocked_component", filter, binds)
        }
        "mergeable_components" => numeric_condition("r.mergeable_components", filter, binds),
        "duplicate_components" => numeric_condition("r.duplicate_components", filter, binds),
        "duplicate_identifier_count" => {
            numeric_condition("r.duplicate_identifier_count", filter, binds)
        }
        "duration_ms" => numeric_condition("r.duration_ms", filter, binds),
        "job_schedule_id" => numeric_condition("r.job_schedule_id", filter, binds),
        other => Err(ServiceError::InvalidRequest(format!(
            "unsupported identity_reconciliation_runs filter '{other}'"
        ))),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::query::identity::tests_support::plan_for;

    #[test]
    fn projects_the_cap_and_whether_it_was_reached() {
        let (sql, _) =
            to_sql_and_params(&plan_for("in:reconciliation_runs time:last_24h")).unwrap();
        assert!(sql.contains("r.max_merges_configured"), "{sql}");
        assert!(sql.contains("r.merge_cap_reached"), "{sql}");
        assert!(sql.contains("r.largest_blocked_component"), "{sql}");
        assert!(sql.contains("r.blocked_component_devices"), "{sql}");
    }

    #[test]
    fn failed_runs_are_filterable_with_their_error() {
        let (sql, binds) =
            to_sql_and_params(&plan_for("in:dire_runs status:failed limit:10")).unwrap();
        assert!(sql.contains("r.status = $"), "{sql}");
        assert!(sql.contains("r.error_summary"), "{sql}");
        assert!(
            binds
                .iter()
                .any(|b| matches!(b, BindParam::Text(v) if v == "failed"))
        );
    }

    #[test]
    fn capped_runs_are_filterable() {
        let (sql, binds) =
            to_sql_and_params(&plan_for("in:reconciliation_runs merge_cap_reached:true")).unwrap();
        assert!(sql.contains("r.merge_cap_reached"), "{sql}");
        assert!(binds.iter().any(|b| matches!(b, BindParam::Bool(true))));
    }

    #[test]
    fn default_sort_is_newest_first() {
        let (sql, _) = to_sql_and_params(&plan_for("in:reconciliation_runs")).unwrap();
        assert!(sql.contains("ORDER BY started_at DESC"), "{sql}");
    }

    #[test]
    fn unknown_filter_is_rejected() {
        let err = to_sql_and_params(&plan_for("in:dire_runs nonsense:1")).unwrap_err();
        assert!(matches!(err, ServiceError::InvalidRequest(_)));
    }
}
