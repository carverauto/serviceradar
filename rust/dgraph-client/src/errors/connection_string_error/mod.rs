/*
 * Copyright (c) "2026" . Marvin Hansen All Rights Reserved.
 */

mod connection_string_error_display;
mod connection_string_error_error;

/// Failure to parse or validate a `dgraph://` connection string.
///
/// The wrapped classification is private; branch on [`ConnectionStringError::kind`].
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct ConnectionStringError(ConnectionStringErrorEnum);

/// Detailed classification of connection-string errors.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
#[non_exhaustive]
pub enum ConnectionStringErrorEnum {
    /// The string did not start with the `dgraph://` scheme.
    InvalidScheme(String),
    /// The authority was empty or contained no host.
    MissingHost,
    /// The authority carried no port, or a port separator with nothing after it.
    MissingPort,
    /// The authority could not be parsed (for example an unterminated IPv6 literal).
    MalformedAuthority(String),
    /// The port was present but not a valid `u16`.
    InvalidPort(String),
    /// Both `apikey` and `bearertoken` were supplied; they are mutually exclusive.
    ConflictingAuth,
    /// `sslmode` was not one of `disable`, `require`, `verify-ca`.
    UnknownSslMode(String),
    /// Exactly one of username and password was supplied; both or neither are required.
    IncompleteCredentials,
    /// `namespace` was present but not a valid `u64`.
    InvalidNamespace(String),
    /// A percent-encoded sequence in the userinfo could not be decoded as UTF-8.
    InvalidPercentEncoding(String),
    /// The query string could not be parsed into key/value pairs.
    MalformedQuery(String),
}

impl ConnectionStringError {
    pub(crate) fn new(variant: ConnectionStringErrorEnum) -> Self {
        Self(variant)
    }

    /// Classification, for callers that need to branch on the failure.
    pub fn kind(&self) -> &ConnectionStringErrorEnum {
        &self.0
    }

    #[allow(non_snake_case)]
    pub fn InvalidScheme(found: String) -> Self {
        Self::new(ConnectionStringErrorEnum::InvalidScheme(found))
    }

    #[allow(non_snake_case)]
    pub fn MissingHost() -> Self {
        Self::new(ConnectionStringErrorEnum::MissingHost)
    }

    #[allow(non_snake_case)]
    pub fn MissingPort() -> Self {
        Self::new(ConnectionStringErrorEnum::MissingPort)
    }

    #[allow(non_snake_case)]
    pub fn MalformedAuthority(msg: String) -> Self {
        Self::new(ConnectionStringErrorEnum::MalformedAuthority(msg))
    }

    #[allow(non_snake_case)]
    pub fn InvalidPort(msg: String) -> Self {
        Self::new(ConnectionStringErrorEnum::InvalidPort(msg))
    }

    #[allow(non_snake_case)]
    pub fn ConflictingAuth() -> Self {
        Self::new(ConnectionStringErrorEnum::ConflictingAuth)
    }

    #[allow(non_snake_case)]
    pub fn UnknownSslMode(found: String) -> Self {
        Self::new(ConnectionStringErrorEnum::UnknownSslMode(found))
    }

    #[allow(non_snake_case)]
    pub fn IncompleteCredentials() -> Self {
        Self::new(ConnectionStringErrorEnum::IncompleteCredentials)
    }

    #[allow(non_snake_case)]
    pub fn InvalidNamespace(msg: String) -> Self {
        Self::new(ConnectionStringErrorEnum::InvalidNamespace(msg))
    }

    #[allow(non_snake_case)]
    pub fn InvalidPercentEncoding(msg: String) -> Self {
        Self::new(ConnectionStringErrorEnum::InvalidPercentEncoding(msg))
    }

    #[allow(non_snake_case)]
    pub fn MalformedQuery(msg: String) -> Self {
        Self::new(ConnectionStringErrorEnum::MalformedQuery(msg))
    }
}
