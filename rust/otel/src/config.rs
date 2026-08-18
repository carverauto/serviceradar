use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;

use tempfile::TempDir;

use crate::nats::NATSConfig;

/// Resolved NATS client TLS material: `(cert, key, ca, scratch_dir)`.
///
/// The fourth element is the `TempDir` that inline `*_pem` values were written
/// into, and it is load-bearing rather than incidental: the first three are
/// paths INTO it, so dropping it deletes the files out from under the client.
/// Callers keep it alive for as long as the connection may reconnect.
type MaterializedTls = (
    Option<PathBuf>,
    Option<PathBuf>,
    Option<PathBuf>,
    Option<Arc<TempDir>>,
);

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct Config {
    #[serde(default)]
    pub server: ServerConfig,
    pub nats: Option<NATSConfigTOML>,
    pub grpc_tls: Option<GRPCTLSConfig>,
    /// Token-based ingestion authentication for both OTLP listeners
    /// (`[auth]`). Disabled by default for trusted networks.
    #[serde(default)]
    pub auth: AuthConfig,
    /// Output backend selection (`[output]`). Defaults to the JetStream
    /// backend, preserving existing deployments.
    #[serde(default)]
    pub output: OutputConfig,
    /// Agent-forward spool settings (`[agent_forward]`), used when
    /// `output.backend = "agent"`. Optional: defaults apply when omitted.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub agent_forward: Option<AgentForwardConfig>,
}

/// `[output]` — selects the [`crate::output::TelemetryOutput`] backend the
/// collector publishes through (design D8).
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, Default)]
pub struct OutputConfig {
    #[serde(default)]
    pub backend: OutputBackend,
}

/// The configured output backend.
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq, Default)]
#[serde(rename_all = "lowercase")]
pub enum OutputBackend {
    /// JetStream publish (central deployment / NATS leaf at the edge).
    #[default]
    Jetstream,
    /// Edge add-on shape: chunks are spooled durably and relayed through the
    /// local serviceradar-agent (`AddonService.RelayOtlp`).
    Agent,
    /// Reserved (design D8): direct OTLP re-export to a central endpoint.
    /// Parsing is allowed so configs can be staged ahead of support, but
    /// selecting it fails at startup until implemented.
    Otlp,
}

/// `[agent_forward]` — durable relay spool settings for the `agent` backend.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct AgentForwardConfig {
    /// Directory holding spool segments + the watermark file.
    #[serde(default = "default_spool_dir")]
    pub spool_dir: String,
    /// Total spool budget in bytes before oldest-segment eviction
    /// (default 256 MiB).
    #[serde(default = "default_spool_max_bytes")]
    pub max_bytes: u64,
    /// Optional age bound in seconds for spooled-but-unacked segments.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub max_age_secs: Option<u64>,
    /// Free-disk floor in bytes (default 512 MiB; 0 disables): when the
    /// spool volume's available space drops below this, the spool behaves
    /// as bound-reached (evict-oldest, counted rejection) instead of
    /// filling the disk.
    #[serde(default = "default_min_free_disk_bytes")]
    pub min_free_disk_bytes: u64,
}

impl Default for AgentForwardConfig {
    fn default() -> Self {
        Self {
            spool_dir: default_spool_dir(),
            max_bytes: default_spool_max_bytes(),
            max_age_secs: None,
            min_free_disk_bytes: default_min_free_disk_bytes(),
        }
    }
}

impl AgentForwardConfig {
    /// Converts the TOML/JSON section into the spool runtime configuration.
    pub fn spool_config(&self) -> crate::agent_forward::spool::SpoolConfig {
        crate::agent_forward::spool::SpoolConfig {
            dir: PathBuf::from(&self.spool_dir),
            max_bytes: self.max_bytes,
            max_age: self.max_age_secs.map(Duration::from_secs),
            segment_max_bytes: crate::agent_forward::spool::DEFAULT_SEGMENT_MAX_BYTES,
            min_free_disk_bytes: self.min_free_disk_bytes,
        }
    }
}

