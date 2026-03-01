use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct NATSTLSConfig {
    pub cert_file: String,
    pub key_file: String,
    pub ca_file: Option<String>,
}
