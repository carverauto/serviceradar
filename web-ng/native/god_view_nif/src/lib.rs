use std::collections::HashMap;
use std::collections::HashSet;
use std::collections::VecDeque;
use std::sync::Arc;

use arrow_array::{Int8Array, RecordBatch, StringArray, UInt16Array, UInt32Array, UInt64Array, UInt8Array};
use arrow_ipc::writer::FileWriter;
use arrow_schema::{DataType, Field, Schema};
use deep_causality::{
    BaseCausaloid, CausableGraph, Causaloid, CausaloidGraph, IdentificationValue, NumericalValue,
    PropagatingEffect,
};
use deep_causality_sparse::CsrMatrix;
use deep_causality_tensor::CausalTensor;
use deep_causality_topology::{Hypergraph, HypergraphTopology};
use roaring::RoaringBitmap;
use rustler::{Binary, Env, NifResult, OwnedBinary};
use serde_json::Value as JsonValue;

#[derive(Debug, Clone, Default)]
struct HypergraphProjection {
    num_nodes: usize,
    num_hyperedges: usize,
    incidence_triplets: Vec<(usize, usize, i8)>,
    dropped_edges: usize,
}

fn build_hypergraph_projection(
    num_nodes: usize,
    edges: &[(u16, u16, u32, u64, u64, String)],
) -> HypergraphProjection {
    let mut projection = HypergraphProjection {
        num_nodes,
        ..Default::default()
    };

    if num_nodes == 0 || edges.is_empty() {
        return projection;
    }

    projection.incidence_triplets.reserve(edges.len() * 2);

    for (source, target, _, _, _, _) in edges {
        let src = usize::from(*source);
        let dst = usize::from(*target);

        if src >= num_nodes || dst >= num_nodes {
            projection.dropped_edges += 1;
            continue;
        }

        let hidx = projection.num_hyperedges;
        projection.num_hyperedges += 1;
        projection.incidence_triplets.push((src, hidx, 1));
        if src != dst {
            projection.incidence_triplets.push((dst, hidx, 1));
        }
    }

    projection
}

fn build_hypergraph_from_projection(projection: &HypergraphProjection) -> Option<Hypergraph<f32>> {
    if projection.num_nodes == 0 || projection.num_hyperedges == 0 {
        return None;
    }

    let incidence = CsrMatrix::from_triplets(
        projection.num_nodes,
        projection.num_hyperedges,
        &projection.incidence_triplets,
    )
    .ok()?;

    let node_data = CausalTensor::new(vec![0.0_f32; projection.num_nodes], vec![projection.num_nodes]).ok()?;
    Hypergraph::new(incidence, node_data, 0).ok()
}

fn build_indexed_hypergraph_projection(
    num_nodes: usize,
    edges: &[(u32, u32)],
) -> HypergraphProjection {
    let mut projection = HypergraphProjection {
        num_nodes,
        ..Default::default()
    };

    if num_nodes == 0 || edges.is_empty() {
        return projection;
    }

    projection.incidence_triplets.reserve(edges.len() * 2);

    for (source, target) in edges {
        let src = *source as usize;
        let dst = *target as usize;

        if src >= num_nodes || dst >= num_nodes {
            projection.dropped_edges += 1;
            continue;
        }

        let hidx = projection.num_hyperedges;
        projection.num_hyperedges += 1;
        projection.incidence_triplets.push((src, hidx, 1));
        if src != dst {
            projection.incidence_triplets.push((dst, hidx, 1));
        }
    }

    projection
}

fn build_adjacency_from_hypergraph(hypergraph: &Hypergraph<f32>) -> Vec<Vec<usize>> {
    let node_count = hypergraph.num_nodes();
    let mut adjacency = vec![HashSet::<usize>::new(); node_count];

    for hidx in 0..hypergraph.num_hyperedges() {
        if let Ok(nodes) = hypergraph.nodes_in_hyperedge(hidx) {
            for &a in &nodes {
                for &b in &nodes {
                    if a != b {
                        adjacency[a].insert(b);
                    }
                }
            }
        }
    }

    adjacency
        .into_iter()
        .map(|neighbors| {
            let mut values: Vec<usize> = neighbors.into_iter().collect();
            values.sort_unstable();
            values
        })
        .collect()
}

