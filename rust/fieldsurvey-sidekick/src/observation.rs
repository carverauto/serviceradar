use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct SidekickObservation {
    pub sidekick_id: String,
    pub radio_id: String,
    pub interface_name: String,
    pub bssid: String,
    pub ssid: Option<String>,
    pub hidden_ssid: bool,
    pub frame_type: ManagementFrameType,
    pub rssi_dbm: Option<i16>,
    pub noise_floor_dbm: Option<i16>,
    pub snr_db: Option<i16>,
    pub frequency_mhz: u32,
    pub channel: Option<u16>,
    pub channel_width_mhz: Option<u16>,
    pub captured_at_unix_nanos: i64,
    pub captured_at_monotonic_nanos: Option<u64>,
    pub parser_confidence: f32,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum ManagementFrameType {
    Beacon,
    ProbeResponse,
    ProbeRequest,
    Other,
}

impl ManagementFrameType {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Beacon => "beacon",
            Self::ProbeResponse => "probe_response",
            Self::ProbeRequest => "probe_request",
            Self::Other => "other",
        }
    }
}
