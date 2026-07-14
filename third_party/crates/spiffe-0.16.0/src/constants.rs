//! Module defining constants used within the Rust-Spiffe library.

/// Specifies the index of the default SVID (Secure Vector Identifier) within a list.
///
/// This constant is used to identify the first SVID in the list returned by the Workload API,
/// which is considered the default for operations involving multiple SVIDs.
pub const DEFAULT_SVID: usize = 0;

/// Name of the environment variable that is used to configure the socket endpoint path for SPIFFE.
///
/// This path is required for communication between SPIFFE-enabled systems and should be set within
/// the environment variables of the host.
pub const SPIFFE_SOCKET_ENV: &str = "SPIFFE_ENDPOINT_SOCKET";
