#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ConfigFormat {
    Json,
    Toml,
}

impl ConfigFormat {
    pub fn as_str(&self) -> &str {
        match self {
            ConfigFormat::Json => "json",
            ConfigFormat::Toml => "toml",
        }
    }
}

/// Options for bootstrapping a service configuration.
#[derive(Debug, Clone)]
pub struct BootstrapOptions {
    /// Service name (e.g., "flowgger", "trapd")
    pub service_name: String,

    /// Path to the on-disk config file
    pub config_path: String,

    /// Config format (JSON or TOML)
    pub format: ConfigFormat,

    /// Optional pinned config path to overlay last (overrides defaults)
    pub pinned_path: Option<String>,
}
