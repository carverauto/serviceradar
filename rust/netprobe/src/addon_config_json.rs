//! Parses the add-on config JSON the control plane delivers into the proto
//! config netprobe applies.
//!
//! `AddonService.Configure` receives `config_json` bytes and nothing else --
//! unlike the legacy `ApplyConfig` frame, which carries a `VisibilityAgentConfig`
//! the agent already merged over the base visibility config. So this parser has
//! to accept the WHOLE effective config, all ten properties of
//! `addons/netprobe/config.schema.json`, not a subset.
//!
//! That is not a stylistic preference. A parser missing `dpi` or
//! `device_bindings` would silently produce an empty value for each and, applied,
//! would wipe every device binding while reporting success.
//!
//! Deliberately NOT `crate::config::Config`: that struct is the BOOTSTRAP file's
//! shape and has no `default_sample_interval_ms`, `dpi` or `device_bindings` at
//! all. Reusing it here is exactly the mistake above.

use serde::Deserialize;

use crate::proto::netprobe::{DeviceBinding, DpiConfig, FingerprintConfig, VisibilityAgentConfig};

/// Every property of `addons/netprobe/config.schema.json`.
///
/// `serde(default)` throughout because proto3 has no presence for scalars and
/// the control plane omits defaults -- `{}` must parse to an all-default config
/// rather than an error.
///
/// Unknown fields are ACCEPTED, not rejected. A newer control plane adding a
/// property must not brick an older netprobe that has not learned it yet; the
/// cost of ignoring one is a setting that does not take effect, and the cost of
/// rejecting is a collector that will not configure at all.
#[derive(Debug, Clone, Default, Deserialize)]
pub struct AddonConfigJson {
    #[serde(default)]
    pub enabled: bool,
    #[serde(default)]
    pub capture_interfaces: Vec<String>,
    #[serde(default)]
    pub default_sample_interval_ms: u32,
    #[serde(default)]
    pub flow_table_max_entries: u32,
    #[serde(default)]
    pub process_snapshot_interval_s: u32,
    #[serde(default)]
    pub external_flow_match_window_ms: u32,
    #[serde(default)]
    pub flow_attribution_ipc_batch: bool,
    #[serde(default)]
    pub emit_raw_flow_attribution_events: bool,
    #[serde(default)]
    pub dpi: Option<DpiJson>,
    #[serde(default)]
    pub device_bindings: Vec<DeviceBindingJson>,
    /// Agent-stamped, never operator-set. See VisibilityAgentConfig.collector_ip.
    #[serde(default)]
    pub collector_ip: String,
}

#[derive(Debug, Clone, Default, Deserialize)]
pub struct DpiJson {
    #[serde(default)]
    pub enabled: bool,
    #[serde(default)]
    pub protocols: Vec<String>,
}

#[derive(Debug, Clone, Default, Deserialize)]
pub struct FingerprintJson {
    #[serde(default)]
    pub tcp: bool,
    #[serde(default)]
    pub tls: bool,
    #[serde(default)]
    pub http: bool,
}

#[derive(Debug, Clone, Default, Deserialize)]
pub struct DeviceBindingJson {
    #[serde(default)]
    pub ip: String,
    #[serde(default)]
    pub profile_id: String,
    #[serde(default)]
    pub profile_name: String,
    #[serde(default)]
    pub sample_interval_ms: u32,
    #[serde(default)]
    pub fingerprint: Option<FingerprintJson>,
    #[serde(default)]
    pub dpi: Option<DpiJson>,
}

impl From<DpiJson> for DpiConfig {
    fn from(value: DpiJson) -> Self {
        DpiConfig {
            enabled: value.enabled,
            protocols: value
                .protocols
                .into_iter()
                .map(|protocol| protocol.trim().to_owned())
                .filter(|protocol| !protocol.is_empty())
                .collect(),
        }
    }
}

impl From<FingerprintJson> for FingerprintConfig {
    fn from(value: FingerprintJson) -> Self {
        FingerprintConfig {
            tcp: value.tcp,
            tls: value.tls,
            http: value.http,
        }
    }
}

