use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};
use std::fs;
use std::path::{Path, PathBuf};
use std::time::Duration;

use crate::nats::NATSConfig;

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
    /// Maximum accepted OTLP export request size in bytes. Applied as the
    /// gRPC decode limit and the OTLP/HTTP body limit. Defaults to 64 MiB.
    #[serde(default = "default_max_request_bytes")]
    pub max_request_bytes: usize,
    #[serde(default)]
    pub metrics: Option<MetricsConfig>,
    /// OTLP/HTTP listener (port 4318 by default, enabled by default).
    #[serde(default)]
    pub http: HttpConfig,
}

/// OTLP/HTTP listener configuration (`[server.http]`).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HttpConfig {
    /// Whether to expose the OTLP/HTTP listener (default: true).
    #[serde(default = "default_http_enabled")]
    pub enabled: bool,
    #[serde(default = "default_bind_address")]
    pub bind_address: String,
    /// Standard OTLP/HTTP port (default: 4318).
    #[serde(default = "default_http_port")]
    pub port: u16,
    /// CORS origins allowed for browser-based OTLP exporters. The default
    /// `["*"]` allows any origin; restrict this when exposing the listener
    /// publicly.
    #[serde(default = "default_allowed_origins")]
    pub allowed_origins: Vec<String>,
    /// Whether the OTLP/HTTP listener serves TLS (default: true). When true
    /// the listener reuses the `[grpc_tls]` server certificate if one is
    /// configured (plaintext otherwise, preserving previous behavior). Set
    /// to false to force plaintext HTTP even when `[grpc_tls]` is set — for
    /// running behind a TLS-terminating gateway in-cluster.
    #[serde(default = "default_http_tls_enabled")]
    pub tls_enabled: bool,
}

