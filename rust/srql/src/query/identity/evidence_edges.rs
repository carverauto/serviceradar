//! `in:identity_evidence_edges` -- the connected component of devices joined by
//! shared identifiers.
//!
//! Each row is one edge, not one identifier. `direct` separates evidence
//! incident to the seed from mere transitive connectivity, which is exactly the
//! distinction that makes a blocked component legible: the scheduled sweep
//! refuses components larger than a pair precisely because their vertices may
//! share no direct evidence.

use super::{
    BuiltSql, JsonPayload, depth_cap, order_by, reject_aggregations, rewrite_placeholders,
    scalar_text,
};
use crate::{
    error::{Result, ServiceError},
    parser::{Entity, Filter},
    query::{BindParam, QueryPlan, bind_sql_param},
};
use diesel::pg::Pg;
use diesel::sql_query;
use diesel_async::{AsyncPgConnection, RunQueryDsl};
use serde_json::Value;

const ORDERABLE: &[(&str, &str)] = &[
    ("depth", "depth"),
    ("identifier_type", "identifier_type"),
    ("identifier_value", "identifier_value"),
    ("device_a", "device_a"),
    ("device_b", "device_b"),
];

/// Merge evidence never crosses a partition, and neither does this walk. An
/// edge is reported as `cross_partition` when the two devices' own partitions
/// disagree even though the identifier row sits in one partition -- that is the
/// ambiguous case an operator needs to see, not a reason to traverse further.
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
    if !matches!(plan.entity, Entity::IdentityEvidenceEdges) {
        return Err(ServiceError::InvalidRequest(
            "entity not supported by identity_evidence_edges query".into(),
        ));
    }
    reject_aggregations(plan, "identity_evidence_edges")
}

fn seed(filters: &[Filter]) -> Result<String> {
    let found = filters.iter().find(|f| {
        matches!(
            f.field.to_ascii_lowercase().as_str(),
            "device" | "device_id" | "device_uid" | "uid" | "component"
        )
    });

    match found {
        Some(filter) => scalar_text(filter),
        // Refusing is the point. An unseeded walk is a self-join across a table
        // that carries millions of rows; serving it slowly would be worse than
        // saying no, because the caller would not know it had asked for that.
        None => Err(ServiceError::InvalidRequest(
            "identity_evidence_edges requires a device: seed, for example \
             in:identity_evidence_edges device:sr:<uuid>"
                .into(),
        )),
    }
}

