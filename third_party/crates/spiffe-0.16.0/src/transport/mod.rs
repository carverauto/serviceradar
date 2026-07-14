//! Transport layer for SPIFFE endpoints.
//!
//! - `transport`: endpoint parsing only (no runtime deps)
//! - `transport-grpc`: gRPC connector + transport errors

#[cfg(feature = "transport")]
pub mod endpoint;

#[cfg(feature = "transport-grpc")]
pub mod connector;

#[cfg(feature = "transport-grpc")]
pub mod error;

#[cfg(feature = "transport")]
pub use endpoint::{Endpoint, EndpointError};

#[cfg(feature = "transport-grpc")]
pub use connector::connect;

#[cfg(feature = "transport-grpc")]
pub use error::TransportError;