fn fallback_ring_layout(node_count: usize) -> Vec<(u16, u16)> {
    if node_count == 0 {
        return Vec::new();
    }

    let center_x = 320.0_f64;
    let center_y = 160.0_f64;
    let radius = 120.0 + (node_count as f64 * 0.8);
    let step = std::f64::consts::TAU / node_count as f64;

    (0..node_count)
        .map(|idx| {
            let angle = step * idx as f64;
            let x = center_x + radius * angle.cos();
            let y = center_y + radius * angle.sin();
            (x.round().clamp(0.0, 65535.0) as u16, y.round().clamp(0.0, 65535.0) as u16)
        })
        .collect()
}

#[derive(Debug, Clone, Default)]
struct InterfaceTelemetryRecord {
    metadata: Option<JsonValue>,
    speed_bps: u64,
}

fn parse_json_map(raw: &str) -> Option<JsonValue> {
    if raw.is_empty() || raw == "{}" {
        return None;
    }
    serde_json::from_str::<JsonValue>(raw).ok()
}

fn json_number_u64(value: &JsonValue) -> Option<u64> {
    match value {
        JsonValue::Number(n) => n.as_u64().or_else(|| n.as_f64().map(|f| f.max(0.0) as u64)),
        JsonValue::String(s) => s.parse::<u64>().ok(),
        _ => None,
    }
}

fn metadata_number(metadata: Option<&JsonValue>, keys: &[&str]) -> Option<u64> {
    let JsonValue::Object(map) = metadata? else {
        return None;
    };

    keys.iter()
        .find_map(|key| map.get(*key).and_then(json_number_u64))
}

fn find_interface_for_edge(
    by_index: &HashMap<(String, i64), InterfaceTelemetryRecord>,
    by_name: &HashMap<(String, String), InterfaceTelemetryRecord>,
    device_id: &str,
    if_name: &str,
    if_index: i64,
) -> Option<InterfaceTelemetryRecord> {
    if if_index >= 0 {
        if let Some(found) = by_index.get(&(device_id.to_string(), if_index)) {
            return Some(found.clone());
        }
    }

    let trimmed = if_name.trim().to_lowercase();
    if !trimmed.is_empty() {
        if let Some(found) = by_name.get(&(device_id.to_string(), trimmed.clone())) {
            return Some(found.clone());
        }
        let fallback_name = trimmed.split(':').next().unwrap_or_default().trim().to_string();
        if !fallback_name.is_empty() {
            if let Some(found) = by_name.get(&(device_id.to_string(), fallback_name)) {
                return Some(found.clone());
            }
        }
    }

    None
}

fn format_rate(value: u64) -> String {
    if value >= 1_000_000 {
        format!("{:.1}Mpps", value as f64 / 1_000_000.0)
    } else if value >= 1_000 {
        format!("{:.1}Kpps", value as f64 / 1_000.0)
    } else {
        format!("{value}pps")
    }
}

fn format_capacity(value: u64) -> String {
    if value >= 1_000_000_000 {
        format!("{}G", value / 1_000_000_000)
    } else if value >= 100_000_000 {
        format!("{}M", value / 1_000_000)
    } else if value > 0 {
        format!("{}M", value / 1_000_000)
    } else {
        "UNK".to_string()
    }
}

fn edge_label(protocol: &str, flow_pps: u32, capacity_bps: u64) -> String {
    let p = protocol.trim().to_uppercase();
    let normalized = if p.is_empty() { "LINK" } else { p.as_str() };
    format!(
        "{normalized} {} / {}",
        format_rate(flow_pps as u64),
        format_capacity(capacity_bps)
    )
}

