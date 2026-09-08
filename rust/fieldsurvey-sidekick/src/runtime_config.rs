use crate::config::SidekickConfig;
use serde::{Deserialize, Serialize};
use std::path::PathBuf;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct SidekickRuntimeConfig {
    #[serde(default = "default_sidekick_id")]
    pub sidekick_id: String,
    #[serde(default)]
    pub radio_plans: Vec<RadioPlanConfig>,
    #[serde(default)]
    pub wifi_uplink: Option<WifiUplinkConfig>,
    #[serde(default)]
    pub paired_devices: Vec<PairedDeviceConfig>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct RadioPlanConfig {
    pub interface_name: String,
    #[serde(default)]
    pub frequencies_mhz: Vec<u32>,
    #[serde(default = "default_hop_interval_ms")]
    pub hop_interval_ms: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct WifiUplinkConfig {
    pub interface_name: String,
    pub ssid: String,
    #[serde(default)]
    pub country_code: Option<String>,
    #[serde(default)]
    pub psk_configured: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct PairedDeviceConfig {
    pub device_id: String,
    #[serde(default)]
    pub device_name: Option<String>,
    pub token_hash: String,
    pub paired_at_unix_secs: u64,
}

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
pub struct PairedDeviceSummary {
    pub device_id: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub device_name: Option<String>,
    pub paired_at_unix_secs: u64,
}

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
pub struct SidekickRuntimeConfigResponse {
    pub sidekick_id: String,
    pub radio_plans: Vec<RadioPlanConfig>,
    pub wifi_uplink: Option<WifiUplinkConfig>,
    pub paired_devices: Vec<PairedDeviceSummary>,
}

#[derive(Debug, Clone, Deserialize, PartialEq, Eq)]
pub struct RuntimeConfigUpdateRequest {
    pub sidekick_id: Option<String>,
    pub radio_plans: Option<Vec<RadioPlanConfig>>,
    pub wifi_uplink: Option<WifiUplinkConfig>,
}

impl Default for SidekickRuntimeConfig {
    fn default() -> Self {
        Self {
            sidekick_id: default_sidekick_id(),
            radio_plans: Vec::new(),
            wifi_uplink: None,
            paired_devices: Vec::new(),
        }
    }
}

impl SidekickRuntimeConfig {
    pub fn response(&self) -> SidekickRuntimeConfigResponse {
        SidekickRuntimeConfigResponse {
            sidekick_id: self.sidekick_id.clone(),
            radio_plans: self.radio_plans.clone(),
            wifi_uplink: self.wifi_uplink.clone(),
            paired_devices: self
                .paired_devices
                .iter()
                .map(|device| PairedDeviceSummary {
                    device_id: device.device_id.clone(),
                    device_name: device.device_name.clone(),
                    paired_at_unix_secs: device.paired_at_unix_secs,
                })
                .collect(),
        }
    }

    pub fn apply_update(mut self, update: RuntimeConfigUpdateRequest) -> Result<Self, String> {
        if let Some(sidekick_id) = update.sidekick_id {
            let sidekick_id = sidekick_id.trim();
            if sidekick_id.is_empty() {
                return Err("sidekick_id cannot be blank".to_string());
            }
            self.sidekick_id = sidekick_id.to_string();
        }

        if let Some(radio_plans) = update.radio_plans {
            self.radio_plans = validate_radio_plans(radio_plans)?;
        }

        if let Some(wifi_uplink) = update.wifi_uplink {
            self.wifi_uplink = Some(validate_wifi_uplink_config(wifi_uplink)?);
        }

        Ok(self)
    }

    pub fn upsert_paired_device(
        mut self,
        device_id: String,
        device_name: Option<String>,
        token_hash: String,
        paired_at_unix_secs: u64,
    ) -> Result<Self, String> {
        let device_id = sanitize_device_id(device_id)?;
        let device_name = device_name.and_then(sanitize_device_name);
        if token_hash.trim().is_empty() {
            return Err("token_hash cannot be blank".to_string());
        }

        self.paired_devices
            .retain(|device| device.device_id != device_id);
        self.paired_devices.push(PairedDeviceConfig {
            device_id,
            device_name,
            token_hash,
            paired_at_unix_secs,
        });
        self.paired_devices
            .sort_by(|left, right| left.device_id.cmp(&right.device_id));

        Ok(self)
    }
}

pub async fn load_runtime_config(config: &SidekickConfig) -> Result<SidekickRuntimeConfig, String> {
    let path = runtime_config_path(config);
    let bytes = match tokio::fs::read(&path).await {
        Ok(bytes) => bytes,
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => {
            return Ok(SidekickRuntimeConfig::default());
        }
        Err(err) => return Err(format!("failed to read {}: {err}", path.display())),
    };

    serde_json::from_slice(&bytes)
        .map_err(|err| format!("failed to parse {}: {err}", path.display()))
}

pub async fn save_runtime_config(
    config: &SidekickConfig,
    runtime_config: &SidekickRuntimeConfig,
) -> Result<(), String> {
    let path = runtime_config_path(config);
    if let Some(parent) = path.parent() {
        tokio::fs::create_dir_all(parent)
            .await
            .map_err(|err| format!("failed to create {}: {err}", parent.display()))?;
    }

    let payload = serde_json::to_vec_pretty(runtime_config)
        .map_err(|err| format!("failed to encode runtime config: {err}"))?;

    tokio::fs::write(&path, payload)
        .await
        .map_err(|err| format!("failed to write {}: {err}", path.display()))
}

pub fn runtime_config_path(config: &SidekickConfig) -> PathBuf {
    config.state_dir.join("runtime-config.json")
}

pub fn sanitize_country_code(country_code: Option<String>) -> Option<String> {
    country_code
        .map(|value| value.trim().to_ascii_uppercase())
        .filter(|value| value.len() == 2 && value.chars().all(|ch| ch.is_ascii_alphabetic()))
}

fn validate_radio_plans(radio_plans: Vec<RadioPlanConfig>) -> Result<Vec<RadioPlanConfig>, String> {
    radio_plans
        .into_iter()
        .map(|plan| {
            let interface_name = plan.interface_name.trim();
            if interface_name.is_empty() {
                return Err("radio plan interface_name cannot be blank".to_string());
            }

            Ok(RadioPlanConfig {
                interface_name: interface_name.to_string(),
                frequencies_mhz: plan.frequencies_mhz,
                hop_interval_ms: plan.hop_interval_ms.max(default_hop_interval_ms()),
            })
        })
        .collect()
}

fn validate_wifi_uplink_config(config: WifiUplinkConfig) -> Result<WifiUplinkConfig, String> {
    let interface_name = config.interface_name.trim();
    if interface_name.is_empty() {
        return Err("wifi uplink interface_name cannot be blank".to_string());
    }

    let ssid = config.ssid.trim();
    if ssid.is_empty() {
        return Err("wifi uplink ssid cannot be blank".to_string());
    }

    Ok(WifiUplinkConfig {
        interface_name: interface_name.to_string(),
        ssid: ssid.to_string(),
        country_code: sanitize_country_code(config.country_code),
        psk_configured: config.psk_configured,
    })
}

pub fn sanitize_device_id(device_id: String) -> Result<String, String> {
    let device_id = device_id.trim();
    if device_id.is_empty() {
        return Err("device_id cannot be blank".to_string());
    }

    if device_id.len() > 128 {
        return Err("device_id cannot be longer than 128 bytes".to_string());
    }

    if !device_id
        .chars()
        .all(|ch| ch.is_ascii_alphanumeric() || matches!(ch, '-' | '_' | '.' | ':'))
    {
        return Err(
            "device_id may only contain ASCII letters, digits, dash, underscore, dot, or colon"
                .to_string(),
        );
    }

    Ok(device_id.to_string())
}

fn sanitize_device_name(device_name: String) -> Option<String> {
    let device_name = device_name.trim();
    if device_name.is_empty() {
        None
    } else {
        Some(device_name.chars().take(80).collect())
    }
}

fn default_sidekick_id() -> String {
    "fieldsurvey-sidekick".to_string()
}

fn default_hop_interval_ms() -> u64 {
    250
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::TempDir;

    #[test]
    fn applies_runtime_config_update_with_trimmed_values() {
        let config = SidekickRuntimeConfig::default()
            .apply_update(RuntimeConfigUpdateRequest {
                sidekick_id: Some(" sidekick-lab ".to_string()),
                radio_plans: Some(vec![RadioPlanConfig {
                    interface_name: " wlan2 ".to_string(),
                    frequencies_mhz: vec![5_180, 5_200],
                    hop_interval_ms: 100,
                }]),
                wifi_uplink: Some(WifiUplinkConfig {
                    interface_name: " wlan0 ".to_string(),
                    ssid: " LabNet ".to_string(),
                    country_code: Some("us".to_string()),
                    psk_configured: true,
                }),
            })
            .unwrap();

        assert_eq!(config.sidekick_id, "sidekick-lab");
        assert_eq!(config.radio_plans[0].interface_name, "wlan2");
        assert_eq!(config.radio_plans[0].hop_interval_ms, 250);
        assert_eq!(
            config.wifi_uplink.as_ref().unwrap().country_code.as_deref(),
            Some("US")
        );
    }

    #[tokio::test]
    async fn saves_and_loads_runtime_config() {
        let temp = TempDir::new().unwrap();
        let sidekick_config = SidekickConfig {
            state_dir: temp.path().to_path_buf(),
            ..SidekickConfig::default()
        };
        let runtime_config = SidekickRuntimeConfig {
            sidekick_id: "sidekick-test".to_string(),
            radio_plans: Vec::new(),
            wifi_uplink: None,
            paired_devices: Vec::new(),
        };

        save_runtime_config(&sidekick_config, &runtime_config)
            .await
            .unwrap();
        let loaded = load_runtime_config(&sidekick_config).await.unwrap();

        assert_eq!(loaded, runtime_config);
    }

    #[test]
    fn upserts_paired_device_and_redacts_runtime_response() {
        let config = SidekickRuntimeConfig::default()
            .upsert_paired_device(
                " iphone-1 ".to_string(),
                Some(" Survey Phone ".to_string()),
                "hash-1".to_string(),
                1_777_132_800,
            )
            .unwrap()
            .upsert_paired_device(
                "iphone-1".to_string(),
                Some("Renamed".to_string()),
                "hash-2".to_string(),
                1_777_132_900,
            )
            .unwrap();

        assert_eq!(config.paired_devices.len(), 1);
        assert_eq!(config.paired_devices[0].token_hash, "hash-2");

        let response = config.response();
        assert_eq!(
            response.paired_devices[0].device_name.as_deref(),
            Some("Renamed")
        );
        let encoded = serde_json::to_string(&response).unwrap();
        assert!(!encoded.contains("hash-2"));
        assert!(!encoded.contains("token_hash"));
    }

    #[test]
    fn rejects_invalid_device_ids() {
        assert!(sanitize_device_id("iphone:abc-123".to_string()).is_ok());
        assert!(sanitize_device_id("bad device".to_string()).is_err());
        assert!(sanitize_device_id("".to_string()).is_err());
    }
}
