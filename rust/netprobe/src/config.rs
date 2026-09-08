use std::collections::HashSet;

use crate::external_flow::default_external_flow_match_window_ms;

use serde::{Deserialize, Deserializer};
use thiserror::Error;

pub const FLOW_TABLE_ENTRIES_PER_INTERFACE: u32 = 65_536;
pub const DEFAULT_PROCESS_SNAPSHOT_INTERVAL_S: u64 = 0;
pub const DEFAULT_FLOW_ATTRIBUTION_RESEND_INTERVAL_S: u64 = 0;
pub const DEFAULT_EMIT_RAW_FLOW_ATTRIBUTION_EVENTS: bool = true;
pub const DEFAULT_FLOW_ATTRIBUTION_IPC_BATCH: bool = true;

#[derive(Debug, Clone, Deserialize)]
pub struct Config {
    #[serde(default = "default_enabled")]
    pub enabled: bool,
    #[serde(default, deserialize_with = "deserialize_capture_interfaces")]
    pub capture_interfaces: Vec<String>,
    #[serde(default)]
    pub flow_table_max_entries: u32,
    #[cfg_attr(not(target_os = "linux"), allow(dead_code))]
    #[serde(default = "default_process_snapshot_interval_s")]
    pub process_snapshot_interval_s: u64,
    #[cfg_attr(not(target_os = "linux"), allow(dead_code))]
    #[serde(default = "default_flow_attribution_resend_interval_s")]
    pub flow_attribution_resend_interval_s: u64,
    #[cfg_attr(not(target_os = "linux"), allow(dead_code))]
    #[serde(default = "default_emit_raw_flow_attribution_events")]
    pub emit_raw_flow_attribution_events: bool,
    #[cfg_attr(not(target_os = "linux"), allow(dead_code))]
    #[serde(default = "default_flow_attribution_ipc_batch")]
    pub flow_attribution_ipc_batch: bool,
    #[serde(default = "default_external_flow_match_window_ms")]
    pub external_flow_match_window_ms: u32,
    /// The address of the host netprobe runs on, stamped by the agent.
    ///
    /// Not derivable here: netprobe has no notion of "the" host address, and
    /// picking one off a capture interface would be a guess that disagrees with
    /// the identity the agent reports under. Empty means the payloads that need
    /// a subject -- DPI endpoint selection, the process snapshot -- cannot name
    /// one, and are not emitted rather than emitted against a guess.
    #[serde(default)]
    pub collector_ip: String,
}

#[derive(Debug, Error, PartialEq, Eq)]
pub enum AllowlistError {
    #[error("capture interface 'any' is not allowed")]
    AnyInterface,
    #[error("empty capture interface entries are not allowed")]
    EmptyInterface,
    #[error("wildcard capture interfaces are not allowed")]
    Wildcard,
    #[error("capture interface '{0}' is not allowlisted")]
    #[allow(dead_code)]
    NotAllowlisted(String),
}

impl Default for Config {
    fn default() -> Self {
        Self {
            enabled: true,
            capture_interfaces: Vec::new(),
            flow_table_max_entries: 0,
            process_snapshot_interval_s: DEFAULT_PROCESS_SNAPSHOT_INTERVAL_S,
            flow_attribution_resend_interval_s: DEFAULT_FLOW_ATTRIBUTION_RESEND_INTERVAL_S,
            emit_raw_flow_attribution_events: DEFAULT_EMIT_RAW_FLOW_ATTRIBUTION_EVENTS,
            flow_attribution_ipc_batch: DEFAULT_FLOW_ATTRIBUTION_IPC_BATCH,
            external_flow_match_window_ms: default_external_flow_match_window_ms(),
            collector_ip: String::new(),
        }
    }
}

impl Config {
    pub fn validate_capture_interfaces(&self) -> Result<(), AllowlistError> {
        validate_capture_interfaces(&self.capture_interfaces)
    }

