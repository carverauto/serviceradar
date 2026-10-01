//! Serialization and deserialization bindings for Apache Arrow and Roaring Bitmaps.
//!
//! Exposes functions to pack in-memory Rust topology graphs into `RecordBatch` streams
//! and decode physical survey payloads from binary IPC frames.

use std::collections::HashMap;
use std::str::FromStr;
use std::sync::Arc;

use arrow_array::{
    cast::AsArray, Array, ArrayRef, Int8Array, RecordBatch, StringArray, UInt16Array, UInt32Array,
    UInt64Array, UInt8Array,
};
use arrow_ipc::writer::FileWriter;
use arrow_schema::{DataType, Field, Schema};
use roaring::RoaringBitmap;
use rustler::{Binary, Env, OwnedBinary};

use crate::core::layout::{build_hypergraph_from_projection, build_hypergraph_projection};
use crate::core::snapshot_details::DetailColumns;
use crate::types::fieldsurvey::{
    FieldSurveyPoseSampleRow, FieldSurveyRfObservationRow, FieldSurveySpectrumObservationRow,
};
use crate::types::snapshot::EncodeSnapshotPayload;
use crate::types::survey::SurveySampleRow;

/// Encodes an entire topology active state into an Apache Arrow IPC stream payload.
///
/// This leverages columnar Arrow layouts to bypass Erlang term limits and securely
/// blast thousands of nodes/edges directly to the frontend God View visualizers.
pub(crate) fn encode_snapshot_impl(
    env: Env,
    payload: EncodeSnapshotPayload,
) -> Result<Binary, rustler::Error> {
    let bytes = encode_snapshot_ipc(payload)?;
    vec_into_binary(env, bytes)
}

/// Writes a snapshot frame as one Arrow IPC file.
///
/// Node rows come first, in `nodes` order, and edge rows follow. The schema
/// metadata carries `node_count` and `edge_count`, so every numeric column is
/// dense over rows `0..node_count` for nodes and `node_count..node_count +
/// edge_count` for edges. A decoder can slice positions, states and endpoints
/// straight out of the column buffers without branching on `row_type` or
/// parsing the `node_details` / `edge_details` JSON.
pub(crate) fn encode_snapshot_ipc(
    payload: EncodeSnapshotPayload,
) -> Result<Vec<u8>, rustler::Error> {
    encode_snapshot_with_metadata(payload, HashMap::new())
}

/// Bounded scene entry point shared by HTTP geometry tiles and detail scenes.
/// Limits apply before Arrow allocation and again to the actual encoded bytes.
pub(crate) fn encode_scene_ipc(
    payload: EncodeSnapshotPayload,
    metadata: HashMap<String, String>,
) -> Result<Vec<u8>, &'static str> {
    let edge_limit = if metadata.get("payload_kind").map(String::as_str) == Some("tile") {
        512
    } else {
        256
    };
    if payload.schema_version != 3
        || payload.nodes.len() > 128
        || payload.edges.len() > edge_limit
        || payload.edge_meta.len() > edge_limit
        || payload.edge_directional.len() > edge_limit
        || payload.edge_details.len() > edge_limit
        || metadata.len() > 32
        || metadata
            .iter()
            .map(|(k, v)| k.len() + v.len())
            .sum::<usize>()
            > 8192
    {
        return Err("scene_budget_exceeded");
    }
    if payload.edges.iter().any(|edge| {
        edge.0 as usize >= payload.nodes.len() || edge.1 as usize >= payload.nodes.len()
    }) {
        return Err("invalid_scene_endpoint");
    }
    let text_bytes = payload
        .nodes
        .iter()
        .map(|n| n.3.len() + n.6.len())
        .sum::<usize>()
        + payload.edges.iter().map(|e| e.5.len()).sum::<usize>()
        + payload
            .edge_meta
            .iter()
            .map(|e| e.0.len() + e.1.len() + e.2.len())
            .sum::<usize>()
        + payload.edge_details.iter().map(String::len).sum::<usize>();
    if text_bytes > 262_144 {
        return Err("scene_budget_exceeded");
    }
    let bytes =
        encode_snapshot_with_metadata(payload, metadata).map_err(|_| "scene_encoding_failed")?;
    if bytes.len() > 262_144 {
        return Err("scene_budget_exceeded");
    }
    Ok(bytes)
}

