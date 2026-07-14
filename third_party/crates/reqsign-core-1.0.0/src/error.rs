use std::fmt;
use thiserror::Error;

/// The error type for reqsign operations
#[derive(Error)]
#[error("{message}")]
pub struct Error {
    /// The category of error that occurred
    kind: ErrorKind,

    /// Human-readable error message
    message: String,

    /// The underlying error source
    #[source]
    source: Option<anyhow::Error>,

    /// Additional context information for debugging
    context: Vec<String>,

    /// Whether this error is retryable
    retryable: bool,
}

/// The kind of error that occurred
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ErrorKind {
    /// Credentials are invalid, expired, or malformed
    /// User action: Check credential format, refresh if expired
    CredentialInvalid,

    /// Permission denied when accessing credentials or resources
    /// User action: Check IAM policies, role trust relationships
    PermissionDenied,

    /// Required configuration is missing or invalid
    /// User action: Check configuration files, environment variables
    ConfigInvalid,

    /// Request cannot be signed or is malformed
    /// User action: Check request parameters, headers
    RequestInvalid,

    /// Rate limit exceeded
    /// User action: Implement backoff, check quotas
    RateLimited,

    /// Unexpected error that doesn't fit other categories
    /// User action: Check logs, report bug if persistent
    Unexpected,
}

impl Error {
    /// Create a new error with the given kind and message
    pub fn new(kind: ErrorKind, message: impl Into<String>) -> Self {
        Self {
            kind,
            message: message.into(),
            source: None,
            context: Vec::new(),
            retryable: kind.default_retryable(),
        }
    }

    /// Add a source error
    pub fn with_source(mut self, source: impl Into<anyhow::Error>) -> Self {
        self.source = Some(source.into());
        self
    }

    /// Add context information for debugging
    pub fn with_context(mut self, context: impl fmt::Display) -> Self {
        self.context.push(context.to_string());
        self
    }

    /// Override the retryable status
    pub fn set_retryable(mut self, retryable: bool) -> Self {
        self.retryable = retryable;
        self
    }

    /// Get the error kind
    pub fn kind(&self) -> ErrorKind {
        self.kind
    }

    /// Check if this error is retryable
    pub fn is_retryable(&self) -> bool {
        self.retryable
    }

    /// Get the context information
    pub fn context(&self) -> &[String] {
        &self.context
    }
}

impl ErrorKind {
    /// Default retryable status for each error kind
    fn default_retryable(&self) -> bool {
        matches!(self, ErrorKind::RateLimited)
    }
}

// Convenience constructors
impl Error {
    /// Create a credential invalid error
    pub fn credential_invalid(message: impl Into<String>) -> Self {
        Self::new(ErrorKind::CredentialInvalid, message)
    }

    /// Create a permission denied error
    pub fn permission_denied(message: impl Into<String>) -> Self {
        Self::new(ErrorKind::PermissionDenied, message)
    }

    /// Create a config invalid error
    pub fn config_invalid(message: impl Into<String>) -> Self {
        Self::new(ErrorKind::ConfigInvalid, message)
    }

    /// Create a request invalid error
    pub fn request_invalid(message: impl Into<String>) -> Self {
        Self::new(ErrorKind::RequestInvalid, message)
    }

    /// Create a rate limited error
    pub fn rate_limited(message: impl Into<String>) -> Self {
        Self::new(ErrorKind::RateLimited, message)
    }

    /// Create an unexpected error
    pub fn unexpected(message: impl Into<String>) -> Self {
        Self::new(ErrorKind::Unexpected, message)
    }
}

// Custom Debug implementation for better error display
impl fmt::Debug for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let mut debug = f.debug_struct("Error");
        debug.field("kind", &self.kind);
        debug.field("message", &self.message);

        if !self.context.is_empty() {
            debug.field("context", &self.context);
        }

        if let Some(source) = &self.source {
            debug.field("source", source);
        }

        debug.field("retryable", &self.retryable);
        debug.finish()
    }
}

