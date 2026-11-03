/*
 * Copyright 2026 Carver Automation Corporation.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

//! The `{nodes, edges}` row shape a read-only DQL result is returned in, shared
//! by SRQL `in:graph` and the web-ng NIF so both emit the same rows.

use serde_json::{Map, Value, json};

/// Wrap a DQL response into topology rows: a `nodes`/`edges` object becomes
/// one row, every array under a query block becomes one row per item, and
/// anything else is carried under `rows`.
pub fn wrap_dql_value(value: Value) -> Vec<Value> {
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

    let mut out = Map::new();
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
