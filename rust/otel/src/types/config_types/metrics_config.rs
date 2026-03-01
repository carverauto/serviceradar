use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MetricsConfig {
    #[serde(default = "default_metrics_bind_address")]
    pub bind_address: String,
    #[serde(default = "default_metrics_port")]
    pub port: u16,
}

fn default_metrics_bind_address() -> String {
    "0.0.0.0".to_string()
}

fn default_metrics_port() -> u16 {
    9090
}
