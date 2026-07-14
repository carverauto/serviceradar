//! Workload API endpoint handling.
//!
//! SPIFFE Workload API clients discover the endpoint via the
//! `SPIFFE_ENDPOINT_SOCKET` environment variable.
//!
//! Wires that environment variable to the shared [`Endpoint`] parser.

use crate::transport::Endpoint;
use crate::workload_api::error::WorkloadApiError;

/// Environment variable holding the Workload API endpoint.
pub const WORKLOAD_API_ENDPOINT_ENV: &str = "SPIFFE_ENDPOINT_SOCKET";

/// Load and parse the Workload API endpoint from `SPIFFE_ENDPOINT_SOCKET`.
///
/// ## Errors
///
/// Returns a [`WorkloadApiError`] if:
/// - the `SPIFFE_ENDPOINT_SOCKET` environment variable is not set, or
/// - the value of `SPIFFE_ENDPOINT_SOCKET` is not a valid SPIFFE endpoint URI.
pub fn from_env() -> Result<Endpoint, WorkloadApiError> {
    let raw = std::env::var_os(WORKLOAD_API_ENDPOINT_ENV)
        .ok_or(WorkloadApiError::MissingEndpointSocket)?;
    if let Some(raw) = raw.to_str() {
        Ok(Endpoint::parse(raw)?)
    } else {
        Err(WorkloadApiError::NotUnicodeEndpointSocket(raw))
    }
}
