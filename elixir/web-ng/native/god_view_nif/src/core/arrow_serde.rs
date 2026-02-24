//! Serialization and deserialization bindings for Apache Arrow and Roaring Bitmaps.
//!
//! Exposes functions to pack in-memory Rust topology graphs into `RecordBatch` streams
//! and decode physical survey payloads from binary IPC frames.

use std::collections::HashMap;
use std::str::FromStr;
use std::sync::Arc;

use arrow_array::{
    cast::AsArray, Array, Int8Array, RecordBatch, StringArray, UInt16Array, UInt32Array,
    UInt64Array, UInt8Array,
};
use arrow_ipc::writer::FileWriter;
use arrow_schema::{DataType, Field, Schema};
use roaring::RoaringBitmap;
use rustler::{Binary, Env, OwnedBinary};

use crate::core::layout::{build_hypergraph_from_projection, build_hypergraph_projection};
use crate::types::survey::SurveySampleRow;

/// Encodes an entire topology active state into an Apache Arrow IPC stream payload.
///
/// This leverages columnar Arrow layouts to bypass Erlang term limits and securely
/// blast thousands of nodes/edges directly to the frontend God View visualizers.
pub(crate) fn encode_snapshot_impl(
    env: Env,
    schema_version: u32,
    revision: u64,
    nodes: Vec<(u16, u16, u8, String, u32, u8, String)>,
    edges: Vec<(u16, u16, u32, u64, u64, String)>,
    root_bitmap_bytes: u32,
    affected_bitmap_bytes: u32,
    healthy_bitmap_bytes: u32,
    unknown_bitmap_bytes: u32,
) -> Result<Binary, rustler::Error> {
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

/// Serializes a sparse `RoaringBitmap` directly into byte chunks for Erlang interop.
pub(crate) fn serialize_bitmap(bitmap: &RoaringBitmap) -> Result<Vec<u8>, rustler::Error> {
    let mut out = Vec::new();
    bitmap
        .serialize_into(&mut out)
        .map_err(|_| rustler::Error::BadArg)?;
    Ok(out)
}

/// Moves an arbitrary byte vector into the NIF boundary wrapping an OwnedBinary.
pub(crate) fn vec_into_binary<'a>(
    env: Env<'a>,
    bytes: Vec<u8>,
) -> Result<Binary<'a>, rustler::Error> {
    let mut out = OwnedBinary::new(bytes.len()).ok_or(rustler::Error::BadArg)?;
    out.as_mut_slice().copy_from_slice(&bytes);
    Ok(Binary::from_owned(out, env))
}

/// Helper method to decode a raw Arrow File byte stream directly into Rust structs.
pub(crate) fn decode_arrow_file(data: &[u8]) -> Result<Vec<SurveySampleRow>, rustler::Error> {
    let cursor = std::io::Cursor::new(data);
    let mut reader =
        arrow_ipc::reader::FileReader::try_new(cursor, None).map_err(|_| rustler::Error::BadArg)?;

    let mut rows = Vec::new();
    while let Some(batch_result) = reader.next() {
        let batch = batch_result.map_err(|_| rustler::Error::BadArg)?;
        extract_rows(&batch, &mut rows)?;
    }

    Ok(rows)
}