/// Ingestion authentication (`[auth]`) for the OTLP/gRPC and OTLP/HTTP
/// listeners. When `enabled`, every export must present a configured token
/// via the `x-serviceradar-ingestion-key` header/metadata key (or
/// `authorization: Bearer <token>`); the matched entry's identity is stamped
/// on published NATS messages (`Sr-Ingest-Identity`) for downstream
/// attribution.
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct AuthConfig {
    /// Enforce ingestion authentication (default: false). Tokens listed
    /// below still resolve identities when enforcement is off.
    #[serde(default)]
    pub enabled: bool,
    /// Accepted tokens and the sender identity each maps to.
    #[serde(default)]
    pub tokens: Vec<AuthTokenEntry>,
}

/// One accepted ingestion token (`[[auth.tokens]]`): exactly one of `token`
/// (inline) or `token_file` (path whose trimmed contents are the token —
/// the same file-based secret idiom as NATS creds/TLS keys) must be set.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AuthTokenEntry {
    /// Identity attributed to exports authenticated with this token.
    pub identity: String,
    /// Inline token value.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub token: Option<String>,
    /// Path to a file containing the token (trimmed on load). Preferred for
    /// secret-managed deployments (e.g. Kubernetes Secret volumes).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub token_file: Option<String>,
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
    /// Ephemeral assignment-scoped material injected by the control plane.
    /// These fields are never written to the base onboarding bundle.
    #[serde(default)]
    pub cert_pem: Option<String>,
    #[serde(default)]
    pub key_pem: Option<String>,
    #[serde(default)]
    pub ca_pem: Option<String>,
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
    pub fn nats_config(&self) -> Result<Option<NATSConfig>> {
        self.nats
            .as_ref()
            .map(|nats| {
                let (tls_cert, tls_key, tls_ca, tls_material_dir) =
                    Self::materialize_tls(nats.tls.as_ref())?;
                let creds_file = nats.creds_file.as_ref().and_then(|value| {
                    let trimmed = value.trim();
                    if trimmed.is_empty() {
                        None
                    } else {
                        Some(PathBuf::from(trimmed))
                    }
                });

                Ok(NATSConfig {
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
                    tls_material_dir,
                    max_inflight_publishes: nats.max_inflight_publishes,
                })
            })
            .transpose()
    }
    fn materialize_tls(tls: Option<&NATSTLSConfig>) -> Result<MaterializedTls> {
        let Some(tls) = tls else {
            return Ok((None, None, None, None));
        };

        let inline = [&tls.cert_pem, &tls.key_pem, &tls.ca_pem];
        let inline_count = inline.iter().filter(|value| value.is_some()).count();

        if inline_count != 0 {
            if inline_count != inline.len()
                || inline
                    .iter()
                    .any(|value| value.as_deref().map(str::is_empty).unwrap_or(true))
            {
                anyhow::bail!(
                    "NATS inline TLS material must include non-empty cert_pem, key_pem, and ca_pem"
                );
            }

            let dir = Arc::new(tempfile::tempdir().context("create ephemeral NATS TLS directory")?);
            let cert =
                Self::write_tls_material(&dir, "client.pem", tls.cert_pem.as_deref().unwrap())?;
            let key =
                Self::write_tls_material(&dir, "client-key.pem", tls.key_pem.as_deref().unwrap())?;
            let ca = Self::write_tls_material(&dir, "ca.pem", tls.ca_pem.as_deref().unwrap())?;
            return Ok((Some(cert), Some(key), Some(ca), Some(dir)));
        }

        Ok((
            Some(PathBuf::from(&tls.cert_file)),
            Some(PathBuf::from(&tls.key_file)),
            tls.ca_file.as_ref().map(PathBuf::from),
            None,
        ))
    }

    fn write_tls_material(dir: &TempDir, name: &str, contents: &str) -> Result<PathBuf> {
        let path = dir.path().join(name);
        fs::write(&path, contents)
            .with_context(|| format!("write ephemeral NATS TLS file {}", path.display()))?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            fs::set_permissions(&path, fs::Permissions::from_mode(0o600))?;
        }
        Ok(path)
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
                    cert_pem: None,
                    key_pem: None,
                    ca_pem: None,
                }),
            }),
            grpc_tls: Some(GRPCTLSConfig {
                cert_file: "/path/to/grpc-server.crt".to_string(),
                key_file: "/path/to/grpc-server.key".to_string(),
                ca_file: Some("/path/to/grpc-ca.pem".to_string()),
                client_auth: ClientAuthMode::Required,
            }),
            auth: AuthConfig {
                enabled: false,
                tokens: vec![AuthTokenEntry {
                    identity: "tenant-a".to_string(),
                    token: Some("replace-with-ingestion-key".to_string()),
                    token_file: None,
                }],
            },
            output: OutputConfig::default(),
            agent_forward: None,
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

