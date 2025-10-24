use anyhow::{Context, Result};
use serde::Deserialize;
use std::fs;

#[derive(Debug, Deserialize, Clone)]
pub struct SecurityConfig {
    pub cert_file: Option<String>,
    pub key_file: Option<String>,
    pub ca_file: Option<String>,
}

#[derive(Debug, Deserialize, Clone)]
pub struct RuleEntry {
    pub order: u32,
    pub key: String,
}

#[derive(Debug, Deserialize, Clone, PartialEq, Default)]
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
    pub security: Option<SecurityConfig>,
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
        if self.nats_url.is_empty() {
            anyhow::bail!("nats_url is required");
        }
        if self.listen_addr.is_empty() {
            anyhow::bail!("listen_addr is required");
        }
        if self.stream_name.is_empty() {
            anyhow::bail!("stream_name is required");
        }
        if self.consumer_name.is_empty() {
            anyhow::bail!("consumer_name is required");
        }
        if self.decision_keys.is_empty() && self.decision_groups.is_empty() {
            anyhow::bail!("at least one decision_key or decision_group is required");
        }
        if self.agent_id.is_empty() {
            anyhow::bail!("agent_id is required");
        }
        if self.subjects.is_empty() {
            anyhow::bail!("at least one subject is required");
        }
        if let Some(sec) = &self.grpc_security {
            if sec.cert_file.is_none() || sec.key_file.is_none() || sec.ca_file.is_none() {
                anyhow::bail!("grpc_security requires cert_file, key_file, and ca_file");
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
        assert!(cfg.grpc_security.is_some());
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
        // Default to JSON for unknown subjects
        assert_eq!(
            cfg.message_format_for_subject("events.unknown"),
            MessageFormat::Json
        );
    }
}
