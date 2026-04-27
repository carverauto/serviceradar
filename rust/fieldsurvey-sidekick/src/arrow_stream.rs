use crate::observation::SidekickObservation;
use crate::spectrum::SpectrumSweep;
use arrow_array::{
    ArrayRef, BooleanArray, Float64Array, Int16Array, Int32Array, Int64Array, RecordBatch,
    StringArray, TimestampMicrosecondArray,
    builder::{Float64Builder, ListBuilder},
};
use arrow_ipc::writer::StreamWriter;
use arrow_schema::{DataType, Field, Schema, TimeUnit};
use std::sync::Arc;

pub fn rf_observation_schema() -> Arc<Schema> {
    Arc::new(Schema::new(vec![
        Field::new("sidekick_id", DataType::Utf8, false),
        Field::new("radio_id", DataType::Utf8, false),
        Field::new("interface_name", DataType::Utf8, false),
        Field::new("bssid", DataType::Utf8, false),
        Field::new("ssid", DataType::Utf8, true),
        Field::new("hidden_ssid", DataType::Boolean, false),
        Field::new("frame_type", DataType::Utf8, false),
        Field::new("rssi_dbm", DataType::Int16, true),
        Field::new("noise_floor_dbm", DataType::Int16, true),
        Field::new("snr_db", DataType::Int16, true),
        Field::new("frequency_mhz", DataType::Int32, false),
        Field::new("channel", DataType::Int32, true),
        Field::new("channel_width_mhz", DataType::Int32, true),
        Field::new(
            "captured_at",
            DataType::Timestamp(TimeUnit::Microsecond, Some("UTC".into())),
            false,
        ),
        Field::new("captured_at_unix_nanos", DataType::Int64, false),
        Field::new("captured_at_monotonic_nanos", DataType::Int64, true),
        Field::new("parser_confidence", DataType::Float64, false),
    ]))
}

pub fn spectrum_observation_schema() -> Arc<Schema> {
    Arc::new(Schema::new(vec![
        Field::new("sidekick_id", DataType::Utf8, false),
        Field::new("sdr_id", DataType::Utf8, false),
        Field::new("device_kind", DataType::Utf8, false),
        Field::new("serial_number", DataType::Utf8, true),
        Field::new("sweep_id", DataType::Int64, false),
        Field::new(
            "started_at",
            DataType::Timestamp(TimeUnit::Microsecond, Some("UTC".into())),
            false,
        ),
        Field::new("started_at_unix_nanos", DataType::Int64, false),
        Field::new(
            "captured_at",
            DataType::Timestamp(TimeUnit::Microsecond, Some("UTC".into())),
            false,
        ),
        Field::new("captured_at_unix_nanos", DataType::Int64, false),
        Field::new("start_frequency_hz", DataType::Int64, false),
        Field::new("stop_frequency_hz", DataType::Int64, false),
        Field::new("bin_width_hz", DataType::Float64, false),
        Field::new("sample_count", DataType::Int32, false),
        Field::new(
            "power_bins_dbm",
            DataType::List(Arc::new(Field::new("item", DataType::Float64, true))),
            false,
        ),
    ]))
}

pub fn encode_observations_ipc(observations: &[SidekickObservation]) -> Result<Vec<u8>, String> {
    let schema = rf_observation_schema();
    let batch = observations_to_record_batch(schema.clone(), observations)?;
    let mut buffer = Vec::new();

    {
        let mut writer =
            StreamWriter::try_new(&mut buffer, &schema).map_err(|error| error.to_string())?;
        writer.write(&batch).map_err(|error| error.to_string())?;
        writer.finish().map_err(|error| error.to_string())?;
    }

    Ok(buffer)
}

pub fn encode_spectrum_sweeps_ipc(sweeps: &[SpectrumSweep]) -> Result<Vec<u8>, String> {
    let schema = spectrum_observation_schema();
    let batch = spectrum_sweeps_to_record_batch(schema.clone(), sweeps)?;
    let mut buffer = Vec::new();

    {
        let mut writer =
            StreamWriter::try_new(&mut buffer, &schema).map_err(|error| error.to_string())?;
        writer.write(&batch).map_err(|error| error.to_string())?;
        writer.finish().map_err(|error| error.to_string())?;
    }

    Ok(buffer)
}

