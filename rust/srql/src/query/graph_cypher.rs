use super::{BindParam, QueryPlan};
use crate::{
    error::{Result, ServiceError},
    parser::{Entity, FilterOp},
};
use diesel::deserialize::QueryableByName;
use diesel::pg::Pg;
use diesel::sql_query;
use diesel::sql_types::{Jsonb, Nullable, Text};
use diesel_async::{AsyncPgConnection, RunQueryDsl};
use serde_json::Value;

const GRAPH_NAME: &str = "serviceradar";

pub(super) async fn execute(conn: &mut AsyncPgConnection, plan: &QueryPlan) -> Result<Vec<Value>> {
    ensure_entity(plan)?;
    let cypher = extract_cypher(plan)?;

    let sql = build_sql();
    let mut query = sql_query(rewrite_placeholders(&sql)).into_boxed::<Pg>();
    query = query.bind::<Text, _>(cypher);
    query = query.bind::<diesel::sql_types::Int8, _>(plan.limit);
    query = query.bind::<diesel::sql_types::Int8, _>(plan.offset);

    let rows: Vec<CypherRow> = query
        .load(conn)
        .await
        .map_err(|err| ServiceError::Internal(err.into()))?;

    Ok(rows.into_iter().filter_map(|row| row.result).collect())
}

pub(super) fn to_sql_and_params(plan: &QueryPlan) -> Result<(String, Vec<BindParam>)> {
    ensure_entity(plan)?;
    let cypher = extract_cypher(plan)?;

    Ok((
        rewrite_placeholders(&build_sql()),
        vec![
            BindParam::Text(cypher),
            BindParam::Int(plan.limit),
            BindParam::Int(plan.offset),
        ],
    ))
}

fn ensure_entity(plan: &QueryPlan) -> Result<()> {
    match plan.entity {
        Entity::GraphCypher => Ok(()),
        _ => Err(ServiceError::InvalidRequest(
            "entity not supported by graph_cypher".into(),
        )),
    }
}

fn build_sql() -> String {
    format!(
        "WITH _config AS (\n  SELECT set_config('search_path', 'ag_catalog,pg_catalog,\"$user\",public', false)\n),\n_rows AS (\n  SELECT (result::text)::jsonb AS r\n  FROM ag_catalog.cypher('{GRAPH_NAME}', ?) AS (result ag_catalog.agtype)\n  LIMIT ? OFFSET ?\n)\nSELECT\n  CASE\n    WHEN jsonb_typeof(r) = 'object' AND ((r ? 'nodes') OR (r ? 'vertices')) AND (r ? 'edges') THEN r\n    WHEN jsonb_typeof(r) = 'object' AND ((r ? 'start_id') OR (r ? 'end_id')) THEN jsonb_build_object(\n      'nodes', jsonb_build_array(\n        jsonb_build_object('id', r->>'start_id', 'label', r->>'start_id'),\n        jsonb_build_object('id', r->>'end_id', 'label', r->>'end_id')\n      ),\n      'edges', jsonb_build_array(r)\n    )\n    WHEN jsonb_typeof(r) = 'object' AND (r ? 'id') THEN jsonb_build_object('nodes', jsonb_build_array(r), 'edges', '[]'::jsonb)\n    ELSE jsonb_build_object('nodes', '[]'::jsonb, 'edges', '[]'::jsonb, 'rows', jsonb_build_array(r))\n  END AS result\nFROM _rows"
    )
}

fn extract_cypher(plan: &QueryPlan) -> Result<String> {
    let filter = plan
        .filters
        .iter()
        .find(|f| f.field == "cypher")
        .ok_or_else(|| {
            ServiceError::InvalidRequest("graph_cypher requires cypher:\"...\"".into())
        })?;

    if !matches!(filter.op, FilterOp::Eq) {
        return Err(ServiceError::InvalidRequest(
            "cypher filter only supports equality".into(),
        ));
    }

    let raw = filter.value.as_scalar()?.trim();
    if raw.is_empty() {
        return Err(ServiceError::InvalidRequest(
            "cypher query cannot be empty".into(),
        ));
    }

    ensure_read_only(raw)?;
    Ok(raw.to_string())
}

fn ensure_read_only(raw: &str) -> Result<()> {
    let lower = raw.to_lowercase();
    if lower.contains(';') {
        return Err(ServiceError::InvalidRequest(
            "cypher queries must not contain ';'".into(),
        ));
    }

    for keyword in [
        "create", "merge", "set", "delete", "detach", "remove", "drop", "call",
    ] {
        if lower
            .split(|c: char| !c.is_ascii_alphanumeric() && c != '_')
            .any(|token| token == keyword)
        {
            return Err(ServiceError::InvalidRequest(format!(
                "cypher queries must be read-only (found '{keyword}')"
            )));
        }
    }

    Ok(())
}

#[derive(Debug, QueryableByName)]
struct CypherRow {
    #[diesel(sql_type = Nullable<Jsonb>)]
    result: Option<Value>,
}

fn rewrite_placeholders(sql: &str) -> String {
    let mut result = String::with_capacity(sql.len());
    let mut index = 1;
    for ch in sql.chars() {
        if ch == '?' {
            result.push('$');
            result.push_str(&index.to_string());
            index += 1;
        } else {
            result.push(ch);
        }
    }
    result
}