impl fmt::Display for ErrorKind {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            ErrorKind::CredentialInvalid => write!(f, "invalid credentials"),
            ErrorKind::PermissionDenied => write!(f, "permission denied"),
            ErrorKind::ConfigInvalid => write!(f, "invalid configuration"),
            ErrorKind::RequestInvalid => write!(f, "invalid request"),
            ErrorKind::RateLimited => write!(f, "rate limited"),
            ErrorKind::Unexpected => write!(f, "unexpected error"),
        }
    }
}

/// Convenience type alias for Results
pub type Result<T> = std::result::Result<T, Error>;

// Common From implementations for better ergonomics
impl From<anyhow::Error> for Error {
    fn from(err: anyhow::Error) -> Self {
        Self::unexpected(err.to_string()).with_source(err)
    }
}

impl From<std::fmt::Error> for Error {
    fn from(err: std::fmt::Error) -> Self {
        Self::unexpected(err.to_string()).with_source(err)
    }
}

impl From<http::Error> for Error {
    fn from(err: http::Error) -> Self {
        Self::request_invalid(err.to_string()).with_source(err)
    }
}

impl From<http::header::InvalidHeaderValue> for Error {
    fn from(err: http::header::InvalidHeaderValue) -> Self {
        Self::request_invalid(err.to_string()).with_source(err)
    }
}

impl From<http::uri::InvalidUri> for Error {
    fn from(err: http::uri::InvalidUri) -> Self {
        Self::request_invalid(err.to_string()).with_source(err)
    }
}

impl From<http::uri::InvalidUriParts> for Error {
    fn from(err: http::uri::InvalidUriParts) -> Self {
        Self::request_invalid(err.to_string()).with_source(err)
    }
}

impl From<std::string::FromUtf8Error> for Error {
    fn from(err: std::string::FromUtf8Error) -> Self {
        Self::unexpected(err.to_string()).with_source(err)
    }
}

impl From<std::io::Error> for Error {
    fn from(err: std::io::Error) -> Self {
        use std::io::ErrorKind;

        let kind = err.kind();
        let message = err.to_string();
        let source = anyhow::Error::from(err);

        match kind {
            ErrorKind::NotFound => Self::config_invalid(message).with_source(source),
            ErrorKind::PermissionDenied => Self::permission_denied(message).with_source(source),
            _ => Self::unexpected(message)
                .with_source(source)
                .set_retryable(matches!(
                    kind,
                    ErrorKind::TimedOut | ErrorKind::Interrupted | ErrorKind::ConnectionRefused
                )),
        }
    }
}

impl From<http::header::InvalidHeaderName> for Error {
    fn from(err: http::header::InvalidHeaderName) -> Self {
        Self::request_invalid(err.to_string()).with_source(err)
    }
}

impl From<http::header::ToStrError> for Error {
    fn from(err: http::header::ToStrError) -> Self {
        Self::request_invalid(err.to_string()).with_source(err)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_error_creation() {
        let err = Error::credential_invalid("token expired");
        assert_eq!(err.kind(), ErrorKind::CredentialInvalid);
        assert!(!err.is_retryable());
    }

    #[test]
    fn test_error_with_context() {
        let err = Error::permission_denied("access denied")
            .with_context("role: arn:aws:iam::123456789012:role/MyRole")
            .with_context("operation: AssumeRole");

        assert_eq!(err.context().len(), 2);
        assert_eq!(
            err.context()[0],
            "role: arn:aws:iam::123456789012:role/MyRole"
        );
        assert_eq!(err.context()[1], "operation: AssumeRole");
    }

    #[test]
    fn test_rate_limited_default_retryable() {
        let err = Error::rate_limited("too many requests");
        assert!(err.is_retryable());
    }

    #[test]
    fn test_override_retryable() {
        let err = Error::unexpected("network timeout").set_retryable(true);
        assert!(err.is_retryable());

        let err = Error::rate_limited("quota exceeded").set_retryable(false);
        assert!(!err.is_retryable());
    }

    #[test]
    fn test_error_debug_format() {
        let err = Error::config_invalid("missing region")
            .with_context("file: ~/.aws/config")
            .with_context("profile: default");

        let debug_str = format!("{:?}", err);
        assert!(debug_str.contains("ConfigInvalid"));
        assert!(debug_str.contains("missing region"));
        assert!(debug_str.contains("~/.aws/config"));
    }
}
