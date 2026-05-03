use serde::{Deserialize, Serialize};
use std::collections::HashSet;
use std::path::PathBuf;

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
    #[serde(default = "default_stream_replicas")]
    pub stream_replicas: usize,
    #[serde(default = "default_partition")]
    pub partition: String,

    // Buffering
    #[serde(default = "default_channel_size")]
    pub channel_size: usize,
    #[serde(default = "default_batch_size")]
    pub batch_size: usize,
    #[serde(default = "default_publish_timeout_ms")]
    pub publish_timeout_ms: u64,

    // Backpressure
    #[serde(default)]
    pub drop_policy: DropPolicy,

    // Security
    pub security: Option<SecurityConfig>,

    // Observability
    pub metrics_addr: Option<String>,

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
        #[serde(default)]
        max_samples_per_datagram: Option<u32>,
    },
    Netflow {
        listen_addr: String,
        subject: String,
        #[serde(default = "default_buffer_size")]
        buffer_size: usize,
        #[serde(default = "default_max_templates")]
        max_templates: usize,
        #[serde(default = "default_max_template_fields")]
        max_template_fields: usize,
        #[serde(default)]
        pending_flows: Option<PendingFlowsCacheConfig>,
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

    pub fn protocol_name(&self) -> &'static str {
        match self {
            ListenerConfig::Sflow { .. } => "sflow",
            ListenerConfig::Netflow { .. } => "netflow",
        }
    }
}

#[derive(Debug, Default, Serialize, Deserialize, Clone, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum DropPolicy {
    #[default]
    DropOldest,
    DropNewest,
    Block,
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
    10 * 1024 * 1024 * 1024
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
            if !seen_addrs.insert(addr.to_string()) {
                anyhow::bail!("listener[{}]: duplicate listen_addr '{}'", i, addr);
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
            "stream_name": "events",
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
    fn test_drop_policy_default() {
        assert_eq!(DropPolicy::default(), DropPolicy::DropOldest);
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
}
