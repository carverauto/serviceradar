use rustler::NifMap;

#[derive(Debug, NifMap)]
pub(crate) struct FieldSurveyRfObservationRow {
    pub(crate) sidekick_id: String,
    pub(crate) radio_id: String,
    pub(crate) interface_name: String,
    pub(crate) bssid: String,
    pub(crate) ssid: Option<String>,
    pub(crate) hidden_ssid: bool,
    pub(crate) frame_type: String,
    pub(crate) rssi_dbm: Option<i16>,
    pub(crate) noise_floor_dbm: Option<i16>,
    pub(crate) snr_db: Option<i16>,
    pub(crate) frequency_mhz: i32,
    pub(crate) channel: Option<i32>,
    pub(crate) channel_width_mhz: Option<i32>,
    pub(crate) captured_at_unix_nanos: i64,
    pub(crate) captured_at_monotonic_nanos: Option<i64>,
    pub(crate) parser_confidence: f64,
}

#[derive(Debug, NifMap)]
pub(crate) struct FieldSurveyPoseSampleRow {
    pub(crate) scanner_device_id: String,
    pub(crate) captured_at_unix_nanos: i64,
    pub(crate) captured_at_monotonic_nanos: Option<i64>,
    pub(crate) x: f64,
    pub(crate) y: f64,
    pub(crate) z: f64,
    pub(crate) qx: f64,
    pub(crate) qy: f64,
    pub(crate) qz: f64,
    pub(crate) qw: f64,
    pub(crate) latitude: Option<f64>,
    pub(crate) longitude: Option<f64>,
    pub(crate) altitude: Option<f64>,
    pub(crate) accuracy_m: Option<f64>,
    pub(crate) tracking_quality: Option<String>,
}

#[derive(Debug, NifMap)]
pub(crate) struct FieldSurveySpectrumObservationRow {
    pub(crate) sidekick_id: String,
    pub(crate) sdr_id: String,
    pub(crate) device_kind: String,
    pub(crate) serial_number: Option<String>,
    pub(crate) sweep_id: i64,
    pub(crate) started_at_unix_nanos: i64,
    pub(crate) captured_at_unix_nanos: i64,
    pub(crate) start_frequency_hz: i64,
    pub(crate) stop_frequency_hz: i64,
    pub(crate) bin_width_hz: f64,
    pub(crate) sample_count: i32,
    pub(crate) power_bins_dbm: Vec<f32>,
}
