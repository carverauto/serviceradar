use super::QueryPlan;
use crate::{
    error::{Result, ServiceError},
    parser::{Entity, FilterOp},
};
use dgraph_topology::TopologyClient;
use serde_json::{Value, json};

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

pub(super) fn wrap_dql_value(value: Value) -> Vec<Value> {
    match value {
        Value::Object(map) => {
            if map.contains_key("nodes") || map.contains_key("edges") {
                return vec![wrap_topology_object(Value::Object(map))];
            }

            let mut wrapped = Vec::new();
            for (_key, nested) in map {
                if let Value::Array(items) = nested {
                    wrapped.extend(items.into_iter().map(wrap_row));
                }
            }
            if wrapped.is_empty() {
                vec![json!({"nodes": [], "edges": [], "rows": []})]
            } else {
                wrapped
            }
        }
        Value::Array(items) => items.into_iter().map(wrap_row).collect(),
        other => vec![json!({"nodes": [], "edges": [], "rows": [other]})],
    }
}

fn wrap_topology_object(value: Value) -> Value {
    let Value::Object(map) = value else {
        return wrap_row(value);
    };

    let nodes = match map.get("nodes") {
        Some(Value::Array(items)) => items
            .iter()
            .cloned()
            .map(flatten_topology_row)
            .collect::<Vec<_>>(),
        Some(other) => vec![flatten_topology_row(other.clone())],
        None => Vec::new(),
    };
    let edges = match map.get("edges") {
        Some(Value::Array(items)) => items
            .iter()
            .cloned()
            .map(flatten_topology_row)
            .collect::<Vec<_>>(),
        Some(other) => vec![flatten_topology_row(other.clone())],
        None => Vec::new(),
    };
    json!({"nodes": nodes, "edges": edges})
}

fn wrap_row(row: Value) -> Value {
    let flattened = flatten_topology_row(row);
    if flattened.get("nodes").is_some() && flattened.get("edges").is_some() {
        return flattened;
    }

    if flattened.get("start_id").is_some() || flattened.get("end_id").is_some() {
        let start = flattened
            .get("start_id")
            .and_then(Value::as_str)
            .unwrap_or("");
        let end = flattened
            .get("end_id")
            .and_then(Value::as_str)
            .unwrap_or("");
        return json!({
            "nodes": [
                {"id": start, "label": start},
                {"id": end, "label": end}
            ],
            "edges": [flattened]
        });
    }

    if flattened.get("id").is_some() {
        return json!({"nodes": [flattened], "edges": []});
    }

    json!({"nodes": [], "edges": [], "rows": [flattened]})
}

fn flatten_topology_row(row: Value) -> Value {
    let Value::Object(map) = row else {
        return row;
    };

    let mut out = serde_json::Map::new();
    for (key, value) in map {
        match key.as_str() {
            "topo.src" | "src" | "start" => {
                if let Some(id) = nested_device_id(&value) {
                    out.insert("start_id".to_string(), json!(id));
                }
            }
            "topo.dst" | "dst" | "end" => {
                if let Some(id) = nested_device_id(&value) {
                    out.insert("end_id".to_string(), json!(id));
                }
            }
            "topo.kind" | "kind" | "label" => {
                out.insert("label".to_string(), value);
            }
            "device.id" => {
                out.insert("id".to_string(), value);
            }
            other => {
                out.insert(other.to_string(), value);
            }
        }
    }
    Value::Object(out)
}

fn nested_device_id(value: &Value) -> Option<String> {
    match value {
        Value::Array(items) => items.first().and_then(nested_device_id),
        Value::Object(map) => map
            .get("device.id")
            .or_else(|| map.get("id"))
            .and_then(Value::as_str)
            .map(str::to_string),
        Value::String(id) => Some(id.clone()),
        _ => None,
    }
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

    #[test]
    fn wraps_reified_topology_edges() {
        let value = json!({
            "edges": [{
                "topo.kind": "CONNECTS_TO",
                "topo.src": [{"device.id": "sr:host01.example.com"}],
                "topo.dst": [{"device.id": "sr:host02.example.com"}]
            }]
        });
        let wrapped = wrap_dql_value(value);
        assert_eq!(wrapped.len(), 1);
        assert_eq!(
            wrapped[0]["edges"][0]["start_id"],
            json!("sr:host01.example.com")
        );
        assert_eq!(
            wrapped[0]["edges"][0]["end_id"],
            json!("sr:host02.example.com")
        );
        assert_eq!(wrapped[0]["edges"][0]["label"], json!("CONNECTS_TO"));
    }
}