fn build_sql(plan: &QueryPlan) -> Result<BuiltSql> {
    let anchor = seed(&plan.filters)?;
    let cap = depth_cap(&plan.filters)?;

    let mut type_filter = String::new();
    let mut extra_binds: Vec<BindParam> = Vec::new();

    for filter in &plan.filters {
        let field = filter.field.to_ascii_lowercase();
        match field.as_str() {
            "device" | "device_id" | "device_uid" | "uid" | "component" | "depth" => {}
            "identifier_type" | "type" => {
                extra_binds.push(BindParam::Text(scalar_text(filter)?));
                type_filter = " AND di.identifier_type = ?".to_string();
            }
            other => {
                return Err(ServiceError::InvalidRequest(format!(
                    "unsupported identity_evidence_edges filter '{other}'"
                )));
            }
        }
    }

    let order_sql = order_by(
        &plan.order,
        ORDERABLE,
        "depth, identifier_type, identifier_value",
    )?;

    // Bind order follows the textual order of `?` in the SQL below.
    let mut binds = Vec::new();
    binds.push(BindParam::Text(anchor.clone()));
    binds.extend(extra_binds.iter().cloned());
    binds.push(BindParam::Int(cap));
    binds.extend(extra_binds.iter().cloned());
    binds.push(BindParam::Text(anchor.clone()));
    binds.push(BindParam::Text(anchor));
    binds.push(BindParam::Int(cap));
    binds.push(BindParam::Int(plan.limit));
    binds.push(BindParam::Int(plan.offset));

    let sql = format!(
        "WITH RECURSIVE reach AS (\
           SELECT ?::text AS device_id, 0 AS depth, ARRAY[]::text[] AS visited \
           UNION \
           SELECT peer.device_id, r.depth + 1, r.visited || r.device_id \
           FROM reach r \
           JOIN platform.device_identifiers di ON di.device_id = r.device_id\
           {type_filter} \
           JOIN platform.device_identifiers peer \
             ON peer.identifier_type = di.identifier_type \
            AND peer.identifier_value = di.identifier_value \
            AND peer.partition = di.partition \
            AND peer.device_id <> di.device_id \
           WHERE NOT (peer.device_id = ANY(r.visited)) \
             AND r.depth < ? \
         ), \
         edges AS (\
           SELECT DISTINCT ON (a.device_id, b.device_id, a.identifier_type, a.identifier_value) \
                  a.device_id AS device_a, b.device_id AS device_b, \
                  a.identifier_type, a.identifier_value, a.partition AS identifier_partition, \
                  a.confidence, \
                  LEAST(ra.depth, rb.depth) + 1 AS depth \
           FROM reach ra \
           JOIN platform.device_identifiers a ON a.device_id = ra.device_id\
           {type_filter} \
           JOIN platform.device_identifiers b \
             ON b.identifier_type = a.identifier_type \
            AND b.identifier_value = a.identifier_value \
            AND b.partition = a.partition \
            AND b.device_id > a.device_id \
           JOIN reach rb ON rb.device_id = b.device_id \
           ORDER BY a.device_id, b.device_id, a.identifier_type, a.identifier_value, depth \
         ) \
         SELECT to_jsonb(sub) AS payload FROM (\
           SELECT e.device_a, e.device_b, e.identifier_type, e.identifier_value, \
                  e.identifier_partition, e.confidence, e.depth, \
                  (e.device_a = ?::text OR e.device_b = ?::text) AS direct, \
                  COALESCE(da.partition, e.identifier_partition) AS partition_a, \
                  COALESCE(db.partition, e.identifier_partition) AS partition_b, \
                  (COALESCE(da.partition, e.identifier_partition) \
                     IS DISTINCT FROM COALESCE(db.partition, e.identifier_partition)) AS cross_partition, \
                  (da.deleted_at IS NOT NULL) AS device_a_deleted, \
                  (db.deleted_at IS NOT NULL) AS device_b_deleted, \
                  COALESCE((SELECT bool_or(depth >= ?) FROM reach), false) AS truncated \
           FROM edges e \
           LEFT JOIN platform.ocsf_devices da ON da.uid = e.device_a \
           LEFT JOIN platform.ocsf_devices db ON db.uid = e.device_b \
           ORDER BY {order_sql} \
           LIMIT ? OFFSET ?\
         ) sub"
    );

    Ok(BuiltSql { sql, binds })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::query::identity::tests_support::plan_for;

    #[test]
    fn unseeded_query_is_refused_not_served_slowly() {
        let err = to_sql_and_params(&plan_for("in:identity_evidence_edges limit:10")).unwrap_err();
        match err {
            ServiceError::InvalidRequest(message) => {
                assert!(message.contains("device:"), "{message}");
            }
            other => panic!("expected InvalidRequest, got {other:?}"),
        }
    }

    #[test]
    fn seeded_walk_projects_direct_and_cross_partition() {
        let (sql, _) = to_sql_and_params(&plan_for(
            "in:identity_evidence_edges device:sr:aaa limit:50",
        ))
        .unwrap();
        assert!(sql.contains("WITH RECURSIVE"), "{sql}");
        assert!(sql.contains("AS direct"), "{sql}");
        assert!(sql.contains("AS cross_partition"), "{sql}");
        assert!(sql.contains("AS depth"), "{sql}");
    }

    #[test]
    fn walk_bounds_itself_against_cycles_and_depth() {
        let (sql, _) =
            to_sql_and_params(&plan_for("in:evidence_edges device:sr:aaa limit:50")).unwrap();
        assert!(sql.contains("= ANY(r.visited)"), "{sql}");
        assert!(sql.contains("r.depth < $"), "{sql}");
        // UNION, not UNION ALL: a cycle must collapse rather than accumulate.
        assert!(!sql.contains("UNION ALL"), "{sql}");
        assert!(sql.contains("truncated"), "{sql}");
    }

    #[test]
    fn direct_is_tested_on_both_endpoints() {
        // `b.device_id > a.device_id` orders each pair, so the seed lands on
        // either side depending on its uid. Testing only device_a would report
        // half the seed-incident edges as transitive.
        let (sql, binds) =
            to_sql_and_params(&plan_for("in:evidence_edges device:sr:mmm limit:50")).unwrap();
        assert!(
            sql.contains("(e.device_a = $") && sql.contains("OR e.device_b = $"),
            "{sql}"
        );
        let seeds = binds
            .iter()
            .filter(|b| matches!(b, BindParam::Text(v) if v == "sr:mmm"))
            .count();
        assert!(
            seeds >= 3,
            "seed must be bound for the walk and both sides of direct"
        );
    }

    #[test]
    fn edges_are_undirected_and_not_self_joined() {
        let (sql, _) = to_sql_and_params(&plan_for("in:identity_evidence device:sr:aaa")).unwrap();
        // b.device_id > a.device_id yields each unordered pair once and
        // excludes a device paired with itself.
        assert!(sql.contains("b.device_id > a.device_id"), "{sql}");
    }

    #[test]
    fn seed_is_bound_not_interpolated() {
        let injection = "sr:aaa'; DROP TABLE platform.device_identifiers; --";
        let query = format!("in:evidence_edges device:\"{injection}\" limit:10");
        let (sql, binds) = to_sql_and_params(&plan_for(&query)).unwrap();
        assert!(!sql.contains("DROP TABLE"), "{sql}");
        assert!(
            binds
                .iter()
                .any(|b| matches!(b, BindParam::Text(v) if v == injection))
        );
    }

    #[test]
    fn unknown_filter_is_rejected() {
        let err =
            to_sql_and_params(&plan_for("in:evidence_edges device:sr:aaa nonsense:1")).unwrap_err();
        assert!(matches!(err, ServiceError::InvalidRequest(_)));
    }
}
