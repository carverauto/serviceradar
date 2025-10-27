use anyhow::{ensure, Context, Result};
use serde::Deserialize;
use std::fs;
use std::path::{Path, PathBuf};

const DEFAULT_WORKLOAD_SOCKET: &str = "unix:/run/spire/sockets/agent.sock";

#[derive(Debug, Deserialize, Clone, Copy, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum SecurityMode {
    None,
    Mtls,
    Spiffe,
}

impl Default for SecurityMode {
    fn default() -> Self {
        SecurityMode::None
    }
}

#[derive(Debug, Deserialize, Clone, Default)]
pub struct TlsConfig {
    pub cert_file: Option<String>,
    pub key_file: Option<String>,
    pub ca_file: Option<String>,
}

#[derive(Debug, Deserialize, Clone, Default)]
pub struct SecurityConfig {
    #[serde(default)]
    mode: Option<SecurityMode>,
    #[serde(default)]
    pub cert_dir: Option<String>,
    #[serde(default)]
    pub trust_domain: Option<String>,
    #[serde(default)]
    pub workload_socket: Option<String>,
    #[serde(default)]
    pub tls: Option<TlsConfig>,
    #[serde(default)]
    pub cert_file: Option<String>,
    #[serde(default)]
    pub key_file: Option<String>,
    #[serde(default)]
    pub ca_file: Option<String>,
}

impl SecurityConfig {
    pub fn mode(&self) -> SecurityMode {
        if let Some(mode) = self.mode {
            return mode;
        }

        let has_files = self.cert_file.is_some()
            || self.key_file.is_some()
            || self.ca_file.is_some()
            || self
                .tls
                .as_ref()
                .map(|tls| {
                    tls.cert_file.is_some() || tls.key_file.is_some() || tls.ca_file.is_some()
                })
                .unwrap_or(false);

        if has_files {
            SecurityMode::Mtls
        } else {
            SecurityMode::None
        }
    }

    pub fn workload_socket(&self) -> &str {
        self.workload_socket
            .as_deref()
            .unwrap_or(DEFAULT_WORKLOAD_SOCKET)
    }

    pub fn trust_domain(&self) -> Option<&str> {
        self.trust_domain.as_deref()
    }

    pub fn cert_file_path(&self) -> Option<PathBuf> {
        self.resolve_path(
            self.tls
                .as_ref()
                .and_then(|tls| tls.cert_file.as_ref())
                .or(self.cert_file.as_ref()),
        )
    }

    pub fn key_file_path(&self) -> Option<PathBuf> {
        self.resolve_path(
            self.tls
                .as_ref()
                .and_then(|tls| tls.key_file.as_ref())
                .or(self.key_file.as_ref()),
        )
    }

    pub fn ca_file_path(&self) -> Option<PathBuf> {
        self.resolve_path(
            self.tls
                .as_ref()
                .and_then(|tls| tls.ca_file.as_ref())
                .or(self.ca_file.as_ref()),
        )
    }

    fn resolve_path(&self, value: Option<&String>) -> Option<PathBuf> {
        value.map(|path| {
            let candidate = Path::new(path);
            if candidate.is_absolute() {
                candidate.to_path_buf()
            } else if let Some(dir) = &self.cert_dir {
                Path::new(dir).join(candidate)
            } else {
                candidate.to_path_buf()
            }
        })
    }
}

#[derive(Debug, Deserialize, Clone)]
pub struct RuleEntry {
    pub order: u32,
    pub key: String,
}

#[derive(Debug, Deserialize, Clone, PartialEq, Eq, Default)]
#[serde(rename_all = "lowercase")]
pub enum MessageFormat {
    #[default]
    Json,
    Protobuf,
    #[serde(rename = "otel_metrics")]
    OtelMetrics,
}

#[derive(Debug, Deserialize, Clone)]
pub struct DecisionGroupConfig {
    #[allow(dead_code)]
    pub name: String,
    #[serde(default)]
    pub subjects: Vec<String>,
    #[serde(default)]
    pub rules: Vec<RuleEntry>,
    #[serde(default)]
    pub format: MessageFormat,
}

