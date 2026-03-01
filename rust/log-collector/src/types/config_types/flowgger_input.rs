use serde::{Deserialize, Serialize};

/// Configuration for the Flowgger syslog/GELF pipeline.
/// When enabled, Flowgger is started with the referenced TOML config file.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FlowggerInput {
    #[serde(default = "default_true")]
    pub enabled: bool,

    /// Path to the Flowgger TOML config file (its native format).
    #[serde(default = "default_flowgger_config")]
    pub config_file: String,
}

impl Default for FlowggerInput {
    fn default() -> Self {
        Self {
            enabled: true,
            config_file: default_flowgger_config(),
        }
    }
}

fn default_true() -> bool {
    true
}

fn default_flowgger_config() -> String {
    "/etc/serviceradar/flowgger.toml".to_string()
}
