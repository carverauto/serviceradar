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
use crate::types::fieldsurvey::{
    FieldSurveyPoseSampleRow, FieldSurveyRfObservationRow, FieldSurveySpectrumObservationRow,
};
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
    edges: Vec<(u16, u16, u32, u64, u64, String, u8)>,
    edge_meta: Vec<(String, String, String)>,
    edge_directional: Vec<(u32, u32, u64, u64)>,
    edge_details: Vec<String>,
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
        let details = edge_details
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
        edge_details_json.push(Some(details));
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
    let mut reader = match arrow_ipc::reader::StreamReader::try_new(cursor, None) {
        Ok(reader) => reader,
        Err(_) => return decode_file(data),
    };

    let mut rows = Vec::new();
    while let Some(batch_result) = reader.next() {
        let batch = batch_result.map_err(|_| rustler::Error::BadArg)?;
        extract_stream_batch(&batch, &mut rows)?;
    }

    Ok(rows)
}

fn extract_fieldsurvey_rf_rows_from_file(
    data: &[u8],
) -> Result<Vec<FieldSurveyRfObservationRow>, rustler::Error> {
    let cursor = std::io::Cursor::new(data);
    let mut reader =
        arrow_ipc::reader::FileReader::try_new(cursor, None).map_err(|_| rustler::Error::BadArg)?;

    let mut rows = Vec::new();
    while let Some(batch_result) = reader.next() {
        let batch = batch_result.map_err(|_| rustler::Error::BadArg)?;
        extract_fieldsurvey_rf_rows(&batch, &mut rows)?;
    }

    Ok(rows)
}

fn extract_fieldsurvey_pose_rows_from_file(
    data: &[u8],
) -> Result<Vec<FieldSurveyPoseSampleRow>, rustler::Error> {
    let cursor = std::io::Cursor::new(data);
    let mut reader =
        arrow_ipc::reader::FileReader::try_new(cursor, None).map_err(|_| rustler::Error::BadArg)?;

    let mut rows = Vec::new();
    while let Some(batch_result) = reader.next() {
        let batch = batch_result.map_err(|_| rustler::Error::BadArg)?;
        extract_fieldsurvey_pose_rows(&batch, &mut rows)?;
    }

    Ok(rows)
}

fn extract_fieldsurvey_spectrum_rows_from_file(
    data: &[u8],
) -> Result<Vec<FieldSurveySpectrumObservationRow>, rustler::Error> {
    let cursor = std::io::Cursor::new(data);
    let mut reader =
        arrow_ipc::reader::FileReader::try_new(cursor, None).map_err(|_| rustler::Error::BadArg)?;

    let mut rows = Vec::new();
    while let Some(batch_result) = reader.next() {
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
    let frequency_mhzes = required_u32_column(batch, "frequency_mhz")?;
    let channels = optional_u16_column(batch, "channel")?;
    let channel_width_mhzes = optional_u16_column(batch, "channel_width_mhz")?;
    let captured_at_unix_nanoses = required_i64_column(batch, "captured_at_unix_nanos")?;
    let captured_at_monotonic_nanoses = optional_u64_column(batch, "captured_at_monotonic_nanos")?;
    let parser_confidences = required_f32_column(batch, "parser_confidence")?;

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
            channel: optional_u16_value(channels, i),
            channel_width_mhz: optional_u16_value(channel_width_mhzes, i),
            captured_at_unix_nanos: captured_at_unix_nanoses.value(i),
            captured_at_monotonic_nanos: optional_u64_value(captured_at_monotonic_nanoses, i),
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
    let sweep_ids = required_u64_column(batch, "sweep_id")?;
    let started_at_unix_nanoses = required_i64_column(batch, "started_at_unix_nanos")?;
    let captured_at_unix_nanoses = required_i64_column(batch, "captured_at_unix_nanos")?;
    let start_frequency_hzes = required_u64_column(batch, "start_frequency_hz")?;
    let stop_frequency_hzes = required_u64_column(batch, "stop_frequency_hz")?;
    let bin_width_hzes = required_f32_column(batch, "bin_width_hz")?;
    let sample_counts = required_u32_column(batch, "sample_count")?;
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
    let captured_at_monotonic_nanoses = optional_u64_column(batch, "captured_at_monotonic_nanos")?;
    let xs = required_f32_column(batch, "x")?;
    let ys = required_f32_column(batch, "y")?;
    let zs = required_f32_column(batch, "z")?;
    let qxs = required_f32_column(batch, "qx")?;
    let qys = required_f32_column(batch, "qy")?;
    let qzs = required_f32_column(batch, "qz")?;
    let qws = required_f32_column(batch, "qw")?;
    let latitudes = optional_f64_column(batch, "latitude")?;
    let longitudes = optional_f64_column(batch, "longitude")?;
    let altitudes = optional_f64_column(batch, "altitude")?;
    let accuracy_ms = optional_f32_column(batch, "accuracy_m")?;
    let tracking_qualities = optional_string_column(batch, "tracking_quality")?;

    for i in 0..batch.num_rows() {
        rows.push(FieldSurveyPoseSampleRow {
            scanner_device_id: string_value(scanner_device_ids, i)?,
            captured_at_unix_nanos: captured_at_unix_nanoses.value(i),
            captured_at_monotonic_nanos: optional_u64_value(captured_at_monotonic_nanoses, i),
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
            accuracy_m: optional_f32_value(accuracy_ms, i),
            tracking_quality: optional_string_value(tracking_qualities, i),
        });
    }

    Ok(())
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

fn optional_u16_column<'a>(
    batch: &'a RecordBatch,
    column_name: &str,
) -> Result<Option<&'a arrow_array::PrimitiveArray<arrow_array::types::UInt16Type>>, rustler::Error>
{
    optional_primitive_column::<arrow_array::types::UInt16Type>(batch, column_name)
}

fn optional_u64_column<'a>(
    batch: &'a RecordBatch,
    column_name: &str,
) -> Result<Option<&'a arrow_array::PrimitiveArray<arrow_array::types::UInt64Type>>, rustler::Error>
{
    optional_primitive_column::<arrow_array::types::UInt64Type>(batch, column_name)
}

