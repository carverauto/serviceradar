//! Arrow record structures for processing mobile diagnostic device surveys.

use rustler::NifMap;

/// Represents an individual wireless spectrum diagnostic sample captured at a coordinate.
///
/// This structure matches the tabular `RecordBatch` streams published via Apache Arrow.
/// It aggregates physical Wi-Fi signals alongside Cartesian layout geometry.
#[derive(Debug, NifMap)]
pub(crate) struct SurveySampleRow {
    /// The absolute Unix epoch timestamp of the recorded physical sample.
    pub(crate) timestamp: f64,
    /// An opaque string or identifier of the specific device capturing this survey point.
    pub(crate) scanner_device_id: String,
    /// The physical MAC address corresponding to the target wireless beacon.
    pub(crate) bssid: String,
    /// The human-readable wireless network name identifier (802.11 SSID).
    pub(crate) ssid: String,
    /// The received signal strength indicator (power level at the scanner).
    pub(crate) rssi: f64,
    /// The operating RF channel frequency in megahertz (e.g. `2412` or `5180`).
    pub(crate) frequency: i64,
    /// A human-readable identifier of the wireless security suite.
    pub(crate) security_type: String,
    /// A boolean indicating if encryption/privacy constraints apply to this SSID.
    pub(crate) is_secure: bool,
    /// An arbitrary dimension floating-point dense embedding tracking generalized RF features.
    pub(crate) rf_vector: Vec<f32>,
    /// A specific density vector modeling close-range Bluetooth Low-Energy observations.
    pub(crate) ble_vector: Vec<f32>,
    /// The physical Cartesian X-coordinate on the corresponding floor plan.
    pub(crate) x: f32,
    /// The physical Cartesian Y-coordinate on the corresponding floor plan.
    pub(crate) y: f32,
    /// The physical Cartesian elevation (height) or relative floor level plane Z-coordinate.
    pub(crate) z: f32,
    /// The raw GPS latitude value recorded if the survey was outdoors.
    pub(crate) latitude: f64,
    /// The raw GPS longitude value recorded if the survey was outdoors.
    pub(crate) longitude: f64,
    /// The variance or statistical confidence bound for the specific geometry coordinates.
    pub(crate) uncertainty: f32,
}
