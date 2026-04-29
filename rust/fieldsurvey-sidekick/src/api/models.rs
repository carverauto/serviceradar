use crate::adaptive_scan::AdaptiveChannelHopRequest;
use crate::adaptive_scan::AdaptiveScanSnapshot;
use crate::capture_control::ActiveCaptureStream;
use crate::live_capture::CaptureRequest;
use crate::radio::ChannelHopRequest;
use crate::radio::{MonitorPrepareExecution, MonitorPreparePlan, RadioInterface};
use crate::wifi::{WifiUplinkExecution, WifiUplinkPlan};
use serde::{Deserialize, Serialize};

#[derive(Debug, Serialize, PartialEq, Eq)]
pub struct HealthResponse {
    pub ok: bool,
}

#[derive(Debug, Serialize)]
pub struct StatusResponse {
    pub service: &'static str,
    pub version: &'static str,
    pub capture_running: bool,
    pub active_streams: Vec<ActiveCaptureStream>,
    pub iw_available: bool,
    pub radios: Vec<RadioInterface>,
    pub adaptive_scan: AdaptiveScanSnapshot,
}

#[derive(Debug, Serialize, PartialEq, Eq)]
pub struct MonitorPrepareResponse {
    pub plan: MonitorPreparePlan,
}

#[derive(Debug, Serialize, PartialEq, Eq)]
pub struct MonitorPrepareExecutionResponse {
    pub result: MonitorPrepareExecution,
}

#[derive(Debug, Serialize, PartialEq, Eq)]
pub struct WifiUplinkPlanResponse {
    pub plan: WifiUplinkPlan,
}

#[derive(Debug, Serialize, PartialEq, Eq)]
pub struct WifiUplinkExecutionResponse {
    pub result: WifiUplinkExecution,
}

#[derive(Debug, Serialize, PartialEq, Eq)]
pub struct CaptureStopResponse {
    pub stopped: bool,
    pub generation: u64,
}

#[derive(Debug, Deserialize, PartialEq, Eq)]
pub struct PairingClaimRequest {
    pub device_id: String,
    #[serde(default)]
    pub device_name: Option<String>,
}

#[derive(Debug, Serialize, PartialEq, Eq)]
pub struct PairingClaimResponse {
    pub sidekick_id: String,
    pub device_id: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub device_name: Option<String>,
    pub token: String,
    pub paired_at_unix_secs: u64,
}

#[derive(Debug, Serialize, PartialEq, Eq)]
pub struct ErrorResponse {
    pub error: String,
}

#[derive(Debug, Deserialize, PartialEq, Eq)]
pub struct ObservationStreamQuery {
    pub interface_name: String,
    #[serde(default = "default_sidekick_id")]
    pub sidekick_id: String,
    #[serde(default = "default_radio_id")]
    pub radio_id: String,
    pub frequencies_mhz: Option<String>,
    #[serde(default = "default_hop_interval_ms")]
    pub hop_interval_ms: u64,
    #[serde(default = "default_scan_mode")]
    pub scan_mode: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ObservationStreamRequest {
    pub capture: CaptureRequest,
    pub channel_hop: Option<ChannelHopMode>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ChannelHopMode {
    Fixed(ChannelHopRequest),
    Adaptive(AdaptiveChannelHopRequest),
}

#[derive(Debug, Deserialize, PartialEq, Eq)]
pub struct SpectrumStreamQuery {
    #[serde(default = "default_sidekick_id")]
    pub sidekick_id: String,
    #[serde(default = "default_sdr_id")]
    pub sdr_id: String,
    pub serial_number: Option<String>,
    #[serde(default = "default_spectrum_frequency_min_mhz")]
    pub frequency_min_mhz: u32,
    #[serde(default = "default_spectrum_frequency_max_mhz")]
    pub frequency_max_mhz: u32,
    #[serde(default = "default_spectrum_bin_width_hz")]
    pub bin_width_hz: u32,
    #[serde(default = "default_spectrum_lna_gain_db")]
    pub lna_gain_db: u8,
    #[serde(default = "default_spectrum_vga_gain_db")]
    pub vga_gain_db: u8,
    #[serde(default = "default_spectrum_sweep_count")]
    pub sweep_count: u32,
}

fn default_sidekick_id() -> String {
    "fieldsurvey-sidekick".to_string()
}

fn default_radio_id() -> String {
    "radio-0".to_string()
}

fn default_hop_interval_ms() -> u64 {
    250
}

fn default_scan_mode() -> String {
    "fixed".to_string()
}

fn default_sdr_id() -> String {
    "hackrf-0".to_string()
}

fn default_spectrum_frequency_min_mhz() -> u32 {
    2400
}

fn default_spectrum_frequency_max_mhz() -> u32 {
    2500
}

fn default_spectrum_bin_width_hz() -> u32 {
    1_000_000
}

fn default_spectrum_lna_gain_db() -> u8 {
    8
}

fn default_spectrum_vga_gain_db() -> u8 {
    8
}

fn default_spectrum_sweep_count() -> u32 {
    1_000_000
}
