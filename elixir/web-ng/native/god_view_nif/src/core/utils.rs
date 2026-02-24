use crate::types::graph::{runtime_graph_atoms, RuntimeGraphRow};
use rustler::Term;
use serde_json::json;
use std::collections::{HashMap, HashSet};

pub fn map_get_any<'a>(
    map: Term<'a>,
    atom_key: rustler::Atom,
    string_key: &str,
) -> Option<Term<'a>> {
    map.map_get(atom_key)
        .ok()
        .or_else(|| map.map_get(string_key).ok())
}

pub fn term_as_string(term: Term<'_>) -> Option<String> {
    if let Ok(v) = term.decode::<String>() {
        return Some(v);
    }
    if let Ok(v) = term.decode::<i64>() {
        return Some(v.to_string());
    }
    if let Ok(v) = term.decode::<u64>() {
        return Some(v.to_string());
    }
    if let Ok(v) = term.decode::<f64>() {
        return Some(v.to_string());
    }
    None
}

pub fn term_as_i64(term: Term<'_>) -> Option<i64> {
    if let Ok(v) = term.decode::<i64>() {
        return Some(v);
    }
    if let Ok(v) = term.decode::<u64>() {
        return i64::try_from(v).ok();
    }
    if let Ok(v) = term.decode::<f64>() {
        return Some(v as i64);
    }
    if let Ok(v) = term.decode::<String>() {
        return v.trim().parse::<i64>().ok();
    }
    None
}

pub fn term_as_f64(term: Term<'_>) -> Option<f64> {
    if let Ok(v) = term.decode::<f64>() {
        return Some(v);
    }
    if let Ok(v) = term.decode::<i64>() {
        return Some(v as f64);
    }
    if let Ok(v) = term.decode::<u64>() {
        return Some(v as f64);
    }
    if let Ok(v) = term.decode::<String>() {
        return v.trim().parse::<f64>().ok();
    }
    None
}

pub fn runtime_graph_row_from_term(row: Term<'_>) -> Option<RuntimeGraphRow> {
    if !row.is_map() {
        return None;
    }

    let local_device_id = map_get_any(
        row,
        runtime_graph_atoms::local_device_id(),
        "local_device_id",
    )
    .and_then(term_as_string)
    .unwrap_or_default();
    let local_device_ip = map_get_any(
        row,
        runtime_graph_atoms::local_device_ip(),
        "local_device_ip",
    )
    .and_then(term_as_string)
    .unwrap_or_default();
    let local_if_name = map_get_any(row, runtime_graph_atoms::local_if_name(), "local_if_name")
        .and_then(term_as_string)
        .unwrap_or_default();
    let local_if_index = map_get_any(row, runtime_graph_atoms::local_if_index(), "local_if_index")
        .and_then(term_as_i64)
        .unwrap_or(-1);
    let neighbor_device_id = map_get_any(
        row,
        runtime_graph_atoms::neighbor_device_id(),
        "neighbor_device_id",
    )
    .and_then(term_as_string)
    .unwrap_or_default();
    let neighbor_mgmt_addr = map_get_any(
        row,
        runtime_graph_atoms::neighbor_mgmt_addr(),
        "neighbor_mgmt_addr",
    )
    .and_then(term_as_string)
    .unwrap_or_default();
    let neighbor_system_name = map_get_any(
        row,
        runtime_graph_atoms::neighbor_system_name(),
        "neighbor_system_name",
    )
    .and_then(term_as_string)
    .unwrap_or_default();
    let protocol = map_get_any(row, runtime_graph_atoms::protocol(), "protocol")
        .and_then(term_as_string)
        .unwrap_or_default();
    let confidence_tier = map_get_any(
        row,
        runtime_graph_atoms::confidence_tier(),
        "confidence_tier",
    )
    .and_then(term_as_string)
    .unwrap_or_else(|| "unknown".to_string());

    let metadata_term = map_get_any(row, runtime_graph_atoms::metadata(), "metadata");
    let metadata_source = metadata_term
        .and_then(|meta| map_get_any(meta, runtime_graph_atoms::source(), "source"))
        .and_then(term_as_string)
        .unwrap_or_default();
    let metadata_inference = metadata_term
        .and_then(|meta| map_get_any(meta, runtime_graph_atoms::inference(), "inference"))
        .and_then(term_as_string)
        .unwrap_or_default();
    let metadata_confidence_tier = metadata_term
        .and_then(|meta| {
            map_get_any(
                meta,
                runtime_graph_atoms::confidence_tier(),
                "confidence_tier",
            )
        })
        .and_then(term_as_string)
        .unwrap_or_else(|| confidence_tier.clone());
    let metadata_confidence_score = metadata_term
        .and_then(|meta| {
            map_get_any(
                meta,
                runtime_graph_atoms::confidence_score(),
                "confidence_score",
            )
        })
        .and_then(term_as_f64)
        .unwrap_or(0.0);

    let metadata_json = json!({
        "source": metadata_source,
        "inference": metadata_inference,
        "confidence_tier": metadata_confidence_tier,
        "confidence_score": metadata_confidence_score
    })
    .to_string();

    Some(RuntimeGraphRow {
        local_device_id,
        local_device_ip,
        local_if_name,
        local_if_index,
        neighbor_device_id,
        neighbor_mgmt_addr,
        neighbor_system_name,
        protocol,
        confidence_tier,
        metadata_json,
    })
}

