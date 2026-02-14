use std::collections::HashMap;
use std::sync::Arc;

use arrow_array::{Int8Array, RecordBatch, UInt16Array, UInt32Array, UInt64Array};
use arrow_ipc::writer::FileWriter;
use arrow_schema::{DataType, Field, Schema};
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

rustler::init!("Elixir.ServiceRadarWebNG.Topology.Native");