impl Default for HttpConfig {
    fn default() -> Self {
        Self {
            enabled: default_http_enabled(),
            bind_address: default_bind_address(),
            port: default_http_port(),
            allowed_origins: default_allowed_origins(),
            tls_enabled: default_http_tls_enabled(),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MetricsConfig {
    #[serde(default = "default_metrics_bind_address")]
    pub bind_address: String,
    #[serde(default = "default_metrics_port")]
    pub port: u16,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct GRPCTLSConfig {
    pub cert_file: String,
    pub key_file: String,
    pub ca_file: Option<String>,
    /// Client certificate policy when `ca_file` is set:
    /// - "required": clients must present a certificate signed by the CA
    ///   (mTLS; the default, preserving previous behavior).
    /// - "optional": client certificates are verified when presented, but
    ///   connections without one are accepted. Useful when the same listener
    ///   serves internal mTLS clients and external OTLP producers.
    /// - "none": never request client certificates, even if `ca_file` is set.
    ///   Use this when exposing external ingest with server-side TLS only.
    #[serde(default)]
    pub client_auth: ClientAuthMode,
}

/// Client certificate policy for the gRPC TLS listener.
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq, Default)]
#[serde(rename_all = "lowercase")]
pub enum ClientAuthMode {
    #[default]
    Required,
    Optional,
    None,
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
    #[serde(default)]
    pub logs_subject: Option<String>,
    #[serde(default = "default_nats_stream")]
    pub stream: String,
    #[serde(default)]
    pub creds_file: Option<String>,
    #[serde(default = "default_timeout_secs")]
    pub timeout_secs: u64,
    #[serde(default = "default_max_bytes")]
    pub max_bytes: i64,
    #[serde(default = "default_max_age_secs")]
    pub max_age_secs: u64,
    #[serde(default = "default_stream_replicas")]
    pub stream_replicas: usize,
    /// Maximum number of concurrently in-flight JetStream chunk publishes
    /// across all export requests (per-request chunk order stays
    /// sequential). Bounds publish fan-out under multi-producer load.
    /// Defaults to 32.
    #[serde(default = "default_max_inflight_publishes")]
    pub max_inflight_publishes: usize,
    pub tls: Option<NATSTLSConfig>,
}

impl Default for ServerConfig {
    fn default() -> Self {
        Self {
            bind_address: default_bind_address(),
            port: default_port(),
            max_request_bytes: default_max_request_bytes(),
            metrics: None,
            http: HttpConfig::default(),
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

    /// Get the full OTLP/HTTP bind address (address:port)
    pub fn http_address(&self) -> String {
        format!(
            "{}:{}",
            self.server.http.bind_address, self.server.http.port
        )
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
                stream_replicas: nats.stream_replicas,
                tls_cert,
                tls_key,
                tls_ca,
                max_inflight_publishes: nats.max_inflight_publishes,
            }
        })
    }

    /// Generate an example configuration file content
    pub fn example_toml() -> String {
        let example = Config {
            server: ServerConfig {
                bind_address: default_bind_address(),
                port: default_port(),
                max_request_bytes: default_max_request_bytes(),
                metrics: Some(MetricsConfig {
                    bind_address: default_metrics_bind_address(),
                    port: default_metrics_port(),
                }),
                http: HttpConfig::default(),
            },
            nats: Some(NATSConfigTOML {
                url: "nats://localhost:4222".to_string(),
                subject: "otel".to_string(),
                logs_subject: Some("logs.otel".to_string()),
                stream: "events".to_string(),
                creds_file: Some("/path/to/nats.creds".to_string()),
                timeout_secs: 30,
                max_bytes: default_max_bytes(),
                max_age_secs: default_max_age_secs(),
                stream_replicas: default_stream_replicas(),
                max_inflight_publishes: default_max_inflight_publishes(),
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
                client_auth: ClientAuthMode::Required,
            }),
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
    4317
}

fn default_nats_subject() -> String {
    "otel".to_string()
}

fn default_nats_stream() -> String {
    "events".to_string()
}

fn default_timeout_secs() -> u64 {
    30
}

fn default_max_bytes() -> i64 {
    2 * 1024 * 1024 * 1024 // 2 GiB
}

fn default_max_age_secs() -> u64 {
    30 * 60 // 30 minutes
}

fn default_stream_replicas() -> usize {
    1
}

fn default_max_inflight_publishes() -> usize {
    crate::nats::DEFAULT_MAX_INFLIGHT_PUBLISHES
}

fn default_metrics_bind_address() -> String {
    "0.0.0.0".to_string()
}

fn default_metrics_port() -> u16 {
    9090
}

fn default_max_request_bytes() -> usize {
    64 * 1024 * 1024 // 64 MiB
}

fn default_http_enabled() -> bool {
    true
}

fn default_http_tls_enabled() -> bool {
    true
}

fn default_http_port() -> u16 {
    4318
}

fn default_allowed_origins() -> Vec<String> {
    vec!["*".to_string()]
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
        assert_eq!(nats.subject, "otel"); // default
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
                ..ServerConfig::default()
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
                client_auth: ClientAuthMode::default(),
            }),
        };

