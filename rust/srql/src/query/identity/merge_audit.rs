//! `in:merge_audit` -- device merge records, and `chain:` resolution of the
//! canonical merge chain.

use super::{
    BuiltSql, JsonPayload, MERGE_DETAILS_KEYS, depth_cap, jsonb_allowlist, numeric_condition,
    order_by, reject_aggregations, rewrite_placeholders, scalar_bool, scalar_text, text_condition,
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
    ("created_at", "created_at"),
    ("time", "created_at"),
    ("reason", "reason"),
    ("source", "source"),
    ("confidence_score", "confidence_score"),
    ("depth", "depth"),
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
    if !matches!(plan.entity, Entity::MergeAudit) {
        return Err(ServiceError::InvalidRequest(
            "entity not supported by merge_audit query".into(),
        ));
    }
    reject_aggregations(plan, "merge_audit")
}

fn chain_seed(filters: &[Filter]) -> Result<Option<String>> {
    match filters
        .iter()
        .find(|f| f.field.eq_ignore_ascii_case("chain"))
    {
        Some(filter) => Ok(Some(scalar_text(filter)?)),
        None => Ok(None),
    }
}

fn include_unmerge(filters: &[Filter]) -> Result<bool> {
    match filters
        .iter()
        .find(|f| f.field.eq_ignore_ascii_case("include_unmerge"))
    {
        Some(filter) => scalar_bool(filter),
        None => Ok(false),
    }
}

fn build_sql(plan: &QueryPlan) -> Result<BuiltSql> {
    match chain_seed(&plan.filters)? {
        Some(seed) => build_chain_sql(plan, &seed),
        None => build_flat_sql(plan),
    }
}

/// Flat listing. Unmerge rows are excluded by default, matching the
/// `MergeAudit` resource's own `:merged_from` / `:merged_to` reads.
fn build_flat_sql(plan: &QueryPlan) -> Result<BuiltSql> {
    let mut binds = Vec::new();
    let mut where_parts: Vec<String> = Vec::new();

    if !include_unmerge(&plan.filters)? {
        where_parts.push("(ma.reason IS NULL OR ma.reason <> 'unmerge')".to_string());
    }

    if let Some(TimeRange { start, end }) = &plan.time_range {
        where_parts.push("ma.created_at >= ? AND ma.created_at <= ?".to_string());
        binds.push(BindParam::timestamptz(*start));
        binds.push(BindParam::timestamptz(*end));
    }

    for filter in &plan.filters {
        if let Some(condition) = flat_filter_condition(filter, &mut binds)? {
            where_parts.push(condition);
        }
    }

    let where_sql = if where_parts.is_empty() {
        String::new()
    } else {
        format!(" WHERE {}", where_parts.join(" AND "))
    };

    let order_sql = order_by(
        &plan.order,
        ORDERABLE,
        "created_at DESC NULLS LAST, event_id",
    )?;
    let details = jsonb_allowlist("ma.details", MERGE_DETAILS_KEYS);

    binds.push(BindParam::Int(plan.limit));
    binds.push(BindParam::Int(plan.offset));

    let sql = format!(
        "SELECT to_jsonb(sub) AS payload FROM (\
           SELECT ma.event_id, ma.from_device_id, ma.to_device_id, ma.reason, \
                  ma.confidence_score, ma.source, {details} AS details, ma.created_at, \
                  NULL::int AS depth, NULL::text AS direction, false AS truncated \
           FROM platform.merge_audit ma\
           {where_sql} \
           ORDER BY {order_sql} \
           LIMIT ? OFFSET ?\
         ) sub"
    );

    Ok(BuiltSql { sql, binds })
}

fn flat_filter_condition(filter: &Filter, binds: &mut Vec<BindParam>) -> Result<Option<String>> {
    let field = filter.field.to_ascii_lowercase();
    let condition = match field.as_str() {
        // Consumed by build_sql / include_unmerge rather than emitted here.
        "chain" | "include_unmerge" | "depth" => return Ok(None),
        "from_device_id" | "from" => text_condition("ma.from_device_id", filter, binds)?,
        "to_device_id" | "to" => text_condition("ma.to_device_id", filter, binds)?,
        "device_id" | "device" | "device_uid" | "uid" => {
            // Either side of the merge. One bound value, used twice.
            let value = scalar_text(filter)?;
            binds.push(BindParam::Text(value.clone()));
            binds.push(BindParam::Text(value));
            "(ma.from_device_id = ? OR ma.to_device_id = ?)".to_string()
        }
        "reason" => text_condition("ma.reason", filter, binds)?,
        "source" => text_condition("ma.source", filter, binds)?,
        "confidence_score" | "confidence" => {
            numeric_condition("ma.confidence_score", filter, binds)?
        }
        other => {
            return Err(ServiceError::InvalidRequest(format!(
                "unsupported merge_audit filter '{other}'"
            )));
        }
    };
    Ok(Some(condition))
}

