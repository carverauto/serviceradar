use serde::{Deserialize, Serialize};
use std::collections::{HashMap, HashSet};
use std::net::IpAddr;
use std::path::PathBuf;

use crate::host_slice::{
    host_slice_publication_allowed, host_slice_subject, validate_host_slice,
    validate_host_slice_allowlist,
};

#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct Config {
    // NATS
    pub nats_url: String,
    #[serde(default)]
    pub nats_creds_file: Option<String>,
    pub stream_name: String,
    #[serde(default)]
    pub stream_subjects: Option<Vec<String>>,
    #[serde(default = "default_stream_max_bytes")]
    pub stream_max_bytes: i64,
    /// JetStream MaxAge for the dedicated flows stream (seconds).
    /// Default 6 hours — sized for recovery lag, not demo thrift.
    #[serde(default = "default_stream_max_age_secs")]
    pub stream_max_age_secs: u64,
    #[serde(default = "default_stream_replicas")]
    pub stream_replicas: usize,
    /// Durable path for in-progress subject rehome markers (survives pod restart).
    #[serde(default)]
    pub rehome_state_path: Option<PathBuf>,
    /// Explicit readiness marker path (must match the K8s readinessProbe path).
    #[serde(default)]
    pub ready_state_path: Option<PathBuf>,
    #[serde(default = "default_partition")]
    pub partition: String,

    // Buffering
    //
    // `channel_size` is the default per-listener bounded mpsc capacity. Each listener
    // owns its own channel so a noisy protocol cannot starve a quiet one. Individual
    // listeners may override this via `ListenerConfig::channel_size`.
    //
    // Backpressure note: tokio's `mpsc::try_send` rejects the *newest* message on
    // overflow (i.e. it is a `DropNewest` policy by construction). We do not expose
    // a `DropOldest` knob because the underlying channel cannot evict the head
    // without a custom ring buffer; pinning to `DropNewest` keeps behavior honest
    // and avoids a config field that silently no-ops. If/when we move to a ring
    // buffer or `broadcast`-style backpressure, reintroduce the policy here.
    #[serde(default = "default_channel_size")]
    pub channel_size: usize,
    #[serde(default = "default_batch_size")]
    pub batch_size: usize,
    #[serde(default = "default_publish_timeout_ms")]
    pub publish_timeout_ms: u64,

    // Security
    pub security: Option<SecurityConfig>,

    // Observability
    pub metrics_addr: Option<String>,

    // Per-host flow slices for netprobe attribution
    #[serde(default)]
    pub host_slices: Vec<HostSliceConfig>,
    #[serde(default)]
    pub host_slice_allowlist: Vec<String>,
    /// Optional shared template store for NetFlow / IPFIX templates.
    /// When configured, every NetFlow listener writes through learned
    /// templates to this store and consults it on cache miss, allowing
    /// multiple flow-collector replicas to share template state behind
    /// a UDP load balancer. Leaving this `None` keeps the legacy
    /// in-process-only behavior.
    #[serde(default)]
    pub template_store: Option<TemplateStoreConfig>,

    // Listeners
    pub listeners: Vec<ListenerConfig>,
}

#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct HostSliceConfig {
    pub agent_id: String,
    #[serde(default = "default_partition")]
    pub partition: String,
    #[serde(default)]
    pub host_ips: Vec<IpAddr>,
    #[serde(default)]
    pub host_network_visibility: HostNetworkVisibilityStatus,
}

impl HostSliceConfig {
    pub fn subject(&self) -> String {
        host_slice_subject(&self.agent_id)
    }

    pub fn host_network_visibility_enabled(&self) -> bool {
        self.host_network_visibility == HostNetworkVisibilityStatus::Enabled
    }
}

#[derive(Debug, Default, Serialize, Deserialize, Clone, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum HostNetworkVisibilityStatus {
    Enabled,
    #[default]
    Unavailable,
}

#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct TemplateStoreConfig {
    /// NATS JetStream KV bucket name (must already exist or will be
    /// created/updated on startup).
    pub kv_bucket: String,
    /// Number of historical revisions to retain per key. Templates rarely
    /// change so 1 is fine; larger values support audit/debug. NATS KV
    /// caps history at 64. Validated at config load.
    #[serde(default = "default_kv_history")]
    pub kv_history: u8,
    /// Optional TTL (seconds) for entries in the KV bucket. NATS will
    /// expire stale templates automatically. `0` disables TTL. Default 0.
    #[serde(default)]
    pub kv_ttl_secs: u64,
    /// Optional NATS URL override for the template store. When unset
    /// (default), the top-level `nats_url` is used. Setting this lets
    /// template state live on a different NATS cluster from publish
    /// traffic — useful for multi-tenant or split-fault-domain setups.
    #[serde(default)]
    pub nats_url: Option<String>,
}

