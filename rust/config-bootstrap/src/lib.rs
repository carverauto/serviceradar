//! Configuration bootstrap library for ServiceRadar Rust services.
//!
//! This crate mirrors the functionality of Go's `pkg/config/bootstrap` to provide
//! a unified config loading experience across all ServiceRadar components:
//!
//! 1. Load config from disk (JSON or TOML)
//! 2. Overlay KV values (if present)
//! 3. Seed sanitized defaults to KV (when missing)
//! 4. Watch for KV changes and trigger reload hooks
//!
//! # Example
//!
//! ```rust,no_run
//! use config_bootstrap::{Bootstrap, BootstrapOptions, ConfigFormat};
//! use serde::{Deserialize, Serialize};
//!
//! #[derive(Debug, Serialize, Deserialize)]
//! struct MyConfig {
//!     listen_addr: String,
//!     log_level: String,
//! }
//!
//! #[tokio::main]
//! async fn main() -> Result<(), Box<dyn std::error::Error>> {
//!     let opts = BootstrapOptions {
//!         service_name: "my-service".to_string(),
//!         config_path: "/etc/serviceradar/my-service.toml".to_string(),
//!         format: ConfigFormat::Toml,
//!         kv_key: Some("config/my-service.toml".to_string()),
//!         seed_kv: true,
//!         watch_kv: false,
//!     };
//!
//!     let mut bootstrap = Bootstrap::new(opts).await?;
//!     let config: MyConfig = bootstrap.load().await?;
//!
//!     println!("Loaded config: {:?}", config);
//!     Ok(())
//! }
//! ```

mod restart;
mod sanitize;
mod watch;

pub use restart::RestartHandle;
pub use sanitize::{load_sanitization_rules, sanitize_toml, SanitizationRules, TomlPath};
pub use watch::ConfigWatcher;

use kvutil::{KvClient, KvError};
use serde::{Deserialize, Serialize};
use std::path::Path;
use thiserror::Error;

