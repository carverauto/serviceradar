/*
 * Copyright (c) "2026" . Marvin Hansen All Rights Reserved.
 */

mod connect_error_display;
mod connect_error_error;

use tonic::Code;

/// Failure to establish or validate a connection to a Dgraph cluster.
///
/// The wrapped classification is private; branch on [`ConnectError::kind`].
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct ConnectError(ConnectErrorEnum);

/// Detailed classification of connection errors.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
#[non_exhaustive]
pub enum ConnectErrorEnum {
    /// No endpoints were supplied. A client must target at least one.
    NoEndpoints,
    /// An endpoint could not be turned into a valid gRPC target.
    InvalidEndpoint { endpoint: String, reason: String },
    /// The transport could not be established.
    Transport(String),
    /// TLS configuration failed, for example loading system roots.
    Tls(String),
    /// The cluster is reachable but not yet accepting requests.
    ///
    /// This replaces the Go client's documented "text contains `Please retry`" contract
    /// with a typed variant, so callers never string-match to detect readiness.
    ClusterNotReady { code: Code, message: String },
    /// The readiness probe failed for a reason other than the cluster still starting.
    ProbeFailed { code: Code, message: String },
}

impl ConnectError {
    pub(crate) fn new(variant: ConnectErrorEnum) -> Self {
        Self(variant)
    }

    /// Classification, for callers that need to branch on the failure.
    pub fn kind(&self) -> &ConnectErrorEnum {
        &self.0
    }

    /// Whether the cluster is up but still starting, so the caller may retry.
    ///
    /// Prefer this over inspecting error text.
    pub fn is_cluster_not_ready(&self) -> bool {
        matches!(self.0, ConnectErrorEnum::ClusterNotReady { .. })
    }

    #[allow(non_snake_case)]
    pub fn NoEndpoints() -> Self {
        Self::new(ConnectErrorEnum::NoEndpoints)
    }

    #[allow(non_snake_case)]
    pub fn InvalidEndpoint(endpoint: String, reason: String) -> Self {
        Self::new(ConnectErrorEnum::InvalidEndpoint { endpoint, reason })
    }

    #[allow(non_snake_case)]
    pub fn Transport(msg: String) -> Self {
        Self::new(ConnectErrorEnum::Transport(msg))
    }

    #[allow(non_snake_case)]
    pub fn Tls(msg: String) -> Self {
        Self::new(ConnectErrorEnum::Tls(msg))
    }

    #[allow(non_snake_case)]
    pub fn ClusterNotReady(code: Code, message: String) -> Self {
        Self::new(ConnectErrorEnum::ClusterNotReady { code, message })
    }

    #[allow(non_snake_case)]
    pub fn ProbeFailed(code: Code, message: String) -> Self {
        Self::new(ConnectErrorEnum::ProbeFailed { code, message })
    }
}