fn default_kv_history() -> u8 {
    1
}

/// NATS KV server-side cap.
const NATS_KV_MAX_HISTORY: u8 = 64;

#[derive(Debug, Serialize, Deserialize, Clone)]
#[serde(tag = "protocol", rename_all = "lowercase")]
pub enum ListenerConfig {
    Sflow {
        listen_addr: String,
        subject: String,
        #[serde(default = "default_buffer_size")]
        buffer_size: usize,
        /// Optional override of the per-listener publisher channel capacity.
        /// Falls back to the top-level `Config::channel_size` when unset.
        #[serde(default)]
        channel_size: Option<usize>,
        #[serde(default)]
        max_samples_per_datagram: Option<u32>,
    },
    Netflow {
        listen_addr: String,
        subject: String,
        #[serde(default = "default_buffer_size")]
        buffer_size: usize,
        /// Optional override of the per-listener publisher channel capacity.
        /// Falls back to the top-level `Config::channel_size` when unset.
        #[serde(default)]
        channel_size: Option<usize>,
        #[serde(default = "default_max_templates")]
        max_templates: usize,
        #[serde(default = "default_max_template_fields")]
        max_template_fields: usize,
        #[serde(default)]
        pending_flows: Option<PendingFlowsCacheConfig>,
        /// Fallback sampling rate for exporters that do not report one.
        /// A value of 1 means unsampled/full-fidelity flows.
        #[serde(default)]
        default_sampling_rate: Option<u64>,
        /// Per-exporter fallback sampling rates keyed by sampler IP address.
        /// These override `default_sampling_rate`.
        #[serde(default)]
        sampling_rate_overrides: HashMap<IpAddr, u64>,
        /// Maximum distinct exporters tracked by the parser for this listener.
        ///
        /// `netflow_parser` defaults to 10,000 and *evicts* past that (LRU),
        /// which silently degrades a fleet larger than the cap into constant
        /// eviction churn. Leaving this unset keeps the library default.
        /// Raising it costs memory proportional to the number of exporters.
        #[serde(default)]
        max_sources: Option<usize>,
    },
}

impl ListenerConfig {
    pub fn listen_addr(&self) -> &str {
        match self {
            ListenerConfig::Sflow { listen_addr, .. } => listen_addr,
            ListenerConfig::Netflow { listen_addr, .. } => listen_addr,
        }
    }

    pub fn subject(&self) -> &str {
        match self {
            ListenerConfig::Sflow { subject, .. } => subject,
            ListenerConfig::Netflow { subject, .. } => subject,
        }
    }

    pub fn buffer_size(&self) -> usize {
        match self {
            ListenerConfig::Sflow { buffer_size, .. } => *buffer_size,
            ListenerConfig::Netflow { buffer_size, .. } => *buffer_size,
        }
    }

    /// Resolve the listener's bounded mpsc capacity. Falls back to the
    /// top-level default when the listener does not override.
    pub fn channel_size(&self, default: usize) -> usize {
        let override_value = match self {
            ListenerConfig::Sflow { channel_size, .. } => *channel_size,
            ListenerConfig::Netflow { channel_size, .. } => *channel_size,
        };
        override_value.unwrap_or(default)
    }

    pub fn protocol_name(&self) -> &'static str {
        match self {
            ListenerConfig::Sflow { .. } => "sflow",
            ListenerConfig::Netflow { .. } => "netflow",
        }
    }
}

#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct PendingFlowsCacheConfig {
    #[serde(default = "default_max_pending_flows")]
    pub max_pending_flows: usize,
    #[serde(default = "default_max_entries_per_template")]
    pub max_entries_per_template: usize,
    #[serde(default = "default_max_entry_size_bytes")]
    pub max_entry_size_bytes: usize,
    #[serde(default = "default_pending_ttl_secs")]
    pub ttl_secs: u64,
}

#[derive(Debug, Serialize, Deserialize, Clone, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum SecurityMode {
    Mtls,
    None,
}

#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct SecurityConfig {
    pub mode: SecurityMode,
    pub cert_dir: Option<String>,
    pub tls: Option<TlsConfig>,
}

#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct TlsConfig {
    pub cert_file: Option<String>,
    pub key_file: Option<String>,
    pub ca_file: Option<String>,
}

impl SecurityConfig {
    pub fn cert_file_path(&self) -> Option<PathBuf> {
        self.build_path(self.tls.as_ref()?.cert_file.as_ref()?)
    }