fn encode_snapshot_with_metadata(
    payload: EncodeSnapshotPayload,
    mut metadata: HashMap<String, String>,
) -> Result<Vec<u8>, rustler::Error> {
    let EncodeSnapshotPayload {
        schema_version,
        revision,
        nodes,
        edges,
        edge_meta,
        edge_directional,
        edge_details,
        root_bitmap_bytes,
        affected_bitmap_bytes,
        healthy_bitmap_bytes,
        unknown_bitmap_bytes,
    } = payload;

    let node_count = nodes.len();
    let edge_count = edges.len();
    let total_rows = node_count + edge_count;
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
    let mut details = DetailColumns::with_capacity(total_rows);
    let mut edge_source = Vec::<Option<u32>>::with_capacity(total_rows);
    let mut edge_target = Vec::<Option<u32>>::with_capacity(total_rows);
    let mut edge_pps = Vec::<Option<u32>>::with_capacity(total_rows);
    let mut edge_pps_ab = Vec::<Option<u32>>::with_capacity(total_rows);
    let mut edge_pps_ba = Vec::<Option<u32>>::with_capacity(total_rows);
    let mut edge_flow_bps = Vec::<Option<u64>>::with_capacity(total_rows);
    let mut edge_flow_bps_ab = Vec::<Option<u64>>::with_capacity(total_rows);
    let mut edge_flow_bps_ba = Vec::<Option<u64>>::with_capacity(total_rows);
    let mut edge_capacity_bps = Vec::<Option<u64>>::with_capacity(total_rows);
    let mut edge_telemetry_eligible = Vec::<Option<u8>>::with_capacity(total_rows);
    let mut edge_label = Vec::<Option<String>>::with_capacity(total_rows);
    let mut edge_topology_class = Vec::<Option<String>>::with_capacity(total_rows);
    let mut edge_protocol = Vec::<Option<String>>::with_capacity(total_rows);
    let mut edge_evidence_class = Vec::<Option<String>>::with_capacity(total_rows);
    let mut edge_details_json = Vec::<Option<String>>::with_capacity(total_rows);

    for (x, y, state, label, pps, oper_up, node_details_json) in nodes {
        row_type.push(0);
        details.push_node(&node_details_json);
        node_x.push(Some(x));
        node_y.push(Some(y));
        node_state.push(Some(u16::from(state)));
        node_label.push(Some(label));
        node_pps.push(Some(pps));
        node_oper_up.push(Some(oper_up));
        node_details.push(Some(node_details_json));
        edge_source.push(None);
        edge_target.push(None);
        edge_pps.push(None);
        edge_pps_ab.push(None);
        edge_pps_ba.push(None);
        edge_flow_bps.push(None);
        edge_flow_bps_ab.push(None);
        edge_flow_bps_ba.push(None);
        edge_capacity_bps.push(None);
        edge_telemetry_eligible.push(None);
        edge_label.push(None);
        edge_topology_class.push(None);
        edge_protocol.push(None);
        edge_evidence_class.push(None);
        edge_details_json.push(None);
    }

    for (idx, (source, target, pps, flow_bps, capacity_bps, label, telemetry_eligible)) in
        edges.into_iter().enumerate()
    {
        let (flow_pps_ab, flow_pps_ba, flow_bps_ab, flow_bps_ba) =
            edge_directional.get(idx).copied().unwrap_or((0, 0, 0, 0));
        let (topology_class, protocol, evidence_class) =
            edge_meta.get(idx).cloned().unwrap_or_else(|| {
                (
                    "backbone".to_string(),
                    "".to_string(),
                    "unknown".to_string(),
                )
            });
        let edge_details_row = edge_details
            .get(idx)
            .cloned()
            .unwrap_or_else(|| "{}".to_string());

        row_type.push(1);
        node_x.push(None);
        node_y.push(None);
        node_state.push(None);
        node_label.push(None);
        node_pps.push(None);
        node_oper_up.push(None);
        node_details.push(None);
        details.push_edge(&edge_details_row);
        edge_source.push(Some(source));
        edge_target.push(Some(target));
        edge_pps.push(Some(pps));
        edge_pps_ab.push(Some(flow_pps_ab));
        edge_pps_ba.push(Some(flow_pps_ba));
        edge_flow_bps.push(Some(flow_bps));
        edge_flow_bps_ab.push(Some(flow_bps_ab));
        edge_flow_bps_ba.push(Some(flow_bps_ba));
        edge_capacity_bps.push(Some(capacity_bps));
        edge_telemetry_eligible.push(Some(if telemetry_eligible > 0 { 1 } else { 0 }));
        edge_label.push(Some(label));
        edge_topology_class.push(Some(topology_class));
        edge_protocol.push(Some(protocol));
        edge_evidence_class.push(Some(evidence_class));
        edge_details_json.push(Some(edge_details_row));
    }

    metadata.insert("schema_version".to_string(), schema_version.to_string());
    metadata.insert("revision".to_string(), revision.to_string());
    metadata.insert("node_count".to_string(), node_count.to_string());
    metadata.insert("edge_count".to_string(), edge_count.to_string());
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

    let (detail_fields, detail_arrays): (Vec<Field>, Vec<ArrayRef>) =
        details.into_fields_and_arrays().into_iter().unzip();

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
            Field::new("edge_source", DataType::UInt32, true),
            Field::new("edge_target", DataType::UInt32, true),
            Field::new("edge_pps", DataType::UInt32, true),
            Field::new("edge_pps_ab", DataType::UInt32, true),
            Field::new("edge_pps_ba", DataType::UInt32, true),
            Field::new("edge_flow_bps", DataType::UInt64, true),
            Field::new("edge_flow_bps_ab", DataType::UInt64, true),
            Field::new("edge_flow_bps_ba", DataType::UInt64, true),
            Field::new("edge_capacity_bps", DataType::UInt64, true),
            Field::new("edge_telemetry_eligible", DataType::UInt8, true),
            Field::new("edge_label", DataType::Utf8, true),
            Field::new("edge_topology_class", DataType::Utf8, true),
            Field::new("edge_protocol", DataType::Utf8, true),
            Field::new("edge_evidence_class", DataType::Utf8, true),
            Field::new("edge_details", DataType::Utf8, true),
            Field::new("snapshot_schema_version", DataType::UInt32, false),
            Field::new("snapshot_revision", DataType::UInt64, false),
        ]
        .into_iter()
        .chain(detail_fields)
        .collect::<Vec<_>>(),
        metadata,
    ));

    let schema_version_col = vec![schema_version; total_rows];
    let revision_col = vec![revision; total_rows];

    let batch = RecordBatch::try_new(
        Arc::clone(&schema),
        vec![
            Arc::new(Int8Array::from(row_type)) as ArrayRef,
            Arc::new(UInt16Array::from(node_x)),
            Arc::new(UInt16Array::from(node_y)),
            Arc::new(UInt16Array::from(node_state)),
            Arc::new(StringArray::from(node_label)),
            Arc::new(UInt32Array::from(node_pps)),
            Arc::new(UInt8Array::from(node_oper_up)),
            Arc::new(StringArray::from(node_details)),
            Arc::new(UInt32Array::from(edge_source)),
            Arc::new(UInt32Array::from(edge_target)),
            Arc::new(UInt32Array::from(edge_pps)),
            Arc::new(UInt32Array::from(edge_pps_ab)),
            Arc::new(UInt32Array::from(edge_pps_ba)),
            Arc::new(UInt64Array::from(edge_flow_bps)),
            Arc::new(UInt64Array::from(edge_flow_bps_ab)),
            Arc::new(UInt64Array::from(edge_flow_bps_ba)),
            Arc::new(UInt64Array::from(edge_capacity_bps)),
            Arc::new(UInt8Array::from(edge_telemetry_eligible)),
            Arc::new(StringArray::from(edge_label)),
            Arc::new(StringArray::from(edge_topology_class)),
            Arc::new(StringArray::from(edge_protocol)),
            Arc::new(StringArray::from(edge_evidence_class)),
            Arc::new(StringArray::from(edge_details_json)),
            Arc::new(UInt32Array::from(schema_version_col)),
            Arc::new(UInt64Array::from(revision_col)) as ArrayRef,
        ]
        .into_iter()
        .chain(detail_arrays)
        .collect(),
    )
    .map_err(|_| rustler::Error::BadArg)?;

    let mut payload = Vec::new();
    {
        let mut writer =
            FileWriter::try_new(&mut payload, &schema).map_err(|_| rustler::Error::BadArg)?;
        writer.write(&batch).map_err(|_| rustler::Error::BadArg)?;
        writer.finish().map_err(|_| rustler::Error::BadArg)?;
    }

    Ok(payload)
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
    let reader =
        arrow_ipc::reader::FileReader::try_new(cursor, None).map_err(|_| rustler::Error::BadArg)?;

    let mut rows = Vec::new();
    for batch_result in reader {
        let batch = batch_result.map_err(|_| rustler::Error::BadArg)?;
        extract_rows(&batch, &mut rows)?;
    }

    Ok(rows)
}