#[derive(Error, Debug)]
pub enum BootstrapError {
    #[error("failed to read config file: {0}")]
    ReadFile(#[from] std::io::Error),

    #[error("failed to parse JSON: {0}")]
    JsonParse(#[from] serde_json::Error),

    #[error("failed to parse TOML: {0}")]
    TomlParse(#[from] toml::de::Error),

    #[error("failed to serialize TOML: {0}")]
    TomlSerialize(#[from] toml::ser::Error),

    #[error("KV error: {0}")]
    Kv(#[from] KvError),

    #[error("config format mismatch: expected {expected}, got {actual}")]
    FormatMismatch { expected: String, actual: String },

    #[error("missing config: no file at {path} and no KV data")]
    MissingConfig { path: String },

    #[error("sanitization rules not loaded")]
    SanitizationRulesNotLoaded,
}

pub type Result<T> = std::result::Result<T, BootstrapError>;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ConfigFormat {
    Json,
    Toml,
}

impl ConfigFormat {
    pub fn as_str(&self) -> &str {
        match self {
            ConfigFormat::Json => "json",
            ConfigFormat::Toml => "toml",
        }
    }
}

/// Options for bootstrapping a service configuration.
#[derive(Debug, Clone)]
pub struct BootstrapOptions {
    /// Service name (e.g., "flowgger", "trapd")
    pub service_name: String,

    /// Path to the on-disk config file
    pub config_path: String,

    /// Config format (JSON or TOML)
    pub format: ConfigFormat,

    /// Optional KV key (if None, KV is not used)
    pub kv_key: Option<String>,

    /// Whether to seed sanitized config to KV when missing
    pub seed_kv: bool,

    /// Whether to watch KV for changes
    pub watch_kv: bool,
}

/// Main bootstrap coordinator.
pub struct Bootstrap {
    opts: BootstrapOptions,
    kv_client: Option<KvClient>,
    sanitization_rules: Option<SanitizationRules>,
}

impl Bootstrap {
    /// Create a new Bootstrap instance.
    ///
    /// If KV_ADDRESS is set, this will attempt to connect to the KV service.
    /// Connection failures are logged but not fatal (service can run from disk config only).
    pub async fn new(opts: BootstrapOptions) -> Result<Self> {
        let kv_client = if opts.kv_key.is_some() {
            match KvClient::connect_from_env().await {
                Ok(client) => {
                    tracing::info!(service = %opts.service_name, "connected to KV service");
                    Some(client)
                }
                Err(e) => {
                    tracing::warn!(
                        service = %opts.service_name,
                        error = %e,
                        "failed to connect to KV; running with disk config only"
                    );
                    None
                }
            }
        } else {
            None
        };

        // Load sanitization rules if we're going to seed KV
        let sanitization_rules = if opts.seed_kv {
            match load_sanitization_rules() {
                Ok(rules) => Some(rules),
                Err(e) => {
                    tracing::warn!(
                        error = %e,
                        "failed to load sanitization rules; KV seeding will use raw config"
                    );
                    None
                }
            }
        } else {
            None
        };

        Ok(Self {
            opts,
            kv_client,
            sanitization_rules,
        })
    }

    /// Load config following the bootstrap lifecycle:
    /// 1. Load from disk
    /// 2. Overlay KV (if present)
    /// 3. Seed to KV (if missing and seed_kv is true)
    pub async fn load<T>(&mut self) -> Result<T>
    where
        T: Serialize + for<'de> Deserialize<'de>,
    {
        // Step 1: Load from disk
        let mut config = self.load_from_disk::<T>().await?;

        // Step 2: Overlay KV if available
        let should_seed = if let Some(ref mut kv_client) = self.kv_client {
            if let Some(ref kv_key) = self.opts.kv_key {
                match kv_client.get(kv_key).await {
                    Ok(Some(kv_data)) => {
                        tracing::info!(
                            service = %self.opts.service_name,
                            kv_key = %kv_key,
                            "overlaying KV config"
                        );
                        self.overlay_kv(&mut config, &kv_data)?;
                        false
                    }
                    Ok(None) => {
                        // KV key doesn't exist - need to seed it
                        self.opts.seed_kv
                    }
                    Err(e) => {
                        tracing::warn!(
                            service = %self.opts.service_name,
                            kv_key = %kv_key,
                            error = %e,
                            "failed to fetch from KV; using disk config"
                        );
                        false
                    }
                }
            } else {
                false
            }
        } else {
            false
        };

        // Step 3: Seed to KV if needed (separate borrow scope)
        if should_seed {
            let sanitized = self.sanitize_config(&config)?;
            if let Some(ref mut kv_client) = self.kv_client {
                if let Some(ref kv_key) = self.opts.kv_key {
                    match kv_client.put(kv_key, sanitized).await {
                        Ok(_) => {
                            tracing::info!(
                                service = %self.opts.service_name,
                                kv_key = %kv_key,
                                "seeded sanitized config to KV"
                            );
                        }
                        Err(e) => {
                            tracing::warn!(
                                service = %self.opts.service_name,
                                error = %e,
                                "failed to seed config to KV"
                            );
                        }
                    }
                }
            }
        }

        Ok(config)
    }

    /// Start watching KV for changes. Returns a ConfigWatcher that the service can poll.
    pub async fn watch<T>(&mut self) -> Result<Option<ConfigWatcher<T>>>
    where
        T: Serialize + for<'de> Deserialize<'de> + Send + 'static,
    {
        if !self.opts.watch_kv {
            return Ok(None);
        }

        let Some(ref mut kv_client) = self.kv_client else {
            tracing::warn!(
                service = %self.opts.service_name,
                "watch requested but no KV client available"
            );
            return Ok(None);
        };

        let Some(ref kv_key) = self.opts.kv_key else {
            return Ok(None);
        };

        ConfigWatcher::new(
            kv_client,
            kv_key.clone(),
            self.opts.format,
            self.opts.service_name.clone(),
        )
        .await
        .map(Some)
    }

    async fn load_from_disk<T>(&self) -> Result<T>
    where
        T: for<'de> Deserialize<'de>,
    {
        let path = Path::new(&self.opts.config_path);

        if !path.exists() {
            return Err(BootstrapError::MissingConfig {
                path: self.opts.config_path.clone(),
            });
        }

        let data = tokio::fs::read(path).await?;

        match self.opts.format {
            ConfigFormat::Json => {
                let config: T = serde_json::from_slice(&data)?;
                Ok(config)
            }
            ConfigFormat::Toml => {
                let s = std::str::from_utf8(&data)
                    .map_err(|e| std::io::Error::new(std::io::ErrorKind::InvalidData, e))?;
                let config: T = toml::from_str(s)?;
                Ok(config)
            }
        }
    }

    fn overlay_kv<T>(&self, config: &mut T, kv_data: &[u8]) -> Result<()>
    where
        T: Serialize + for<'de> Deserialize<'de>,
    {
        match self.opts.format {
            ConfigFormat::Json => {
                kvutil::overlay_json(config, kv_data)?;
            }
            ConfigFormat::Toml => {
                kvutil::overlay_toml(config, kv_data)?;
            }
        }
        Ok(())
    }

    fn sanitize_config<T>(&self, config: &T) -> Result<Vec<u8>>
    where
        T: Serialize,
    {
        match self.opts.format {
            ConfigFormat::Json => {
                // For JSON, just serialize as-is (sensitive field filtering happens in Go layer)
                // Rust services typically use TOML, so JSON sanitization is less critical
                Ok(serde_json::to_vec(config)?)
            }
            ConfigFormat::Toml => {
                let toml_str = toml::to_string(config)?;

                if let Some(ref rules) = self.sanitization_rules {
                    let sanitized = sanitize_toml(toml_str.as_bytes(), &rules.toml_deny_list);
                    Ok(sanitized)
                } else {
                    // No rules loaded - use raw config
                    tracing::warn!(
                        service = %self.opts.service_name,
                        "sanitizing TOML without rules; sensitive data may leak to KV"
                    );
                    Ok(toml_str.into_bytes())
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;
    use tempfile::NamedTempFile;

    #[derive(Debug, Serialize, Deserialize, PartialEq)]
    struct TestConfig {
        listen_addr: String,
        log_level: String,
        #[serde(default)]
        token: String,
    }

    #[tokio::test]
    async fn test_load_from_disk_json() {
        let mut file = NamedTempFile::new().unwrap();
        writeln!(
            file,
            r#"{{"listen_addr": "0.0.0.0:8080", "log_level": "info"}}"#
        )
        .unwrap();

        let opts = BootstrapOptions {
            service_name: "test".to_string(),
            config_path: file.path().to_str().unwrap().to_string(),
            format: ConfigFormat::Json,
            kv_key: None,
            seed_kv: false,
            watch_kv: false,
        };

        let mut bootstrap = Bootstrap::new(opts).await.unwrap();
        let config: TestConfig = bootstrap.load().await.unwrap();

        assert_eq!(config.listen_addr, "0.0.0.0:8080");
        assert_eq!(config.log_level, "info");
    }

    #[tokio::test]
    async fn test_load_from_disk_toml() {
        let mut file = NamedTempFile::new().unwrap();
        writeln!(
            file,
            r#"
listen_addr = "0.0.0.0:9090"
log_level = "debug"
"#
        )
        .unwrap();

        let opts = BootstrapOptions {
            service_name: "test".to_string(),
            config_path: file.path().to_str().unwrap().to_string(),
            format: ConfigFormat::Toml,
            kv_key: None,
            seed_kv: false,
            watch_kv: false,
        };

        let mut bootstrap = Bootstrap::new(opts).await.unwrap();
        let config: TestConfig = bootstrap.load().await.unwrap();

        assert_eq!(config.listen_addr, "0.0.0.0:9090");
        assert_eq!(config.log_level, "debug");
    }

    #[tokio::test]
    async fn test_missing_config_file() {
        let opts = BootstrapOptions {
            service_name: "test".to_string(),
            config_path: "/nonexistent/path.json".to_string(),
            format: ConfigFormat::Json,
            kv_key: None,
            seed_kv: false,
            watch_kv: false,
        };

        let mut bootstrap = Bootstrap::new(opts).await.unwrap();
        let result: Result<TestConfig> = bootstrap.load().await;

        assert!(matches!(result, Err(BootstrapError::MissingConfig { .. })));
    }
}