/// Extracts strongly typed columns from a RecordBatch and populates the Elixir-facing structs.
pub(crate) fn extract_rows(
    batch: &RecordBatch,
    rows: &mut Vec<SurveySampleRow>,
) -> Result<(), rustler::Error> {
    let timestamps = batch
        .column_by_name("timestamp")
        .ok_or(rustler::Error::BadArg)?
        .as_primitive::<arrow_array::types::Float64Type>();
    let scanner_device_ids = batch
        .column_by_name("scannerDeviceId")
        .ok_or(rustler::Error::BadArg)?
        .as_string::<i32>();
    let bssids = batch
        .column_by_name("bssid")
        .ok_or(rustler::Error::BadArg)?
        .as_string::<i32>();
    let ssids = batch
        .column_by_name("ssid")
        .ok_or(rustler::Error::BadArg)?
        .as_string::<i32>();
    let rssis = batch
        .column_by_name("rssi")
        .ok_or(rustler::Error::BadArg)?
        .as_primitive::<arrow_array::types::Float64Type>();
    let frequencies = batch
        .column_by_name("frequency")
        .ok_or(rustler::Error::BadArg)?
        .as_primitive::<arrow_array::types::Int64Type>();
    let security_types = batch
        .column_by_name("securityType")
        .ok_or(rustler::Error::BadArg)?
        .as_string::<i32>();
    let is_secures = batch
        .column_by_name("isSecure")
        .ok_or(rustler::Error::BadArg)?
        .as_boolean();
    let rf_vectors = extract_vector_column(batch, "rfVector")?;
    let ble_vectors = extract_vector_column(batch, "bleVector")?;
    let xs = batch
        .column_by_name("x")
        .ok_or(rustler::Error::BadArg)?
        .as_primitive::<arrow_array::types::Float32Type>();
    let ys = batch
        .column_by_name("y")
        .ok_or(rustler::Error::BadArg)?
        .as_primitive::<arrow_array::types::Float32Type>();
    let zs = batch
        .column_by_name("z")
        .ok_or(rustler::Error::BadArg)?
        .as_primitive::<arrow_array::types::Float32Type>();
    let lats = batch
        .column_by_name("latitude")
        .ok_or(rustler::Error::BadArg)?
        .as_primitive::<arrow_array::types::Float64Type>();
    let lons = batch
        .column_by_name("longitude")
        .ok_or(rustler::Error::BadArg)?
        .as_primitive::<arrow_array::types::Float64Type>();
    let uncertainties = batch
        .column_by_name("uncertainty")
        .ok_or(rustler::Error::BadArg)?
        .as_primitive::<arrow_array::types::Float32Type>();

    for i in 0..batch.num_rows() {
        rows.push(SurveySampleRow {
            timestamp: timestamps.value(i),
            scanner_device_id: scanner_device_ids.value(i).to_string(),
            bssid: bssids.value(i).to_string(),
            ssid: ssids.value(i).to_string(),
            rssi: rssis.value(i),
            frequency: frequencies.value(i),
            security_type: security_types.value(i).to_string(),
            is_secure: is_secures.value(i),
            rf_vector: rf_vectors.get(i).cloned().unwrap_or_default(),
            ble_vector: ble_vectors.get(i).cloned().unwrap_or_default(),
            x: xs.value(i),
            y: ys.value(i),
            z: zs.value(i),
            latitude: lats.value(i),
            longitude: lons.value(i),
            uncertainty: uncertainties.value(i),
        });
    }
    Ok(())
}

/// Helper to decode either fixed Lists or dense CSV-string vectors out of Arrow columns.
pub(crate) fn extract_vector_column(
    batch: &RecordBatch,
    column_name: &str,
) -> Result<Vec<Vec<f32>>, rustler::Error> {
    let column = batch
        .column_by_name(column_name)
        .ok_or(rustler::Error::BadArg)?;

    match column.data_type() {
        DataType::List(_) => list_column_to_vectors_i32(column),
        DataType::LargeList(_) => list_column_to_vectors_i64(column),
        DataType::Utf8 => {
            let values = column.as_string::<i32>();
            Ok((0..batch.num_rows())
                .map(|i| parse_vector_csv(values.value(i)))
                .collect())
        }
        DataType::LargeUtf8 => {
            let values = column.as_string::<i64>();
            Ok((0..batch.num_rows())
                .map(|i| parse_vector_csv(values.value(i)))
                .collect())
        }
        _ => Err(rustler::Error::BadArg),
    }
}

pub(crate) fn list_column_to_vectors_i32(
    column: &arrow_array::ArrayRef,
) -> Result<Vec<Vec<f32>>, rustler::Error> {
    let list = column.as_list::<i32>();
    list_column_to_vectors(list)
}

pub(crate) fn list_column_to_vectors_i64(
    column: &arrow_array::ArrayRef,
) -> Result<Vec<Vec<f32>>, rustler::Error> {
    let list = column.as_list::<i64>();
    list_column_to_vectors(list)
}

pub(crate) fn list_column_to_vectors<O: arrow_array::array::OffsetSizeTrait>(
    list: &arrow_array::array::GenericListArray<O>,
) -> Result<Vec<Vec<f32>>, rustler::Error> {
    let values = list.values();
    let offsets = list.value_offsets();

    match values.data_type() {
        DataType::Float32 => {
            let value_array = values.as_primitive::<arrow_array::types::Float32Type>();
            Ok((0..list.len())
                .map(|i| {
                    if list.is_null(i) {
                        Vec::new()
                    } else {
                        let start = offsets[i].as_usize();
                        let end = offsets[i + 1].as_usize();
                        (start..end).map(|idx| value_array.value(idx)).collect()
                    }
                })
                .collect())
        }
        DataType::Float64 => {
            let value_array = values.as_primitive::<arrow_array::types::Float64Type>();
            Ok((0..list.len())
                .map(|i| {
                    if list.is_null(i) {
                        Vec::new()
                    } else {
                        let start = offsets[i].as_usize();
                        let end = offsets[i + 1].as_usize();
                        (start..end)
                            .map(|idx| value_array.value(idx) as f32)
                            .collect()
                    }
                })
                .collect())
        }
        _ => Err(rustler::Error::BadArg),
    }
}

pub(crate) fn parse_vector_csv(raw: &str) -> Vec<f32> {
    if raw.trim().is_empty() {
        return Vec::new();
    }

    raw.split(',')
        .filter_map(|token| f32::from_str(token.trim()).ok())
        .collect()
}