fn required_string_column<'a>(
    batch: &'a RecordBatch,
    column_name: &str,
) -> Result<&'a arrow_array::array::GenericStringArray<i32>, rustler::Error> {
    batch
        .column_by_name(column_name)
        .ok_or(rustler::Error::BadArg)?
        .as_any()
        .downcast_ref::<arrow_array::array::GenericStringArray<i32>>()
        .ok_or(rustler::Error::BadArg)
}

fn required_i64_column<'a>(
    batch: &'a RecordBatch,
    column_name: &str,
) -> Result<&'a arrow_array::PrimitiveArray<arrow_array::types::Int64Type>, rustler::Error> {
    required_primitive_column::<arrow_array::types::Int64Type>(batch, column_name)
}

fn required_f64_column<'a>(
    batch: &'a RecordBatch,
    column_name: &str,
) -> Result<&'a arrow_array::PrimitiveArray<arrow_array::types::Float64Type>, rustler::Error> {
    required_primitive_column::<arrow_array::types::Float64Type>(batch, column_name)
}

fn required_f32_column<'a>(
    batch: &'a RecordBatch,
    column_name: &str,
) -> Result<&'a arrow_array::PrimitiveArray<arrow_array::types::Float32Type>, rustler::Error> {
    required_primitive_column::<arrow_array::types::Float32Type>(batch, column_name)
}

fn required_boolean_column<'a>(
    batch: &'a RecordBatch,
    column_name: &str,
) -> Result<&'a arrow_array::BooleanArray, rustler::Error> {
    batch
        .column_by_name(column_name)
        .ok_or(rustler::Error::BadArg)?
        .as_any()
        .downcast_ref::<arrow_array::BooleanArray>()
        .ok_or(rustler::Error::BadArg)
}

fn required_primitive_column<'a, T>(
    batch: &'a RecordBatch,
    column_name: &str,
) -> Result<&'a arrow_array::PrimitiveArray<T>, rustler::Error>
where
    T: arrow_array::types::ArrowPrimitiveType,
{
    batch
        .column_by_name(column_name)
        .ok_or(rustler::Error::BadArg)?
        .as_any()
        .downcast_ref::<arrow_array::PrimitiveArray<T>>()
        .ok_or(rustler::Error::BadArg)
}

/// Extracts strongly typed columns from a RecordBatch and populates the Elixir-facing structs.
pub(crate) fn extract_rows(
    batch: &RecordBatch,
    rows: &mut Vec<SurveySampleRow>,
) -> Result<(), rustler::Error> {
    let timestamps = required_f64_column(batch, "timestamp")?;
    let scanner_device_ids = required_string_column(batch, "scannerDeviceId")?;
    let bssids = required_string_column(batch, "bssid")?;
    let ssids = required_string_column(batch, "ssid")?;
    let rssis = required_f64_column(batch, "rssi")?;
    let frequencies = required_i64_column(batch, "frequency")?;
    let security_types = required_string_column(batch, "securityType")?;
    let is_secures = required_boolean_column(batch, "isSecure")?;
    let rf_vectors = extract_vector_column(batch, "rfVector")?;
    let ble_vectors = extract_vector_column(batch, "bleVector")?;
    let xs = required_f32_column(batch, "x")?;
    let ys = required_f32_column(batch, "y")?;
    let zs = required_f32_column(batch, "z")?;
    let lats = required_f64_column(batch, "latitude")?;
    let lons = required_f64_column(batch, "longitude")?;
    let uncertainties = required_f32_column(batch, "uncertainty")?;

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
            let values = column
                .as_any()
                .downcast_ref::<arrow_array::array::GenericStringArray<i32>>()
                .ok_or(rustler::Error::BadArg)?;
            Ok((0..batch.num_rows())
                .map(|i| parse_vector_csv(values.value(i)))
                .collect())
        }
        DataType::LargeUtf8 => {
            let values = column
                .as_any()
                .downcast_ref::<arrow_array::array::GenericStringArray<i64>>()
                .ok_or(rustler::Error::BadArg)?;
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
    let list = column
        .as_any()
        .downcast_ref::<arrow_array::array::GenericListArray<i32>>()
        .ok_or(rustler::Error::BadArg)?;
    list_column_to_vectors(list)
}