#[rustler::nif(schedule = "DirtyCpu")]
fn enrich_edges_telemetry(
    edges: Vec<(String, String, String, i64, String, String)>,
    interfaces: Vec<(String, String, i64, u64, String)>,
    pps_metrics: Vec<(String, i64, u32)>,
    bps_metrics: Vec<(String, i64, u64)>,
) -> NifResult<Vec<(String, String, u32, u64, u64, String)>> {
    let mut by_index = HashMap::<(String, i64), InterfaceTelemetryRecord>::new();
    let mut by_name = HashMap::<(String, String), InterfaceTelemetryRecord>::new();

    for (device_id, if_name, if_index, speed_bps, metadata_json) in interfaces {
        let record = InterfaceTelemetryRecord {
            metadata: parse_json_map(&metadata_json),
            speed_bps,
        };

        if if_index >= 0 {
            by_index
                .entry((device_id.clone(), if_index))
                .or_insert_with(|| record.clone());
        }

        let lowered_name = if_name.trim().to_lowercase();
        if !lowered_name.is_empty() {
            by_name
                .entry((device_id.clone(), lowered_name))
                .or_insert_with(|| record.clone());
        }
    }

    let pps_by_if = pps_metrics
        .into_iter()
        .map(|(device_id, if_index, value)| ((device_id, if_index), value))
        .collect::<HashMap<_, _>>();

    let bps_by_if = bps_metrics
        .into_iter()
        .map(|(device_id, if_index, value)| ((device_id, if_index), value))
        .collect::<HashMap<_, _>>();

    let enriched = edges
        .into_iter()
        .map(|(source, target, protocol, local_if_index, local_if_name, edge_metadata_json)| {
            let edge_metadata = parse_json_map(&edge_metadata_json);
            let iface = find_interface_for_edge(
                &by_index,
                &by_name,
                &source,
                &local_if_name,
                local_if_index,
            );

            let (iface_pps, iface_bps, iface_capacity, iface_meta) = if let Some(record) = iface {
                let pps = if local_if_index >= 0 {
                    pps_by_if
                        .get(&(source.clone(), local_if_index))
                        .copied()
                        .map(|v| v as u64)
                } else {
                    None
                };

                let bps = if local_if_index >= 0 {
                    bps_by_if.get(&(source.clone(), local_if_index)).copied()
                } else {
                    None
                };

                (
                    pps,
                    bps,
                    Some(record.speed_bps),
                    record.metadata.as_ref().cloned(),
                )
            } else {
                (None, None, None, None)
            };

            let iface_meta_ref = iface_meta.as_ref();

            let flow_pps = iface_pps
                .or_else(|| {
                    metadata_number(
                        iface_meta_ref,
                        &[
                            "pps",
                            "packets_per_sec",
                            "packets_per_second",
                            "tx_pps",
                            "rx_pps",
                            "if_in_pps",
                            "if_out_pps",
                        ],
                    )
                })
                .or_else(|| {
                    metadata_number(
                        edge_metadata.as_ref(),
                        &[
                            "flow_pps",
                            "pps",
                            "packets_per_sec",
                            "packets_per_second",
                            "tx_pps",
                            "rx_pps",
                        ],
                    )
                })
                .unwrap_or(0)
                .min(u32::MAX as u64) as u32;

            let flow_bps = iface_bps
                .or_else(|| {
                    metadata_number(
                        iface_meta_ref,
                        &[
                            "bps",
                            "bits_per_sec",
                            "bits_per_second",
                            "tx_bps",
                            "rx_bps",
                            "if_in_bps",
                            "if_out_bps",
                        ],
                    )
                })
                .or_else(|| {
                    metadata_number(
                        edge_metadata.as_ref(),
                        &[
                            "flow_bps",
                            "bps",
                            "bits_per_sec",
                            "bits_per_second",
                            "tx_bps",
                            "rx_bps",
                        ],
                    )
                })
                .unwrap_or(0);

            let capacity_bps = iface_capacity
                .filter(|v| *v > 0)
                .or_else(|| {
                    metadata_number(
                        iface_meta_ref,
                        &["if_speed_bps", "if_speed", "speed_bps", "capacity_bps"],
                    )
                })
                .or_else(|| {
                    metadata_number(
                        edge_metadata.as_ref(),
                        &["capacity_bps", "if_speed_bps", "if_speed", "speed_bps"],
                    )
                })
                .unwrap_or(0);

            let label = edge_label(&protocol, flow_pps, capacity_bps);
            (source, target, flow_pps, flow_bps, capacity_bps, label)
        })
        .collect();

    Ok(enriched)
}