fn observations_to_record_batch(
    schema: Arc<Schema>,
    observations: &[SidekickObservation],
) -> Result<RecordBatch, String> {
    let columns: Vec<ArrayRef> = vec![
        Arc::new(StringArray::from(
            observations
                .iter()
                .map(|observation| observation.sidekick_id.as_str())
                .collect::<Vec<_>>(),
        )),
        Arc::new(StringArray::from(
            observations
                .iter()
                .map(|observation| observation.radio_id.as_str())
                .collect::<Vec<_>>(),
        )),
        Arc::new(StringArray::from(
            observations
                .iter()
                .map(|observation| observation.interface_name.as_str())
                .collect::<Vec<_>>(),
        )),
        Arc::new(StringArray::from(
            observations
                .iter()
                .map(|observation| observation.bssid.as_str())
                .collect::<Vec<_>>(),
        )),
        Arc::new(StringArray::from(
            observations
                .iter()
                .map(|observation| observation.ssid.as_deref())
                .collect::<Vec<_>>(),
        )),
        Arc::new(BooleanArray::from(
            observations
                .iter()
                .map(|observation| observation.hidden_ssid)
                .collect::<Vec<_>>(),
        )),
        Arc::new(StringArray::from(
            observations
                .iter()
                .map(|observation| observation.frame_type.as_str())
                .collect::<Vec<_>>(),
        )),
        Arc::new(Int16Array::from(
            observations
                .iter()
                .map(|observation| observation.rssi_dbm)
                .collect::<Vec<_>>(),
        )),
        Arc::new(Int16Array::from(
            observations
                .iter()
                .map(|observation| observation.noise_floor_dbm)
                .collect::<Vec<_>>(),
        )),
        Arc::new(Int16Array::from(
            observations
                .iter()
                .map(|observation| observation.snr_db)
                .collect::<Vec<_>>(),
        )),
        Arc::new(Int32Array::from(
            observations
                .iter()
                .map(|observation| observation.frequency_mhz as i32)
                .collect::<Vec<_>>(),
        )),
        Arc::new(Int32Array::from(
            observations
                .iter()
                .map(|observation| observation.channel.map(i32::from))
                .collect::<Vec<_>>(),
        )),
        Arc::new(Int32Array::from(
            observations
                .iter()
                .map(|observation| observation.channel_width_mhz.map(i32::from))
                .collect::<Vec<_>>(),
        )),
        Arc::new(
            TimestampMicrosecondArray::from(
                observations
                    .iter()
                    .map(|observation| unix_nanos_to_micros(observation.captured_at_unix_nanos))
                    .collect::<Vec<_>>(),
            )
            .with_timezone("UTC"),
        ),
        Arc::new(Int64Array::from(
            observations
                .iter()
                .map(|observation| observation.captured_at_unix_nanos)
                .collect::<Vec<_>>(),
        )),
        Arc::new(Int64Array::from(
            observations
                .iter()
                .map(|observation| {
                    observation
                        .captured_at_monotonic_nanos
                        .map(|value| value as i64)
                })
                .collect::<Vec<_>>(),
        )),
        Arc::new(Float64Array::from(
            observations
                .iter()
                .map(|observation| f64::from(observation.parser_confidence))
                .collect::<Vec<_>>(),
        )),
    ];

    RecordBatch::try_new(schema, columns).map_err(|error| error.to_string())
}

fn spectrum_sweeps_to_record_batch(
    schema: Arc<Schema>,
    sweeps: &[SpectrumSweep],
) -> Result<RecordBatch, String> {
    let mut power_bins_builder = ListBuilder::new(Float64Builder::new());
    for sweep in sweeps {
        for value in &sweep.power_bins_dbm {
            power_bins_builder.values().append_value(f64::from(*value));
        }
        power_bins_builder.append(true);
    }

    let columns: Vec<ArrayRef> = vec![
        Arc::new(StringArray::from(
            sweeps
                .iter()
                .map(|sweep| sweep.sidekick_id.as_str())
                .collect::<Vec<_>>(),
        )),
        Arc::new(StringArray::from(
            sweeps
                .iter()
                .map(|sweep| sweep.sdr_id.as_str())
                .collect::<Vec<_>>(),
        )),
        Arc::new(StringArray::from(
            sweeps
                .iter()
                .map(|sweep| sweep.device_kind.as_str())
                .collect::<Vec<_>>(),
        )),
        Arc::new(StringArray::from(
            sweeps
                .iter()
                .map(|sweep| sweep.serial_number.as_deref())
                .collect::<Vec<_>>(),
        )),
        Arc::new(Int64Array::from(
            sweeps
                .iter()
                .map(|sweep| sweep.sweep_id as i64)
                .collect::<Vec<_>>(),
        )),
        Arc::new(
            TimestampMicrosecondArray::from(
                sweeps
                    .iter()
                    .map(|sweep| unix_nanos_to_micros(sweep.started_at_unix_nanos))
                    .collect::<Vec<_>>(),
            )
            .with_timezone("UTC"),
        ),
        Arc::new(Int64Array::from(
            sweeps
                .iter()
                .map(|sweep| sweep.started_at_unix_nanos)
                .collect::<Vec<_>>(),
        )),
        Arc::new(
            TimestampMicrosecondArray::from(
                sweeps
                    .iter()
                    .map(|sweep| unix_nanos_to_micros(sweep.captured_at_unix_nanos))
                    .collect::<Vec<_>>(),
            )
            .with_timezone("UTC"),
        ),
        Arc::new(Int64Array::from(
            sweeps
                .iter()
                .map(|sweep| sweep.captured_at_unix_nanos)
                .collect::<Vec<_>>(),
        )),
        Arc::new(Int64Array::from(
            sweeps
                .iter()
                .map(|sweep| sweep.start_frequency_hz as i64)
                .collect::<Vec<_>>(),
        )),
        Arc::new(Int64Array::from(
            sweeps
                .iter()
                .map(|sweep| sweep.stop_frequency_hz as i64)
                .collect::<Vec<_>>(),
        )),
        Arc::new(Float64Array::from(
            sweeps
                .iter()
                .map(|sweep| f64::from(sweep.bin_width_hz))
                .collect::<Vec<_>>(),
        )),
        Arc::new(Int32Array::from(
            sweeps
                .iter()
                .map(|sweep| sweep.sample_count as i32)
                .collect::<Vec<_>>(),
        )),
        Arc::new(power_bins_builder.finish()),
    ];

    RecordBatch::try_new(schema, columns).map_err(|error| error.to_string())
}