pub(crate) fn list_column_to_vectors_i64(
    column: &arrow_array::ArrayRef,
) -> Result<Vec<Vec<f32>>, rustler::Error> {
    let list = column
        .as_any()
        .downcast_ref::<arrow_array::array::GenericListArray<i64>>()
        .ok_or(rustler::Error::BadArg)?;
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

pub(crate) fn decode_fieldsurvey_rf_payload(
    data: &[u8],
) -> Result<Vec<FieldSurveyRfObservationRow>, rustler::Error> {
    decode_arrow_payload(
        data,
        extract_fieldsurvey_rf_rows,
        extract_fieldsurvey_rf_rows_from_file,
    )
}

pub(crate) fn decode_fieldsurvey_pose_payload(
    data: &[u8],
) -> Result<Vec<FieldSurveyPoseSampleRow>, rustler::Error> {
    decode_arrow_payload(
        data,
        extract_fieldsurvey_pose_rows,
        extract_fieldsurvey_pose_rows_from_file,
    )
}

pub(crate) fn decode_fieldsurvey_spectrum_payload(
    data: &[u8],
) -> Result<Vec<FieldSurveySpectrumObservationRow>, rustler::Error> {
    decode_arrow_payload(
        data,
        extract_fieldsurvey_spectrum_rows,
        extract_fieldsurvey_spectrum_rows_from_file,
    )
}

fn decode_arrow_payload<T>(
    data: &[u8],
    extract_stream_batch: fn(&RecordBatch, &mut Vec<T>) -> Result<(), rustler::Error>,
    decode_file: fn(&[u8]) -> Result<Vec<T>, rustler::Error>,
) -> Result<Vec<T>, rustler::Error> {
    let cursor = std::io::Cursor::new(data);
    let reader = match arrow_ipc::reader::StreamReader::try_new(cursor, None) {
        Ok(reader) => reader,
        Err(_) => return decode_file(data),
    };

    let mut rows = Vec::new();
    for batch_result in reader {
        let batch = batch_result.map_err(|_| rustler::Error::BadArg)?;
        extract_stream_batch(&batch, &mut rows)?;
    }

    Ok(rows)
}

fn extract_fieldsurvey_rf_rows_from_file(
    data: &[u8],
) -> Result<Vec<FieldSurveyRfObservationRow>, rustler::Error> {
    let cursor = std::io::Cursor::new(data);
    let reader =
        arrow_ipc::reader::FileReader::try_new(cursor, None).map_err(|_| rustler::Error::BadArg)?;

    let mut rows = Vec::new();
    for batch_result in reader {
        let batch = batch_result.map_err(|_| rustler::Error::BadArg)?;
        extract_fieldsurvey_rf_rows(&batch, &mut rows)?;
    }

    Ok(rows)
}

fn extract_fieldsurvey_pose_rows_from_file(
    data: &[u8],
) -> Result<Vec<FieldSurveyPoseSampleRow>, rustler::Error> {
    let cursor = std::io::Cursor::new(data);
    let reader =
        arrow_ipc::reader::FileReader::try_new(cursor, None).map_err(|_| rustler::Error::BadArg)?;

    let mut rows = Vec::new();
    for batch_result in reader {
        let batch = batch_result.map_err(|_| rustler::Error::BadArg)?;
        extract_fieldsurvey_pose_rows(&batch, &mut rows)?;
    }

    Ok(rows)
}

fn extract_fieldsurvey_spectrum_rows_from_file(
    data: &[u8],
) -> Result<Vec<FieldSurveySpectrumObservationRow>, rustler::Error> {
    let cursor = std::io::Cursor::new(data);
    let reader =
        arrow_ipc::reader::FileReader::try_new(cursor, None).map_err(|_| rustler::Error::BadArg)?;

    let mut rows = Vec::new();
    for batch_result in reader {
        let batch = batch_result.map_err(|_| rustler::Error::BadArg)?;
        extract_fieldsurvey_spectrum_rows(&batch, &mut rows)?;
    }

    Ok(rows)
}

fn extract_fieldsurvey_rf_rows(
    batch: &RecordBatch,
    rows: &mut Vec<FieldSurveyRfObservationRow>,
) -> Result<(), rustler::Error> {
    let sidekick_ids = required_string_column(batch, "sidekick_id")?;
    let radio_ids = required_string_column(batch, "radio_id")?;
    let interface_names = required_string_column(batch, "interface_name")?;
    let bssids = required_string_column(batch, "bssid")?;
    let ssids = optional_string_column(batch, "ssid")?;
    let hidden_ssids = required_boolean_column(batch, "hidden_ssid")?;
    let frame_types = required_string_column(batch, "frame_type")?;
    let rssi_dbms = optional_i16_column(batch, "rssi_dbm")?;
    let noise_floor_dbms = optional_i16_column(batch, "noise_floor_dbm")?;
    let snr_dbs = optional_i16_column(batch, "snr_db")?;
    let frequency_mhzes = required_i32_column(batch, "frequency_mhz")?;
    let channels = optional_i32_column(batch, "channel")?;
    let channel_width_mhzes = optional_i32_column(batch, "channel_width_mhz")?;
    let captured_at_unix_nanoses = required_i64_column(batch, "captured_at_unix_nanos")?;
    let captured_at_monotonic_nanoses = optional_i64_column(batch, "captured_at_monotonic_nanos")?;
    let parser_confidences = required_f64_column(batch, "parser_confidence")?;

    for i in 0..batch.num_rows() {
        rows.push(FieldSurveyRfObservationRow {
            sidekick_id: string_value(sidekick_ids, i)?,
            radio_id: string_value(radio_ids, i)?,
            interface_name: string_value(interface_names, i)?,
            bssid: string_value(bssids, i)?,
            ssid: optional_string_value(ssids, i),
            hidden_ssid: hidden_ssids.value(i),
            frame_type: string_value(frame_types, i)?,
            rssi_dbm: optional_i16_value(rssi_dbms, i),
            noise_floor_dbm: optional_i16_value(noise_floor_dbms, i),
            snr_db: optional_i16_value(snr_dbs, i),
            frequency_mhz: frequency_mhzes.value(i),
            channel: optional_i32_value(channels, i),
            channel_width_mhz: optional_i32_value(channel_width_mhzes, i),
            captured_at_unix_nanos: captured_at_unix_nanoses.value(i),
            captured_at_monotonic_nanos: optional_i64_value(captured_at_monotonic_nanoses, i),
            parser_confidence: parser_confidences.value(i),
        });
    }

    Ok(())
}

fn extract_fieldsurvey_spectrum_rows(
    batch: &RecordBatch,
    rows: &mut Vec<FieldSurveySpectrumObservationRow>,
) -> Result<(), rustler::Error> {
    let sidekick_ids = required_string_column(batch, "sidekick_id")?;
    let sdr_ids = required_string_column(batch, "sdr_id")?;
    let device_kinds = required_string_column(batch, "device_kind")?;
    let serial_numbers = optional_string_column(batch, "serial_number")?;
    let sweep_ids = required_i64_column(batch, "sweep_id")?;
    let started_at_unix_nanoses = required_i64_column(batch, "started_at_unix_nanos")?;
    let captured_at_unix_nanoses = required_i64_column(batch, "captured_at_unix_nanos")?;
    let start_frequency_hzes = required_i64_column(batch, "start_frequency_hz")?;
    let stop_frequency_hzes = required_i64_column(batch, "stop_frequency_hz")?;
    let bin_width_hzes = required_f64_column(batch, "bin_width_hz")?;
    let sample_counts = required_i32_column(batch, "sample_count")?;
    let power_bins_dbms = extract_vector_column(batch, "power_bins_dbm")?;

    for i in 0..batch.num_rows() {
        rows.push(FieldSurveySpectrumObservationRow {
            sidekick_id: string_value(sidekick_ids, i)?,
            sdr_id: string_value(sdr_ids, i)?,
            device_kind: string_value(device_kinds, i)?,
            serial_number: optional_string_value(serial_numbers, i),
            sweep_id: sweep_ids.value(i),
            started_at_unix_nanos: started_at_unix_nanoses.value(i),
            captured_at_unix_nanos: captured_at_unix_nanoses.value(i),
            start_frequency_hz: start_frequency_hzes.value(i),
            stop_frequency_hz: stop_frequency_hzes.value(i),
            bin_width_hz: bin_width_hzes.value(i),
            sample_count: sample_counts.value(i),
            power_bins_dbm: power_bins_dbms.get(i).cloned().unwrap_or_default(),
        });
    }

    Ok(())
}

fn extract_fieldsurvey_pose_rows(
    batch: &RecordBatch,
    rows: &mut Vec<FieldSurveyPoseSampleRow>,
) -> Result<(), rustler::Error> {
    let scanner_device_ids = required_string_column(batch, "scanner_device_id")?;
    let captured_at_unix_nanoses = required_i64_column(batch, "captured_at_unix_nanos")?;
    let captured_at_monotonic_nanoses = optional_i64_column(batch, "captured_at_monotonic_nanos")?;
    let xs = required_f64_column(batch, "x")?;
    let ys = required_f64_column(batch, "y")?;
    let zs = required_f64_column(batch, "z")?;
    let qxs = required_f64_column(batch, "qx")?;
    let qys = required_f64_column(batch, "qy")?;
    let qzs = required_f64_column(batch, "qz")?;
    let qws = required_f64_column(batch, "qw")?;
    let latitudes = optional_f64_column(batch, "latitude")?;
    let longitudes = optional_f64_column(batch, "longitude")?;
    let altitudes = optional_f64_column(batch, "altitude")?;
    let accuracy_ms = optional_f64_column(batch, "accuracy_m")?;
    let tracking_qualities = optional_string_column(batch, "tracking_quality")?;

    for i in 0..batch.num_rows() {
        rows.push(FieldSurveyPoseSampleRow {
            scanner_device_id: string_value(scanner_device_ids, i)?,
            captured_at_unix_nanos: captured_at_unix_nanoses.value(i),
            captured_at_monotonic_nanos: optional_i64_value(captured_at_monotonic_nanoses, i),
            x: xs.value(i),
            y: ys.value(i),
            z: zs.value(i),
            qx: qxs.value(i),
            qy: qys.value(i),
            qz: qzs.value(i),
            qw: qws.value(i),
            latitude: optional_f64_value(latitudes, i),
            longitude: optional_f64_value(longitudes, i),
            altitude: optional_f64_value(altitudes, i),
            accuracy_m: optional_f64_value(accuracy_ms, i),
            tracking_quality: optional_string_value(tracking_qualities, i),
        });
    }

    Ok(())
}

fn optional_string_column<'a>(
    batch: &'a RecordBatch,
    column_name: &str,
) -> Result<Option<&'a arrow_array::array::GenericStringArray<i32>>, rustler::Error> {
    batch
        .column_by_name(column_name)
        .map(|column| {
            column
                .as_any()
                .downcast_ref::<arrow_array::array::GenericStringArray<i32>>()
                .ok_or(rustler::Error::BadArg)
        })
        .transpose()
}