    #[allow(dead_code)]
    pub fn validate_interface(&self, interface: &str) -> Result<(), AllowlistError> {
        validate_interface(&self.capture_interfaces, interface)
    }

    pub fn effective_flow_table_max_entries(&self) -> u32 {
        effective_flow_table_max_entries(self.flow_table_max_entries, self.capture_interfaces.len())
    }
}

pub fn effective_flow_table_max_entries(configured: u32, interface_count: usize) -> u32 {
    if configured > 0 {
        return configured;
    }

    let interface_slots = u32::try_from(interface_count.max(1)).unwrap_or(u32::MAX);
    FLOW_TABLE_ENTRIES_PER_INTERFACE.saturating_mul(interface_slots)
}

pub fn validate_capture_interfaces(interfaces: &[String]) -> Result<(), AllowlistError> {
    for interface in interfaces {
        if interface.trim().is_empty() {
            return Err(AllowlistError::EmptyInterface);
        }

        if interface == "any" {
            return Err(AllowlistError::AnyInterface);
        }

        if interface.contains('*') {
            return Err(AllowlistError::Wildcard);
        }
    }

    Ok(())
}

#[allow(dead_code)]
pub fn validate_interface(allowlist: &[String], interface: &str) -> Result<(), AllowlistError> {
    if interface.trim().is_empty() {
        return Err(AllowlistError::EmptyInterface);
    }

    if interface == "any" {
        return Err(AllowlistError::AnyInterface);
    }

    if interface.contains('*') {
        return Err(AllowlistError::Wildcard);
    }

    let allowed: HashSet<&str> = allowlist.iter().map(String::as_str).collect();
    if allowed.contains(interface) {
        Ok(())
    } else {
        Err(AllowlistError::NotAllowlisted(interface.to_string()))
    }
}

fn default_enabled() -> bool {
    true
}

fn default_process_snapshot_interval_s() -> u64 {
    DEFAULT_PROCESS_SNAPSHOT_INTERVAL_S
}

fn default_flow_attribution_resend_interval_s() -> u64 {
    DEFAULT_FLOW_ATTRIBUTION_RESEND_INTERVAL_S
}

fn default_emit_raw_flow_attribution_events() -> bool {
    DEFAULT_EMIT_RAW_FLOW_ATTRIBUTION_EVENTS
}

fn default_flow_attribution_ipc_batch() -> bool {
    DEFAULT_FLOW_ATTRIBUTION_IPC_BATCH
}

fn deserialize_capture_interfaces<'de, D>(deserializer: D) -> Result<Vec<String>, D::Error>
where
    D: Deserializer<'de>,
{
    Ok(Option::<Vec<String>>::deserialize(deserializer)?.unwrap_or_default())
}

#[cfg(test)]
mod tests {
    use super::{
        AllowlistError, Config, DEFAULT_EMIT_RAW_FLOW_ATTRIBUTION_EVENTS,
        DEFAULT_FLOW_ATTRIBUTION_IPC_BATCH, DEFAULT_FLOW_ATTRIBUTION_RESEND_INTERVAL_S,
        DEFAULT_PROCESS_SNAPSHOT_INTERVAL_S, FLOW_TABLE_ENTRIES_PER_INTERFACE,
        effective_flow_table_max_entries, validate_capture_interfaces, validate_interface,
    };

    #[test]
    fn rejects_any_interface() {
        let allowlist = vec!["eth0".to_string(), "lo".to_string()];

        assert_eq!(
            validate_interface(&allowlist, "any"),
            Err(AllowlistError::AnyInterface)
        );
    }

    #[test]
    fn rejects_wildcards() {
        let allowlist = vec!["eth0".to_string()];

        assert_eq!(
            validate_interface(&allowlist, "eth*"),
            Err(AllowlistError::Wildcard)
        );
    }

    #[test]
    fn rejects_empty_entries() {
        let allowlist = vec!["eth0".to_string(), " ".to_string()];

        assert_eq!(
            validate_capture_interfaces(&allowlist),
            Err(AllowlistError::EmptyInterface)
        );
    }