fn default_spool_dir() -> String {
    "/var/lib/serviceradar/otel-spool".to_string()
}

fn default_spool_max_bytes() -> u64 {
    crate::agent_forward::spool::DEFAULT_SPOOL_MAX_BYTES
}

fn default_min_free_disk_bytes() -> u64 {
    crate::agent_forward::spool::DEFAULT_MIN_FREE_DISK_BYTES
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
            auth: AuthConfig::default(),
            ..Default::default()
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
            auth: AuthConfig::default(),
            ..Default::default()
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
                    cert_pem: None,
                    key_pem: None,
                    ca_pem: None,
                }),
            }),
            grpc_tls: None,
            auth: AuthConfig::default(),
            ..Default::default()
        };

        let nats_config = config.nats_config().unwrap().unwrap();
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
    fn test_inline_nats_tls_material_is_ephemeral_and_private() {
        let config = Config {
            nats: Some(NATSConfigTOML {
                url: "tls://leaf.example:4222".to_string(),
                subject: default_nats_subject(),
                logs_subject: None,
                stream: default_nats_stream(),
                creds_file: None,
                timeout_secs: default_timeout_secs(),
                max_bytes: default_max_bytes(),
                max_age_secs: default_max_age_secs(),
                stream_replicas: default_stream_replicas(),
                max_inflight_publishes: default_max_inflight_publishes(),
                tls: Some(NATSTLSConfig {
                    cert_file: "/ignored/cert.pem".to_string(),
                    key_file: "/ignored/key.pem".to_string(),
                    ca_file: Some("/ignored/ca.pem".to_string()),
                    cert_pem: Some("CERTIFICATE".to_string()),
                    key_pem: Some("PRIVATE KEY".to_string()),
                    ca_pem: Some("CA".to_string()),
                }),
            }),
            ..Default::default()
        };

        let nats = config.nats_config().unwrap().unwrap();
        let cert = nats.tls_cert.clone().unwrap();
        let key = nats.tls_key.clone().unwrap();
        let ca = nats.tls_ca.clone().unwrap();

        assert_eq!(std::fs::read_to_string(&cert).unwrap(), "CERTIFICATE");
        assert_eq!(std::fs::read_to_string(&key).unwrap(), "PRIVATE KEY");
        assert_eq!(std::fs::read_to_string(&ca).unwrap(), "CA");

        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            assert_eq!(
                std::fs::metadata(&key).unwrap().permissions().mode() & 0o777,
                0o600
            );
        }

        drop(nats);
        assert!(!cert.exists());
        assert!(!key.exists());
        assert!(!ca.exists());
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
    fn test_auth_defaults_to_disabled_with_no_tokens() {
        let config: Config = toml::from_str("").unwrap();
        assert!(!config.auth.enabled);
        assert!(config.auth.tokens.is_empty());
    }

    #[test]
    fn test_auth_parses_inline_token_array() {
        let toml_content = r#"
[auth]
enabled = true
tokens = [
    { token = "secret-a", identity = "tenant-a" },
    { token_file = "/etc/serviceradar/ingest-auth/key", identity = "tenant-b" },
]
"#;
        let config: Config = toml::from_str(toml_content).unwrap();
        assert!(config.auth.enabled);
        assert_eq!(config.auth.tokens.len(), 2);
        assert_eq!(config.auth.tokens[0].identity, "tenant-a");
        assert_eq!(config.auth.tokens[0].token.as_deref(), Some("secret-a"));
        assert!(config.auth.tokens[0].token_file.is_none());
        assert_eq!(config.auth.tokens[1].identity, "tenant-b");
        assert!(config.auth.tokens[1].token.is_none());
        assert_eq!(
            config.auth.tokens[1].token_file.as_deref(),
            Some("/etc/serviceradar/ingest-auth/key")
        );
    }

    #[test]
    fn test_auth_parses_array_of_tables() {
        let toml_content = r#"
[auth]
enabled = false

[[auth.tokens]]
identity = "tenant-a"
token = "secret-a"
"#;
        let config: Config = toml::from_str(toml_content).unwrap();
        assert!(!config.auth.enabled);
        assert_eq!(config.auth.tokens.len(), 1);
        assert_eq!(config.auth.tokens[0].identity, "tenant-a");
    }

    #[test]
    fn test_auth_entry_requires_identity() {
        let toml_content = r#"
[auth]
enabled = true
tokens = [{ token = "secret-a" }]
"#;
        assert!(toml::from_str::<Config>(toml_content).is_err());
    }

    #[test]
    fn test_example_toml_generation() {
        let example = Config::example_toml();
        assert!(example.contains("[server]"));
        assert!(example.contains("[nats]"));
        assert!(example.contains("[grpc_tls]"));
        assert!(example.contains("[auth]"));
        assert!(example.contains("bind_address"));
        assert!(example.contains("url"));
        assert!(example.contains("cert_file"));
        assert!(example.contains("key_file"));
    }

    #[test]
    fn test_output_backend_defaults_to_jetstream() {
        let config: Config = toml::from_str("").unwrap();
        assert_eq!(config.output.backend, OutputBackend::Jetstream);
        assert!(config.agent_forward.is_none());
    }

    #[test]
    fn test_output_backend_parses_agent_with_spool_settings() {
        let toml_content = r#"
[output]
backend = "agent"

[agent_forward]
spool_dir = "/var/tmp/otel-spool"
max_bytes = 1048576
max_age_secs = 600
min_free_disk_bytes = 33554432
"#;
        let config: Config = toml::from_str(toml_content).unwrap();
        assert_eq!(config.output.backend, OutputBackend::Agent);
        let agent_forward = config.agent_forward.unwrap();
        assert_eq!(agent_forward.spool_dir, "/var/tmp/otel-spool");
        assert_eq!(agent_forward.max_bytes, 1024 * 1024);
        assert_eq!(agent_forward.max_age_secs, Some(600));
        assert_eq!(agent_forward.min_free_disk_bytes, 32 * 1024 * 1024);

        let spool = agent_forward.spool_config();
        assert_eq!(spool.dir, PathBuf::from("/var/tmp/otel-spool"));
        assert_eq!(spool.max_bytes, 1024 * 1024);
        assert_eq!(spool.max_age, Some(Duration::from_secs(600)));
        assert_eq!(spool.min_free_disk_bytes, 32 * 1024 * 1024);
    }

    #[test]
    fn test_agent_forward_defaults() {
        let toml_content = r#"
[output]
backend = "agent"
"#;
        let config: Config = toml::from_str(toml_content).unwrap();
        assert_eq!(config.output.backend, OutputBackend::Agent);
        // The section itself is optional; defaults apply on construction.
        let defaults = AgentForwardConfig::default();
        assert_eq!(defaults.spool_dir, "/var/lib/serviceradar/otel-spool");
        assert_eq!(
            defaults.max_bytes,
            crate::agent_forward::spool::DEFAULT_SPOOL_MAX_BYTES
        );
        assert!(defaults.max_age_secs.is_none());
        assert_eq!(
            defaults.min_free_disk_bytes,
            crate::agent_forward::spool::DEFAULT_MIN_FREE_DISK_BYTES
        );
    }

    #[test]
    fn test_output_backend_parses_otlp_reserved_value() {
        let toml_content = r#"
[output]
backend = "otlp"
"#;
        let config: Config = toml::from_str(toml_content).unwrap();
        assert_eq!(config.output.backend, OutputBackend::Otlp);
    }

    #[test]
    fn test_output_backend_rejects_unknown_value() {
        let toml_content = r#"
[output]
backend = "carrier-pigeon"
"#;
        assert!(toml::from_str::<Config>(toml_content).is_err());
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
