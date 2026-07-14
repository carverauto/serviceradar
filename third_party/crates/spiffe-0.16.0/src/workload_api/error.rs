//! Error types for Workload API operations.

use thiserror::Error;

use crate::transport::EndpointError;
use crate::SpiffeIdError;
#[cfg(feature = "jwt")]
use crate::{JwtBundleError, JwtSvidError};
#[cfg(feature = "x509")]
use crate::{X509BundleError, X509SvidError};

#[cfg(any(feature = "workload-api-x509", feature = "workload-api-jwt"))]
use crate::transport::TransportError;

/// Errors produced by Workload API operations.
#[derive(Debug, Error)]
#[non_exhaustive]
pub enum WorkloadApiError {
    /// `SPIFFE_ENDPOINT_SOCKET` is not set.
    #[error("missing SPIFFE endpoint socket path (SPIFFE_ENDPOINT_SOCKET)")]
    MissingEndpointSocket,

    /// `SPIFFE_ENDPOINT_SOCKET` is not a valid UTF-8 string.
    #[error("SPIFFE endpoint socket path is not a valid UTF-8 string: {}", .0.display())]
    NotUnicodeEndpointSocket(std::ffi::OsString),

    /// The Workload API returned an empty response.
    ///
    /// This error can occur when:
    /// - The gRPC stream ends unexpectedly
    /// - No SVIDs are available for the requested identity
    /// - The Workload API is misconfigured or the workload is not registered
    ///
    /// **Common causes:**
    /// - Workload selectors don't match
    /// - SPIRE agent is not running
    /// - Network connectivity issues
    #[error("empty Workload API response")]
    EmptyResponse,

    /// Failed to parse the Workload API endpoint string.
    #[error("invalid workload api endpoint: {0}")]
    Endpoint(#[from] EndpointError),

    /// The Workload API denied issuing an identity for this workload (e.g. selectors do not match).
    ///
    /// This error occurs when the SPIRE agent cannot match the workload to any
    /// registration entry based on the workload's selectors.
    #[error("no identity issued")]
    NoIdentityIssued,

    /// The Workload API denied the request for other permission reasons.
    #[error("permission denied: {0}")]
    PermissionDenied(String),

    /// No JWT-SVID found with the requested hint.
    #[error("no JWT-SVID found with hint: {0}")]
    HintNotFound(String),

    /// Errors returned by the underlying transport.
    #[cfg(any(feature = "workload-api-x509", feature = "workload-api-jwt"))]
    #[error(transparent)]
    Transport(#[from] TransportError),

    /// Failed to parse an X.509 SVID from the Workload API response.
    #[cfg(feature = "x509")]
    #[error("failed to parse X.509 SVID: {0}")]
    X509Svid(#[from] X509SvidError),

    /// Failed to parse a JWT-SVID from the Workload API response.
    #[cfg(feature = "jwt")]
    #[error("failed to parse JWT-SVID: {0}")]
    JwtSvid(#[from] JwtSvidError),

    /// Failed to parse an X.509 bundle from the Workload API response.
    #[cfg(feature = "x509")]
    #[error("failed to parse X.509 bundle: {0}")]
    X509Bundle(#[from] X509BundleError),

    /// Failed to parse a JWT bundle from the Workload API response.
    #[cfg(feature = "jwt")]
    #[error("failed to parse JWT bundle: {0}")]
    JwtBundle(#[from] JwtBundleError),

    /// Failed to parse a SPIFFE identifier from the Workload API response.
    #[error("failed to parse SPIFFE ID: {0}")]
    SpiffeId(#[from] SpiffeIdError),
}

#[cfg(any(feature = "workload-api-x509", feature = "workload-api-jwt"))]
impl From<tonic::Status> for WorkloadApiError {
    fn from(status: tonic::Status) -> Self {
        use tonic::Code;

        if status.code() == Code::PermissionDenied {
            let msg = status.message();

            if msg.contains("no identity issued") {
                return Self::NoIdentityIssued;
            }

            return Self::PermissionDenied(msg.to_owned());
        }

        Self::Transport(TransportError::Status(status))
    }
}

#[cfg(any(feature = "workload-api-x509", feature = "workload-api-jwt"))]
impl From<tonic::transport::Error> for WorkloadApiError {
    fn from(e: tonic::transport::Error) -> Self {
        Self::Transport(TransportError::Tonic(e))
    }
}
