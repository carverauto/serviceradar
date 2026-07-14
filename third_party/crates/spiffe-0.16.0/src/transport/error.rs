//! Error types for the transport layer (gRPC/tonic).

use thiserror::Error;

/// Errors produced by the shared transport layer (tonic channel/connector).
#[derive(Debug, Error)]
#[non_exhaustive]
pub enum TransportError {
    /// The endpoint transport is unsupported on the current platform.
    #[error("unsupported endpoint transport: {scheme}")]
    UnsupportedEndpointTransport {
        /// The unsupported transport scheme.
        scheme: &'static str,
    },

    /// gRPC status returned by the Workload API.
    #[error(transparent)]
    Status(#[from] tonic::Status),

    /// Transport error while connecting to the Workload API.
    #[error(transparent)]
    Tonic(#[from] tonic::transport::Error),
}
