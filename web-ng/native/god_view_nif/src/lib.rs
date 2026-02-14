use std::collections::HashMap;
use std::collections::VecDeque;
use std::sync::Arc;

use arrow_array::{Int8Array, RecordBatch, UInt16Array, UInt32Array, UInt64Array};
use arrow_ipc::writer::FileWriter;
use arrow_schema::{DataType, Field, Schema};
use deep_causality::{
    BaseCausaloid, CausableGraph, Causaloid, CausaloidGraph, IdentificationValue, NumericalValue,
    PropagatingEffect,
};
use roaring::RoaringBitmap;
use rustler::{Binary, Env, NifResult, OwnedBinary};

#[rustler::nif(schedule = "DirtyCpu")]
fn encode_snapshot<'a>(
    env: Env<'a>,
    schema_version: u32,
    revision: u64,
    nodes: Vec<(u16, u16, u8)>,
    edges: Vec<(u16, u16)>,
    root_bitmap_bytes: u32,
    affected_bitmap_bytes: u32,
    healthy_bitmap_bytes: u32,
    unknown_bitmap_bytes: u32,
) -> NifResult<Binary<'a>> {
    let total_rows = nodes.len() + edges.len();

    let mut row_type = Vec::<i8>::with_capacity(total_rows);
    let mut node_x = Vec::<Option<u16>>::with_capacity(total_rows);
    let mut node_y = Vec::<Option<u16>>::with_capacity(total_rows);
    let mut node_state = Vec::<Option<u16>>::with_capacity(total_rows);
    let mut edge_source = Vec::<Option<u16>>::with_capacity(total_rows);
    let mut edge_target = Vec::<Option<u16>>::with_capacity(total_rows);

    for (x, y, state) in nodes {
        row_type.push(0);
        node_x.push(Some(x));
        node_y.push(Some(y));
        node_state.push(Some(u16::from(state)));
        edge_source.push(None);
        edge_target.push(None);
    }

    for (source, target) in edges {
        row_type.push(1);
        node_x.push(None);
        node_y.push(None);
        node_state.push(None);
        edge_source.push(Some(source));
        edge_target.push(Some(target));
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

    let schema = Arc::new(Schema::new_with_metadata(
        vec![
            Field::new("row_type", DataType::Int8, false),
            Field::new("node_x", DataType::UInt16, true),
            Field::new("node_y", DataType::UInt16, true),
            Field::new("node_state", DataType::UInt16, true),
            Field::new("edge_source", DataType::UInt16, true),
            Field::new("edge_target", DataType::UInt16, true),
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
            Arc::new(UInt16Array::from(edge_source)),
            Arc::new(UInt16Array::from(edge_target)),
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