#[derive(Debug, Deserialize, Clone)]
pub struct Config {
    pub nats_url: String,
    #[serde(default)]
    pub domain: Option<String>,
    pub stream_name: String,
    pub consumer_name: String,
    #[serde(default)]
    pub subjects: Vec<String>,
    pub result_subject: Option<String>,
    pub result_subject_suffix: Option<String>,
    #[serde(default)]
    pub decision_keys: Vec<String>,
    #[serde(default)]
    pub decision_groups: Vec<DecisionGroupConfig>,
    #[serde(default = "default_kv_bucket")]
    pub kv_bucket: String,
    pub agent_id: String,
    #[serde(default = "default_listen_addr")]
    pub listen_addr: String,
    #[serde(default)]
    pub security: Option<SecurityConfig>,
    #[serde(default)]
    pub grpc_security: Option<SecurityConfig>,
}

fn default_kv_bucket() -> String {
    "serviceradar-datasvc".to_string()
}

fn default_listen_addr() -> String {
    "0.0.0.0:50055".to_string()
}

impl Config {
    pub fn from_file<P: AsRef<std::path::Path>>(path: P) -> Result<Self> {
        let content = fs::read_to_string(path).context("Failed to read config file")?;
        let cfg: Config = serde_json::from_str(&content).context("Failed to parse config file")?;
        cfg.validate()?;
        Ok(cfg)
    }

    pub fn validate(&self) -> Result<()> {
        ensure!(!self.nats_url.is_empty(), "nats_url is required");
        ensure!(!self.listen_addr.is_empty(), "listen_addr is required");
        ensure!(!self.stream_name.is_empty(), "stream_name is required");
        ensure!(!self.consumer_name.is_empty(), "consumer_name is required");
        ensure!(
            !(self.decision_keys.is_empty() && self.decision_groups.is_empty()),
            "at least one decision_key or decision_group is required"
        );
        ensure!(!self.agent_id.is_empty(), "agent_id is required");
        ensure!(
            !self.subjects.is_empty(),
            "at least one subject is required"
        );

        if let Some(sec) = &self.grpc_security {
            match sec.mode() {
                SecurityMode::Mtls => {
                    ensure!(
                        sec.cert_file_path().is_some()
                            && sec.key_file_path().is_some()
                            && sec.ca_file_path().is_some(),
                        "grpc_security requires cert_file, key_file, and ca_file for mtls mode"
                    );
                }
                SecurityMode::Spiffe => {
                    ensure!(
                        sec.trust_domain().map(|td| !td.is_empty()).unwrap_or(false),
                        "grpc_security.trust_domain is required for spiffe mode"
                    );
                }
                SecurityMode::None => {}
            }
        }

        Ok(())
    }

    pub fn ordered_rules_for_subject(&self, subject: &str) -> Vec<String> {
        if !self.decision_groups.is_empty() {
            if let Some(group) = self
                .decision_groups
                .iter()
                .find(|g| g.subjects.is_empty() || g.subjects.iter().any(|s| s == subject))
            {
                let mut rules = group.rules.clone();
                rules.sort_by_key(|r| r.order);
                return rules.into_iter().map(|r| r.key).collect();
            }
        }
        self.decision_keys.clone()
    }

