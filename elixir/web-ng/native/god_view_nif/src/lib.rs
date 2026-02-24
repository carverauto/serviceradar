pub mod core;
pub mod errors;
pub mod traits;
pub mod types;

use rustler::{Binary, Env, ResourceArc, Term};

use crate::core::arrow_serde::encode_snapshot_impl;
use crate::core::causality::evaluate_causal_states_with_reasons_impl;
use crate::core::layout::layout_nodes_layered;
use crate::core::telemetry::enrich_edges_telemetry_impl;
use crate::core::utils::{
    indexed_edge_telemetry, indexed_edges_from_runtime_rows, runtime_graph_row_from_term,
};
use crate::types::causality::CausalStateReasonRow;
use crate::types::graph::{RuntimeGraphResource, RuntimeGraphRow};
use rustler::NifResult;
use std::sync::RwLock;

// -----------------------------------------------------------------------------
// NIF Mappings
// -----------------------------------------------------------------------------

#[rustler::nif(schedule = "DirtyCpu")]
fn enrich_edges_telemetry(
    edges: Vec<(String, String, String, i64, String, (u32, u64, u64))>,
    interfaces: Vec<(String, String, i64, u64)>,
    pps_metrics: Vec<(String, i64, u32)>,
    bps_metrics: Vec<(String, i64, u64)>,
) -> NifResult<Vec<(String, String, u32, u64, u64, String)>> {
    enrich_edges_telemetry_impl(edges, interfaces, pps_metrics, bps_metrics)
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

#[rustler::nif(schedule = "DirtyCpu")]
fn evaluate_causal_states_with_reasons(
    health_signals: Vec<u8>,
    edges: Vec<(u32, u32)>,
) -> NifResult<Vec<CausalStateReasonRow>> {
    evaluate_causal_states_with_reasons_impl(health_signals, edges)
}

#[rustler::nif(schedule = "DirtyCpu")]
fn evaluate_causal_states(health_signals: Vec<u8>, edges: Vec<(u32, u32)>) -> NifResult<Vec<u8>> {
    evaluate_causal_states_with_reasons_impl(health_signals, edges)
        .map(|rows| rows.into_iter().map(|row| row.state).collect())
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
    let mut root = roaring::RoaringBitmap::new();
    let mut affected = roaring::RoaringBitmap::new();
    let mut healthy = roaring::RoaringBitmap::new();
    let mut unknown = roaring::RoaringBitmap::new();

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

    let root_bytes =
        core::arrow_serde::serialize_bitmap(&root).map_err(|_| rustler::Error::BadArg)?;
    let affected_bytes = crate::core::arrow_serde::serialize_bitmap(&affected)
        .map_err(|_| rustler::Error::BadArg)?;
    let healthy_bytes =
        core::arrow_serde::serialize_bitmap(&healthy).map_err(|_| rustler::Error::BadArg)?;
    let unknown_bytes =
        core::arrow_serde::serialize_bitmap(&unknown).map_err(|_| rustler::Error::BadArg)?;

    Ok((
        core::arrow_serde::vec_into_binary(env, root_bytes).map_err(|_| rustler::Error::BadArg)?,
        core::arrow_serde::vec_into_binary(env, affected_bytes)
            .map_err(|_| rustler::Error::BadArg)?,
        core::arrow_serde::vec_into_binary(env, healthy_bytes)
            .map_err(|_| rustler::Error::BadArg)?,
        core::arrow_serde::vec_into_binary(env, unknown_bytes)
            .map_err(|_| rustler::Error::BadArg)?,
        (root_count, affected_count, healthy_count, unknown_count),
    ))
}

#[rustler::nif(schedule = "DirtyCpu")]
fn decode_arrow_payload(binary: Binary) -> NifResult<Vec<crate::types::survey::SurveySampleRow>> {
    let cursor = std::io::Cursor::new(binary.as_slice());

    // Try streaming format first
    let mut reader = match arrow_ipc::reader::StreamReader::try_new(cursor, None) {
        Ok(r) => r,
        Err(_) => {
            // Fallback to file reader
            return core::arrow_serde::decode_arrow_file(binary.as_slice());
        }
    };

    let mut rows = Vec::new();
    while let Some(batch_result) = reader.next() {
        let batch = batch_result.map_err(|_| rustler::Error::BadArg)?;
        core::arrow_serde::extract_rows(&batch, &mut rows).map_err(|_| rustler::Error::BadArg)?;
    }

    Ok(rows)
}

#[rustler::nif]
fn runtime_graph_new() -> ResourceArc<RuntimeGraphResource> {
    ResourceArc::new(RuntimeGraphResource {
        links: RwLock::new(Vec::new()),
    })
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
    let node_index = core::utils::build_node_index(&node_ids);
    let mut allowed = std::collections::HashSet::<(u32, u32)>::new();

    for (source_id, target_id) in &allowed_edges {
        let src = core::utils::normalized_id(source_id).and_then(|id| {
            node_index
                .get(&id)
                .copied()
                .or_else(|| node_index.get(&id.to_ascii_lowercase()).copied())
        });
        let dst = core::utils::normalized_id(target_id).and_then(|id| {
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
        allowed.insert(core::utils::canonical_pair_u32(a as u32, b as u32));
    }

    let filtered = indexed
        .into_iter()
        .filter_map(|(a, b, _)| {
            let key = core::utils::canonical_pair_u32(a, b);
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
            let Some((flow_pps, flow_bps, capacity_bps, label)) = telemetry
                .get(&crate::core::utils::canonical_pair_u32(a, b))
                .cloned()
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
    use crate::core::layout::{build_hypergraph_projection, layout_nodes_layered};
    use crate::core::telemetry::enrich_edges_telemetry_impl;
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
        assert!(
            elapsed.as_millis() < 3_000,
            "layout took {}ms",
            elapsed.as_millis()
        );
    }
}
