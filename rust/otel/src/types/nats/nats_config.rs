use std::path::PathBuf;
use std::time::Duration;

#[derive(Clone, Debug)]
pub struct NATSConfig {
    pub url: String,
    pub subject: String,
    pub stream: String,
    pub logs_subject: Option<String>,
    pub timeout: Duration,
    pub max_bytes: i64,
    pub max_age: Duration,
    pub creds_file: Option<PathBuf>,
    pub tls_cert: Option<PathBuf>,
    pub tls_key: Option<PathBuf>,
    pub tls_ca: Option<PathBuf>,
}

impl Default for NATSConfig {
    fn default() -> Self {
        Self {
            url: "nats://localhost:4222".to_string(),
            subject: "otel".to_string(),
            stream: "events".to_string(),
            logs_subject: None,
            timeout: Duration::from_secs(30),
            max_bytes: 2 * 1024 * 1024 * 1024,
            max_age: Duration::from_secs(30 * 60),
            creds_file: None,
            tls_cert: None,
            tls_key: None,
            tls_ca: None,
        }
    }
}