        let tls = config.grpc_tls.unwrap();
        assert_eq!(tls.cert_file, "/server.crt");
        assert_eq!(tls.key_file, "/server.key");
        assert!(tls.ca_file.is_none());
        assert_eq!(tls.client_auth, ClientAuthMode::Required);
    }

    #[test]
    fn test_max_request_bytes_defaults_to_64mib() {
        let config: Config = toml::from_str("").unwrap();
        assert_eq!(config.server.max_request_bytes, 64 * 1024 * 1024);
    }

    #[test]
    fn test_max_request_bytes_parses_from_toml() {
        let toml_content = r#"
[server]
max_request_bytes = 1048576
"#;
        let config: Config = toml::from_str(toml_content).unwrap();
        assert_eq!(config.server.max_request_bytes, 1024 * 1024);
    }

    #[test]
    fn test_http_listener_defaults() {
        let config: Config = toml::from_str("").unwrap();
        assert!(config.server.http.enabled);
        assert_eq!(config.server.http.bind_address, "0.0.0.0");
        assert_eq!(config.server.http.port, 4318);
        assert_eq!(config.server.http.allowed_origins, vec!["*".to_string()]);
        assert!(config.server.http.tls_enabled);
        assert_eq!(config.http_address(), "0.0.0.0:4318");
    }

    #[test]
    fn test_http_listener_parses_from_toml() {
        let toml_content = r#"
[server.http]
enabled = false
bind_address = "127.0.0.1"
port = 4319
allowed_origins = ["https://app.example.com", "https://ops.example.com"]
tls_enabled = false
"#;
        let config: Config = toml::from_str(toml_content).unwrap();
        assert!(!config.server.http.enabled);
        assert_eq!(config.server.http.bind_address, "127.0.0.1");
        assert_eq!(config.server.http.port, 4319);
        assert!(!config.server.http.tls_enabled);
        assert_eq!(
            config.server.http.allowed_origins,
            vec![
                "https://app.example.com".to_string(),
                "https://ops.example.com".to_string()
            ]
        );
    }

    #[test]
    fn test_client_auth_defaults_to_required() {
        let toml_content = r#"
[grpc_tls]
cert_file = "/grpc.crt"
key_file = "/grpc.key"
ca_file = "/ca.pem"
"#;
        let config: Config = toml::from_str(toml_content).unwrap();
        assert_eq!(
            config.grpc_tls.unwrap().client_auth,
            ClientAuthMode::Required
        );
    }

    #[test]
    fn test_client_auth_parses_all_modes() {
        for (raw, expected) in [
            ("required", ClientAuthMode::Required),
            ("optional", ClientAuthMode::Optional),
            ("none", ClientAuthMode::None),
        ] {
            let toml_content = format!(
                r#"
[grpc_tls]
cert_file = "/grpc.crt"
key_file = "/grpc.key"
ca_file = "/ca.pem"
client_auth = "{raw}"
"#
            );
            let config: Config = toml::from_str(&toml_content).unwrap();
            assert_eq!(config.grpc_tls.unwrap().client_auth, expected, "{raw}");
        }
    }

    #[test]
    fn test_client_auth_rejects_unknown_mode() {
        let toml_content = r#"
[grpc_tls]
cert_file = "/grpc.crt"
key_file = "/grpc.key"
client_auth = "sometimes"
"#;
        assert!(toml::from_str::<Config>(toml_content).is_err());
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
                logs_subject: None,
                stream: "test_stream".to_string(),
                creds_file: None,
                timeout_secs: 45,
                max_bytes: default_max_bytes(),
                max_age_secs: default_max_age_secs(),
                stream_replicas: default_stream_replicas(),
                max_inflight_publishes: 8,
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
        assert_eq!(nats_config.max_bytes, default_max_bytes());
        assert_eq!(
            nats_config.max_age,
            Duration::from_secs(default_max_age_secs())
        );
        assert_eq!(nats_config.tls_cert.unwrap(), PathBuf::from("/cert.pem"));
        assert_eq!(nats_config.tls_key.unwrap(), PathBuf::from("/key.pem"));
        assert_eq!(nats_config.tls_ca.unwrap(), PathBuf::from("/ca.pem"));
        assert_eq!(nats_config.max_inflight_publishes, 8);
    }

    #[test]
    fn test_max_inflight_publishes_defaults_to_32() {
        let toml_content = r#"
[nats]
url = "nats://test:4222"
"#;
        let config: Config = toml::from_str(toml_content).unwrap();
        assert_eq!(config.nats.unwrap().max_inflight_publishes, 32);
    }

    #[test]
    fn test_max_inflight_publishes_parses_from_toml() {
        let toml_content = r#"
[nats]
url = "nats://test:4222"
max_inflight_publishes = 4
"#;
        let config: Config = toml::from_str(toml_content).unwrap();
        assert_eq!(config.nats.unwrap().max_inflight_publishes, 4);
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
