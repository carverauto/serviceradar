use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};
use std::fs;
use std::path::{Path, PathBuf};
use std::time::Duration;

use super::server_config::ServerConfig;
use super::nats_config_toml::NATSConfigTOML;
use super::grpc_tls_config::GRPCTLSConfig;
use super::metrics_config::MetricsConfig;
use super::nats_tls_config::NATSTLSConfig;
use crate::types::nats::nats_config::NATSConfig;

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct Config {
    #[serde(default)]
    pub server: ServerConfig,
    pub nats: Option<NATSConfigTOML>,
    pub grpc_tls: Option<GRPCTLSConfig>,
}

impl Config {
    /// Load configuration from a TOML file
    pub fn from_file<P: AsRef<Path>>(path: P) -> Result<Self> {
        let path = path.as_ref();
        let content = fs::read_to_string(path)
            .with_context(|| format!("Failed to read config file: {}", path.display()))?;

        let config: Config = toml::from_str(&content)
            .with_context(|| format!("Failed to parse config file: {}", path.display()))?;

        Ok(config)
    }

    /// Load configuration from the specified path, or search default locations if None
    pub fn load(config_path: Option<&str>) -> Result<Self> {
        // If a specific path is provided, use it
        if let Some(path) = config_path {
            println!("Loading config from specified path: {path}");
            return Self::from_file(path);
        }

        // Otherwise search default locations
        Self::load_from_defaults()
    }

    /// Load configuration from the default locations
    /// Tries: ./otel.toml, /etc/serviceradar/otel.toml, ~/.config/serviceradar/otel.toml
    pub fn load_from_defaults() -> Result<Self> {
        let mut all_paths = vec![
            "./otel.toml".to_string(),
            "/etc/serviceradar/otel.toml".to_string(),
        ];

        // Add home directory path if available
        if let Ok(home) = std::env::var("HOME") {
            all_paths.push(format!("{}/.config/serviceradar/otel.toml", home));
        }

        for path in &all_paths {
            if Path::new(path).exists() {
                println!("Loading config from: {path}");
                return Self::from_file(path);
            }
        }

        println!("No config file found, using defaults (searched: {:?})", all_paths);
        Ok(Self::default())
    }

    /// Get the full bind address (address:port)
    pub fn bind_address(&self) -> String {
        format!("{}:{}", self.server.bind_address, self.server.port)
    }

    /// Get the full metrics bind address (address:port) if metrics are enabled
    pub fn metrics_address(&self) -> Option<String> {
        self.server
            .metrics
            .as_ref()
            .map(|m| format!("{}:{}", m.bind_address, m.port))
    }

    /// Convert to NatsConfig if NATS is configured
    pub fn nats_config(&self) -> Option<NATSConfig> {
        self.nats.as_ref().map(|nats| {
            let (tls_cert, tls_key, tls_ca) = if let Some(ref tls) = nats.tls {
                (
                    Some(PathBuf::from(&tls.cert_file)),
                    Some(PathBuf::from(&tls.key_file)),
                    tls.ca_file.as_ref().map(PathBuf::from),
                )
            } else {
                (None, None, None)
            };
            let creds_file = nats.creds_file.as_ref().and_then(|value| {
                let trimmed = value.trim();
                if trimmed.is_empty() {
                    None
                } else {
                    Some(PathBuf::from(trimmed))
                }
            });

            NATSConfig {
                url: nats.url.clone(),
                subject: nats.subject.clone(),
                stream: nats.stream.clone(),
                logs_subject: nats.logs_subject.clone(),
                creds_file,
                timeout: Duration::from_secs(nats.timeout_secs),
                max_bytes: nats.max_bytes,
                max_age: Duration::from_secs(nats.max_age_secs),
                tls_cert,
                tls_key,
                tls_ca,
            }
        })
    }

    /// Generate an example configuration file content
    pub fn example_toml() -> String {
        let example = Config {
            server: ServerConfig {
                bind_address: "0.0.0.0".to_string(),
                port: 4317,
                metrics: Some(MetricsConfig {
                    bind_address: "0.0.0.0".to_string(),
                    port: 9090,
                }),
            },
            nats: Some(NATSConfigTOML {
                url: "nats://localhost:4222".to_string(),
                subject: "otel".to_string(),
                logs_subject: Some("logs.otel".to_string()),
                stream: "events".to_string(),
                creds_file: Some("/path/to/nats.creds".to_string()),
                timeout_secs: 30,
                max_bytes: 2 * 1024 * 1024 * 1024,
                max_age_secs: 30 * 60,
                tls: Some(NATSTLSConfig {
                    cert_file: "/path/to/nats-client.crt".to_string(),
                    key_file: "/path/to/nats-client.key".to_string(),
                    ca_file: Some("/path/to/nats-ca.crt".to_string()),
                }),
            }),
            grpc_tls: Some(GRPCTLSConfig {
                cert_file: "/path/to/grpc-server.crt".to_string(),
                key_file: "/path/to/grpc-server.key".to_string(),
                ca_file: Some("/path/to/grpc-ca.pem".to_string()),
            }),
        };

        toml::to_string_pretty(&example)
            .unwrap_or_else(|_| "# Failed to generate example".to_string())
    }
}
