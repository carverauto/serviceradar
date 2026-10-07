use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};
use std::net::SocketAddr;
use std::path::{Path, PathBuf};

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct SidekickConfig {
    #[serde(default = "default_listen_addr")]
    pub listen_addr: SocketAddr,
    #[serde(default = "default_sysfs_net_path")]
    pub sysfs_net_path: PathBuf,
    #[serde(default = "default_state_dir")]
    pub state_dir: PathBuf,
    #[serde(default)]
    pub interfaces: Vec<String>,
    #[serde(default)]
    pub api_token: Option<String>,
}

impl Default for SidekickConfig {
    fn default() -> Self {
        Self {
            listen_addr: default_listen_addr(),
            sysfs_net_path: default_sysfs_net_path(),
            state_dir: default_state_dir(),
            interfaces: Vec::new(),
            api_token: api_token_from_env(),
        }
    }
}

impl SidekickConfig {
    pub async fn load(path: impl AsRef<Path>) -> Result<Self> {
        let path = path.as_ref();
        let bytes = tokio::fs::read(path)
            .await
            .with_context(|| format!("failed to read config {}", path.display()))?;

        let raw = std::str::from_utf8(&bytes)
            .with_context(|| format!("config {} is not valid UTF-8", path.display()))?;

        let mut config: Self = toml::from_str(raw)
            .with_context(|| format!("failed to parse config {}", path.display()))?;
        config.api_token = select_api_token(
            config.api_token,
            std::env::var("SERVICERADAR_SIDEKICK_API_TOKEN").ok(),
        );

        Ok(config)
    }

    pub fn with_overrides(
        mut self,
        listen_addr: Option<SocketAddr>,
        sysfs_net_path: Option<PathBuf>,
    ) -> Self {
        if let Some(addr) = listen_addr {
            self.listen_addr = addr;
        }

        if let Some(path) = sysfs_net_path {
            self.sysfs_net_path = path;
        }

        self
    }
}

fn default_listen_addr() -> SocketAddr {
    "127.0.0.1:17321"
        .parse()
        .expect("default sidekick listen address must parse")
}

fn default_sysfs_net_path() -> PathBuf {
    PathBuf::from("/sys/class/net")
}

fn default_state_dir() -> PathBuf {
    PathBuf::from("/var/lib/serviceradar/fieldsurvey-sidekick")
}

fn api_token_from_env() -> Option<String> {
    select_api_token(
        None,
        std::env::var("SERVICERADAR_SIDEKICK_API_TOKEN").ok(),
    )
}

fn select_api_token(configured: Option<String>, environment: Option<String>) -> Option<String> {
    normalize_api_token(configured).or_else(|| normalize_api_token(environment))
}

fn normalize_api_token(token: Option<String>) -> Option<String> {
    let token = token?.trim().to_string();
    let normalized: String = token
        .chars()
        .filter(|character| character.is_ascii_alphanumeric())
        .flat_map(char::to_lowercase)
        .collect();

    if token.is_empty()
        || matches!(normalized.as_str(), "changeme" | "changeit" | "placeholder")
    {
        None
    } else {
        Some(token)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn defaults_bind_to_loopback() {
        let cfg = SidekickConfig::default();
        assert_eq!(cfg.listen_addr.ip().to_string(), "127.0.0.1");
        assert!(cfg.interfaces.is_empty());
    }

    #[test]
    fn placeholder_setup_tokens_are_unconfigured() {
        for token in [
            "change-me",
            " CHANGEME ",
            "change_it",
            "change it",
            "placeholder",
            "",
        ] {
            assert_eq!(normalize_api_token(Some(token.to_string())), None);
        }

        assert_eq!(
            normalize_api_token(Some("synthetic-setup-token".to_string())),
            Some("synthetic-setup-token".to_string())
        );
    }

    #[test]
    fn valid_environment_token_replaces_rejected_config_token() {
        assert_eq!(
            select_api_token(
                Some("change-me".to_string()),
                Some("synthetic-environment-token".to_string()),
            ),
            Some("synthetic-environment-token".to_string())
        );
        assert_eq!(
            select_api_token(
                Some("configured-token".to_string()),
                Some("environment-token".to_string()),
            ),
            Some("configured-token".to_string())
        );
    }
}
