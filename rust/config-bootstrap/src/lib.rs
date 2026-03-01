//! Configuration bootstrap library for ServiceRadar Rust services.
//!
//! This crate mirrors the file-based portion of Go's `pkg/config/bootstrap` to provide
//! a unified config loading experience across ServiceRadar components:
//!
//! 1. Load config from disk (JSON or TOML)
//! 2. Overlay a pinned filesystem config (if provided) so sensitive values win
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
//!         pinned_path: config_bootstrap::pinned_path_from_env(),
//!     };
//!
//!     let mut bootstrap = Bootstrap::new(opts).await?;
//!     let config: MyConfig = bootstrap.load().await?;
//!
//!     println!("Loaded config: {:?}", config);
//!     Ok(())
//! }
//! ```

use serde::{Deserialize, Serialize};
use std::env;
use std::fs;
use std::path::Path;

pub mod errors;
pub mod types;

pub use errors::{BootstrapError, Result};
pub use types::{BootstrapOptions, ConfigFormat};


/// Derive a trimmed pinned config path from the `PINNED_CONFIG_PATH` environment variable.
pub fn pinned_path_from_env() -> Option<String> {
    env::var("PINNED_CONFIG_PATH")
        .ok()
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
}


/// Main bootstrap coordinator.
pub struct Bootstrap {
    opts: BootstrapOptions,
}

impl Bootstrap {
    /// Create a new Bootstrap instance.
    pub async fn new(mut opts: BootstrapOptions) -> Result<Self> {
        opts.pinned_path = opts
            .pinned_path
            .as_ref()
            .map(|p| p.trim().to_string())
            .filter(|p| !p.is_empty());

        Ok(Self { opts })
    }

    /// Load config following the bootstrap lifecycle:
    /// 1. Load from disk
    /// 2. Overlay pinned file (if provided)
    pub async fn load<T>(&mut self) -> Result<T>
    where
        T: Serialize + for<'de> Deserialize<'de>,
    {
        // Step 1: Load from disk
        let mut config = self.load_from_disk::<T>().await?;

        // Step 2: Overlay pinned file last so it wins over defaults.
        if let Some(ref pinned) = self.opts.pinned_path {
            if !pinned.is_empty() {
                tracing::info!(
                    service = %self.opts.service_name,
                    pinned = %pinned,
                    "applying pinned config"
                );
                self.overlay_pinned(&mut config, pinned)?;
            }
        }

        Ok(config)
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

    fn overlay_pinned<T>(&self, config: &mut T, pinned_path: &str) -> Result<()>
    where
        T: Serialize + for<'de> Deserialize<'de>,
    {
        let data = fs::read(pinned_path).map_err(|e| {
            tracing::warn!(pinned = %pinned_path, error = %e, "failed to read pinned config");
            e
        })?;

        match self.opts.format {
            ConfigFormat::Json => {
                kvutil::overlay_json(config, &data)?;
            }
            ConfigFormat::Toml => {
                kvutil::overlay_toml(config, &data)?;
            }
        }

        Ok(())
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
        file.write_all(br#"{"listen_addr": "0.0.0.0:8080", "log_level": "info"}"#)
            .unwrap();

        let opts = BootstrapOptions {
            service_name: "test".to_string(),
            config_path: file.path().to_str().unwrap().to_string(),
            format: ConfigFormat::Json,
            pinned_path: None,
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
            pinned_path: None,
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
            pinned_path: None,
        };

        let mut bootstrap = Bootstrap::new(opts).await.unwrap();
        let result: Result<TestConfig> = bootstrap.load().await;

        assert!(matches!(result, Err(BootstrapError::MissingConfig { .. })));
    }
}
