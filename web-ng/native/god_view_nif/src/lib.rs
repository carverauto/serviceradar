use std::collections::HashMap;
use std::collections::HashSet;
use std::collections::VecDeque;
use std::sync::Arc;
use std::sync::RwLock;

use arrow_array::{
    Int8Array, RecordBatch, StringArray, UInt16Array, UInt32Array, UInt64Array, UInt8Array,
};
use arrow_ipc::writer::FileWriter;
use arrow_schema::{DataType, Field, Schema};
use deep_causality::{
    BaseCausaloid, CausableGraph, Causaloid, CausaloidGraph, IdentificationValue, NumericalValue,
    PropagatingEffect,
};
use deep_causality_sparse::CsrMatrix;
use deep_causality_tensor::CausalTensor;
use deep_causality_topology::Hypergraph;
use roaring::RoaringBitmap;
use rustler::{Binary, Env, NifMap, NifResult, OwnedBinary, ResourceArc, Term};
use serde_json::json;
use ultragraph::{CentralityGraphAlgorithms, GraphMut, UltraGraph};

const MAX_BETWEENNESS_NODES: usize = 4_096;

#[derive(Clone, Debug, NifMap)]
struct RuntimeGraphRow {
    local_device_id: String,
    local_device_ip: String,
    local_if_name: String,
    local_if_index: i64,
    neighbor_device_id: String,
    neighbor_mgmt_addr: String,
    neighbor_system_name: String,
    protocol: String,
    confidence_tier: String,
    metadata_json: String,
}

struct RuntimeGraphResource {
    links: RwLock<Vec<RuntimeGraphRow>>,
}

mod runtime_graph_atoms {
    rustler::atoms! {
        local_device_id,
        local_device_ip,
        local_if_name,
        local_if_index,
        neighbor_device_id,
        neighbor_mgmt_addr,
        neighbor_system_name,
        protocol,
        confidence_tier,
        metadata,
        source,
        inference,
        confidence_score
    }
}

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

    let node_data = CausalTensor::new(
        vec![0.0_f32; projection.num_nodes],
        vec![projection.num_nodes],
    )
    .ok()?;
    Hypergraph::new(incidence, node_data, 0).ok()
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
            (
                x.round().clamp(0.0, 65535.0) as u16,
                y.round().clamp(0.0, 65535.0) as u16,
            )
        })
        .collect()
}

fn betweenness_scores(node_count: usize, edges: &[(u32, u32)]) -> Option<Vec<f64>> {
    if node_count == 0 || node_count > MAX_BETWEENNESS_NODES {
        return None;
    }

    // Keep a mutable reference graph for continuous updates; clone for frozen analytics.
    let mut live_graph = UltraGraph::with_capacity(node_count, None);
    for idx in 0..node_count {
        let result = if idx == 0 {
            live_graph.add_root_node(idx)
        } else {
            live_graph.add_node(idx)
        };
        if result.is_err() {
            return None;
        }
    }

    for (source, target) in edges {
        let src = *source as usize;
        let dst = *target as usize;
        if src >= node_count || dst >= node_count || src == dst {
            continue;
        }

        if live_graph.add_edge(src, dst, ()).is_err() {
            return None;
        }
        if live_graph.add_edge(dst, src, ()).is_err() {
            return None;
        }
    }

    let mut analysis_graph = live_graph.clone();
    analysis_graph.freeze();

    let centrality = analysis_graph.betweenness_centrality(false, true).ok()?;
    let mut scores = vec![0.0_f64; node_count];
    for (idx, score) in centrality {
        if idx < scores.len() && score.is_finite() && score >= 0.0 {
            scores[idx] = score;
        }
    }

    Some(scores)
}

#[derive(Debug, Clone, Default)]
struct InterfaceTelemetryRecord {
    speed_bps: u64,
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
        let fallback_name = trimmed
            .split(':')
            .next()
            .unwrap_or_default()
            .trim()
            .to_string();
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
    edges: Vec<(String, String, String, i64, String, (u32, u64, u64))>,
    interfaces: Vec<(String, String, i64, u64)>,
    pps_metrics: Vec<(String, i64, u32)>,
    bps_metrics: Vec<(String, i64, u64)>,
) -> NifResult<Vec<(String, String, u32, u64, u64, String)>> {
    enrich_edges_telemetry_impl(edges, interfaces, pps_metrics, bps_metrics)
}