fn string_value(
    values: &arrow_array::array::GenericStringArray<i32>,
    index: usize,
) -> Result<String, rustler::Error> {
    if values.is_null(index) {
        return Err(rustler::Error::BadArg);
    }

    Ok(values.value(index).to_string())
}

fn optional_string_value(
    values: Option<&arrow_array::array::GenericStringArray<i32>>,
    index: usize,
) -> Option<String> {
    values.and_then(|array| {
        if array.is_null(index) {
            None
        } else {
            Some(array.value(index).to_string())
        }
    })
}

fn optional_i16_column<'a>(
    batch: &'a RecordBatch,
    column_name: &str,
) -> Result<Option<&'a arrow_array::PrimitiveArray<arrow_array::types::Int16Type>>, rustler::Error>
{
    optional_primitive_column::<arrow_array::types::Int16Type>(batch, column_name)
}

fn optional_i32_column<'a>(
    batch: &'a RecordBatch,
    column_name: &str,
) -> Result<Option<&'a arrow_array::PrimitiveArray<arrow_array::types::Int32Type>>, rustler::Error>
{
    optional_primitive_column::<arrow_array::types::Int32Type>(batch, column_name)
}

fn optional_i64_column<'a>(
    batch: &'a RecordBatch,
    column_name: &str,
) -> Result<Option<&'a arrow_array::PrimitiveArray<arrow_array::types::Int64Type>>, rustler::Error>
{
    optional_primitive_column::<arrow_array::types::Int64Type>(batch, column_name)
}