    pub fn key_file_path(&self) -> Option<PathBuf> {
        self.build_path(self.tls.as_ref()?.key_file.as_ref()?)
    }

    pub fn ca_file_path(&self) -> Option<PathBuf> {
        self.build_path(self.tls.as_ref()?.ca_file.as_ref()?)
    }

    fn build_path(&self, file: &str) -> Option<PathBuf> {
        if let Some(cert_dir) = &self.cert_dir {
            Some(PathBuf::from(cert_dir).join(file))
        } else {
            Some(PathBuf::from(file))
        }
    }
}

fn default_buffer_size() -> usize {
    65536
}

fn default_channel_size() -> usize {
    10000
}

fn default_batch_size() -> usize {
    100
}

fn default_publish_timeout_ms() -> u64 {
    5000
}

fn default_partition() -> String {
    "default".to_string()
}

fn default_stream_max_bytes() -> i64 {
    // 10 GiB for the dedicated `flows` stream (order-of-magnitude above the
    // historical 1 GiB shared-events pin). Docker/tenant/helm overlays override
    // with capacity-safe values. Must NEVER reshape the shared `events` stream.
    10 * 1024 * 1024 * 1024
}

fn default_stream_max_age_secs() -> u64 {
    // 6 hours.
    6 * 60 * 60
}

fn default_stream_replicas() -> usize {
    1
}

fn default_max_templates() -> usize {
    2000
}

fn default_max_template_fields() -> usize {
    10_000
}

fn default_max_pending_flows() -> usize {
    256
}

fn default_max_entries_per_template() -> usize {
    1024
}

fn default_max_entry_size_bytes() -> usize {
    65535
}

fn default_pending_ttl_secs() -> u64 {
    300
}

impl Config {
    pub fn from_file(path: &str) -> anyhow::Result<Self> {
        let content = std::fs::read_to_string(path)?;
        let config: Config = serde_json::from_str(&content)?;
        config.validate()?;
        Ok(config)
    }

