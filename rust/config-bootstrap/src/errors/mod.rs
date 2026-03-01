use thiserror::Error;

#[derive(Error, Debug)]
pub enum BootstrapError {
    #[error("failed to read config file: {0}")]
    ReadFile(#[from] std::io::Error),

    #[error("failed to parse JSON: {0}")]
    JsonParse(#[from] serde_json::Error),

    #[error("failed to parse TOML: {0}")]
    TomlParse(#[from] toml::de::Error),

    #[error("overlay error: {0}")]
    Kv(#[from] kvutil::KvError),

    #[error("config format mismatch: expected {expected}, got {actual}")]
    FormatMismatch { expected: String, actual: String },

    #[error("missing config: no file at {path}")]
    MissingConfig { path: String },
}

pub type Result<T> = std::result::Result<T, BootstrapError>;