fn required_i32_column<'a>(
    batch: &'a RecordBatch,
    column_name: &str,
) -> Result<&'a arrow_array::PrimitiveArray<arrow_array::types::Int32Type>, rustler::Error> {
    required_primitive_column::<arrow_array::types::Int32Type>(batch, column_name)
}

fn optional_f64_column<'a>(
    batch: &'a RecordBatch,
    column_name: &str,
) -> Result<Option<&'a arrow_array::PrimitiveArray<arrow_array::types::Float64Type>>, rustler::Error>
{
    optional_primitive_column::<arrow_array::types::Float64Type>(batch, column_name)
}

fn optional_primitive_column<'a, T>(
    batch: &'a RecordBatch,
    column_name: &str,
) -> Result<Option<&'a arrow_array::PrimitiveArray<T>>, rustler::Error>
where
    T: arrow_array::types::ArrowPrimitiveType,
{
    batch
        .column_by_name(column_name)
        .map(|column| {
            column
                .as_any()
                .downcast_ref::<arrow_array::PrimitiveArray<T>>()
                .ok_or(rustler::Error::BadArg)
        })
        .transpose()
}

fn optional_i16_value(
    values: Option<&arrow_array::PrimitiveArray<arrow_array::types::Int16Type>>,
    index: usize,
) -> Option<i16> {
    values.and_then(|array| {
        if array.is_null(index) {
            None
        } else {
            Some(array.value(index))
        }
    })
}

fn optional_i32_value(
    values: Option<&arrow_array::PrimitiveArray<arrow_array::types::Int32Type>>,
    index: usize,
) -> Option<i32> {
    values.and_then(|array| {
        if array.is_null(index) {
            None
        } else {
            Some(array.value(index))
        }
    })
}

fn optional_i64_value(
    values: Option<&arrow_array::PrimitiveArray<arrow_array::types::Int64Type>>,
    index: usize,
) -> Option<i64> {
    values.and_then(|array| {
        if array.is_null(index) {
            None
        } else {
            Some(array.value(index))
        }
    })
}

fn optional_f64_value(
    values: Option<&arrow_array::PrimitiveArray<arrow_array::types::Float64Type>>,
    index: usize,
) -> Option<f64> {
    values.and_then(|array| {
        if array.is_null(index) {
            None
        } else {
            Some(array.value(index))
        }
    })
}

#[cfg(test)]
mod tests {
    use super::{encode_scene_ipc, encode_snapshot_ipc};
    use crate::types::snapshot::EncodeSnapshotPayload;
    use arrow_array::{
        Array, Float64Array, RecordBatch, StringArray, UInt16Array, UInt32Array, UInt8Array,
    };
    use arrow_ipc::reader::FileReader;
    use arrow_schema::DataType;
    use std::collections::HashMap;

    type NodeRow = (u16, u16, u8, String, u32, u8, String);
    type EdgeRow = (u32, u32, u32, u64, u64, String, u8);

    fn encode(nodes: Vec<NodeRow>, edges: Vec<EdgeRow>, edge_details: Vec<String>) -> RecordBatch {
        let bytes = encode_snapshot_ipc(EncodeSnapshotPayload {
            schema_version: 3,
            revision: 9,
            nodes,
            edges,
            edge_meta: Vec::new(),
            edge_directional: Vec::new(),
            edge_details,
            root_bitmap_bytes: 0,
            affected_bitmap_bytes: 0,
            healthy_bitmap_bytes: 0,
            unknown_bitmap_bytes: 0,
        })
        .unwrap();
        let reader = FileReader::try_new(std::io::Cursor::new(bytes), None).unwrap();
        let batches: Vec<RecordBatch> = reader.map(|batch| batch.unwrap()).collect();
        assert_eq!(batches.len(), 1);
        batches.into_iter().next().unwrap()
    }