    fn validate(&self) -> anyhow::Result<()> {
        if self.nats_url.is_empty() {
            anyhow::bail!("nats_url cannot be empty");
        }
        if self.stream_name.is_empty() {
            anyhow::bail!("stream_name cannot be empty");
        }
        if self.stream_replicas == 0 {
            anyhow::bail!("stream_replicas must be > 0");
        }
        if self.stream_max_age_secs == 0 {
            anyhow::bail!("stream_max_age_secs must be > 0");
        }
        if self.stream_max_bytes <= 0 {
            anyhow::bail!("stream_max_bytes must be > 0");
        }
        if self.channel_size == 0 {
            anyhow::bail!("channel_size must be > 0");
        }
        if self.listeners.is_empty() {
            anyhow::bail!("at least one listener is required");
        }
        if let Some(ts) = &self.template_store {
            if ts.kv_bucket.is_empty() {
                anyhow::bail!("template_store.kv_bucket cannot be empty");
            }
            if ts.kv_history < 1 || ts.kv_history > NATS_KV_MAX_HISTORY {
                anyhow::bail!(
                    "template_store.kv_history must be in 1..={} (got {})",
                    NATS_KV_MAX_HISTORY,
                    ts.kv_history
                );
            }
            if let Some(url) = &ts.nats_url
                && url.is_empty()
            {
                anyhow::bail!("template_store.nats_url, if set, cannot be empty");
            }
        }

        // Check for duplicate listen addresses
        let mut seen_addrs = HashSet::new();
        for (i, listener) in self.listeners.iter().enumerate() {
            let addr = listener.listen_addr();
            if addr.is_empty() {
                anyhow::bail!("listener[{}]: listen_addr cannot be empty", i);
            }
            if listener.subject().is_empty() {
                anyhow::bail!("listener[{}]: subject cannot be empty", i);
            }
            // NATS publish subjects must be concrete (no whole-token * / >).
            if !crate::publisher::is_valid_listener_publish_subject(listener.subject()) {
                anyhow::bail!(
                    "listener[{}]: subject {:?} must be a concrete NATS subject (no whole-token * or >)",
                    i,
                    listener.subject()
                );
            }
            if !seen_addrs.insert(addr.to_string()) {
                anyhow::bail!("listener[{}]: duplicate listen_addr '{}'", i, addr);
            }
            if listener.channel_size(self.channel_size) == 0 {
                anyhow::bail!("listener[{}]: channel_size must be > 0", i);
            }

            // Validate netflow-specific pending_flows config
            if let ListenerConfig::Netflow {
                pending_flows: Some(pf),
                ..
            } = listener
            {
                if pf.max_pending_flows == 0 || pf.max_pending_flows > 10_000 {
                    anyhow::bail!(
                        "listener[{}]: pending_flows.max_pending_flows must be 1..=10,000",
                        i
                    );
                }
                if pf.max_entries_per_template == 0 || pf.max_entries_per_template > 100_000 {
                    anyhow::bail!(
                        "listener[{}]: pending_flows.max_entries_per_template must be 1..=100,000",
                        i
                    );
                }
                if pf.max_entry_size_bytes == 0 || pf.max_entry_size_bytes > 1_048_576 {
                    anyhow::bail!(
                        "listener[{}]: pending_flows.max_entry_size_bytes must be 1..=1,048,576",
                        i
                    );
                }
                if pf.ttl_secs == 0 || pf.ttl_secs > 3600 {
                    anyhow::bail!("listener[{}]: pending_flows.ttl_secs must be 1..=3,600", i);
                }
            }

            if let ListenerConfig::Netflow {
                default_sampling_rate,
                sampling_rate_overrides,
                ..
            } = listener
            {
                if matches!(default_sampling_rate, Some(0)) {
                    anyhow::bail!("listener[{}]: default_sampling_rate must be > 0", i);
                }

                for (exporter, rate) in sampling_rate_overrides {
                    if *rate == 0 {
                        anyhow::bail!(
                            "listener[{}]: sampling_rate_overrides[{}] must be > 0",
                            i,
                            exporter
                        );
                    }
                }
            }
        }
        for (i, slice) in self.host_slices.iter().enumerate() {
            validate_host_slice(slice, i)?;
        }
        validate_host_slice_allowlist(&self.host_slice_allowlist)?;

        // stream_subjects: reject filters that overlap the raw-flow namespace via
        // NATS pattern coverage (not just a flows.raw. textual prefix). This is
        // the source of truth; Helm is an early UX check only.
        if let Some(subjects) = &self.stream_subjects {
            for (i, subject) in subjects.iter().enumerate() {
                if subject.is_empty() {
                    anyhow::bail!("stream_subjects[{i}]: subject cannot be empty");
                }
                if !crate::publisher::is_protocol_valid_nats_subject(subject) {
                    anyhow::bail!(
                        "stream_subjects[{i}]: {subject:?} is not a protocol-valid NATS subject \
                         (no whitespace/empty tokens; a whole-token '>' wildcard must be terminal)"
                    );
                }
                if crate::publisher::pattern_overlaps_flow_namespace(subject) {
                    anyhow::bail!(
                        "stream_subjects[{i}]: {subject:?} uses a NATS filter that intersects \
                         flows.raw.> or flow.host-slice.>; use concrete leaves (EventWriter \
                         requires exact subjects; wildcards block rehome and leave extensions unconsumed)"
                    );
                }
            }
        }

        Ok(())
    }

    pub fn stream_subjects_resolved(&self) -> Vec<String> {
        let mut subjects: Vec<String> = self.stream_subjects.clone().unwrap_or_default();

        // Add each listener's subject
        for listener in &self.listeners {
            let subj = listener.subject().to_string();
            if !subjects.contains(&subj) {
                subjects.push(subj);
            }
        }
        for slice in self
            .host_slices
            .iter()
            .filter(|slice| host_slice_publication_allowed(self, slice))
        {
            let subject = slice.subject();
            if !subjects.contains(&subject) {
                subjects.push(subject);
            }
        }

        subjects.sort();
        subjects.dedup();
        subjects
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_valid_multi_listener_config() {
        let json = r#"{
            "nats_url": "nats://localhost:4222",
            "stream_name": "flows",
            "listeners": [
                {
                    "protocol": "sflow",
                    "listen_addr": "0.0.0.0:6343",
                    "subject": "flows.raw.sflow"
                },
                {
                    "protocol": "netflow",
                    "listen_addr": "0.0.0.0:2055",
                    "subject": "flows.raw.netflow"
                }
            ]
        }"#;
        let config: Config = serde_json::from_str(json).unwrap();
        assert!(config.validate().is_ok());
        assert_eq!(config.listeners.len(), 2);
        assert_eq!(config.channel_size, 10000);
        assert_eq!(config.batch_size, 100);
        assert_eq!(config.stream_max_age_secs, 6 * 60 * 60);
        assert_eq!(config.stream_max_bytes, 10 * 1024 * 1024 * 1024);
    }