fn unix_nanos_to_micros(unix_nanos: i64) -> i64 {
    unix_nanos / 1_000
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::observation::ManagementFrameType;
    use arrow_array::{Int64Array, StringArray, TimestampMicrosecondArray};
    use arrow_ipc::reader::StreamReader;
    use std::io::Cursor;

    #[test]
    fn encodes_observations_as_arrow_ipc_stream() {
        let observation = SidekickObservation {
            sidekick_id: "sidekick-1".to_string(),
            radio_id: "wlan2".to_string(),
            interface_name: "wlan2".to_string(),
            bssid: "00:11:22:33:44:55".to_string(),
            ssid: Some("fieldlab".to_string()),
            hidden_ssid: false,
            frame_type: ManagementFrameType::Beacon,
            rssi_dbm: Some(-64),
            noise_floor_dbm: Some(-97),
            snr_db: Some(33),
            frequency_mhz: 5_180,
            channel: Some(36),
            channel_width_mhz: None,
            captured_at_unix_nanos: 1_712_345_678_000_000_123,
            captured_at_monotonic_nanos: Some(9_876_543_210),
            parser_confidence: 0.9,
        };

        let payload = encode_observations_ipc(&[observation]).unwrap();
        let mut reader = StreamReader::try_new(Cursor::new(payload), None).unwrap();
        let batch = reader.next().unwrap().unwrap();

        assert_eq!(batch.num_rows(), 1);
        assert_eq!(batch.num_columns(), rf_observation_schema().fields().len());

        let ssid = batch
            .column_by_name("ssid")
            .unwrap()
            .as_any()
            .downcast_ref::<StringArray>()
            .unwrap();
        assert_eq!(ssid.value(0), "fieldlab");

        let unix_nanos = batch
            .column_by_name("captured_at_unix_nanos")
            .unwrap()
            .as_any()
            .downcast_ref::<Int64Array>()
            .unwrap();
        assert_eq!(unix_nanos.value(0), 1_712_345_678_000_000_123);

        let captured_at = batch
            .column_by_name("captured_at")
            .unwrap()
            .as_any()
            .downcast_ref::<TimestampMicrosecondArray>()
            .unwrap();
        assert_eq!(captured_at.value(0), 1_712_345_678_000_000);

        let monotonic_nanos = batch
            .column_by_name("captured_at_monotonic_nanos")
            .unwrap()
            .as_any()
            .downcast_ref::<Int64Array>()
            .unwrap();
        assert_eq!(monotonic_nanos.value(0), 9_876_543_210);
    }

    #[test]
    fn encodes_spectrum_sweeps_as_arrow_ipc_stream() {
        let sweep = SpectrumSweep {
            sidekick_id: "sidekick-1".to_string(),
            sdr_id: "hackrf-0".to_string(),
            device_kind: "hackrf".to_string(),
            serial_number: Some("abc".to_string()),
            sweep_id: 42,
            started_at_unix_nanos: 1_712_345_678_000_000_000,
            captured_at_unix_nanos: 1_712_345_678_000_000_123,
            start_frequency_hz: 2_400_000_000,
            stop_frequency_hz: 2_405_000_000,
            bin_width_hz: 1_000_000.0,
            sample_count: 20,
            power_bins_dbm: vec![-74.5, -70.25],
        };

        let payload = encode_spectrum_sweeps_ipc(&[sweep]).unwrap();
        let mut reader = StreamReader::try_new(Cursor::new(payload), None).unwrap();
        let batch = reader.next().unwrap().unwrap();

        assert_eq!(batch.num_rows(), 1);
        assert_eq!(
            batch.num_columns(),
            spectrum_observation_schema().fields().len()
        );

        let sdr_id = batch
            .column_by_name("sdr_id")
            .unwrap()
            .as_any()
            .downcast_ref::<StringArray>()
            .unwrap();
        assert_eq!(sdr_id.value(0), "hackrf-0");
    }
}
