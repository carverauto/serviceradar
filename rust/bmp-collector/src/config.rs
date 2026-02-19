use serde::{Deserialize, Serialize};
use std::net::SocketAddr;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Config {
    #[serde(default = "default_listen_addr")]
    pub listen_addr: String,
    #[serde(default = "default_read_buffer_bytes")]
    pub read_buffer_bytes: usize,
    #[serde(default = "default_max_frame_size_bytes")]
    pub max_frame_size_bytes: usize,
    pub nats_url: String,
    #[serde(default)]
    pub nats_domain: Option<String>,
    #[serde(default)]
    pub nats_creds_file: Option<String>,
    #[serde(default = "default_nats_tls_required")]
    pub nats_tls_required: bool,
    #[serde(default)]
    pub nats_tls_first: bool,
    #[serde(default)]
    pub nats_tls_ca_cert_path: Option<String>,
    #[serde(default)]
    pub nats_tls_client_cert_path: Option<String>,
    #[serde(default)]
    pub nats_tls_client_key_path: Option<String>,
    #[serde(default = "default_stream_name")]
    pub stream_name: String,
    #[serde(default = "default_subject_prefix")]
    pub subject_prefix: String,
    #[serde(default)]
    pub stream_subjects: Option<Vec<String>>,
    #[serde(default = "default_stream_max_bytes")]
    pub stream_max_bytes: i64,
    #[serde(default = "default_publish_timeout_ms")]
    pub publish_timeout_ms: u64,
}

impl Config {
    pub fn from_file(path: &str) -> anyhow::Result<Self> {
        let content = std::fs::read_to_string(path)?;
        let cfg: Config = serde_json::from_str(&content)?;
        cfg.validate()?;
        Ok(cfg)
    }

    pub fn validate(&self) -> anyhow::Result<()> {
        if self.listen_addr.trim().is_empty() {
            anyhow::bail!("listen_addr is required");
        }
        if self.listen_addr_parsed().is_err() {
            anyhow::bail!("listen_addr must be a valid host:port socket address");
        }
        if self.read_buffer_bytes == 0 {
            anyhow::bail!("read_buffer_bytes must be > 0");
        }
        if self.max_frame_size_bytes < 6 {
            anyhow::bail!("max_frame_size_bytes must be >= 6");
        }
        if self.nats_url.trim().is_empty() {
            anyhow::bail!("nats_url is required");
        }
        if self.stream_name.trim().is_empty() {
            anyhow::bail!("stream_name is required");
        }
        if self.subject_prefix.trim().is_empty() {
            anyhow::bail!("subject_prefix is required");
        }
        Ok(())
    }

    pub fn listen_addr_parsed(&self) -> anyhow::Result<SocketAddr> {
        self.listen_addr
            .parse()
            .map_err(|e| anyhow::anyhow!("invalid listen_addr '{}': {}", self.listen_addr, e))
    }

    pub fn stream_subjects_resolved(&self) -> Vec<String> {
        let wildcard = format!("{}.>", self.subject_prefix.trim_end_matches('.'));
        let mut subjects = self
            .stream_subjects
            .clone()
            .unwrap_or_else(|| vec![wildcard.clone()]);

        if !subjects.iter().any(|v| v == &wildcard) {
            subjects.push(wildcard);
        }

        subjects.sort();
        subjects.dedup();
        subjects
    }
}

fn default_listen_addr() -> String {
    "0.0.0.0:4000".to_string()
}

fn default_read_buffer_bytes() -> usize {
    64 * 1024
}

fn default_max_frame_size_bytes() -> usize {
    16 * 1024 * 1024
}

fn default_stream_name() -> String {
    "ARANCINI_CAUSAL".to_string()
}

fn default_subject_prefix() -> String {
    "arancini.updates".to_string()
}

fn default_stream_max_bytes() -> i64 {
    10 * 1024 * 1024 * 1024
}

fn default_publish_timeout_ms() -> u64 {
    5_000
}

fn default_nats_tls_required() -> bool {
    true
}