    #[test]
    fn test_rehomeable_flow_subject_is_prefix_safe() {
        use crate::publisher::is_rehomeable_flow_subject;

        let required = vec![
            "flows.raw.netflow".to_string(),
            "flow.host-slice.agent-1".to_string(),
        ];
        assert!(is_rehomeable_flow_subject("flows.raw.netflow", &required));
        assert!(is_rehomeable_flow_subject("flows.raw.sflow", &required));
        assert!(is_rehomeable_flow_subject(
            "flow.host-slice.agent-1",
            &required
        ));
        // Not configured host-slice — leave on events.
        assert!(!is_rehomeable_flow_subject(
            "flow.host-slice.other",
            &required
        ));
        // Unrelated events subjects must never rehome.
        assert!(!is_rehomeable_flow_subject("logs.syslog", &required));
        assert!(!is_rehomeable_flow_subject("k8s.inventory", &required));
        assert!(!is_rehomeable_flow_subject("events.>", &required));
    }

    #[test]
    fn test_stream_max_age_secs_override() {
        let json = r#"{
            "nats_url": "nats://localhost:4222",
            "stream_name": "flows",
            "stream_max_age_secs": 7200,
            "stream_max_bytes": 10737418240,
            "listeners": [
                {
                    "protocol": "netflow",
                    "listen_addr": "0.0.0.0:2055",
                    "subject": "flows.raw.netflow"
                }
            ]
        }"#;
        let config: Config = serde_json::from_str(json).unwrap();
        assert!(config.validate().is_ok());
        assert_eq!(config.stream_max_age_secs, 7200);
        assert_eq!(config.stream_max_bytes, 10737418240);
    }

    #[test]
    fn test_empty_listeners_fails() {
        let json = r#"{
            "nats_url": "nats://localhost:4222",
            "stream_name": "events",
            "listeners": []
        }"#;
        let config: Config = serde_json::from_str(json).unwrap();
        let err = config.validate().unwrap_err();
        assert!(err.to_string().contains("at least one listener"));
    }

    #[test]
    fn test_missing_nats_url_fails() {
        let json = r#"{
            "nats_url": "",
            "stream_name": "events",
            "listeners": [
                {
                    "protocol": "sflow",
                    "listen_addr": "0.0.0.0:6343",
                    "subject": "flows.raw.sflow"
                }
            ]
        }"#;
        let config: Config = serde_json::from_str(json).unwrap();
        assert!(config.validate().is_err());
    }

    #[test]
    fn test_duplicate_listen_addr_fails() {
        let json = r#"{
            "nats_url": "nats://localhost:4222",
            "stream_name": "events",
            "listeners": [
                {
                    "protocol": "sflow",
                    "listen_addr": "0.0.0.0:6343",
                    "subject": "flows.raw.sflow"
                },
                {
                    "protocol": "netflow",
                    "listen_addr": "0.0.0.0:6343",
                    "subject": "flows.raw.netflow"
                }
            ]
        }"#;
        let config: Config = serde_json::from_str(json).unwrap();
        let err = config.validate().unwrap_err();
        assert!(err.to_string().contains("duplicate listen_addr"));
    }

    #[test]
    fn test_pending_flows_validation() {
        let json = r#"{
            "nats_url": "nats://localhost:4222",
            "stream_name": "events",
            "listeners": [
                {
                    "protocol": "netflow",
                    "listen_addr": "0.0.0.0:2055",
                    "subject": "flows.raw.netflow",
                    "pending_flows": {
                        "max_pending_flows": 0
                    }
                }
            ]
        }"#;
        let config: Config = serde_json::from_str(json).unwrap();
        let err = config.validate().unwrap_err();
        assert!(err.to_string().contains("max_pending_flows"));
    }

    #[test]
    fn test_stream_subjects_resolved_merges_listeners() {
        let json = r#"{
            "nats_url": "nats://localhost:4222",
            "stream_name": "events",
            "stream_subjects": ["flows.raw.extra"],
            "listeners": [
                {
                    "protocol": "sflow",
                    "listen_addr": "0.0.0.0:6343",
                    "subject": "flows.raw.sflow"
                },
                {
                    "protocol": "netflow",
                    "listen_addr": "0.0.0.0:2055",
                    "subject": "flows.raw.netflow"
                }
            ]
        }"#;
        let config: Config = serde_json::from_str(json).unwrap();
        let subjects = config.stream_subjects_resolved();
        assert!(subjects.contains(&"flows.raw.sflow".to_string()));
        assert!(subjects.contains(&"flows.raw.netflow".to_string()));
        assert!(subjects.contains(&"flows.raw.extra".to_string()));
    }

    #[test]
    fn validate_rejects_listener_wildcard_publish_subject() {
        let json = r#"{
            "nats_url": "nats://localhost:4222",
            "stream_name": "flows",
            "listeners": [
                {
                    "protocol": "netflow",
                    "listen_addr": "0.0.0.0:2055",
                    "subject": "flows.>"
                }
            ]
        }"#;
        let config: Config = serde_json::from_str(json).unwrap();
        let err = config.validate().unwrap_err().to_string();
        assert!(err.contains("concrete"), "{err}");
    }

    #[test]
    fn validate_rejects_stream_subject_namespace_wildcards() {
        for subject in ["*.>", "flows.>", "*.raw.>", "flows.raw.>"] {
            let json = format!(
                r#"{{
                "nats_url": "nats://localhost:4222",
                "stream_name": "flows",
                "stream_subjects": ["{subject}"],
                "listeners": [{{
                    "protocol": "netflow",
                    "listen_addr": "0.0.0.0:2055",
                    "subject": "flows.raw.netflow"
                }}]
            }}"#
            );
            let config: Config = serde_json::from_str(&json).unwrap();
            let err = config.validate().unwrap_err().to_string();
            assert!(
                err.contains("covers") || err.contains("wildcard") || err.contains("flows.raw"),
                "subject={subject} err={err}"
            );
        }
    }

    #[test]
    fn validate_rejects_nonterminal_tail_wildcards() {
        for subject in ["logs.>.vendor", "logs.>.>"] {
            let json = format!(
                r#"{{
                "nats_url": "nats://localhost:4222",
                "stream_name": "flows",
                "stream_subjects": ["{subject}"],
                "listeners": [{{
                    "protocol": "netflow",
                    "listen_addr": "0.0.0.0:2055",
                    "subject": "flows.raw.netflow"
                }}]
            }}"#
            );
            let config: Config = serde_json::from_str(&json).unwrap();
            let err = config.validate().unwrap_err().to_string();
            assert!(
                err.contains("protocol-valid"),
                "subject={subject} err={err}"
            );
        }
    }

    #[test]
    fn validate_preserves_embedded_literal_wildcard_characters() {
        for subject in ["logs.vend*or", "logs.vendor>.tail"] {
            let json = format!(
                r#"{{
                "nats_url": "nats://localhost:4222",
                "stream_name": "flows",
                "stream_subjects": ["{subject}"],
                "listeners": [{{
                    "protocol": "netflow",
                    "listen_addr": "0.0.0.0:2055",
                    "subject": "flows.raw.netflow"
                }}]
            }}"#
            );
            let config: Config = serde_json::from_str(&json).unwrap();
            config.validate().unwrap();
        }
    }

    #[test]
    fn test_stream_subjects_requires_host_slice_allowlist() {
        let json = r#"{
            "nats_url": "nats://localhost:4222",
            "stream_name": "events",
            "host_slice_allowlist": ["agent-1"],
            "host_slices": [
                {
                    "agent_id": "agent-1",
                    "host_ips": ["192.0.2.10"],
                    "host_network_visibility": "enabled"
                },
                {
                    "agent_id": "agent-2",
                    "host_ips": ["192.0.2.20"],
                    "host_network_visibility": "enabled"
                }
            ],
            "listeners": [
                {
                    "protocol": "sflow",
                    "listen_addr": "0.0.0.0:6343",
                    "subject": "flows.raw.sflow"
                }
            ]
        }"#;
        let config: Config = serde_json::from_str(json).unwrap();
        config.validate().unwrap();

        let subjects = config.stream_subjects_resolved();

        assert!(subjects.contains(&"flow.host-slice.agent-1".to_string()));
        assert!(!subjects.contains(&"flow.host-slice.agent-2".to_string()));
    }

    #[test]
    fn test_host_slice_allowlist_validation() {
        let json = r#"{
            "nats_url": "nats://localhost:4222",
            "stream_name": "events",
            "host_slice_allowlist": ["agent.1"],
            "listeners": [
                {
                    "protocol": "sflow",
                    "listen_addr": "0.0.0.0:6343",
                    "subject": "flows.raw.sflow"
                }
            ]
        }"#;
        let config: Config = serde_json::from_str(json).unwrap();

        assert!(
            config
                .validate()
                .unwrap_err()
                .to_string()
                .contains("host_slice_allowlist")
        );
    }

    #[test]
    fn test_sflow_specific_options() {
        let json = r#"{
            "nats_url": "nats://localhost:4222",
            "stream_name": "events",
            "listeners": [
                {
                    "protocol": "sflow",
                    "listen_addr": "0.0.0.0:6343",
                    "subject": "flows.raw.sflow",
                    "max_samples_per_datagram": 1000
                }
            ]
        }"#;
        let config: Config = serde_json::from_str(json).unwrap();
        assert!(config.validate().is_ok());
        match &config.listeners[0] {
            ListenerConfig::Sflow {
                max_samples_per_datagram,
                ..
            } => {
                assert_eq!(*max_samples_per_datagram, Some(1000));
            }
            _ => panic!("Expected Sflow variant"),
        }
    }

    #[test]
    fn test_security_config_path_resolution() {
        let config = SecurityConfig {
            mode: SecurityMode::Mtls,
            cert_dir: Some("/etc/serviceradar/certs".to_string()),
            tls: Some(TlsConfig {
                cert_file: Some("flow-client.crt".to_string()),
                key_file: Some("flow-client.key".to_string()),
                ca_file: Some("ca.crt".to_string()),
            }),
        };

        assert_eq!(
            config.cert_file_path(),
            Some(PathBuf::from("/etc/serviceradar/certs/flow-client.crt"))
        );
        assert_eq!(
            config.key_file_path(),
            Some(PathBuf::from("/etc/serviceradar/certs/flow-client.key"))
        );
        assert_eq!(
            config.ca_file_path(),
            Some(PathBuf::from("/etc/serviceradar/certs/ca.crt"))
        );
    }

    #[test]
    fn test_per_listener_channel_size_override() {
        let json = r#"{
            "nats_url": "nats://localhost:4222",
            "stream_name": "events",
            "channel_size": 5000,
            "listeners": [
                {
                    "protocol": "sflow",
                    "listen_addr": "0.0.0.0:6343",
                    "subject": "flows.raw.sflow",
                    "channel_size": 1234
                },
                {
                    "protocol": "netflow",
                    "listen_addr": "0.0.0.0:2055",
                    "subject": "flows.raw.netflow"
                }
            ]
        }"#;
        let config: Config = serde_json::from_str(json).unwrap();
        config.validate().unwrap();
        assert_eq!(config.channel_size, 5000);
        assert_eq!(config.listeners[0].channel_size(config.channel_size), 1234);
        assert_eq!(config.listeners[1].channel_size(config.channel_size), 5000);
    }

    #[test]
    fn test_zero_channel_size_fails() {
        let json = r#"{
            "nats_url": "nats://localhost:4222",
            "stream_name": "events",
            "channel_size": 0,
            "listeners": [
                {
                    "protocol": "sflow",
                    "listen_addr": "0.0.0.0:6343",
                    "subject": "flows.raw.sflow"
                }
            ]
        }"#;
        let config: Config = serde_json::from_str(json).unwrap();
        let err = config.validate().unwrap_err();
        assert!(err.to_string().contains("channel_size"));
    }

    #[test]
    fn test_zero_listener_channel_size_fails() {
        let json = r#"{
            "nats_url": "nats://localhost:4222",
            "stream_name": "events",
            "listeners": [
                {
                    "protocol": "sflow",
                    "listen_addr": "0.0.0.0:6343",
                    "subject": "flows.raw.sflow",
                    "channel_size": 0
                }
            ]
        }"#;
        let config: Config = serde_json::from_str(json).unwrap();
        let err = config.validate().unwrap_err();
        assert!(err.to_string().contains("channel_size"));
    }

    #[test]
    fn test_normalize_stream_subjects_drops_covered_exacts() {
        use crate::publisher::{normalize_stream_subjects, subject_covers};

        assert!(subject_covers("flows.raw.>", "flows.raw.netflow"));
        assert!(subject_covers("flows.raw.>", "flows.raw.sflow"));
        assert!(subject_covers("flows.raw.>", "flows.raw.ipfix.v9"));
        assert!(!subject_covers("flows.raw.netflow", "flows.raw.sflow"));
        assert!(!subject_covers("flows.raw.*", "flows.raw.ipfix.v9"));
        assert!(subject_covers("flows.raw.*", "flows.raw.ipfix"));

        // Wildcard vs wildcard: * must NOT cover >; > covers *.
        assert!(!subject_covers("flows.raw.*", "flows.raw.>"));
        assert!(subject_covers("flows.raw.>", "flows.raw.*"));
        assert!(!subject_covers("flows.*.netflow", "flows.raw.sflow"));
        assert!(subject_covers("flows.*.netflow", "flows.raw.netflow"));
        assert!(!subject_covers(
            "flows.*.netflow",
            "flows.raw.other.netflow"
        ));

        let normalized = normalize_stream_subjects(vec![
            "flows.raw.>".to_string(),
            "flows.raw.netflow".to_string(),
            "flows.raw.sflow".to_string(),
        ]);
        assert_eq!(normalized, vec!["flows.raw.>".to_string()]);

        let star_and_gt = normalize_stream_subjects(vec![
            "flows.raw.>".to_string(),
            "flows.raw.*".to_string(),
            "flows.raw.netflow".to_string(),
        ]);
        assert_eq!(star_and_gt, vec!["flows.raw.>".to_string()]);

        let star = normalize_stream_subjects(vec![
            "flows.raw.*".to_string(),
            "flows.raw.netflow".to_string(),
            "flows.raw.sflow".to_string(),
        ]);
        assert_eq!(star, vec!["flows.raw.*".to_string()]);

        let mixed = normalize_stream_subjects(vec![
            "flows.raw.netflow".to_string(),
            "flows.raw.sflow".to_string(),
            "events.device".to_string(),
        ]);
        assert_eq!(
            mixed,
            vec![
                "events.device".to_string(),
                "flows.raw.netflow".to_string(),
                "flows.raw.sflow".to_string(),
            ]
        );
    }

    #[test]
    fn image_baked_config_targets_flows_with_capacity_safe_cap() {
        let raw = include_str!("../flow-collector.json");
        let config: Config = serde_json::from_str(raw).expect("flow-collector.json parses");
        assert_eq!(config.stream_name, "flows");
        // Image/docker bake uses a capacity-safe override, not the 10 GiB binary default.
        assert_eq!(config.stream_max_bytes, 1024 * 1024 * 1024);
        assert!(config.stream_max_age_secs > 0);
    }

    #[test]
    fn omitted_retention_fields_default_but_events_name_is_legacy() {
        let raw = r#"{
            "nats_url": "nats://localhost:4222",
            "stream_name": "events",
            "listeners": [{"protocol":"netflow","listen_addr":"0.0.0.0:2055","subject":"flows.raw.netflow"}]
        }"#;
        let config: Config = serde_json::from_str(raw).unwrap();
        assert_eq!(config.stream_name, "events");
        // Defaults apply for parsing; publisher must not reshape events with them.
        assert_eq!(config.stream_max_bytes, 10 * 1024 * 1024 * 1024);
    }

    #[test]
    fn template_store_block_deserializes() {
        // Mirrors what the kustomize manifest and Helm values render.
        let json = r#"{
            "nats_url": "nats://localhost:4222",
            "stream_name": "events",
            "template_store": {
                "kv_bucket": "flow_templates",
                "kv_history": 1,
                "kv_ttl_secs": 0
            },
            "listeners": [
                {
                    "protocol": "netflow",
                    "listen_addr": "0.0.0.0:2055",
                    "subject": "flows.raw.netflow"
                }
            ]
        }"#;
        let cfg: Config = serde_json::from_str(json).expect("deserialize");
        let ts = cfg.template_store.expect("template_store should parse");
        assert_eq!(ts.kv_bucket, "flow_templates");
        assert_eq!(ts.kv_history, 1);
        assert_eq!(ts.kv_ttl_secs, 0);
    }

    #[test]
    fn template_store_omitted_means_disabled() {
        let json = r#"{
            "nats_url": "nats://localhost:4222",
            "stream_name": "events",
            "listeners": [
                {
                    "protocol": "sflow",
                    "listen_addr": "0.0.0.0:6343",
                    "subject": "flows.raw.sflow"
                }
            ]
        }"#;
        let cfg: Config = serde_json::from_str(json).expect("deserialize");
        assert!(cfg.template_store.is_none());
    }

    #[test]
    fn netflow_listener_accepts_max_sources() {
        let json = r#"{
            "nats_url": "nats://localhost:4222",
            "stream_name": "flows",
            "listeners": [{
                "protocol": "netflow",
                "listen_addr": "0.0.0.0:2055",
                "subject": "flows.raw.netflow",
                "max_sources": 25000
            }]
        }"#;
        let cfg: Config = serde_json::from_str(json).expect("config should parse");
        match &cfg.listeners[0] {
            ListenerConfig::Netflow { max_sources, .. } => {
                assert_eq!(*max_sources, Some(25_000));
            }
            other => panic!("expected netflow listener, got {other:?}"),
        }
    }

    #[test]
    fn netflow_max_sources_defaults_to_none() {
        let json = r#"{
            "nats_url": "nats://localhost:4222",
            "stream_name": "flows",
            "listeners": [{
                "protocol": "netflow",
                "listen_addr": "0.0.0.0:2055",
                "subject": "flows.raw.netflow"
            }]
        }"#;
        let cfg: Config = serde_json::from_str(json).expect("config should parse");
        match &cfg.listeners[0] {
            // None means "leave the library default of 10_000 alone".
            ListenerConfig::Netflow { max_sources, .. } => assert_eq!(*max_sources, None),
            other => panic!("expected netflow listener, got {other:?}"),
        }
    }
}
