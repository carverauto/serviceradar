use std::{
    collections::{BTreeSet, HashMap},
    sync::{Arc, Mutex, RwLock},
};

use anyhow::{Context, Result};
use prost::Message;

use crate::{
    config::{Config, effective_flow_table_max_entries, validate_capture_interfaces},
    external_flow::default_external_flow_match_window_ms,
    proto::netprobe::{
        DeviceBinding, DpiConfig, DpiEvent, FingerprintConfig, FingerprintEvent,
        VisibilityAgentConfig, fingerprint_event,
    },
};

#[derive(Clone)]
pub struct RuntimeConfig {
    inner: Arc<RwLock<VisibilityState>>,
    capture_interfaces: Arc<Vec<String>>,
    /// Where netprobe is running, stamped by the agent. See
    /// VisibilityAgentConfig.collector_ip -- DPI subject selection and the
    /// process snapshot both need it and neither can guess it.
    collector_ip: Arc<RwLock<String>>,
    flow_table_max_entries: u32,
    // Startup-only, like the two above, and stored for the same reason: apply()
    // has to compare a requested config against what this PROCESS is running.
    //
    // Both were previously absent here AND absent from VisibilityState, so a
    // change to either was neither applied nor refused -- apply() returned a
    // fresh hash for a config that never took effect, and the control plane
    // recorded it as delivered.
    process_snapshot_interval_s: u64,
    emit_raw_flow_attribution_events: bool,
    external_flow_match_window_ms: Arc<RwLock<u32>>,
}

#[derive(Clone, Debug)]
#[allow(dead_code)]
struct VisibilityState {
    enabled: bool,
    bindings: HashMap<String, BindingState>,
    default_sample_interval_ms: u32,
    default_dpi: DpiConfig,
    flow_attribution_ipc_batch: bool,
}

#[derive(Clone, Debug)]
#[allow(dead_code)]
struct BindingState {
    profile_id: String,
    fingerprint: FingerprintConfig,
    dpi: DpiConfig,
    sample_interval_ms: u32,
}

#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
#[allow(dead_code)]
enum FingerprintProtocol {
    Tcp,
    Tls,
    Http,
}

#[derive(Clone, Debug, Eq, Hash, PartialEq)]
#[allow(dead_code)]
struct DpiEventKey {
    source_ip: String,
    destination_ip: String,
    source_port: u32,
    destination_port: u32,
    transport_protocol: String,
    protocol: String,
}

#[derive(Clone, Debug)]
#[allow(dead_code)]
struct EventDecision {
    enabled: bool,
    profile_id: String,
    sample_interval_ms: u32,
}

pub struct FingerprintEventGate {
    #[allow(dead_code)]
    config: RuntimeConfig,
    #[allow(dead_code)]
    last_emitted: HashMap<(String, FingerprintProtocol), i64>,
}

pub struct DpiEventGate {
    #[allow(dead_code)]
    config: RuntimeConfig,
    #[allow(dead_code)]
    last_emitted: Mutex<HashMap<DpiEventKey, i64>>,
}

impl RuntimeConfig {
    pub fn new(config: &Config) -> Self {
        Self {
            inner: Arc::new(RwLock::new(VisibilityState {
                enabled: config.enabled,
                bindings: HashMap::new(),
                default_sample_interval_ms: 0,
                default_dpi: default_dpi_disabled(),
                flow_attribution_ipc_batch: config.flow_attribution_ipc_batch,
            })),
            capture_interfaces: Arc::new(normalize_capture_interfaces(&config.capture_interfaces)),
            collector_ip: Arc::new(RwLock::new(config.collector_ip.trim().to_owned())),
            flow_table_max_entries: config.effective_flow_table_max_entries(),
            process_snapshot_interval_s: config.process_snapshot_interval_s,
            emit_raw_flow_attribution_events: config.emit_raw_flow_attribution_events,
            external_flow_match_window_ms: Arc::new(RwLock::new(
                effective_external_flow_match_window_ms(config.external_flow_match_window_ms),
            )),
        }
    }

