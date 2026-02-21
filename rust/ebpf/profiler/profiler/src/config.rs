use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};
use std::fs;
use std::path::Path;

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct Config {
    #[serde(default)]
    pub server: ServerConfig,
    pub grpc_tls: Option<GRPCTLSConfig>,
    #[serde(default)]
    pub profiler: ProfilerConfig,
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
pub struct ProfilerConfig {
    #[serde(default = "default_max_concurrent_sessions")]
    pub max_concurrent_sessions: u32,
    #[serde(default = "default_max_session_duration")]
    pub max_session_duration_seconds: i32,
    #[serde(default = "default_max_frequency")]
    pub max_frequency_hz: i32,
    #[serde(default = "default_chunk_size")]
    pub chunk_size_bytes: usize,
}

impl Default for ServerConfig {
    fn default() -> Self {
        Self {
            bind_address: default_bind_address(),
            port: default_port(),
        }
    }
}

impl Default for ProfilerConfig {
    fn default() -> Self {
        Self {
            max_concurrent_sessions: default_max_concurrent_sessions(),
            max_session_duration_seconds: default_max_session_duration(),
            max_frequency_hz: default_max_frequency(),
            chunk_size_bytes: default_chunk_size(),
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
    /// Tries: ./profiler.toml, /etc/serviceradar/profiler.toml, ~/.config/serviceradar/profiler.toml
    pub fn load_from_defaults() -> Result<Self> {
        let mut all_paths = vec![
            "./profiler.toml".to_string(),
            "/etc/serviceradar/profiler.toml".to_string(),
        ];

        // Add home directory path if available
        if let Ok(home) = std::env::var("HOME") {
            all_paths.push(format!("{home}/.config/serviceradar/profiler.toml"));
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

    /// Generate an example configuration file content
    pub fn example_toml() -> String {
        let example = Config {
            server: ServerConfig::default(),
            grpc_tls: Some(GRPCTLSConfig {
                cert_file: "/path/to/grpc-server.crt".to_string(),
                key_file: "/path/to/grpc-server.key".to_string(),
                ca_file: Some("/path/to/grpc-ca.pem".to_string()),
            }),
            profiler: ProfilerConfig::default(),
        };

        toml::to_string_pretty(&example)
            .unwrap_or_else(|_| "# Failed to generate example".to_string())
    }
}

// Default value functions
fn default_bind_address() -> String {
    "0.0.0.0".to_string()
}

fn default_port() -> u16 {
    8080
}

fn default_max_concurrent_sessions() -> u32 {
    10
}

fn default_max_session_duration() -> i32 {
    300 // 5 minutes
}

fn default_max_frequency() -> i32 {
    1000 // 1000 Hz
}

fn default_chunk_size() -> usize {
    64 * 1024 // 64KB
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
        assert_eq!(config.server.port, 8080);
        assert!(config.grpc_tls.is_none());
        assert_eq!(config.profiler.max_concurrent_sessions, 10);
        assert_eq!(config.profiler.max_session_duration_seconds, 300);
        assert_eq!(config.profiler.max_frequency_hz, 1000);
        assert_eq!(config.profiler.chunk_size_bytes, 64 * 1024);
    }

    #[test]
    fn test_config_from_toml() {
        let toml_content = r#"
[server]
bind_address = "127.0.0.1"
port = 9090

[profiler]
max_concurrent_sessions = 5
max_session_duration_seconds = 600
max_frequency_hz = 500
chunk_size_bytes = 32768
"#;

        let config: Config = toml::from_str(toml_content).unwrap();
        assert_eq!(config.server.bind_address, "127.0.0.1");
        assert_eq!(config.server.port, 9090);
        assert_eq!(config.profiler.max_concurrent_sessions, 5);
        assert_eq!(config.profiler.max_session_duration_seconds, 600);
        assert_eq!(config.profiler.max_frequency_hz, 500);
        assert_eq!(config.profiler.chunk_size_bytes, 32768);
    }

    #[test]
    fn test_config_from_file() {
        let toml_content = r#"
[server]
port = 9090

[grpc_tls]
cert_file = "/test.crt"
key_file = "/test.key"
"#;

        let mut temp_file = NamedTempFile::new().unwrap();
        temp_file.write_all(toml_content.as_bytes()).unwrap();

        let config = Config::from_file(temp_file.path()).unwrap();
        assert_eq!(config.server.port, 9090);
        assert_eq!(config.server.bind_address, "0.0.0.0"); // default

        let tls = config.grpc_tls.unwrap();
        assert_eq!(tls.cert_file, "/test.crt");
        assert_eq!(tls.key_file, "/test.key");
        assert!(tls.ca_file.is_none());
    }

    #[test]
    fn test_bind_address() {
        let config = Config {
            server: ServerConfig {
                bind_address: "127.0.0.1".to_string(),
                port: 8080,
            },
            grpc_tls: None,
            profiler: ProfilerConfig::default(),
        };

        assert_eq!(config.bind_address(), "127.0.0.1:8080");
    }

    #[test]
    fn test_example_toml_generation() {
        let example = Config::example_toml();
        assert!(example.contains("[server]"));
        assert!(example.contains("[grpc_tls]"));
        assert!(example.contains("[profiler]"));
        assert!(example.contains("bind_address"));
        assert!(example.contains("cert_file"));
        assert!(example.contains("max_concurrent_sessions"));
    }
}
