use serde::{Deserialize, Serialize};
use std::path::PathBuf;

#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct Config {
    // UDP listener
    pub listen_addr: String,
    #[serde(default = "default_buffer_size")]
    pub buffer_size: usize,

    // NATS
    pub nats_url: String,
    #[serde(default)]
    pub nats_creds_file: Option<String>,
    pub stream_name: String,
    pub subject: String,
    #[serde(default)]
    pub stream_subjects: Option<Vec<String>>,
    #[serde(default = "default_stream_max_bytes")]
    pub stream_max_bytes: i64,
    #[serde(default = "default_partition")]
    pub partition: String,

    // sFlow parser options
    #[serde(default)]
    pub max_samples_per_datagram: Option<u32>,

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
}

#[derive(Debug, Serialize, Deserialize, Clone, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum DropPolicy {
    DropOldest,
    DropNewest,
    Block,
}

impl Default for DropPolicy {
    fn default() -> Self {
        Self::DropOldest
    }
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

impl Config {
    pub fn from_file(path: &str) -> anyhow::Result<Self> {
        let content = std::fs::read_to_string(path)?;
        let config: Config = serde_json::from_str(&content)?;
        config.validate()?;
        Ok(config)
    }

    fn validate(&self) -> anyhow::Result<()> {
        if self.listen_addr.is_empty() {
            anyhow::bail!("listen_addr cannot be empty");
        }
        if self.nats_url.is_empty() {
            anyhow::bail!("nats_url cannot be empty");
        }
        if self.stream_name.is_empty() {
            anyhow::bail!("stream_name cannot be empty");
        }
        if self.subject.is_empty() {
            anyhow::bail!("subject cannot be empty");
        }
        Ok(())
    }

    pub fn stream_subjects_resolved(&self) -> Vec<String> {
        let mut subjects = self
            .stream_subjects
            .clone()
            .unwrap_or_else(|| vec![self.subject.clone()]);
        if !subjects.contains(&self.subject) {
            subjects.push(self.subject.clone());
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
    fn test_security_config_path_resolution() {
        let config = SecurityConfig {
            mode: SecurityMode::Mtls,
            cert_dir: Some("/etc/serviceradar/certs".to_string()),
            tls: Some(TlsConfig {
                cert_file: Some("sflow-client.crt".to_string()),
                key_file: Some("sflow-client.key".to_string()),
                ca_file: Some("ca.crt".to_string()),
            }),
        };

        assert_eq!(
            config.cert_file_path(),
            Some(PathBuf::from("/etc/serviceradar/certs/sflow-client.crt"))
        );
        assert_eq!(
            config.key_file_path(),
            Some(PathBuf::from("/etc/serviceradar/certs/sflow-client.key"))
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
    fn test_valid_config_from_json() {
        let json = r#"{
            "listen_addr": "0.0.0.0:6343",
            "nats_url": "nats://localhost:4222",
            "stream_name": "events",
            "subject": "flows.raw.sflow"
        }"#;
        let config: Config = serde_json::from_str(json).unwrap();
        assert!(config.validate().is_ok());
        assert_eq!(config.listen_addr, "0.0.0.0:6343");
        assert_eq!(config.buffer_size, 65536);
        assert_eq!(config.channel_size, 10000);
        assert_eq!(config.batch_size, 100);
        assert_eq!(config.publish_timeout_ms, 5000);
        assert!(config.max_samples_per_datagram.is_none());
    }

    #[test]
    fn test_missing_required_field() {
        let json = r#"{
            "listen_addr": "0.0.0.0:6343",
            "stream_name": "events",
            "subject": "flows.raw.sflow"
        }"#;
        let result: Result<Config, _> = serde_json::from_str(json);
        assert!(result.is_err());
    }

    #[test]
    fn test_empty_listen_addr_fails_validation() {
        let json = r#"{
            "listen_addr": "",
            "nats_url": "nats://localhost:4222",
            "stream_name": "events",
            "subject": "flows.raw.sflow"
        }"#;
        let config: Config = serde_json::from_str(json).unwrap();
        assert!(config.validate().is_err());
    }

    #[test]
    fn test_stream_subjects_resolved() {
        let json = r#"{
            "listen_addr": "0.0.0.0:6343",
            "nats_url": "nats://localhost:4222",
            "stream_name": "events",
            "subject": "flows.raw.sflow",
            "stream_subjects": ["flows.raw.sflow", "flows.raw.sflow.processed"]
        }"#;
        let config: Config = serde_json::from_str(json).unwrap();
        let subjects = config.stream_subjects_resolved();
        assert!(subjects.contains(&"flows.raw.sflow".to_string()));
        assert!(subjects.contains(&"flows.raw.sflow.processed".to_string()));
    }
}