impl From<AddonConfigJson> for VisibilityAgentConfig {
    fn from(value: AddonConfigJson) -> Self {
        // Sorted by ip, and bindings with no address dropped.
        //
        // Sorted because the result is HASHED: prost encodes a repeated field in
        // vector order, so operator-controlled JSON array order would otherwise
        // move the config hash without changing the config, and the agent reads
        // that hash to decide whether anything changed.
        //
        // Dropped because a binding with no address can never match; the schema
        // marks `ip` required and this is the runtime half of that, matching
        // what the agent's Go decoder does.
        let mut device_bindings: Vec<DeviceBinding> = value
            .device_bindings
            .into_iter()
            .filter_map(|binding| {
                let ip = binding.ip.trim().to_owned();
                if ip.is_empty() {
                    return None;
                }

                Some(DeviceBinding {
                    ip,
                    profile_id: binding.profile_id.trim().to_owned(),
                    profile_name: binding.profile_name.trim().to_owned(),
                    fingerprint: binding.fingerprint.map(Into::into),
                    sample_interval_ms: binding.sample_interval_ms,
                    dpi: binding.dpi.map(Into::into),
                })
            })
            .collect();
        device_bindings.sort_by(|a, b| a.ip.cmp(&b.ip));

        VisibilityAgentConfig {
            enabled: value.enabled,
            capture_interfaces: value
                .capture_interfaces
                .into_iter()
                .map(|interface| interface.trim().to_owned())
                .filter(|interface| !interface.is_empty())
                .collect(),
            device_bindings,
            default_sample_interval_ms: value.default_sample_interval_ms,
            dpi: value.dpi.map(Into::into),
            flow_table_max_entries: value.flow_table_max_entries,
            process_snapshot_interval_s: value.process_snapshot_interval_s,
            external_flow_match_window_ms: value.external_flow_match_window_ms,
            flow_attribution_ipc_batch: value.flow_attribution_ipc_batch,
            emit_raw_flow_attribution_events: value.emit_raw_flow_attribution_events,
            collector_ip: value.collector_ip.trim().to_owned(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn parse(json: &str) -> VisibilityAgentConfig {
        serde_json::from_str::<AddonConfigJson>(json)
            .expect("parses")
            .into()
    }

    #[test]
    fn an_empty_object_parses_to_all_defaults() {
        // The control plane omits defaults, so {} is a real input rather than a
        // degenerate one.
        let config = parse("{}");

        assert!(!config.enabled);
        assert!(config.capture_interfaces.is_empty());
        assert!(config.device_bindings.is_empty());
        assert!(config.dpi.is_none());
    }

    #[test]
    fn the_whole_schema_round_trips() {
        // Every one of the ten properties addons/netprobe/config.schema.json
        // declares. This is the fixture shape the control plane emits.
        let config = parse(
            r#"{
                "enabled": true,
                "capture_interfaces": ["ens18", " ens19 "],
                "default_sample_interval_ms": 500,
                "flow_table_max_entries": 65536,
                "process_snapshot_interval_s": 30,
                "external_flow_match_window_ms": 1500,
                "flow_attribution_ipc_batch": true,
                "emit_raw_flow_attribution_events": false,
                "dpi": {"enabled": true, "protocols": ["tls", " http "]},
                "device_bindings": [
                    {
                        "ip": "192.168.1.10",
                        "profile_id": "camera-profile",
                        "profile_name": "Camera",
                        "sample_interval_ms": 500,
                        "fingerprint": {"tcp": true, "tls": true, "http": false},
                        "dpi": {"enabled": true, "protocols": ["dns"]}
                    }
                ]
            }"#,
        );

        assert!(config.enabled);
        assert_eq!(config.capture_interfaces, vec!["ens18", "ens19"]);
        assert_eq!(config.default_sample_interval_ms, 500);
        assert_eq!(config.flow_table_max_entries, 65_536);
        assert_eq!(config.process_snapshot_interval_s, 30);
        assert_eq!(config.external_flow_match_window_ms, 1_500);
        assert!(config.flow_attribution_ipc_batch);
        assert!(!config.emit_raw_flow_attribution_events);

        let dpi = config.dpi.expect("dpi present");
        assert!(dpi.enabled);
        assert_eq!(dpi.protocols, vec!["tls", "http"]);

        assert_eq!(config.device_bindings.len(), 1);
        let binding = &config.device_bindings[0];
        assert_eq!(binding.ip, "192.168.1.10");
        assert_eq!(binding.profile_id, "camera-profile");
        assert_eq!(binding.sample_interval_ms, 500);
        let fingerprint = binding.fingerprint.as_ref().expect("fingerprint present");
        assert!(fingerprint.tcp && fingerprint.tls && !fingerprint.http);
        assert!(binding.dpi.as_ref().expect("binding dpi").enabled);
    }

    #[test]
    fn bindings_are_sorted_so_array_order_cannot_move_the_hash() {
        // prost encodes a repeated field in vector order, and the encoded config
        // is what gets hashed. Without sorting, reordering the operator's array
        // would look like a config change to the agent and to Edge Ops.
        let a = parse(r#"{"device_bindings":[{"ip":"10.0.0.2"},{"ip":"10.0.0.1"}]}"#);
        let b = parse(r#"{"device_bindings":[{"ip":"10.0.0.1"},{"ip":"10.0.0.2"}]}"#);

        let ips: Vec<&str> = a.device_bindings.iter().map(|x| x.ip.as_str()).collect();
        assert_eq!(ips, vec!["10.0.0.1", "10.0.0.2"]);
        assert_eq!(a.device_bindings, b.device_bindings);
    }

    #[test]
    fn a_binding_with_no_address_is_dropped() {
        let config = parse(r#"{"device_bindings":[{"ip":"   "},{"ip":"10.0.0.7"}]}"#);

        assert_eq!(config.device_bindings.len(), 1);
        assert_eq!(config.device_bindings[0].ip, "10.0.0.7");
    }

    #[test]
    fn an_unknown_property_is_ignored_rather_than_fatal() {
        // A newer control plane adding a property must not stop an older
        // netprobe configuring at all. Ignoring costs one setting; rejecting
        // costs the whole config.
        let config = parse(r#"{"enabled": true, "a_field_from_the_future": 42}"#);

        assert!(config.enabled);
    }
}