    #[test]
    fn rejects_not_allowlisted_interfaces() {
        let allowlist = vec!["eth0".to_string()];

        assert_eq!(
            validate_interface(&allowlist, "enp0s1"),
            Err(AllowlistError::NotAllowlisted("enp0s1".to_string()))
        );
    }

    #[test]
    fn accepts_allowlisted_interface() {
        let allowlist = vec!["eth0".to_string()];

        assert_eq!(validate_interface(&allowlist, "eth0"), Ok(()));
    }

    #[test]
    fn validates_empty_capture_allowlist() {
        assert_eq!(validate_capture_interfaces(&[]), Ok(()));
    }

    #[test]
    fn validates_capture_allowlist_entries() {
        let allowlist = vec!["eth0".to_string(), "enp0s1".to_string()];

        assert_eq!(validate_capture_interfaces(&allowlist), Ok(()));
    }

    #[test]
    fn rejects_any_in_capture_allowlist() {
        let allowlist = vec!["any".to_string()];

        assert_eq!(
            validate_capture_interfaces(&allowlist),
            Err(AllowlistError::AnyInterface)
        );
    }

    #[test]
    fn defaults_flow_table_capacity_to_one_interface_slot() {
        assert_eq!(
            effective_flow_table_max_entries(0, 0),
            FLOW_TABLE_ENTRIES_PER_INTERFACE
        );
    }

    #[test]
    fn sizes_default_flow_table_capacity_by_interface_count() {
        assert_eq!(
            effective_flow_table_max_entries(0, 3),
            FLOW_TABLE_ENTRIES_PER_INTERFACE * 3
        );
    }

    #[test]
    fn honors_configured_flow_table_capacity() {
        let config = Config {
            flow_table_max_entries: 250_000,
            ..Default::default()
        };

        assert_eq!(config.effective_flow_table_max_entries(), 250_000);
    }

    #[test]
    fn defaults_flow_attribution_resend_interval() {
        let config: Config = serde_json::from_str("{}").unwrap();

        assert_eq!(
            config.flow_attribution_resend_interval_s,
            DEFAULT_FLOW_ATTRIBUTION_RESEND_INTERVAL_S
        );
        assert_eq!(config.flow_attribution_resend_interval_s, 0);
    }

    #[test]
    fn disables_periodic_process_snapshot_by_default() {
        let config: Config = serde_json::from_str("{}").unwrap();

        assert_eq!(
            config.process_snapshot_interval_s,
            DEFAULT_PROCESS_SNAPSHOT_INTERVAL_S
        );
        assert_eq!(config.process_snapshot_interval_s, 0);
    }

    #[test]
    fn treats_null_capture_interfaces_as_default_empty() {
        let config: Config =
            serde_json::from_str(r#"{"enabled":true,"capture_interfaces":null}"#).unwrap();

        assert!(config.capture_interfaces.is_empty());
    }

    #[test]
    fn enables_raw_flow_attribution_stream_by_default() {
        let config: Config = serde_json::from_str("{}").unwrap();

        assert_eq!(
            config.emit_raw_flow_attribution_events,
            DEFAULT_EMIT_RAW_FLOW_ATTRIBUTION_EVENTS
        );
        assert!(config.emit_raw_flow_attribution_events);
    }

    #[test]
    fn enables_flow_attribution_ipc_batching_by_default() {
        let config: Config = serde_json::from_str("{}").unwrap();

        assert_eq!(
            config.flow_attribution_ipc_batch,
            DEFAULT_FLOW_ATTRIBUTION_IPC_BATCH
        );
        assert!(config.flow_attribution_ipc_batch);
    }

    #[test]
    fn allows_disabling_flow_attribution_ipc_batching() {
        let config: Config =
            serde_json::from_str(r#"{"flow_attribution_ipc_batch":false}"#).unwrap();

        assert!(!config.flow_attribution_ipc_batch);
    }
}