fn enrich_edges_telemetry_impl(
    edges: Vec<(String, String, String, i64, String, (u32, u64, u64))>,
    interfaces: Vec<(String, String, i64, u64)>,
    pps_metrics: Vec<(String, i64, u32)>,
    bps_metrics: Vec<(String, i64, u64)>,
) -> NifResult<Vec<(String, String, u32, u64, u64, String)>> {
    let mut by_index = HashMap::<(String, i64), InterfaceTelemetryRecord>::new();
    let mut by_name = HashMap::<(String, String), InterfaceTelemetryRecord>::new();

    for (device_id, if_name, if_index, speed_bps) in interfaces {
        let record = InterfaceTelemetryRecord { speed_bps };

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
        .map(
            |(source, target, protocol, local_if_index, local_if_name, typed_telemetry)| {
                let (typed_flow_pps, typed_flow_bps, typed_capacity_bps) = typed_telemetry;
                let iface = find_interface_for_edge(
                    &by_index,
                    &by_name,
                    &source,
                    &local_if_name,
                    local_if_index,
                );

                let (iface_pps, iface_bps, iface_capacity) = if let Some(record) = iface {
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

                    (pps, bps, Some(record.speed_bps))
                } else {
                    (None, None, None)
                };

                let flow_pps = if typed_flow_pps > 0 {
                    typed_flow_pps
                } else {
                    iface_pps.unwrap_or(0).min(u32::MAX as u64) as u32
                };

                let flow_bps = if typed_flow_bps > 0 {
                    typed_flow_bps
                } else {
                    iface_bps.unwrap_or(0)
                };

                let capacity_bps = if typed_capacity_bps > 0 {
                    typed_capacity_bps
                } else {
                    iface_capacity.filter(|v| *v > 0).unwrap_or(0)
                };

                let label = edge_label(&protocol, flow_pps, capacity_bps);
                (source, target, flow_pps, flow_bps, capacity_bps, label)
            },
        )
        .collect();

    Ok(enriched)
}

#[rustler::nif(schedule = "DirtyCpu")]
fn layout_nodes_hypergraph(
    node_count: u32,
    edges: Vec<(u32, u32)>,
    node_weights: Vec<u32>,
) -> NifResult<Vec<(u16, u16)>> {
    Ok(layout_nodes_layered(
        node_count as usize,
        &edges,
        &node_weights,
    ))
}

fn build_adjacency_from_indexed_edges(node_count: usize, edges: &[(u32, u32)]) -> Vec<Vec<usize>> {
    let mut adjacency = vec![HashSet::<usize>::new(); node_count];

    for (source, target) in edges {
        let src = *source as usize;
        let dst = *target as usize;
        if src >= node_count || dst >= node_count || src == dst {
            continue;
        }

        adjacency[src].insert(dst);
        adjacency[dst].insert(src);
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

fn layout_nodes_layered(
    node_count: usize,
    edges: &[(u32, u32)],
    node_weights: &[u32],
) -> Vec<(u16, u16)> {
    let count = node_count as usize;
    if count == 0 {
        return Vec::new();
    }

    let adjacency = build_adjacency_from_indexed_edges(count, edges);
    if adjacency.iter().all(|neighbors| neighbors.is_empty()) {
        return fallback_ring_layout(count);
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

    components.sort_by(|a, b| {
        b.len()
            .cmp(&a.len())
            .then_with(|| a.iter().min().cmp(&b.iter().min()))
    });

    let mut positions = vec![(0u16, 0u16); count];
    let comp_total = components.len().max(1) as f64;
    let canvas_left = 40.0_f64;
    let canvas_right = 600.0_f64;
    let canvas_top = 48.0_f64;
    let layer_gap = 92.0_f64;

    for (comp_idx, component) in components.iter().enumerate() {
        let mut in_component = vec![false; count];
        for &node in component {
            in_component[node] = true;
        }

        let slot = (comp_idx as f64 + 0.5) / comp_total;
        let comp_center_x = canvas_left + (canvas_right - canvas_left) * slot;
        let comp_span = ((canvas_right - canvas_left) / comp_total * 0.92).max(120.0);
        let comp_min_x = (comp_center_x - comp_span / 2.0).max(canvas_left);
        let comp_max_x = (comp_center_x + comp_span / 2.0).min(canvas_right);

        if component.len() == 1 {
            let node = component[0];
            positions[node] = (comp_center_x.round() as u16, canvas_top.round() as u16);
            continue;
        }

        let weight_at = |idx: usize| -> u32 { *node_weights.get(idx).unwrap_or(&0) };
        let root = component
            .iter()
            .copied()
            .max_by_key(|n| (weight_at(*n), adjacency[*n].len(), usize::MAX - *n))
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
                positions[node] = (comp_center_x.round() as u16, canvas_top.round() as u16);
                continue;
            }

            let y = canvas_top + l as f64 * layer_gap;
            let min_sep = 24.0_f64;

            let mut desired = nodes
                .iter()
                .map(|node| {
                    let mut parent_x = Vec::new();
                    for parent in &adjacency[*node] {
                        if in_component[*parent]
                            && level.get(parent).copied().unwrap_or(usize::MAX) + 1 == l
                        {
                            parent_x.push(positions[*parent].0 as f64);
                        }
                    }
                    parent_x.sort_by(|a, b| a.total_cmp(b));
                    let target = if parent_x.is_empty() {
                        comp_center_x
                    } else {
                        parent_x.iter().sum::<f64>() / parent_x.len() as f64
                    };
                    (*node, target)
                })
                .collect::<Vec<_>>();

            desired.sort_by(|a, b| a.1.total_cmp(&b.1).then_with(|| a.0.cmp(&b.0)));

            let mut placed = Vec::<(usize, f64)>::new();
            let mut cursor = comp_min_x;
            for (node, target) in desired {
                let x = target.max(cursor).min(comp_max_x);
                placed.push((node, x));
                cursor = x + min_sep;
            }

            if let Some((_, last_x)) = placed.last().copied() {
                if last_x > comp_max_x {
                    let shift = last_x - comp_max_x;
                    for (_, x) in &mut placed {
                        *x = (*x - shift).max(comp_min_x);
                    }
                }
            }

            for (node, x) in placed {
                let x = x.round().clamp(0.0, 65535.0) as u16;
                let y = y.round().clamp(0.0, 65535.0) as u16;
                positions[node] = (x, y);
            }
        }
    }

    positions
}

fn encode_snapshot_impl<'a>(
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
    encode_snapshot_impl(
        env,
        schema_version,
        revision,
        nodes,
        edges,
        root_bitmap_bytes,
        affected_bitmap_bytes,
        healthy_bitmap_bytes,
        unknown_bitmap_bytes,
    )
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
    let centrality_scores = betweenness_scores(node_count, &edges);

    for &(a, b) in &edges {
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
        .max_by_key(|idx| {
            let centrality = centrality_scores
                .as_ref()
                .and_then(|scores| scores.get(*idx))
                .copied()
                .unwrap_or(0.0);
            let scaled = (centrality * 1_000_000.0).round() as i64;
            (scaled, adjacency[*idx].len() as i64, -(*idx as i64))
        })
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

#[rustler::nif]
fn runtime_graph_new() -> ResourceArc<RuntimeGraphResource> {
    ResourceArc::new(RuntimeGraphResource {
        links: RwLock::new(Vec::new()),
    })
}

fn map_get_any<'a>(map: Term<'a>, atom_key: rustler::Atom, string_key: &str) -> Option<Term<'a>> {
    map.map_get(atom_key)
        .ok()
        .or_else(|| map.map_get(string_key).ok())
}

fn term_as_string(term: Term<'_>) -> Option<String> {
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

fn term_as_i64(term: Term<'_>) -> Option<i64> {
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

fn term_as_f64(term: Term<'_>) -> Option<f64> {
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

fn runtime_graph_row_from_term(row: Term<'_>) -> Option<RuntimeGraphRow> {
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

fn normalized_id(value: &str) -> Option<String> {
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

fn build_node_index(node_ids: &[String]) -> HashMap<String, usize> {
    let mut index = HashMap::with_capacity(node_ids.len() * 2);
    for (idx, id) in node_ids.iter().enumerate() {
        if let Some(norm) = normalized_id(id) {
            index.insert(norm.clone(), idx);
            index.insert(norm.to_ascii_lowercase(), idx);
        }
    }
    index
}

fn resolve_endpoint(
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

fn indexed_edges_from_runtime_rows(
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

fn canonical_pair_u32(a: u32, b: u32) -> (u32, u32) {
    if a <= b {
        (a, b)
    } else {
        (b, a)
    }
}

fn indexed_edge_telemetry(
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

#[rustler::nif(schedule = "DirtyCpu")]
fn runtime_graph_replace_links(
    graph: ResourceArc<RuntimeGraphResource>,
    links: Vec<RuntimeGraphRow>,
) -> NifResult<bool> {
    let mut guard = graph.links.write().map_err(|_| rustler::Error::BadArg)?;
    *guard = links;
    Ok(true)
}

#[rustler::nif(schedule = "DirtyCpu")]
fn runtime_graph_get_links(
    graph: ResourceArc<RuntimeGraphResource>,
) -> NifResult<Vec<RuntimeGraphRow>> {
    let guard = graph.links.read().map_err(|_| rustler::Error::BadArg)?;
    Ok(guard.clone())
}

#[rustler::nif(schedule = "DirtyCpu")]
fn runtime_graph_ingest_rows(
    graph: ResourceArc<RuntimeGraphResource>,
    rows: Vec<Term>,
) -> NifResult<usize> {
    let mut parsed_rows = Vec::with_capacity(rows.len());
    for row in rows {
        if let Some(normalized) = runtime_graph_row_from_term(row) {
            parsed_rows.push(normalized);
        }
    }

    let ingested = parsed_rows.len();
    let mut guard = graph.links.write().map_err(|_| rustler::Error::BadArg)?;
    *guard = parsed_rows;
    Ok(ingested)
}

#[rustler::nif(schedule = "DirtyCpu")]
fn runtime_graph_indexed_edges(
    graph: ResourceArc<RuntimeGraphResource>,
    node_ids: Vec<String>,
    allowed_edges: Vec<(String, String)>,
) -> NifResult<Vec<(u32, u32)>> {
    let guard = graph.links.read().map_err(|_| rustler::Error::BadArg)?;
    let indexed = indexed_edges_from_runtime_rows(&guard, &node_ids);
    let node_index = build_node_index(&node_ids);
    let mut allowed = HashSet::<(u32, u32)>::new();

    for (source_id, target_id) in &allowed_edges {
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
        let (Some(a), Some(b)) = (src, dst) else {
            continue;
        };
        if a == b {
            continue;
        }
        allowed.insert(canonical_pair_u32(a as u32, b as u32));
    }

    let filtered = indexed
        .into_iter()
        .filter_map(|(a, b, _)| {
            let key = canonical_pair_u32(a, b);
            if allowed.contains(&key) {
                Some((key.0, key.1))
            } else {
                None
            }
        })
        .collect();

    Ok(filtered)
}

#[rustler::nif(schedule = "DirtyCpu")]
fn runtime_graph_encode_snapshot<'a>(
    env: Env<'a>,
    graph: ResourceArc<RuntimeGraphResource>,
    schema_version: u16,
    revision: u64,
    node_ids: Vec<String>,
    nodes: Vec<(u16, u16, u8, String, u32, u8, String)>,
    edge_telemetry: Vec<(String, String, u32, u64, u64, String)>,
    root_bitmap_bytes: usize,
    affected_bitmap_bytes: usize,
    healthy_bitmap_bytes: usize,
    unknown_bitmap_bytes: usize,
) -> NifResult<Binary<'a>> {
    let guard = graph.links.read().map_err(|_| rustler::Error::BadArg)?;
    let indexed = indexed_edges_from_runtime_rows(&guard, &node_ids);
    let telemetry = indexed_edge_telemetry(&edge_telemetry, &node_ids);
    let edges: Vec<(u16, u16, u32, u64, u64, String)> = indexed
        .into_iter()
        .filter_map(|(a, b, protocol)| {
            let Some((flow_pps, flow_bps, capacity_bps, label)) =
                telemetry.get(&canonical_pair_u32(a, b)).cloned()
            else {
                return None;
            };

            let src = u16::try_from(a).ok()?;
            let dst = u16::try_from(b).ok()?;

            let final_label = if label.trim().is_empty() {
                if protocol.trim().is_empty() {
                    "TOPOLOGY".to_string()
                } else {
                    protocol.trim().to_ascii_uppercase()
                }
            } else {
                label
            };
            Some((src, dst, flow_pps, flow_bps, capacity_bps, final_label))
        })
        .collect();

    encode_snapshot_impl(
        env,
        u32::from(schema_version),
        revision,
        nodes,
        edges,
        root_bitmap_bytes as u32,
        affected_bitmap_bytes as u32,
        healthy_bitmap_bytes as u32,
        unknown_bitmap_bytes as u32,
    )
}

#[allow(non_local_definitions)]
fn on_load(env: Env, _info: Term) -> bool {
    let _ = rustler::resource!(RuntimeGraphResource, env);
    true
}
rustler::init!("Elixir.ServiceRadarWebNG.Topology.Native", load = on_load);

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Instant;

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

    #[test]
    fn enrich_edges_telemetry_prefers_typed_values() {
        let edges = vec![(
            "dev-a".to_string(),
            "dev-b".to_string(),
            "lldp".to_string(),
            10,
            "eth0".to_string(),
            (111u32, 2_000u64, 3_000u64),
        )];
        let interfaces = vec![("dev-a".to_string(), "eth0".to_string(), 10, 50_000u64)];
        let pps_metrics = vec![("dev-a".to_string(), 10, 999u32)];
        let bps_metrics = vec![("dev-a".to_string(), 10, 888u64)];

        let result =
            enrich_edges_telemetry_impl(edges, interfaces, pps_metrics, bps_metrics).unwrap();
        assert_eq!(result.len(), 1);
        let (_source, _target, flow_pps, flow_bps, capacity_bps, _label) = &result[0];

        assert_eq!(*flow_pps, 111);
        assert_eq!(*flow_bps, 2_000);
        assert_eq!(*capacity_bps, 3_000);
    }

    #[test]
    fn enrich_edges_telemetry_uses_metric_and_speed_fallback_when_typed_missing() {
        let edges = vec![(
            "dev-a".to_string(),
            "dev-b".to_string(),
            "lldp".to_string(),
            10,
            "eth0".to_string(),
            (0u32, 0u64, 0u64),
        )];
        let interfaces = vec![("dev-a".to_string(), "eth0".to_string(), 10, 123_000u64)];
        let pps_metrics = vec![("dev-a".to_string(), 10, 77u32)];
        let bps_metrics = vec![("dev-a".to_string(), 10, 456u64)];

        let result =
            enrich_edges_telemetry_impl(edges, interfaces, pps_metrics, bps_metrics).unwrap();
        assert_eq!(result.len(), 1);
        let (_source, _target, flow_pps, flow_bps, capacity_bps, _label) = &result[0];

        assert_eq!(*flow_pps, 77);
        assert_eq!(*flow_bps, 456);
        assert_eq!(*capacity_bps, 123_000);
    }

    #[test]
    fn layout_nodes_layered_is_deterministic_for_identical_inputs() {
        let edges = vec![(0, 1), (0, 2), (0, 3), (3, 4), (3, 5)];
        let weights = vec![900, 300, 300, 800, 300, 300];

        let first = layout_nodes_layered(6, &edges, &weights);
        let second = layout_nodes_layered(6, &edges, &weights);

        assert_eq!(first, second);
    }

    #[test]
    fn layout_nodes_layered_uses_weights_for_anchor_selection() {
        let edges = vec![(0, 1), (0, 2), (0, 3), (0, 4), (0, 5), (0, 6)];
        // node 0 has highest degree, but node 3 is given higher weight and should anchor.
        let weights = vec![100, 10, 10, 1_000, 10, 10, 10];

        let positions = layout_nodes_layered(7, &edges, &weights);

        // Weighted anchor should be in top layer.
        assert!(positions[3].1 < positions[0].1);
        // High-fanout neighbors should be pushed into lower layers, not same layer ring.
        assert!(positions[0].1 < positions[1].1);
        assert!(positions[0].1 < positions[2].1);
    }

    #[test]
    fn layout_nodes_layered_meets_high_node_count_baseline() {
        let node_count = 1_201usize;
        let mut edges = Vec::with_capacity(node_count - 1);
        for idx in 1..node_count {
            edges.push((0u32, idx as u32));
        }

        let mut weights = vec![50u32; node_count];
        weights[0] = 1_000;

        let started = Instant::now();
        let positions = layout_nodes_layered(node_count, &edges, &weights);
        let elapsed = started.elapsed();

        assert_eq!(positions.len(), node_count);
        // Baseline guard: layered layout on a large fanout graph should complete quickly.
        assert!(elapsed.as_millis() < 3_000, "layout took {}ms", elapsed.as_millis());
    }
}
