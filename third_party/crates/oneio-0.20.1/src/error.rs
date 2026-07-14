use thiserror::Error;

/// Simplified error enum with only 3 variants
#[derive(Debug, Error)]
pub enum OneIoError {
    /// All IO-related errors (file system, EOF, etc.)
    #[error("IO error: {0}")]
    Io(#[from] std::io::Error),

    /// All network/remote operation errors (HTTP, FTP, S3, JSON parsing)
    #[error("{0}")]
    Network(Box<dyn std::error::Error + Send + Sync>),

    /// Feature not supported/compiled
    #[error("Not supported: {0}")]
    NotSupported(String),
}

// Convert various network-related errors to Network variant
#[cfg(feature = "http")]
impl From<reqwest::Error> for OneIoError {
    fn from(err: reqwest::Error) -> Self {
        OneIoError::Network(Box::new(err))
    }
}

#[cfg(feature = "ftp")]
impl From<suppaftp::FtpError> for OneIoError {
    fn from(err: suppaftp::FtpError) -> Self {
        OneIoError::Network(Box::new(err))
    }
}

#[cfg(feature = "json")]
impl From<serde_json::Error> for OneIoError {
    fn from(err: serde_json::Error) -> Self {
        OneIoError::Network(Box::new(err))
    }
}

#[cfg(feature = "s3")]
impl From<s3::error::S3Error> for OneIoError {
    fn from(err: s3::error::S3Error) -> Self {
        OneIoError::Network(Box::new(err))
    }
}

#[cfg(feature = "s3")]
impl From<s3::creds::error::CredentialsError> for OneIoError {
    fn from(err: s3::creds::error::CredentialsError) -> Self {
        OneIoError::Network(Box::new(err))
    }
}

#[cfg(feature = "s3")]
impl From<s3::region::error::RegionError> for OneIoError {
    fn from(err: s3::region::error::RegionError) -> Self {
        OneIoError::Network(Box::new(err))
    }
}