fn required_i64_column<'a>(
    batch: &'a RecordBatch,
    column_name: &str,
) -> Result<&'a arrow_array::PrimitiveArray<arrow_array::types::Int64Type>, rustler::Error> {
    required_primitive_column::<arrow_array::types::Int64Type>(batch, column_name)
}

fn required_u32_column<'a>(
    batch: &'a RecordBatch,
    column_name: &str,
) -> Result<&'a arrow_array::PrimitiveArray<arrow_array::types::UInt32Type>, rustler::Error> {
    required_primitive_column::<arrow_array::types::UInt32Type>(batch, column_name)
}

fn required_u64_column<'a>(
    batch: &'a RecordBatch,
    column_name: &str,
) -> Result<&'a arrow_array::PrimitiveArray<arrow_array::types::UInt64Type>, rustler::Error> {
    required_primitive_column::<arrow_array::types::UInt64Type>(batch, column_name)
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

fn optional_f32_column<'a>(
    batch: &'a RecordBatch,
    column_name: &str,
) -> Result<Option<&'a arrow_array::PrimitiveArray<arrow_array::types::Float32Type>>, rustler::Error>
{
    optional_primitive_column::<arrow_array::types::Float32Type>(batch, column_name)
}

fn optional_f64_column<'a>(
    batch: &'a RecordBatch,
    column_name: &str,
) -> Result<Option<&'a arrow_array::PrimitiveArray<arrow_array::types::Float64Type>>, rustler::Error>
{
    optional_primitive_column::<arrow_array::types::Float64Type>(batch, column_name)
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

fn optional_u16_value(
    values: Option<&arrow_array::PrimitiveArray<arrow_array::types::UInt16Type>>,
    index: usize,
) -> Option<u16> {
    values.and_then(|array| {
        if array.is_null(index) {
            None
        } else {
            Some(array.value(index))
        }
    })
}

fn optional_u64_value(
    values: Option<&arrow_array::PrimitiveArray<arrow_array::types::UInt64Type>>,
    index: usize,
) -> Option<u64> {
    values.and_then(|array| {
        if array.is_null(index) {
            None
        } else {
            Some(array.value(index))
        }
    })
}

fn optional_f32_value(
    values: Option<&arrow_array::PrimitiveArray<arrow_array::types::Float32Type>>,
    index: usize,
) -> Option<f32> {
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