#[rustler::nif(schedule = "DirtyCpu")]
fn layout_nodes_hypergraph(node_count: u32, edges: Vec<(u32, u32)>) -> NifResult<Vec<(u16, u16)>> {
    let count = node_count as usize;
    if count == 0 {
        return Ok(Vec::new());
    }

    let projection = build_indexed_hypergraph_projection(count, &edges);
    let Some(hypergraph) = build_hypergraph_from_projection(&projection) else {
        return Ok(fallback_ring_layout(count));
    };

    let adjacency = build_adjacency_from_hypergraph(&hypergraph);
    if adjacency.iter().all(|neighbors| neighbors.is_empty()) {
        return Ok(fallback_ring_layout(count));
    }

    let mut visited = vec![false; count];
    let mut components = Vec::<Vec<usize>>::new();

    for start in 0..count {
        if visited[start] {
            continue;
        }

        let mut queue = VecDeque::new();
        let mut component = Vec::new();
        queue.push_back(start);
        visited[start] = true;

        while let Some(node) = queue.pop_front() {
            component.push(node);
            for &next in &adjacency[node] {
                if !visited[next] {
                    visited[next] = true;
                    queue.push_back(next);
                }
            }
        }

        components.push(component);
    }

    components.sort_by(|a, b| b.len().cmp(&a.len()));

    let mut positions = vec![(0u16, 0u16); count];
    let comp_total = components.len().max(1);
    let comp_step = std::f64::consts::TAU / comp_total as f64;
    let comp_radius = 90.0_f64;

    for (comp_idx, component) in components.iter().enumerate() {
        let mut in_component = vec![false; count];
        for &node in component {
            in_component[node] = true;
        }

        let comp_center = if comp_total == 1 {
            (320.0_f64, 160.0_f64)
        } else {
            let a = comp_step * comp_idx as f64;
            (320.0 + comp_radius * a.cos(), 160.0 + comp_radius * a.sin())
        };

        if component.len() == 1 {
            let node = component[0];
            positions[node] = (comp_center.0.round() as u16, comp_center.1.round() as u16);
            continue;
        }

        let root = component
            .iter()
            .copied()
            .max_by_key(|n| adjacency[*n].len())
            .unwrap_or(component[0]);

        let mut level = HashMap::<usize, usize>::new();
        let mut queue = VecDeque::new();
        queue.push_back(root);
        level.insert(root, 0);

        while let Some(node) = queue.pop_front() {
            let curr = *level.get(&node).unwrap_or(&0);
            for &next in &adjacency[node] {
                if in_component[next] && !level.contains_key(&next) {
                    level.insert(next, curr + 1);
                    queue.push_back(next);
                }
            }
        }

        let mut by_level = HashMap::<usize, Vec<usize>>::new();
        for &node in component {
            let l = *level.get(&node).unwrap_or(&0);
            by_level.entry(l).or_default().push(node);
        }

        let mut levels: Vec<usize> = by_level.keys().copied().collect();
        levels.sort_unstable();

        for l in levels {
            let mut nodes = by_level.remove(&l).unwrap_or_default();
            nodes.sort_unstable();

            if l == 0 && nodes.len() == 1 {
                let node = nodes[0];
                positions[node] = (comp_center.0.round() as u16, comp_center.1.round() as u16);
                continue;
            }

            let ring_r = 28.0 + l as f64 * 36.0;
            let step = std::f64::consts::TAU / nodes.len().max(1) as f64;
            let phase = (comp_idx as f64) * 0.6 + (l as f64) * 0.25;

            for (idx, node) in nodes.into_iter().enumerate() {
                let a = phase + step * idx as f64;
                let x = (comp_center.0 + ring_r * a.cos()).round().clamp(0.0, 65535.0) as u16;
                let y = (comp_center.1 + ring_r * a.sin()).round().clamp(0.0, 65535.0) as u16;
                positions[node] = (x, y);
            }
        }
    }

    Ok(positions)
}

