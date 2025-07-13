use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};
use std::fs;
use std::path::{Path, PathBuf};
use std::time::Duration;

use crate::nats_output::NATSConfig;

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct Config {
    #[serde(default)]
    pub server: ServerConfig,
    pub nats: Option<NATSConfigTOML>,
    pub grpc_tls: Option<GRPCTLSConfig>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ServerConfig {
    #[serde(default = "default_bind_address")]
    pub bind_address: String,
    #[serde(default = "default_port")]
    pub port: u16,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct GRPCTLSConfig {
    pub cert_file: String,
    pub key_file: String,
    pub ca_file: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct NATSTLSConfig {
    pub cert_file: String,
    pub key_file: String,
    pub ca_file: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct NATSConfigTOML {
    pub url: String,
    #[serde(default = "default_nats_subject")]
    pub subject: String,
    #[serde(default = "default_nats_stream")]
    pub stream: String,
    #[serde(default = "default_timeout_secs")]
    pub timeout_secs: u64,
    pub tls: Option<NATSTLSConfig>,
}

impl Default for ServerConfig {
    fn default() -> Self {
        Self {
            bind_address: default_bind_address(),
            port: default_port(),
        }
    }
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
            all_paths.push(format!("{home}/.config/serviceradar/otel.toml"));
        }
        
        for path in &all_paths {
            if Path::new(path).exists() {
                println!("Loading config from: {path}");
                return Self::from_file(path);
            }
        }
        
        println!("No config file found, using defaults (searched: {all_paths:?})");
        Ok(Self::default())
    }
    
    /// Get the full bind address (address:port)
    pub fn bind_address(&self) -> String {
        format!("{}:{}", self.server.bind_address, self.server.port)
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
            
            NATSConfig {
                url: nats.url.clone(),
                subject: nats.subject.clone(),
                stream: nats.stream.clone(),
                timeout: Duration::from_secs(nats.timeout_secs),
                tls_cert,
                tls_key,
                tls_ca,
            }
        })
    }
    
    /// Generate an example configuration file content
    pub fn example_toml() -> String {
        let example = Config {
            server: ServerConfig::default(),
            nats: Some(NATSConfigTOML {
                url: "nats://localhost:4222".to_string(),
                subject: "events.otel".to_string(),
                stream: "events".to_string(),
                timeout_secs: 30,
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
        
        toml::to_string_pretty(&example).unwrap_or_else(|_| "# Failed to generate example".to_string())
    }
}

// Default value functions
fn default_bind_address() -> String {
    "0.0.0.0".to_string()
}

fn default_port() -> u16 {
    4317
}

fn default_nats_subject() -> String {
    "events.otel".to_string()
}

fn default_nats_stream() -> String {
    "events".to_string()
}

fn default_timeout_secs() -> u64 {
    30
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;
    use tempfile::NamedTempFile;

    #[test]
    fn test_default_config() {
        let config = Config::default();
        assert_eq!(config.server.bind_address, "0.0.0.0");
        assert_eq!(config.server.port, 4317);
        assert!(config.nats.is_none());
        assert!(config.grpc_tls.is_none());
    }

    #[test]
    fn test_config_from_toml() {
        let toml_content = r#"
[server]
bind_address = "127.0.0.1"
port = 8080

[nats]
url = "nats://test:4222"
subject = "test.otel"
stream = "test"
timeout_secs = 60
"#;
        
        let config: Config = toml::from_str(toml_content).unwrap();
        assert_eq!(config.server.bind_address, "127.0.0.1");
        assert_eq!(config.server.port, 8080);
        
        let nats = config.nats.unwrap();
        assert_eq!(nats.url, "nats://test:4222");
        assert_eq!(nats.subject, "test.otel");
        assert_eq!(nats.stream, "test");
        assert_eq!(nats.timeout_secs, 60);
    }

    #[test]
    fn test_config_from_file() {
        let toml_content = r#"
[server]
port = 9090

[nats]
url = "nats://localhost:4222"
"#;
        
        let mut temp_file = NamedTempFile::new().unwrap();
        temp_file.write_all(toml_content.as_bytes()).unwrap();
        
        let config = Config::from_file(temp_file.path()).unwrap();
        assert_eq!(config.server.port, 9090);
        assert_eq!(config.server.bind_address, "0.0.0.0"); // default
        
        let nats = config.nats.unwrap();
        assert_eq!(nats.url, "nats://localhost:4222");
        assert_eq!(nats.subject, "events.otel"); // default
    }

    #[test]
    fn test_config_load_with_path() {
        let toml_content = r#"
[server]
port = 8888

[nats]
url = "nats://test:4222"
"#;
        
        let mut temp_file = NamedTempFile::new().unwrap();
        temp_file.write_all(toml_content.as_bytes()).unwrap();
        
        let config = Config::load(Some(temp_file.path().to_str().unwrap())).unwrap();
        assert_eq!(config.server.port, 8888);
        
        let nats = config.nats.unwrap();
        assert_eq!(nats.url, "nats://test:4222");
    }

    #[test]
    fn test_config_load_without_path() {
        // This should search default locations and use defaults if not found
        let config = Config::load(None).unwrap_or_else(|_| Config::default());
        // Don't assert specific values since it might find an actual config file
        // Just ensure we get a valid config
        assert!(!config.server.bind_address.is_empty());
        assert!(config.server.port > 0);
    }

    #[test]
    fn test_bind_address() {
        let config = Config {
            server: ServerConfig {
                bind_address: "127.0.0.1".to_string(),
                port: 8080,
            },
            nats: None,
            grpc_tls: None,
        };
        
        assert_eq!(config.bind_address(), "127.0.0.1:8080");
    }

    #[test]
    fn test_grpc_tls_config_optional_ca() {
        let config = Config {
            server: ServerConfig::default(),
            nats: None,
            grpc_tls: Some(GRPCTLSConfig {
                cert_file: "/server.crt".to_string(),
                key_file: "/server.key".to_string(),
                ca_file: None,
            }),
        };
        
        let tls = config.grpc_tls.unwrap();
        assert_eq!(tls.cert_file, "/server.crt");
        assert_eq!(tls.key_file, "/server.key");
        assert!(tls.ca_file.is_none());
    }

    #[test]
    fn test_nats_tls_config_from_toml() {
        let toml_content = r#"
[server]
bind_address = "127.0.0.1"
port = 8080

[nats]
url = "nats://test:4222"
subject = "test.otel"

[nats.tls]
cert_file = "/path/to/nats-client.crt"
key_file = "/path/to/nats-client.key"
ca_file = "/path/to/nats-ca.crt"
"#;
        
        let config: Config = toml::from_str(toml_content).unwrap();
        let nats = config.nats.unwrap();
        let nats_tls = nats.tls.unwrap();
        assert_eq!(nats_tls.cert_file, "/path/to/nats-client.crt");
        assert_eq!(nats_tls.key_file, "/path/to/nats-client.key");
        assert_eq!(nats_tls.ca_file.unwrap(), "/path/to/nats-ca.crt");
    }

    #[test]
    fn test_separate_tls_configs() {
        let toml_content = r#"
[server]
bind_address = "127.0.0.1"
port = 8080

[nats]
url = "nats://test:4222"

[nats.tls]
cert_file = "/nats.crt"
key_file = "/nats.key"

[grpc_tls]
cert_file = "/grpc.crt"
key_file = "/grpc.key"
"#;
        
        let config: Config = toml::from_str(toml_content).unwrap();
        
        // Check NATS TLS
        let nats = config.nats.unwrap();
        let nats_tls = nats.tls.unwrap();
        assert_eq!(nats_tls.cert_file, "/nats.crt");
        assert_eq!(nats_tls.key_file, "/nats.key");
        
        // Check gRPC TLS
        let grpc_tls = config.grpc_tls.unwrap();
        assert_eq!(grpc_tls.cert_file, "/grpc.crt");
        assert_eq!(grpc_tls.key_file, "/grpc.key");
    }

    #[test]
    fn test_nats_config_conversion() {
        let config = Config {
            server: ServerConfig::default(),
            nats: Some(NATSConfigTOML {
                url: "nats://test:4222".to_string(),
                subject: "test.subject".to_string(),
                stream: "test_stream".to_string(),
                timeout_secs: 45,
                tls: Some(NATSTLSConfig {
                    cert_file: "/cert.pem".to_string(),
                    key_file: "/key.pem".to_string(),
                    ca_file: Some("/ca.pem".to_string()),
                }),
            }),
            grpc_tls: None,
        };
        
        let nats_config = config.nats_config().unwrap();
        assert_eq!(nats_config.url, "nats://test:4222");
        assert_eq!(nats_config.subject, "test.subject");
        assert_eq!(nats_config.stream, "test_stream");
        assert_eq!(nats_config.timeout, Duration::from_secs(45));
        assert_eq!(nats_config.tls_cert.unwrap(), PathBuf::from("/cert.pem"));
        assert_eq!(nats_config.tls_key.unwrap(), PathBuf::from("/key.pem"));
        assert_eq!(nats_config.tls_ca.unwrap(), PathBuf::from("/ca.pem"));
    }

    #[test]
    fn test_example_toml_generation() {
        let example = Config::example_toml();
        assert!(example.contains("[server]"));
        assert!(example.contains("[nats]"));
        assert!(example.contains("[grpc_tls]"));
        assert!(example.contains("bind_address"));
        assert!(example.contains("url"));
        assert!(example.contains("cert_file"));
        assert!(example.contains("key_file"));
    }

    #[test]
    fn test_grpc_tls_config_from_toml() {
        let toml_content = r#"
[server]
bind_address = "127.0.0.1"
port = 8080

[grpc_tls]
cert_file = "/path/to/server.crt"
key_file = "/path/to/server.key"
ca_file = "/path/to/ca.pem"
"#;
        
        let config: Config = toml::from_str(toml_content).unwrap();
        assert_eq!(config.server.bind_address, "127.0.0.1");
        assert_eq!(config.server.port, 8080);
        
        let tls = config.grpc_tls.unwrap();
        assert_eq!(tls.cert_file, "/path/to/server.crt");
        assert_eq!(tls.key_file, "/path/to/server.key");
        assert_eq!(tls.ca_file.unwrap(), "/path/to/ca.pem");
    }
}