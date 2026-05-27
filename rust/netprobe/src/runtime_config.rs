use std::{
    collections::{hash_map::DefaultHasher, HashMap},
    hash::{Hash, Hasher},
    sync::{Arc, RwLock},
};

use anyhow::{Context, Result};
use prost::Message;

use crate::{
    config::{validate_capture_interfaces, Config},
    proto::netprobe::{
        fingerprint_event, DeviceBinding, FingerprintConfig, FingerprintEvent,
        VisibilityAgentConfig,
    },
};

#[derive(Clone)]
pub struct RuntimeConfig {
    inner: Arc<RwLock<VisibilityState>>,
}

#[derive(Clone, Debug)]
#[cfg_attr(not(feature = "pcap-capture"), allow(dead_code))]
struct VisibilityState {
    enabled: bool,
    bindings: HashMap<String, BindingState>,
    default_sample_interval_ms: u32,
}

#[derive(Clone, Debug)]
#[cfg_attr(not(feature = "pcap-capture"), allow(dead_code))]
struct BindingState {
    profile_id: String,
    fingerprint: FingerprintConfig,
    sample_interval_ms: u32,
}

#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
#[cfg_attr(not(feature = "pcap-capture"), allow(dead_code))]
enum FingerprintProtocol {
    Tcp,
    Tls,
    Http,
}

#[derive(Clone, Debug)]
#[cfg_attr(not(feature = "pcap-capture"), allow(dead_code))]
struct EventDecision {
    enabled: bool,
    profile_id: String,
    sample_interval_ms: u32,
}

pub struct FingerprintEventGate {
    #[cfg_attr(not(feature = "pcap-capture"), allow(dead_code))]
    config: RuntimeConfig,
    #[cfg_attr(not(feature = "pcap-capture"), allow(dead_code))]
    last_emitted: HashMap<(String, FingerprintProtocol), i64>,
}

impl RuntimeConfig {
    pub fn new(config: &Config) -> Self {
        Self {
            inner: Arc::new(RwLock::new(VisibilityState {
                enabled: config.enabled,
                bindings: HashMap::new(),
                default_sample_interval_ms: 0,
            })),
        }
    }

    pub fn apply(&self, config: VisibilityAgentConfig) -> Result<String> {
        validate_capture_interfaces(&config.capture_interfaces)
            .context("invalid capture interface allowlist")?;

        let next = VisibilityState {
            enabled: config.enabled,
            bindings: bindings_by_ip(&config.device_bindings),
            default_sample_interval_ms: config.default_sample_interval_ms,
        };

        let config_hash = config_hash(&config);
        let mut state = self.inner.write().expect("runtime config lock poisoned");
        *state = next;

        Ok(config_hash)
    }

    #[cfg_attr(not(feature = "pcap-capture"), allow(dead_code))]
    fn decision_for(
        &self,
        event: &FingerprintEvent,
        protocol: FingerprintProtocol,
    ) -> EventDecision {
        let state = self.inner.read().expect("runtime config lock poisoned");
        if !state.enabled {
            return EventDecision {
                enabled: false,
                profile_id: String::new(),
                sample_interval_ms: 0,
            };
        }

        let Some(binding) = state.bindings.get(&event.ip) else {
            return EventDecision {
                enabled: true,
                profile_id: String::new(),
                sample_interval_ms: state.default_sample_interval_ms,
            };
        };

        EventDecision {
            enabled: protocol_enabled(&binding.fingerprint, protocol),
            profile_id: binding.profile_id.clone(),
            sample_interval_ms: if binding.sample_interval_ms == 0 {
                state.default_sample_interval_ms
            } else {
                binding.sample_interval_ms
            },
        }
    }
}

impl FingerprintEventGate {
    pub fn new(config: RuntimeConfig) -> Self {
        Self {
            config,
            last_emitted: HashMap::new(),
        }
    }

    #[cfg_attr(not(feature = "pcap-capture"), allow(dead_code))]
    pub fn filter(&mut self, mut event: FingerprintEvent) -> Option<FingerprintEvent> {
        let protocol = protocol_for(&event)?;
        let decision = self.config.decision_for(&event, protocol);
        if !decision.enabled {
            return None;
        }

        if !should_emit(
            &mut self.last_emitted,
            &event.ip,
            protocol,
            event.observed_at_unix_nano,
            decision.sample_interval_ms,
        ) {
            return None;
        }

        event.profile_id = decision.profile_id;
        Some(event)
    }
}

fn bindings_by_ip(bindings: &[DeviceBinding]) -> HashMap<String, BindingState> {
    bindings
        .iter()
        .filter(|binding| !binding.ip.is_empty())
        .map(|binding| {
            (
                binding.ip.clone(),
                BindingState {
                    profile_id: binding.profile_id.clone(),
                    fingerprint: binding
                        .fingerprint
                        .clone()
                        .unwrap_or_else(all_fingerprints_enabled),
                    sample_interval_ms: binding.sample_interval_ms,
                },
            )
        })
        .collect()
}