    pub fn message_format_for_subject(&self, subject: &str) -> MessageFormat {
        if !self.decision_groups.is_empty() {
            if let Some(group) = self
                .decision_groups
                .iter()
                .find(|g| g.subjects.is_empty() || g.subjects.iter().any(|s| s == subject))
            {
                return group.format.clone();
            }
        }
        MessageFormat::default()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_security_config_mode_detection() {
        let sec = SecurityConfig {
            cert_file: Some("cert.pem".to_string()),
            key_file: Some("key.pem".to_string()),
            ca_file: Some("ca.pem".to_string()),
            ..Default::default()
        };
        assert_eq!(sec.mode(), SecurityMode::Mtls);

        let spiffe = SecurityConfig {
            mode: Some(SecurityMode::Spiffe),
            trust_domain: Some("example.org".to_string()),
            ..Default::default()
        };
        assert_eq!(spiffe.mode(), SecurityMode::Spiffe);

        let none = SecurityConfig::default();
        assert_eq!(none.mode(), SecurityMode::None);
    }

    #[test]
    fn test_config_from_file() {
        let path = concat!(env!("CARGO_MANIFEST_DIR"), "/zen-consumer.json");
        let cfg = Config::from_file(path).unwrap();
        assert_eq!(cfg.nats_url, "nats://127.0.0.1:4222");
        assert_eq!(cfg.domain.as_deref(), Some("edge"));
        assert_eq!(cfg.stream_name, "events");
        assert_eq!(cfg.consumer_name, "zen-consumer");
        assert_eq!(
            cfg.subjects,
            vec![
                "events.syslog",
                "events.snmp",
                "events.otel.logs",
                "events.otel.metrics.raw"
            ]
        );
        assert_eq!(cfg.decision_groups.len(), 4);
        assert_eq!(cfg.decision_groups[0].name, "syslog");
        assert_eq!(cfg.decision_groups[0].subjects, vec!["events.syslog"]);
        assert_eq!(cfg.decision_groups[0].rules[0].key, "strip_full_message");
        assert_eq!(cfg.decision_groups[0].rules[1].key, "cef_severity");
        assert_eq!(cfg.decision_groups[1].name, "snmp");
        assert_eq!(cfg.decision_groups[1].subjects, vec!["events.snmp"]);
        assert_eq!(cfg.decision_groups[1].rules[0].key, "cef_severity");
        assert_eq!(cfg.decision_groups[2].name, "otel_logs");
        assert_eq!(cfg.decision_groups[2].subjects, vec!["events.otel.logs"]);
        assert_eq!(cfg.decision_groups[2].format, MessageFormat::Protobuf);
        assert_eq!(cfg.decision_groups[3].name, "otel_metrics_raw");
        assert_eq!(
            cfg.decision_groups[3].subjects,
            vec!["events.otel.metrics.raw"]
        );
        assert_eq!(cfg.decision_groups[3].format, MessageFormat::OtelMetrics);
        assert_eq!(cfg.agent_id, "default-agent");
        assert_eq!(cfg.kv_bucket, "serviceradar-datasvc");
        assert_eq!(cfg.result_subject_suffix.as_deref(), Some(".processed"));
        assert_eq!(cfg.listen_addr, "0.0.0.0:50055");
        let grpc_sec = cfg.grpc_security.as_ref().unwrap();
        assert_eq!(grpc_sec.mode(), SecurityMode::Mtls);
        assert!(grpc_sec.cert_file_path().is_some());
    }

    #[test]
    fn test_config_validate_missing_fields() {
        let cfg = Config {
            nats_url: String::new(),
            domain: None,
            stream_name: String::new(),
            consumer_name: String::new(),
            subjects: Vec::new(),
            result_subject: None,
            result_subject_suffix: None,
            decision_keys: Vec::new(),
            decision_groups: Vec::new(),
            kv_bucket: String::new(),
            agent_id: String::new(),
            listen_addr: String::new(),
            security: None,
            grpc_security: None,
        };
        assert!(cfg.validate().is_err());
    }

    #[test]
    fn test_message_format_for_subject() {
        let cfg = Config::from_file(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/zen-consumer-with-otel.json"
        ))
        .unwrap();

        assert_eq!(
            cfg.message_format_for_subject("events.syslog"),
            MessageFormat::Json
        );
        assert_eq!(
            cfg.message_format_for_subject("events.snmp"),
            MessageFormat::Json
        );
        assert_eq!(
            cfg.message_format_for_subject("events.otel.logs"),
            MessageFormat::Protobuf
        );
        assert_eq!(
            cfg.message_format_for_subject("events.otel.metrics.raw"),
            MessageFormat::OtelMetrics
        );
        assert_eq!(
            cfg.message_format_for_subject("events.unknown"),
            MessageFormat::Json
        );
    }
}