#[rustler::nif(schedule = "DirtyCpu")]
fn encode_snapshot<'a>(
    env: Env<'a>,
    schema_version: u32,
    revision: u64,
    nodes: Vec<(u16, u16, u8, String, u32, u8, String)>,
    edges: Vec<(u16, u16, u32, u64, u64, String)>,
    root_bitmap_bytes: u32,
    affected_bitmap_bytes: u32,
    healthy_bitmap_bytes: u32,
    unknown_bitmap_bytes: u32,
) -> NifResult<Binary<'a>> {
    let total_rows = nodes.len() + edges.len();
    let hypergraph_projection = build_hypergraph_projection(nodes.len(), &edges);
    let hypergraph = build_hypergraph_from_projection(&hypergraph_projection);

    let mut row_type = Vec::<i8>::with_capacity(total_rows);
    let mut node_x = Vec::<Option<u16>>::with_capacity(total_rows);
    let mut node_y = Vec::<Option<u16>>::with_capacity(total_rows);
    let mut node_state = Vec::<Option<u16>>::with_capacity(total_rows);
    let mut node_label = Vec::<Option<String>>::with_capacity(total_rows);
    let mut node_pps = Vec::<Option<u32>>::with_capacity(total_rows);
    let mut node_oper_up = Vec::<Option<u8>>::with_capacity(total_rows);
    let mut node_details = Vec::<Option<String>>::with_capacity(total_rows);
    let mut edge_source = Vec::<Option<u16>>::with_capacity(total_rows);
    let mut edge_target = Vec::<Option<u16>>::with_capacity(total_rows);
    let mut edge_pps = Vec::<Option<u32>>::with_capacity(total_rows);
    let mut edge_flow_bps = Vec::<Option<u64>>::with_capacity(total_rows);
    let mut edge_capacity_bps = Vec::<Option<u64>>::with_capacity(total_rows);
    let mut edge_label = Vec::<Option<String>>::with_capacity(total_rows);

    for (x, y, state, label, pps, oper_up, details) in nodes {
        row_type.push(0);
        node_x.push(Some(x));
        node_y.push(Some(y));
        node_state.push(Some(u16::from(state)));
        node_label.push(Some(label));
        node_pps.push(Some(pps));
        node_oper_up.push(Some(oper_up));
        node_details.push(Some(details));
        edge_source.push(None);
        edge_target.push(None);
        edge_pps.push(None);
        edge_flow_bps.push(None);
        edge_capacity_bps.push(None);
        edge_label.push(None);
    }

    for (source, target, pps, flow_bps, capacity_bps, label) in edges {
        row_type.push(1);
        node_x.push(None);
        node_y.push(None);
        node_state.push(None);
        node_label.push(None);
        node_pps.push(None);
        node_oper_up.push(None);
        node_details.push(None);
        edge_source.push(Some(source));
        edge_target.push(Some(target));
        edge_pps.push(Some(pps));
        edge_flow_bps.push(Some(flow_bps));
        edge_capacity_bps.push(Some(capacity_bps));
        edge_label.push(Some(label));
    }

    let mut metadata = HashMap::new();
    metadata.insert("schema_version".to_string(), schema_version.to_string());
    metadata.insert("revision".to_string(), revision.to_string());
    metadata.insert(
        "root_bitmap_bytes".to_string(),
        root_bitmap_bytes.to_string(),
    );
    metadata.insert(
        "affected_bitmap_bytes".to_string(),
        affected_bitmap_bytes.to_string(),
    );
    metadata.insert(
        "healthy_bitmap_bytes".to_string(),
        healthy_bitmap_bytes.to_string(),
    );
    metadata.insert(
        "unknown_bitmap_bytes".to_string(),
        unknown_bitmap_bytes.to_string(),
    );
    metadata.insert(
        "topology_hypergraph_nodes".to_string(),
        hypergraph_projection.num_nodes.to_string(),
    );
    metadata.insert(
        "topology_hypergraph_edges".to_string(),
        hypergraph_projection.num_hyperedges.to_string(),
    );
    metadata.insert(
        "topology_hypergraph_dropped_edges".to_string(),
        hypergraph_projection.dropped_edges.to_string(),
    );
    metadata.insert(
        "topology_hypergraph_valid".to_string(),
        if hypergraph.is_some() { "1" } else { "0" }.to_string(),
    );

    let schema = Arc::new(Schema::new_with_metadata(
        vec![
            Field::new("row_type", DataType::Int8, false),
            Field::new("node_x", DataType::UInt16, true),
            Field::new("node_y", DataType::UInt16, true),
            Field::new("node_state", DataType::UInt16, true),
            Field::new("node_label", DataType::Utf8, true),
            Field::new("node_pps", DataType::UInt32, true),
            Field::new("node_oper_up", DataType::UInt8, true),
            Field::new("node_details", DataType::Utf8, true),
            Field::new("edge_source", DataType::UInt16, true),
            Field::new("edge_target", DataType::UInt16, true),
            Field::new("edge_pps", DataType::UInt32, true),
            Field::new("edge_flow_bps", DataType::UInt64, true),
            Field::new("edge_capacity_bps", DataType::UInt64, true),
            Field::new("edge_label", DataType::Utf8, true),
            Field::new("snapshot_schema_version", DataType::UInt32, false),
            Field::new("snapshot_revision", DataType::UInt64, false),
        ],
        metadata,
    ));

    let schema_version_col = vec![schema_version; total_rows];
    let revision_col = vec![revision; total_rows];

    let batch = RecordBatch::try_new(
        Arc::clone(&schema),
        vec![
            Arc::new(Int8Array::from(row_type)),
            Arc::new(UInt16Array::from(node_x)),
            Arc::new(UInt16Array::from(node_y)),
            Arc::new(UInt16Array::from(node_state)),
            Arc::new(StringArray::from(node_label)),
            Arc::new(UInt32Array::from(node_pps)),
            Arc::new(UInt8Array::from(node_oper_up)),
            Arc::new(StringArray::from(node_details)),
            Arc::new(UInt16Array::from(edge_source)),
            Arc::new(UInt16Array::from(edge_target)),
            Arc::new(UInt32Array::from(edge_pps)),
            Arc::new(UInt64Array::from(edge_flow_bps)),
            Arc::new(UInt64Array::from(edge_capacity_bps)),
            Arc::new(StringArray::from(edge_label)),
            Arc::new(UInt32Array::from(schema_version_col)),
            Arc::new(UInt64Array::from(revision_col)),
        ],
    )
    .map_err(|_| rustler::Error::BadArg)?;

    let mut payload = Vec::new();
    {
        let mut writer =
            FileWriter::try_new(&mut payload, &schema).map_err(|_| rustler::Error::BadArg)?;
        writer.write(&batch).map_err(|_| rustler::Error::BadArg)?;
        writer.finish().map_err(|_| rustler::Error::BadArg)?;
    }

    let mut out = OwnedBinary::new(payload.len()).ok_or(rustler::Error::BadArg)?;
    out.as_mut_slice().copy_from_slice(&payload);
    Ok(Binary::from_owned(out, env))
}