/// Recursive resolution of the merge chain from a seed device.
///
/// Walks forward (`from_device_id` matches, so "where did this device go") and
/// backward (`to_device_id` matches, so "what was merged into it"). Both
/// directions ride indexes that already exist:
/// `merge_audit_from_device_created_idx` and `merge_audit_to_device_idx`.
///
/// Termination does not assume an acyclic graph, because the graph is not
/// acyclic: oscillating pairs re-merged 18-22 times are a documented live
/// condition. The `visited` array plus `UNION` handles the cycle; the depth cap
/// handles a legitimately deep chain, and `truncated` tells the caller when the
/// cap bit rather than handing back a partial chain that looks complete.
///
/// One row per audit record, at its SHORTEST path from the seed. Distinguishing
/// rows by `(event_id, direction)` instead double-counts an oscillating pair:
/// the walk reaches `a -> b` going forward from `a` and again going backward
/// from `b`, so the same audit row came back twice carrying opposite
/// directions, which reads as two merges that never happened. Measured against
/// the fixture pair: 8 rows for 4 audit records.
fn build_chain_sql(plan: &QueryPlan, seed: &str) -> Result<BuiltSql> {
    let mut binds = Vec::new();
    let cap = depth_cap(&plan.filters)?;
    let unmerge_clause = if include_unmerge(&plan.filters)? {
        ""
    } else {
        " AND (ma.reason IS NULL OR ma.reason <> 'unmerge')"
    };

    for filter in &plan.filters {
        let field = filter.field.to_ascii_lowercase();
        if !matches!(field.as_str(), "chain" | "include_unmerge" | "depth") {
            return Err(ServiceError::InvalidRequest(format!(
                "merge_audit chain: does not combine with '{}'",
                filter.field
            )));
        }
    }

    let details = jsonb_allowlist("ma.details", MERGE_DETAILS_KEYS);

    // Bind order follows the TEXTUAL order of `?` below, not logical grouping:
    // walk seed, walk depth cap, anchor seed, capped-probe cap, limit, offset.
    binds.push(BindParam::Text(seed.to_string()));
    binds.push(BindParam::Int(cap));
    binds.push(BindParam::Text(seed.to_string()));
    binds.push(BindParam::Int(cap));
    binds.push(BindParam::Int(plan.limit));
    binds.push(BindParam::Int(plan.offset));

    let sql = format!(
        "WITH RECURSIVE walk AS (\
           SELECT ma.event_id, ma.from_device_id, ma.to_device_id, ma.reason, \
                  ma.confidence_score, ma.source, ma.details, ma.created_at, \
                  1 AS depth, \
                  CASE WHEN ma.from_device_id = seed.uid THEN 'merged_into' ELSE 'merged_from' END AS direction, \
                  CASE WHEN ma.from_device_id = seed.uid THEN ma.to_device_id ELSE ma.from_device_id END AS next_uid, \
                  ARRAY[seed.uid] AS visited \
           FROM (SELECT ?::text AS uid) seed \
           JOIN platform.merge_audit ma \
             ON ma.from_device_id = seed.uid OR ma.to_device_id = seed.uid\
           {unmerge_clause} \
           UNION \
           SELECT ma.event_id, ma.from_device_id, ma.to_device_id, ma.reason, \
                  ma.confidence_score, ma.source, ma.details, ma.created_at, \
                  w.depth + 1, \
                  w.direction, \
                  CASE WHEN ma.from_device_id = w.next_uid THEN ma.to_device_id ELSE ma.from_device_id END, \
                  w.visited || w.next_uid \
           FROM walk w \
           JOIN platform.merge_audit ma \
             ON (w.direction = 'merged_into' AND ma.from_device_id = w.next_uid) \
             OR (w.direction = 'merged_from' AND ma.to_device_id = w.next_uid) \
           WHERE NOT (w.next_uid = ANY(w.visited))\
             AND w.depth < ?\
           {unmerge_clause} \
         ), \
         anchor AS (SELECT ?::text AS uid), \
         capped AS (SELECT bool_or(depth >= ?) AS hit FROM walk) \
         SELECT to_jsonb(sub) AS payload FROM (\
           SELECT DISTINCT ON (walk.event_id) \
                  walk.event_id, walk.from_device_id, walk.to_device_id, walk.reason, \
                  walk.confidence_score, walk.source, \
                  {details_walk} AS details, walk.created_at, \
                  walk.depth, walk.direction, \
                  COALESCE((SELECT hit FROM capped), false) AS truncated, \
                  (SELECT uid FROM anchor) AS chain_seed \
           FROM walk \
           ORDER BY walk.event_id, walk.depth \
         ) sub \
         ORDER BY sub.depth, sub.created_at \
         LIMIT ? OFFSET ?",
        details_walk = details.replace("ma.details", "walk.details"),
    );

    Ok(BuiltSql { sql, binds })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::query::identity::tests_support::plan_for;

    #[test]
    fn flat_query_hides_unmerge_rows_by_default() {
        let (sql, _) = to_sql_and_params(&plan_for("in:merge_audit limit:10")).unwrap();
        assert!(sql.contains("<> 'unmerge'"), "{sql}");
    }

    #[test]
    fn include_unmerge_shows_them() {
        let (sql, _) =
            to_sql_and_params(&plan_for("in:merge_audit include_unmerge:true limit:10")).unwrap();
        assert!(!sql.contains("<> 'unmerge'"), "{sql}");
    }

    #[test]
    fn details_are_allowlisted_not_projected_whole() {
        let (sql, _) = to_sql_and_params(&plan_for("in:merge_audit limit:10")).unwrap();
        assert!(sql.contains("jsonb_each"), "{sql}");
        assert!(sql.contains("'component_size'"), "{sql}");
        // The raw column must never be selected as-is.
        assert!(!sql.contains("ma.details AS details"), "{sql}");
    }

    #[test]
    fn device_filter_matches_either_side() {
        let (sql, binds) =
            to_sql_and_params(&plan_for("in:merge_audit device_id:sr:aaa limit:10")).unwrap();
        assert!(sql.contains("from_device_id = $"), "{sql}");
        assert!(sql.contains("to_device_id = $"), "{sql}");
        // Both sides bind the same value; nothing is interpolated.
        let texts: Vec<_> = binds
            .iter()
            .filter_map(|b| match b {
                BindParam::Text(v) => Some(v.as_str()),
                _ => None,
            })
            .collect();
        assert_eq!(texts, vec!["sr:aaa", "sr:aaa"]);
    }

    #[test]
    fn chain_walks_both_directions_and_bounds_itself() {
        let (sql, binds) =
            to_sql_and_params(&plan_for("in:merge_audit chain:sr:aaa limit:50")).unwrap();
        assert!(sql.contains("WITH RECURSIVE"), "{sql}");
        assert!(sql.contains("merged_into"), "{sql}");
        assert!(sql.contains("merged_from"), "{sql}");
        // Cycle guard and depth cap, both present.
        assert!(sql.contains("= ANY(w.visited)"), "{sql}");
        assert!(sql.contains("w.depth <"), "{sql}");
        assert!(sql.contains("truncated"), "{sql}");
        // UNION, never UNION ALL: repeated edges in an oscillating pair must
        // collapse rather than accumulate.
        assert!(!sql.contains("UNION ALL"), "{sql}");
        assert!(matches!(binds.as_slice(), [BindParam::Text(v), ..] if v == "sr:aaa"));
    }

    #[test]
    fn chain_binds_are_in_textual_placeholder_order() {
        // The placeholders interleave seed and cap; pushing them grouped sends
        // a uuid where the depth cap belongs and the query fails at execute
        // time, not at build time.
        let (_, binds) =
            to_sql_and_params(&plan_for("in:merge_audit chain:sr:aaa limit:50")).unwrap();
        assert!(
            matches!(
                binds.as_slice(),
                [
                    BindParam::Text(_),
                    BindParam::Int(_),
                    BindParam::Text(_),
                    BindParam::Int(_),
                    BindParam::Int(_),
                    BindParam::Int(_),
                ]
            ),
            "{binds:?}"
        );
    }

    #[test]
    fn chain_returns_each_audit_row_once() {
        // DISTINCT ON must be the event alone. Adding `direction` to the key
        // lets an oscillating pair report the same merge twice with opposite
        // directions -- two merges that never happened.
        let (sql, _) =
            to_sql_and_params(&plan_for("in:merge_audit chain:sr:aaa limit:50")).unwrap();
        assert!(sql.contains("DISTINCT ON (walk.event_id)"), "{sql}");
        assert!(
            !sql.contains("DISTINCT ON (walk.event_id, walk.direction)"),
            "{sql}"
        );
    }

    #[test]
    fn chain_seed_is_bound_not_interpolated() {
        let injection = "sr:aaa' OR '1'='1";
        let query = format!("in:merge_audit chain:\"{injection}\" limit:10");
        let (sql, binds) = to_sql_and_params(&plan_for(&query)).unwrap();
        assert!(!sql.contains("1'='1"), "{sql}");
        assert!(
            binds
                .iter()
                .any(|b| matches!(b, BindParam::Text(v) if v == injection))
        );
    }

    #[test]
    fn chain_rejects_unrelated_filters() {
        let err = to_sql_and_params(&plan_for(
            "in:merge_audit chain:sr:aaa reason:duplicate_mac",
        ))
        .unwrap_err();
        assert!(matches!(err, ServiceError::InvalidRequest(_)));
    }

    #[test]
    fn unknown_filter_is_rejected() {
        let err = to_sql_and_params(&plan_for("in:merge_audit nonsense:1")).unwrap_err();
        assert!(matches!(err, ServiceError::InvalidRequest(_)));
    }
}
