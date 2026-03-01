

#[derive(Debug)]
pub enum BmpError {
    ConfigRead(std::io::Error),

    ConfigParse(serde_json::Error),

    ConfigValidation(String),

    InvalidAddress { addr: String, source: std::net::AddrParseError },

    NatsConnect(String),

    NatsPublish(String),

    NatsStream(String),

    Other(anyhow::Error),
}

impl std::fmt::Display for BmpError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            BmpError::ConfigRead(e) => write!(f, "failed to read config file: {}", e),
            BmpError::ConfigParse(e) => write!(f, "failed to parse config JSON: {}", e),
            BmpError::ConfigValidation(msg) => write!(f, "config validation failed: {}", msg),
            BmpError::InvalidAddress { addr, source } => write!(f, "invalid listen address '{}': {}", addr, source),
            BmpError::NatsConnect(msg) => write!(f, "NATS connect error: {}", msg),
            BmpError::NatsPublish(msg) => write!(f, "NATS publish error: {}", msg),
            BmpError::NatsStream(msg) => write!(f, "NATS stream error: {}", msg),
            BmpError::Other(e) => write!(f, "{}", e),
        }
    }
}

impl std::error::Error for BmpError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            BmpError::ConfigRead(e) => Some(e),
            BmpError::ConfigParse(e) => Some(e),
            BmpError::InvalidAddress { source, .. } => Some(source),
            BmpError::Other(e) => Some(e.as_ref()),
            _ => None,
        }
    }
}

pub type Result<T> = std::result::Result<T, BmpError>;