fn deep_causality_eval(obs: NumericalValue) -> PropagatingEffect<bool> {
    PropagatingEffect::pure(obs > 0.5)
}

#[rustler::nif(schedule = "DirtyCpu")]
fn evaluate_causal_states(health_signals: Vec<u8>, edges: Vec<(u32, u32)>) -> NifResult<Vec<u8>> {
    let node_count = health_signals.len();
    if node_count == 0 {
        return Ok(Vec::new());
    }

    let mut graph = CausaloidGraph::<BaseCausaloid<NumericalValue, bool>>::new(0);
    let mut node_indices = Vec::with_capacity(node_count);

    for idx in 0..node_count {
        let causaloid = Causaloid::new(
            idx as IdentificationValue,
            deep_causality_eval,
            "serviceradar_god_view_causal_eval",
        );

        let graph_index = if idx == 0 {
            graph
                .add_root_causaloid(causaloid)
                .map_err(|_| rustler::Error::BadArg)?
        } else {
            graph
                .add_causaloid(causaloid)
                .map_err(|_| rustler::Error::BadArg)?
        };
        node_indices.push(graph_index);
    }

    let mut adjacency = vec![Vec::<usize>::new(); node_count];

    for (a, b) in edges {
        let ai = a as usize;
        let bi = b as usize;

        if ai >= node_count || bi >= node_count || ai == bi {
            continue;
        }

        let ga = node_indices[ai];
        let gb = node_indices[bi];
        graph.add_edge(ga, gb).map_err(|_| rustler::Error::BadArg)?;
        graph.add_edge(gb, ga).map_err(|_| rustler::Error::BadArg)?;

        adjacency[ai].push(bi);
        adjacency[bi].push(ai);
    }
    graph.freeze();

    let unhealthy: Vec<usize> = health_signals
        .iter()
        .enumerate()
        .filter_map(|(idx, signal)| if *signal == 1 { Some(idx) } else { None })
        .collect();

    let mut states = vec![3u8; node_count];

    if unhealthy.is_empty() {
        for (idx, signal) in health_signals.iter().enumerate() {
            states[idx] = if *signal == 0 { 2 } else { 3 };
        }
        return Ok(states);
    }

    let root = unhealthy
        .iter()
        .copied()
        .max_by_key(|idx| (adjacency[*idx].len(), usize::MAX - *idx))
        .ok_or(rustler::Error::BadArg)?;

    let mut dist = vec![usize::MAX; node_count];
    let mut queue = VecDeque::new();
    dist[root] = 0;
    queue.push_back(root);

    while let Some(current) = queue.pop_front() {
        let next_dist = dist[current] + 1;
        if next_dist > 3 {
            continue;
        }

        for neighbor in &adjacency[current] {
            if dist[*neighbor] == usize::MAX {
                dist[*neighbor] = next_dist;
                queue.push_back(*neighbor);
            }
        }
    }

    states[root] = 0;

    for idx in 0..node_count {
        if idx == root {
            continue;
        }

        if dist[idx] != usize::MAX && dist[idx] <= 3 {
            states[idx] = 1;
        } else if health_signals[idx] == 0 {
            states[idx] = 2;
        } else {
            states[idx] = 3;
        }
    }

    Ok(states)
}

