use serde::{Deserialize, Serialize};

/// Configuration for the OTEL gRPC collector.
/// When enabled, the OTEL collector is started with the referenced TOML config file.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct OtelInput {
    #[serde(default = "default_true")]
    pub enabled: bool,

    /// Path to the OTEL TOML config file (its native format).
    #[serde(default = "default_otel_config")]
    pub config_file: String,
}

impl Default for OtelInput {
    fn default() -> Self {
        Self {
            enabled: true,
            config_file: default_otel_config(),
        }
    }
}

fn default_true() -> bool {
    true
}

fn default_otel_config() -> String {
    "/etc/serviceradar/otel.toml".to_string()
}