#[cfg_attr(not(feature = "pcap-capture"), allow(dead_code))]
fn protocol_for(event: &FingerprintEvent) -> Option<FingerprintProtocol> {
    match event.evidence.as_ref()? {
        fingerprint_event::Evidence::Tcp(_) => Some(FingerprintProtocol::Tcp),
        fingerprint_event::Evidence::Tls(_) => Some(FingerprintProtocol::Tls),
        fingerprint_event::Evidence::Http(_) => Some(FingerprintProtocol::Http),
    }
}

#[cfg_attr(not(feature = "pcap-capture"), allow(dead_code))]
fn protocol_enabled(config: &FingerprintConfig, protocol: FingerprintProtocol) -> bool {
    match protocol {
        FingerprintProtocol::Tcp => config.tcp,
        FingerprintProtocol::Tls => config.tls,
        FingerprintProtocol::Http => config.http,
    }
}

fn all_fingerprints_enabled() -> FingerprintConfig {
    FingerprintConfig {
        tcp: true,
        tls: true,
        http: true,
    }
}

#[cfg_attr(not(feature = "pcap-capture"), allow(dead_code))]
fn should_emit(
    last_emitted: &mut HashMap<(String, FingerprintProtocol), i64>,
    ip: &str,
    protocol: FingerprintProtocol,
    observed_at_unix_nano: i64,
    sample_interval_ms: u32,
) -> bool {
    if sample_interval_ms == 0 {
        last_emitted.insert((ip.to_string(), protocol), observed_at_unix_nano);
        return true;
    }

    let key = (ip.to_string(), protocol);
    let minimum_interval_nanos = i64::from(sample_interval_ms) * 1_000_000;
    if let Some(last_seen) = last_emitted.get(&key) {
        if observed_at_unix_nano.saturating_sub(*last_seen) < minimum_interval_nanos {
            return false;
        }
    }

    last_emitted.insert(key, observed_at_unix_nano);
    true
}

fn config_hash(config: &VisibilityAgentConfig) -> String {
    let mut hasher = DefaultHasher::new();
    config.encode_to_vec().hash(&mut hasher);
    format!("netprobe-v1:{:016x}", hasher.finish())
}

#[cfg(test)]
mod tests {
    use super::{FingerprintEventGate, RuntimeConfig};
    use crate::{
        config::Config,
        proto::netprobe::{
            fingerprint_event, DeviceBinding, FingerprintConfig, FingerprintEvent, TcpFingerprint,
            VisibilityAgentConfig,
        },
    };

    #[test]
    fn applies_profile_id_and_sample_interval_per_ip_protocol() {
        let runtime_config = RuntimeConfig::new(&Config::default());
        runtime_config
            .apply(VisibilityAgentConfig {
                enabled: true,
                device_bindings: vec![DeviceBinding {
                    ip: "192.0.2.10".to_string(),
                    profile_id: "profile-1".to_string(),
                    fingerprint: Some(FingerprintConfig {
                        tcp: true,
                        tls: false,
                        http: false,
                    }),
                    sample_interval_ms: 1_000,
                    ..Default::default()
                }],
                ..Default::default()
            })
            .unwrap();
        let mut gate = FingerprintEventGate::new(runtime_config);

        let first = gate.filter(tcp_event("192.0.2.10", 1_000_000_000));
        let second = gate.filter(tcp_event("192.0.2.10", 1_500_000_000));
        let third = gate.filter(tcp_event("192.0.2.10", 2_000_000_000));

        assert_eq!(first.unwrap().profile_id, "profile-1");
        assert!(second.is_none());
        assert!(third.is_some());
    }

    #[test]
    fn drops_protocols_disabled_by_binding() {
        let runtime_config = RuntimeConfig::new(&Config::default());
        runtime_config
            .apply(VisibilityAgentConfig {
                enabled: true,
                device_bindings: vec![DeviceBinding {
                    ip: "192.0.2.10".to_string(),
                    profile_id: "profile-1".to_string(),
                    fingerprint: Some(FingerprintConfig {
                        tcp: false,
                        tls: true,
                        http: true,
                    }),
                    ..Default::default()
                }],
                ..Default::default()
            })
            .unwrap();
        let mut gate = FingerprintEventGate::new(runtime_config);

        assert!(gate.filter(tcp_event("192.0.2.10", 1)).is_none());
    }

    #[test]
    fn rejects_invalid_capture_interfaces_on_apply() {
        let runtime_config = RuntimeConfig::new(&Config::default());

        let result = runtime_config.apply(VisibilityAgentConfig {
            enabled: true,
            capture_interfaces: vec!["any".to_string()],
            ..Default::default()
        });

        assert!(result.is_err());
    }

    fn tcp_event(ip: &str, observed_at_unix_nano: i64) -> FingerprintEvent {
        FingerprintEvent {
            ip: ip.to_string(),
            interface_name: "eth0".to_string(),
            observed_at_unix_nano,
            evidence: Some(fingerprint_event::Evidence::Tcp(TcpFingerprint {
                signature: "sig".to_string(),
                os_family: String::new(),
                os_name: String::new(),
                confidence: 1.0,
            })),
            ..Default::default()
        }
    }
}