    fn column<'a, T: 'static>(batch: &'a RecordBatch, name: &str) -> &'a T {
        batch
            .column_by_name(name)
            .unwrap_or_else(|| panic!("missing column {name}"))
            .as_any()
            .downcast_ref::<T>()
            .unwrap_or_else(|| panic!("column {name} has an unexpected type"))
    }

    fn node(details: &str) -> NodeRow {
        (0, 0, 2, "n".to_string(), 0, 1, details.to_string())
    }

    fn scene() -> EncodeSnapshotPayload {
        EncodeSnapshotPayload {
            schema_version: 3,
            revision: 0,
            nodes: vec![
                (0, 32768, 3, "West".into(), 0, 0,
                 r#"{"id":"aggregate:west","type":"aggregate","cluster_member_count":70000}"#.into()),
                (65535, 32768, 3, "Boundary".into(), 0, 0,
                 r#"{"id":"boundary:east","type":"boundary","cluster_member_count":0}"#.into()),
            ],
            edges: vec![(0, 1, 0, 0, 0, String::new(), 0)],
            edge_details: vec![r#"{"id":"bundle:west-east","represented_count":90000,"phase_start":0.25,"phase_end":0.75}"#.into()],
            edge_meta: vec![],
            edge_directional: vec![],
            root_bitmap_bytes: 0,
            affected_bitmap_bytes: 0,
            healthy_bitmap_bytes: 0,
            unknown_bitmap_bytes: 0,
        }
    }

    #[test]
    fn bounded_scene_round_trips_transform_membership_and_clipped_flow_phase() {
        let metadata: HashMap<String, String> = [
            ("payload_kind", "tile"),
            ("origin_x", "8388608"),
            ("coordinate_scale", "128.00195315480278"),
        ]
        .into_iter()
        .map(|(k, v)| (k.into(), v.into()))
        .collect();
        let bytes = encode_scene_ipc(scene(), metadata.clone()).unwrap();
        // HashMap allocation/iteration order must not churn content-addressed tiles.
        for _ in 0..8 {
            assert_eq!(bytes, encode_scene_ipc(scene(), metadata.clone()).unwrap());
        }
        let mut reader = FileReader::try_new(std::io::Cursor::new(bytes), None).unwrap();
        let batch = reader.next().unwrap().unwrap();
        assert!(reader.next().is_none());
        assert_eq!(batch.num_rows(), 3);
        assert_eq!(batch.schema().metadata()["origin_x"], "8388608");
        let xs: &UInt16Array = column(&batch, "node_x");
        assert_eq!(xs.values().as_ref()[..2], [0, 65535]);
        let members: &Float64Array = column(&batch, "node_detail_cluster_member_count");
        assert_eq!(members.value(0), 70000.0);
        assert_eq!(members.value(1), 0.0);
        let count: &Float64Array = column(&batch, "edge_detail_represented_count");
        let start: &Float64Array = column(&batch, "edge_detail_phase_start");
        let end: &Float64Array = column(&batch, "edge_detail_phase_end");
        let ids: &StringArray = column(&batch, "edge_detail_id");
        assert_eq!(count.value(2), 90000.0);
        assert_eq!((start.value(2), end.value(2)), (0.25, 0.75));
        assert_eq!(ids.value(2), "bundle:west-east");
    }

    #[test]
    fn scene_rejects_actual_encoded_overflow_cardinality_and_invalid_endpoints() {
        let mut too_many = scene();
        too_many.nodes = (0..129).map(|_| node("{}")).collect();
        assert_eq!(
            encode_scene_ipc(too_many, HashMap::new()),
            Err("scene_budget_exceeded")
        );
        for (kind, limit) in [("tile", 512), ("detail", 256)] {
            let metadata = HashMap::from([("payload_kind".into(), kind.into())]);
            let mut bounded = scene();
            bounded.edges = vec![bounded.edges[0].clone(); limit];
            bounded.edge_details = vec![bounded.edge_details[0].clone(); limit];
            let bytes = encode_scene_ipc(bounded, metadata.clone()).unwrap();
            let mut reader = FileReader::try_new(std::io::Cursor::new(bytes), None).unwrap();
            assert_eq!(reader.next().unwrap().unwrap().num_rows(), limit + 2);
            let mut overflow = scene();
            overflow.edges = vec![overflow.edges[0].clone(); limit + 1];
            assert_eq!(
                encode_scene_ipc(overflow, metadata),
                Err("scene_budget_exceeded")
            );
        }
        let mut invalid = scene();
        invalid.edges[0].1 = 2;
        assert_eq!(
            encode_scene_ipc(invalid, HashMap::new()),
            Err("invalid_scene_endpoint")
        );
        let mut large = scene();
        let details = format!(r#"{{"id":"{}"}}"#, "a".repeat(1500));
        large.nodes = (0..128).map(|_| node(&details)).collect();
        // Input JSON fits, but its dense id column also consumes wire bytes.
        assert!(128 * details.len() < 262_144);
        assert_eq!(
            encode_scene_ipc(large, HashMap::new()),
            Err("scene_budget_exceeded")
        );
        let mut empty = scene();
        empty.nodes.clear();
        empty.edges.clear();
        empty.edge_details.clear();
        let bytes = encode_scene_ipc(empty, HashMap::new()).unwrap();
        let mut reader = FileReader::try_new(std::io::Cursor::new(bytes), None).unwrap();
        assert_eq!(reader.next().unwrap().unwrap().num_rows(), 0);
        assert!(reader.next().is_none());
    }

    #[test]
    fn snapshot_endpoints_above_u16_round_trip() {
        let node_count: u32 = 70_000;
        let nodes = (0..node_count)
            .map(|idx| {
                (
                    (idx % 65_536) as u16,
                    (idx / 2 % 65_536) as u16,
                    (idx % 4) as u8,
                    format!("node-{idx}"),
                    idx,
                    1u8,
                    format!(r#"{{"id":"sr:test-{idx}"}}"#),
                )
            })
            .collect();
        let edges = vec![
            (0u32, 65_535u32, 1u32, 2u64, 3u64, "a".to_string(), 1u8),
            (65_536, 69_999, 4, 5, 6, "b".to_string(), 1),
            (69_998, 1, 7, 8, 9, "c".to_string(), 0),
        ];

        let batch = encode(nodes, edges, Vec::new());

        let edge_offset = node_count as usize;
        assert_eq!(batch.num_rows(), edge_offset + 3);
        let metadata = batch.schema().metadata().clone();
        let meta = |key: &str| metadata.get(key).map(String::as_str);
        assert_eq!(meta("node_count"), Some("70000"));
        assert_eq!(meta("edge_count"), Some("3"));
        assert_eq!(meta("schema_version"), Some("3"));
        assert_eq!(meta("topology_hypergraph_dropped_edges"), Some("0"));

        let sources: &UInt32Array = column(&batch, "edge_source");
        let targets: &UInt32Array = column(&batch, "edge_target");
        assert_eq!(sources.data_type(), &DataType::UInt32);
        let endpoints: Vec<(u32, u32)> = (edge_offset..edge_offset + 3)
            .map(|row| (sources.value(row), targets.value(row)))
            .collect();
        assert_eq!(endpoints, vec![(0, 65_535), (65_536, 69_999), (69_998, 1)]);
        assert!(sources.is_null(0) && targets.is_null(edge_offset - 1));

        // Layout coordinates stay in the 16-bit quantized space.
        let xs: &UInt16Array = column(&batch, "node_x");
        let ys: &UInt16Array = column(&batch, "node_y");
        assert_eq!((xs.value(65_537), ys.value(65_537)), (1, 32_768));
        assert!(xs.is_null(edge_offset));

        // Node ids come from each row's own details JSON.
        let ids: &StringArray = column(&batch, "node_detail_id");
        assert_eq!(ids.value(69_999), "sr:test-69999");
        assert!(ids.is_null(edge_offset));
    }

    #[test]
    fn details_keys_read_for_every_row_are_dense_columns() {
        let nodes = vec![
            node(
                r#"{"id":"sr:a","type":"switch","cluster_kind":"endpoint-summary","cluster_id":"c1",
                    "cluster_anchor_id":"sr:b","cluster_expanded":true,"topology_unplaced":false,
                    "cluster_member_count":12,"geo_lat":1.5,"geo_lon":null,"ip":"192.0.2.1"}"#,
            ),
            node("not json"),
        ];
        let edges = vec![(0u32, 1u32, 0u32, 0u64, 0u64, String::new(), 1u8)];
        let edge_details = vec![
            r#"{"source_id":"sr:a","target_id":"sr:b","source_if_index":7,
            "source_interface":"ge-0/0/1","telemetry_observed_at":"2026-01-01T00:00:00Z",
            "interface_sparkline":[{"value":1}],
            "metadata":{"relation_type":"CONNECTS_TO","topology_plane":"physical",
                        "connectivity_forest_bridge":false}}"#
                .to_string(),
        ];

        let batch = encode(nodes, edges, edge_details);

        let text = |name: &str, row: usize| {
            let values: &StringArray = column(&batch, name);
            (!values.is_null(row)).then(|| values.value(row).to_string())
        };
        let flag = |name: &str, row: usize| column::<UInt8Array>(&batch, name).value(row);
        let number = |name: &str, row: usize| column::<Float64Array>(&batch, name).value(row);

        assert_eq!(
            text("node_detail_cluster_kind", 0).as_deref(),
            Some("endpoint-summary")
        );
        assert_eq!(
            text("node_detail_cluster_anchor_id", 0).as_deref(),
            Some("sr:b")
        );
        assert_eq!(text("node_detail_cluster_panel_side", 0), None);
        assert_eq!(flag("node_detail_cluster_expanded", 0), 2);
        assert_eq!(flag("node_detail_topology_unplaced", 0), 1);
        assert_eq!(number("node_detail_cluster_member_count", 0), 12.0);
        assert_eq!(number("node_detail_geo_lat", 0), 1.5);
        assert!(number("node_detail_geo_lon", 0).is_nan());
        // Invalid JSON decodes to {} on the client; every column says "absent".
        assert_eq!(text("node_detail_id", 1), None);
        assert_eq!(flag("node_detail_cluster_expanded", 1), 0);

        assert_eq!(text("edge_detail_source_id", 2).as_deref(), Some("sr:a"));
        assert_eq!(number("edge_detail_source_if_index", 2), 7.0);
        assert!(number("edge_detail_target_if_index", 2).is_nan());
        assert_eq!(flag("edge_has_metadata", 2), 1);
        assert_eq!(flag("edge_has_sparkline", 2), 1);
        assert_eq!(
            text("edge_metadata_relation_type", 2).as_deref(),
            Some("CONNECTS_TO")
        );
        assert_eq!(flag("edge_metadata_connectivity_forest_bridge", 2), 1);
        assert_eq!(text("edge_detail_source_id", 0), None);

        let irregular: &UInt8Array = column(&batch, "details_irregular");
        assert_eq!(
            (irregular.value(0), irregular.value(1), irregular.value(2)),
            (0, 0, 0)
        );
    }

    #[test]
    fn a_value_the_column_cannot_carry_marks_the_row_irregular() {
        let nodes = vec![
            node(r#"{"cluster_expanded":"true"}"#),
            node(r#"{"cluster_member_count":"12"}"#),
            node(r#"{"cluster_kind":"endpoint-member"}"#),
        ];
        let edges = vec![
            (0u32, 1u32, 0u32, 0u64, 0u64, String::new(), 1u8),
            (1, 2, 0, 0, 0, String::new(), 1),
        ];
        let edge_details = vec![
            r#"{"metadata":{"relation-type":"CONNECTS_TO"}}"#.to_string(),
            r#"{"metadata":"physical"}"#.to_string(),
        ];

        let batch = encode(nodes, edges, edge_details);

        let irregular: &UInt8Array = column(&batch, "details_irregular");
        let values: Vec<u8> = (0..batch.num_rows())
            .map(|row| irregular.value(row))
            .collect();
        assert_eq!(values, vec![1, 1, 0, 1, 1]);
    }
}