    pub fn apply(&self, config: VisibilityAgentConfig) -> Result<String> {
        validate_capture_interfaces(&config.capture_interfaces)
            .context("invalid capture interface allowlist")?;
        let requested_capture_interfaces = normalize_capture_interfaces(&config.capture_interfaces);
        if requested_capture_interfaces.as_slice() != self.capture_interfaces.as_ref().as_slice() {
            anyhow::bail!(
                "capture interface changes require a netprobe restart in Phase 1; runtime ApplyConfig cannot alter capture_interfaces"
            );
        }
        let requested_flow_table_max_entries = effective_flow_table_max_entries(
            config.flow_table_max_entries,
            requested_capture_interfaces.len(),
        );
        if requested_flow_table_max_entries != self.flow_table_max_entries {
            anyhow::bail!(
                "flow table capacity changes require a netprobe restart; runtime ApplyConfig cannot alter flow_table_max_entries"
            );
        }

        // Startup-only fields that this process cannot become.
        //
        // WARNED, not refused, and the distinction is forced by proto3: scalars
        // have no presence, so `emit_raw_flow_attribution_events: false` and
        // "the operator said nothing" are the same bytes on the wire. Bailing
        // would make netprobe refuse every config whose sender did not happen to
        // populate these -- a collector that configures nothing at all, which is
        // far worse than one that ignores two fields.
        //
        // Both are consumed once, when the eBPF runtime is constructed
        // (ebpf_runtime.rs:356 sizes the process-snapshot timer; main.rs:221
        // decides whether the raw flow-attribution sender is wired at all).
        //
        // So the ack below still reports success for a change that did not take
        // effect. That is a real gap and it is NOT closed here -- closing it
        // needs presence on the wire (optional fields, or a separate
        // restart-required signal), which is a contract change. What this adds
        // is the log line that was missing entirely, so the gap is at least
        // observable while it stands.
        if u64::from(config.process_snapshot_interval_s) != self.process_snapshot_interval_s {
            log::warn!(
                "process_snapshot_interval_s cannot change without a netprobe restart: running with {}, config says {} -- ignoring",
                self.process_snapshot_interval_s,
                config.process_snapshot_interval_s
            );
        }
        if config.emit_raw_flow_attribution_events != self.emit_raw_flow_attribution_events {
            log::warn!(
                "emit_raw_flow_attribution_events cannot change without a netprobe restart: running with {}, config says {} -- ignoring",
                self.emit_raw_flow_attribution_events,
                config.emit_raw_flow_attribution_events
            );
        }

        let next = VisibilityState {
            enabled: config.enabled,
            bindings: bindings_by_ip(&config.device_bindings),
            default_sample_interval_ms: config.default_sample_interval_ms,
            default_dpi: config.dpi.clone().unwrap_or_else(default_dpi_disabled),
            flow_attribution_ipc_batch: config.flow_attribution_ipc_batch,
        };
        let external_flow_match_window_ms =
            effective_external_flow_match_window_ms(config.external_flow_match_window_ms);

        // An EMPTY collector_ip means "this config did not carry one", never
        // "clear the one you have". The AddonService Configure path builds its
        // VisibilityAgentConfig from operator-facing JSON, which deliberately has
        // no collector_ip field -- so without this guard the first Configure call
        // would wipe the address the bootstrap config supplied at boot, and DPI
        // subject selection would silently stop.
        let requested_collector_ip = config.collector_ip.trim().to_owned();
        if !requested_collector_ip.is_empty() {
            *self
                .collector_ip
                .write()
                .expect("collector ip lock poisoned") = requested_collector_ip;
        }

        let config_hash = config_hash(&config);
        let mut state = self.inner.write().expect("runtime config lock poisoned");
        *state = next;
        *self
            .external_flow_match_window_ms
            .write()
            .expect("external flow match window lock poisoned") = external_flow_match_window_ms;

        Ok(config_hash)
    }

    /// Empty when the agent has not supplied one. Callers must treat that as
    /// "cannot name a subject" and skip, rather than substituting a guess.
    pub fn collector_ip(&self) -> String {
        self.collector_ip
            .read()
            .expect("collector ip lock poisoned")
            .clone()
    }

    pub fn external_flow_match_window_ms(&self) -> u32 {
        *self
            .external_flow_match_window_ms
            .read()
            .expect("external flow match window lock poisoned")
    }

    pub fn flow_attribution_ipc_batch_enabled(&self) -> bool {
        self.inner
            .read()
            .expect("runtime config lock poisoned")
            .flow_attribution_ipc_batch
    }

    #[allow(dead_code)]
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

