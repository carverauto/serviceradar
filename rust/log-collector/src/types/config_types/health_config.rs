use serde::{Deserialize, Serialize};

/// Configuration for the unified gRPC health check server.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HealthConfig {
    /// gRPC health server listen address (default "0.0.0.0:50044").
    #[serde(default = "default_health_listen")]
    pub listen_addr: String,
}

impl Default for HealthConfig {
    fn default() -> Self {
        Self {
            listen_addr: default_health_listen(),
        }
    }
}

fn default_health_listen() -> String {
    "0.0.0.0:50044".to_string()
}
