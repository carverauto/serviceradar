use super::QueryPlan;
use crate::{
    error::{Result, ServiceError},
    parser::{Entity, FilterOp},
};
use dgraph_topology::{TopologyClient, wrap_dql_value};
use serde_json::Value;

pub(super) async fn execute(plan: &QueryPlan, dgraph_url: Option<&str>) -> Result<Vec<Value>> {
    ensure_entity(plan)?;
    let dql = extract_dql(plan)?;
    let url = dgraph_url
        .filter(|value| !value.is_empty())
        .ok_or_else(|| ServiceError::InvalidRequest("graph_dql requires DGRAPH_URL".into()))?;

    let client = TopologyClient::connect(url)
        .await
        .map_err(|err| ServiceError::Internal(err.into()))?;
    let value = client
        .query_dql(&dql)
        .await
        .map_err(|err| ServiceError::Internal(err.into()))?;
    Ok(wrap_dql_value(value))
}

pub(super) fn to_sql_and_params(plan: &QueryPlan) -> Result<(String, Vec<super::BindParam>)> {
    ensure_entity(plan)?;
    let _ = extract_dql(plan)?;
    Err(ServiceError::InvalidRequest(
        "graph_dql is not SQL; execute it against Dgraph".into(),
    ))
}

fn ensure_entity(plan: &QueryPlan) -> Result<()> {
    match plan.entity {
        Entity::GraphDql => Ok(()),
        _ => Err(ServiceError::InvalidRequest(
            "entity not supported by graph_dql".into(),
        )),
    }
}

fn extract_dql(plan: &QueryPlan) -> Result<String> {
    let filter = plan
        .filters
        .iter()
        .find(|f| f.field == "dql" || f.field == "query")
        .ok_or_else(|| ServiceError::InvalidRequest("graph_dql requires dql:\"...\"".into()))?;

    if !matches!(filter.op, FilterOp::Eq) {
        return Err(ServiceError::InvalidRequest(
            "dql filter only supports equality".into(),
        ));
    }

    let raw = filter.value.as_scalar()?.trim();
    if raw.is_empty() {
        return Err(ServiceError::InvalidRequest(
            "dql query cannot be empty".into(),
        ));
    }

    ensure_read_only(raw)?;
    Ok(raw.to_string())
}

fn ensure_read_only(raw: &str) -> Result<()> {
    if refuses_mutation(raw) {
        return Err(ServiceError::InvalidRequest(
            "dql queries must be read-only (mutations are refused)".into(),
        ));
    }
    Ok(())
}

fn refuses_mutation(dql: &str) -> bool {
    let collapsed = dql
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
        .to_ascii_lowercase();
    collapsed.contains("mutation ")
        || collapsed.contains("mutation{")
        || collapsed.contains("set {")
        || collapsed.contains("set{")
        || collapsed.contains("delete {")
        || collapsed.contains("delete{")
        || collapsed.contains("upsert {")
        || collapsed.contains("upsert{")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn refuses_mutations() {
        assert!(refuses_mutation(
            "mutation { set { _:x <dgraph.type> \"Device\" } }"
        ));
        assert!(!refuses_mutation(
            "{ q(func: eq(device.id, \"sr:host01.example.com\")) { device.id } }"
        ));
    }
}
