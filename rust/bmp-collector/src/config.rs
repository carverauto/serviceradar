use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Config {
    pub nats_url: String,
    #[serde(default)]
    pub nats_domain: Option<String>,
    #[serde(default)]
    pub nats_creds_file: Option<String>,
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

fn default_stream_name() -> String {
    "BMP_CAUSAL".to_string()
}

fn default_subject_prefix() -> String {
    "bmp.events".to_string()
}

fn default_stream_max_bytes() -> i64 {
    10 * 1024 * 1024 * 1024
}

fn default_publish_timeout_ms() -> u64 {
    5_000
}

#[cfg(test)]
mod tests {
    use super::Config;

    #[test]
    fn resolved_subjects_include_wildcard() {
        let cfg = Config {
            nats_url: "nats://localhost:4222".to_string(),
            nats_domain: None,
            nats_creds_file: None,
            stream_name: "BMP_CAUSAL".to_string(),
            subject_prefix: "bmp.events".to_string(),
            stream_subjects: Some(vec!["bmp.events.peer".to_string()]),
            stream_max_bytes: 1,
            publish_timeout_ms: 100,
        };

        let subjects = cfg.stream_subjects_resolved();
        assert!(subjects.contains(&"bmp.events.>".to_string()));
        assert!(subjects.contains(&"bmp.events.peer".to_string()));
    }
}