pub fn normalized_id(value: &str) -> Option<String> {
    let trimmed = value.trim();
    if trimmed.is_empty() {
        return None;
    }
    let lowered = trimmed.to_ascii_lowercase();
    if ["nil", "null", "undefined", "unknown", "n/a", "na", "-"].contains(&lowered.as_str()) {
        return None;
    }
    Some(trimmed.to_string())
}

pub fn build_node_index(node_ids: &[String]) -> HashMap<String, usize> {
    let mut index = HashMap::with_capacity(node_ids.len() * 2);
    for (idx, id) in node_ids.iter().enumerate() {
        if let Some(norm) = normalized_id(id) {
            index.insert(norm.clone(), idx);
            index.insert(norm.to_ascii_lowercase(), idx);
        }
    }
    index
}

pub fn resolve_endpoint(
    row: &RuntimeGraphRow,
    node_index: &HashMap<String, usize>,
    is_source: bool,
) -> Option<usize> {
    let candidates: Vec<&str> = if is_source {
        vec![&row.local_device_id, &row.local_device_ip]
    } else {
        vec![
            &row.neighbor_device_id,
            &row.neighbor_mgmt_addr,
            &row.neighbor_system_name,
        ]
    };

    for candidate in candidates {
        if let Some(norm) = normalized_id(candidate) {
            if let Some(idx) = node_index.get(&norm) {
                return Some(*idx);
            }
            let lowered = norm.to_ascii_lowercase();
            if let Some(idx) = node_index.get(&lowered) {
                return Some(*idx);
            }
        }
    }
    None
}

pub fn indexed_edges_from_runtime_rows(
    rows: &[RuntimeGraphRow],
    node_ids: &[String],
) -> Vec<(u32, u32, String)> {
    let node_index = build_node_index(node_ids);
    let mut seen = HashSet::<(u32, u32)>::new();
    let mut indexed = Vec::<(u32, u32, String)>::new();

    for row in rows {
        let Some(src) = resolve_endpoint(row, &node_index, true) else {
            continue;
        };
        let Some(dst) = resolve_endpoint(row, &node_index, false) else {
            continue;
        };
        if src == dst {
            continue;
        }

        let src_u32 = src as u32;
        let dst_u32 = dst as u32;
        let (a, b) = if src_u32 <= dst_u32 {
            (src_u32, dst_u32)
        } else {
            (dst_u32, src_u32)
        };

        if seen.insert((a, b)) {
            indexed.push((a, b, row.protocol.clone()));
        }
    }

    indexed
}

pub fn canonical_pair_u32(a: u32, b: u32) -> (u32, u32) {
    if a <= b {
        (a, b)
    } else {
        (b, a)
    }
}

pub fn indexed_edge_telemetry(
    edge_telemetry: &[(String, String, u32, u64, u64, String)],
    node_ids: &[String],
) -> HashMap<(u32, u32), (u32, u64, u64, String)> {
    let node_index = build_node_index(node_ids);
    let mut map = HashMap::new();

    for (source_id, target_id, flow_pps, flow_bps, capacity_bps, label) in edge_telemetry {
        let src = normalized_id(source_id).and_then(|id| {
            node_index
                .get(&id)
                .copied()
                .or_else(|| node_index.get(&id.to_ascii_lowercase()).copied())
        });
        let dst = normalized_id(target_id).and_then(|id| {
            node_index
                .get(&id)
                .copied()
                .or_else(|| node_index.get(&id.to_ascii_lowercase()).copied())
        });

        let (Some(src_idx), Some(dst_idx)) = (src, dst) else {
            continue;
        };
        if src_idx == dst_idx {
            continue;
        }

        let key = canonical_pair_u32(src_idx as u32, dst_idx as u32);
        map.insert(key, (*flow_pps, *flow_bps, *capacity_bps, label.clone()));
    }

    map
}
