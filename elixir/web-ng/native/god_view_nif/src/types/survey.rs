use rustler::NifMap;

#[derive(Debug, NifMap)]
pub struct SurveySampleRow {
    pub timestamp: f64,
    pub scanner_device_id: String,
    pub bssid: String,
    pub ssid: String,
    pub rssi: f64,
    pub frequency: i64,
    pub security_type: String,
    pub is_secure: bool,
    pub rf_vector: Vec<f32>,
    pub ble_vector: Vec<f32>,
    pub x: f32,
    pub y: f32,
    pub z: f32,
    pub latitude: f64,
    pub longitude: f64,
    pub uncertainty: f32,
}