#[rustler::nif(schedule = "DirtyCpu")]
fn build_roaring_bitmaps<'a>(
    env: Env<'a>,
    states: Vec<u8>,
) -> NifResult<(
    Binary<'a>,
    Binary<'a>,
    Binary<'a>,
    Binary<'a>,
    (u32, u32, u32, u32),
)> {
    let mut root = RoaringBitmap::new();
    let mut affected = RoaringBitmap::new();
    let mut healthy = RoaringBitmap::new();
    let mut unknown = RoaringBitmap::new();

    for (idx, state) in states.iter().enumerate() {
        let i = idx as u32;
        match *state {
            0 => {
                root.insert(i);
            }
            1 => {
                affected.insert(i);
            }
            2 => {
                healthy.insert(i);
            }
            _ => {
                unknown.insert(i);
            }
        }
    }

    let root_count = root.len() as u32;
    let affected_count = affected.len() as u32;
    let healthy_count = healthy.len() as u32;
    let unknown_count = unknown.len() as u32;

    let root_bytes = serialize_bitmap(&root)?;
    let affected_bytes = serialize_bitmap(&affected)?;
    let healthy_bytes = serialize_bitmap(&healthy)?;
    let unknown_bytes = serialize_bitmap(&unknown)?;

    Ok((
        vec_into_binary(env, root_bytes)?,
        vec_into_binary(env, affected_bytes)?,
        vec_into_binary(env, healthy_bytes)?,
        vec_into_binary(env, unknown_bytes)?,
        (root_count, affected_count, healthy_count, unknown_count),
    ))
}

fn serialize_bitmap(bitmap: &RoaringBitmap) -> NifResult<Vec<u8>> {
    let mut out = Vec::new();
    bitmap
        .serialize_into(&mut out)
        .map_err(|_| rustler::Error::BadArg)?;
    Ok(out)
}

fn vec_into_binary<'a>(env: Env<'a>, bytes: Vec<u8>) -> NifResult<Binary<'a>> {
    let mut out = OwnedBinary::new(bytes.len()).ok_or(rustler::Error::BadArg)?;
    out.as_mut_slice().copy_from_slice(&bytes);
    Ok(Binary::from_owned(out, env))
}

rustler::init!("Elixir.ServiceRadarWebNG.Topology.Native");

#[cfg(test)]
mod tests {
    use super::*;

    fn edge(source: u16, target: u16) -> (u16, u16, u32, u64, u64, String) {
        (source, target, 0, 0, 0, String::new())
    }

    #[test]
    fn projection_builds_incidence_for_valid_edges() {
        let projection = build_hypergraph_projection(4, &[edge(0, 1), edge(2, 3)]);

        assert_eq!(projection.num_nodes, 4);
        assert_eq!(projection.num_hyperedges, 2);
        assert_eq!(projection.dropped_edges, 0);
        assert_eq!(projection.incidence_triplets.len(), 4);
    }

    #[test]
    fn projection_drops_out_of_range_edges() {
        let projection = build_hypergraph_projection(3, &[edge(0, 1), edge(0, 9)]);

        assert_eq!(projection.num_hyperedges, 1);
        assert_eq!(projection.dropped_edges, 1);
        assert_eq!(projection.incidence_triplets, vec![(0, 0, 1), (1, 0, 1)]);
    }
}