    #[allow(dead_code)]
    fn dpi_decision_for(&self, event: &DpiEvent) -> EventDecision {
        let state = self.inner.read().expect("runtime config lock poisoned");
        if !state.enabled {
            return EventDecision {
                enabled: false,
                profile_id: String::new(),
                sample_interval_ms: 0,
            };
        }

        let protocol = normalize_dpi_protocol(&event.protocol);
        let binding = state
            .bindings
            .get(&event.source_ip)
            .or_else(|| state.bindings.get(&event.destination_ip));

        let Some(binding) = binding else {
            return EventDecision {
                enabled: dpi_protocol_enabled(&state.default_dpi, &protocol),
                profile_id: String::new(),
                sample_interval_ms: state.default_sample_interval_ms,
            };
        };

        EventDecision {
            enabled: dpi_protocol_enabled(&binding.dpi, &protocol),
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

    #[allow(dead_code)]
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

impl DpiEventGate {
    pub fn new(config: RuntimeConfig) -> Self {
        Self {
            config,
            last_emitted: Mutex::new(HashMap::new()),
        }
    }

    #[allow(dead_code)]
    pub fn filter(&self, mut event: DpiEvent) -> Option<DpiEvent> {
        let decision = self.config.dpi_decision_for(&event);
        if !decision.enabled {
            return None;
        }

        if !should_emit_dpi(
            &mut self
                .last_emitted
                .lock()
                .expect("dpi event gate lock poisoned"),
            &event,
            decision.sample_interval_ms,
        ) {
            return None;
        }

        event.profile_id = decision.profile_id;
        Some(event)
    }
}

fn bindings_by_ip(bindings: &[DeviceBinding]) -> HashMap<String, BindingState> {
    let mut out = HashMap::new();
    for binding in bindings.iter().filter(|binding| !binding.ip.is_empty()) {
        let previous = out.insert(
            binding.ip.clone(),
            BindingState {
                profile_id: binding.profile_id.clone(),
                fingerprint: binding
                    .fingerprint
                    .unwrap_or_else(default_fingerprints_disabled),
                dpi: binding.dpi.clone().unwrap_or_else(default_dpi_disabled),
                sample_interval_ms: binding.sample_interval_ms,
            },
        );
        if previous.is_some() {
            log::warn!(
                "duplicate netprobe device binding for {}; using the last profile",
                binding.ip
            );
        }
    }

    out
}

#[allow(dead_code)]
// The proto deliberately keeps tcp/tls/http deprecated-but-populated while agents
// migrate to license_clean, so this must still read them. Remove the allow (and the
// arms) once the migration window closes.
#[allow(deprecated)]
fn protocol_for(event: &FingerprintEvent) -> Option<FingerprintProtocol> {
    match event.evidence.as_ref()? {
        fingerprint_event::Evidence::Tcp(_) => Some(FingerprintProtocol::Tcp),
        fingerprint_event::Evidence::Tls(_) => Some(FingerprintProtocol::Tls),
        fingerprint_event::Evidence::Http(_) => Some(FingerprintProtocol::Http),
        fingerprint_event::Evidence::LicenseClean(fingerprint) => {
            if !fingerprint.p0f_signature.is_empty()
                || !fingerprint.hassh.is_empty()
                || !fingerprint.hassh_server.is_empty()
            {
                Some(FingerprintProtocol::Tcp)
            } else if !fingerprint.ja4.is_empty() {
                Some(FingerprintProtocol::Tls)
            } else {
                None
            }
        }
    }
}

#[allow(dead_code)]
fn protocol_enabled(config: &FingerprintConfig, protocol: FingerprintProtocol) -> bool {
    match protocol {
        FingerprintProtocol::Tcp => config.tcp,
        FingerprintProtocol::Tls => config.tls,
        FingerprintProtocol::Http => config.http,
    }
}

fn default_fingerprints_disabled() -> FingerprintConfig {
    FingerprintConfig::default()
}

fn default_dpi_disabled() -> DpiConfig {
    DpiConfig::default()
}

fn effective_external_flow_match_window_ms(configured: u32) -> u32 {
    if configured == 0 {
        default_external_flow_match_window_ms()
    } else {
        configured
    }
}

#[allow(dead_code)]
fn dpi_protocol_enabled(config: &DpiConfig, protocol: &str) -> bool {
    config.enabled
        && config
            .protocols
            .iter()
            .any(|candidate| normalize_dpi_protocol(candidate) == protocol)
}

fn normalize_dpi_protocol(protocol: &str) -> String {
    protocol.trim().to_ascii_lowercase().replace('_', "-")
}

fn normalize_capture_interfaces(interfaces: &[String]) -> Vec<String> {
    interfaces
        .iter()
        .map(String::as_str)
        .collect::<BTreeSet<_>>()
        .into_iter()
        .map(str::to_string)
        .collect()
}

#[allow(dead_code)]
fn should_emit(
    last_emitted: &mut HashMap<(String, FingerprintProtocol), i64>,
    ip: &str,
    protocol: FingerprintProtocol,
    observed_at_unix_nano: i64,
    sample_interval_ms: u32,
) -> bool {
    if sample_interval_ms == 0 {
        return true;
    }

    let key = (ip.to_string(), protocol);
    let minimum_interval_nanos = i64::from(sample_interval_ms) * 1_000_000;
    if let Some(last_seen) = last_emitted.get(&key)
        && observed_at_unix_nano.saturating_sub(*last_seen) < minimum_interval_nanos
    {
        return false;
    }

    last_emitted.insert(key, observed_at_unix_nano);
    true
}

#[allow(dead_code)]
fn should_emit_dpi(
    last_emitted: &mut HashMap<DpiEventKey, i64>,
    event: &DpiEvent,
    sample_interval_ms: u32,
) -> bool {
    if sample_interval_ms == 0 {
        return true;
    }

    let key = dpi_event_key(event);
    let minimum_interval_nanos = i64::from(sample_interval_ms) * 1_000_000;
    if let Some(last_seen) = last_emitted.get(&key)
        && event.observed_at_unix_nano.saturating_sub(*last_seen) < minimum_interval_nanos
    {
        return false;
    }

    last_emitted.insert(key, event.observed_at_unix_nano);
    true
}

#[allow(dead_code)]
fn dpi_event_key(event: &DpiEvent) -> DpiEventKey {
    let forward = (
        event.source_ip.as_str(),
        event.source_port,
        event.destination_ip.as_str(),
        event.destination_port,
    );
    let reverse = (
        event.destination_ip.as_str(),
        event.destination_port,
        event.source_ip.as_str(),
        event.source_port,
    );
    let (source_ip, source_port, destination_ip, destination_port) = if forward <= reverse {
        (
            event.source_ip.clone(),
            event.source_port,
            event.destination_ip.clone(),
            event.destination_port,
        )
    } else {
        (
            event.destination_ip.clone(),
            event.destination_port,
            event.source_ip.clone(),
            event.source_port,
        )
    };

    DpiEventKey {
        source_ip,
        destination_ip,
        source_port,
        destination_port,
        transport_protocol: event.transport_protocol.clone(),
        protocol: normalize_dpi_protocol(&event.protocol),
    }
}

fn config_hash(config: &VisibilityAgentConfig) -> String {
    let mut hash = 0xcbf2_9ce4_8422_2325u64;
    for byte in config.encode_to_vec() {
        hash ^= u64::from(byte);
        hash = hash.wrapping_mul(0x0000_0100_0000_01b3);
    }
    format!("netprobe-v1:{hash:016x}")
}

#[cfg(test)]
mod tests {
    use super::{DpiEventGate, FingerprintEventGate, RuntimeConfig};
    use crate::{
        config::Config,
        proto::netprobe::{
            DeviceBinding, DpiConfig, DpiEvent, FingerprintConfig, FingerprintEvent,
            LicenseCleanFingerprint, TcpFingerprint, VisibilityAgentConfig, fingerprint_event,
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
    fn license_clean_event_uses_tcp_fingerprint_gate() {
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
                    ..Default::default()
                }],
                ..Default::default()
            })
            .unwrap();
        let mut gate = FingerprintEventGate::new(runtime_config);

        let allowed = gate.filter(license_clean_event("192.0.2.10", "4:64:0:1460:29200"));

        assert_eq!(allowed.unwrap().profile_id, "profile-1");
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

    #[test]
    fn rejects_runtime_capture_interface_changes() {
        let runtime_config = RuntimeConfig::new(&Config {
            enabled: true,
            capture_interfaces: vec!["eth0".to_string()],
            ..Default::default()
        });

        let result = runtime_config.apply(VisibilityAgentConfig {
            enabled: true,
            capture_interfaces: vec!["enp0s1".to_string()],
            ..Default::default()
        });

        assert!(result.is_err());
    }

    #[test]
    fn rejects_runtime_flow_table_capacity_changes() {
        let runtime_config = RuntimeConfig::new(&Config {
            flow_table_max_entries: 131_072,
            ..Default::default()
        });

        let result = runtime_config.apply(VisibilityAgentConfig {
            enabled: true,
            flow_table_max_entries: 262_144,
            ..Default::default()
        });

        assert!(result.is_err());
    }

    #[test]
    fn initializes_flow_attribution_ipc_batch_from_bootstrap_config() {
        let batched = RuntimeConfig::new(&Config {
            flow_attribution_ipc_batch: true,
            ..Default::default()
        });
        assert!(batched.flow_attribution_ipc_batch_enabled());

        let unbatched = RuntimeConfig::new(&Config {
            flow_attribution_ipc_batch: false,
            ..Default::default()
        });
        assert!(!unbatched.flow_attribution_ipc_batch_enabled());
    }

    #[test]
    fn dpi_gate_honors_per_binding_protocols() {
        let runtime_config = RuntimeConfig::new(&Config::default());
        runtime_config
            .apply(VisibilityAgentConfig {
                enabled: true,
                device_bindings: vec![DeviceBinding {
                    ip: "192.0.2.10".to_string(),
                    profile_id: "profile-1".to_string(),
                    dpi: Some(DpiConfig {
                        enabled: true,
                        protocols: vec!["dns".to_string()],
                    }),
                    ..Default::default()
                }],
                ..Default::default()
            })
            .unwrap();
        let gate = DpiEventGate::new(runtime_config);

        let allowed = gate.filter(dpi_event("192.0.2.10", "dns"));
        let denied = gate.filter(dpi_event("192.0.2.10", "http1"));

        assert_eq!(allowed.unwrap().profile_id, "profile-1");
        assert!(denied.is_none());
    }

    #[test]
    fn dpi_gate_honors_sample_interval_per_canonical_flow_protocol() {
        let runtime_config = RuntimeConfig::new(&Config::default());
        runtime_config
            .apply(VisibilityAgentConfig {
                enabled: true,
                default_sample_interval_ms: 1_000,
                device_bindings: vec![DeviceBinding {
                    ip: "192.0.2.10".to_string(),
                    profile_id: "profile-1".to_string(),
                    dpi: Some(DpiConfig {
                        enabled: true,
                        protocols: vec!["dns".to_string()],
                    }),
                    ..Default::default()
                }],
                ..Default::default()
            })
            .unwrap();
        let gate = DpiEventGate::new(runtime_config);

        assert!(
            gate.filter(dpi_event_at("192.0.2.10", "dns", 1_000))
                .is_some()
        );
        assert!(
            gate.filter(dpi_event_at("192.0.2.10", "dns", 500_000_000))
                .is_none()
        );

        let mut reverse = dpi_event_at("198.51.100.20", "dns", 600_000_000);
        reverse.destination_ip = "192.0.2.10".to_string();
        reverse.source_port = 53;
        reverse.destination_port = 49_152;
        assert!(gate.filter(reverse).is_none());

        assert!(
            gate.filter(dpi_event_at("192.0.2.10", "dns", 1_100_000_000))
                .is_some()
        );
    }

    #[test]
    fn dpi_gate_defaults_to_disabled() {
        let runtime_config = RuntimeConfig::new(&Config::default());
        runtime_config
            .apply(VisibilityAgentConfig {
                enabled: true,
                device_bindings: vec![DeviceBinding {
                    ip: "192.0.2.10".to_string(),
                    profile_id: "profile-1".to_string(),
                    ..Default::default()
                }],
                ..Default::default()
            })
            .unwrap();
        let gate = DpiEventGate::new(runtime_config);

        assert!(gate.filter(dpi_event("192.0.2.10", "dns")).is_none());
    }

    #[test]
    fn accepts_matching_capture_interfaces_in_any_order() {
        let runtime_config = RuntimeConfig::new(&Config {
            enabled: true,
            capture_interfaces: vec!["eth0".to_string(), "enp0s1".to_string()],
            ..Default::default()
        });

        runtime_config
            .apply(VisibilityAgentConfig {
                enabled: true,
                capture_interfaces: vec!["enp0s1".to_string(), "eth0".to_string()],
                ..Default::default()
            })
            .unwrap();
    }

    // Exercises the deprecated-but-still-supported tcp evidence path.
    #[allow(deprecated)]
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
                ..Default::default()
            })),
            ..Default::default()
        }
    }

    fn license_clean_event(ip: &str, p0f_signature: &str) -> FingerprintEvent {
        FingerprintEvent {
            ip: ip.to_string(),
            interface_name: "eth0".to_string(),
            observed_at_unix_nano: 1,
            evidence: Some(fingerprint_event::Evidence::LicenseClean(
                LicenseCleanFingerprint {
                    p0f_signature: p0f_signature.to_string(),
                    ..Default::default()
                },
            )),
            ..Default::default()
        }
    }

    fn dpi_event(ip: &str, protocol: &str) -> DpiEvent {
        dpi_event_at(ip, protocol, 123)
    }

    fn dpi_event_at(ip: &str, protocol: &str, observed_at_unix_nano: i64) -> DpiEvent {
        DpiEvent {
            source_ip: ip.to_string(),
            destination_ip: "198.51.100.20".to_string(),
            source_port: 49_152,
            destination_port: 53,
            transport_protocol: "udp".to_string(),
            protocol: protocol.to_string(),
            confidence: 0.95,
            observed_at_unix_nano,
            interface_name: "eth0".to_string(),
            dissector_id: "dns_header".to_string(),
            ..Default::default()
        }
    }
    #[test]
    fn a_restart_only_change_reports_which_field_and_both_values() {
        // The message is the whole point. It used to be discarded by `.ok()` in
        // the IPC handler and replaced with "visibility config is missing or
        // invalid", so an operator changing capture_interfaces learned only
        // that something was wrong -- not which field, nor that a restart was
        // the remedy.
        let config = Config {
            capture_interfaces: vec!["ens18".to_owned()],
            ..Default::default()
        };
        let runtime = RuntimeConfig::new(&config);

        let err = runtime
            .apply(VisibilityAgentConfig {
                capture_interfaces: vec!["ens19".to_owned()],
                ..Default::default()
            })
            .expect_err("a capture interface change cannot be applied live");

        let message = format!("{err:#}");
        assert!(
            message.contains("capture_interfaces") && message.contains("restart"),
            "message should name the field and the remedy: {message}"
        );
    }

    #[test]
    fn collector_ip_comes_from_the_bootstrap_config() {
        let config = Config {
            collector_ip: "  10.20.30.40  ".to_string(),
            ..Default::default()
        };

        assert_eq!(RuntimeConfig::new(&config).collector_ip(), "10.20.30.40");
    }

    #[test]
    fn collector_ip_defaults_to_empty_rather_than_a_guess() {
        // Empty is the honest answer when the agent has not stamped one. Callers
        // must skip the payloads that need a subject rather than invent one.
        assert_eq!(RuntimeConfig::new(&Config::default()).collector_ip(), "");
    }

    #[test]
    fn apply_updates_the_collector_ip() {
        let runtime_config = RuntimeConfig::new(&Config::default());

        runtime_config
            .apply(VisibilityAgentConfig {
                enabled: true,
                collector_ip: "10.20.30.41".to_string(),
                ..Default::default()
            })
            .expect("apply");

        assert_eq!(runtime_config.collector_ip(), "10.20.30.41");
    }

    #[test]
    fn apply_without_a_collector_ip_does_not_wipe_the_one_we_have() {
        // The AddonService Configure path builds its VisibilityAgentConfig from
        // operator-facing JSON, which has no collector_ip field. Without this,
        // the first Configure call after boot would clear the address the
        // bootstrap supplied and DPI subject selection would silently stop.
        let config = Config {
            collector_ip: "10.20.30.40".to_string(),
            ..Default::default()
        };
        let runtime_config = RuntimeConfig::new(&config);

        runtime_config
            .apply(VisibilityAgentConfig {
                enabled: true,
                ..Default::default()
            })
            .expect("apply");

        assert_eq!(
            runtime_config.collector_ip(),
            "10.20.30.40",
            "an absent collector_ip means 'not supplied', never 'clear it'"
        );
    }
}
