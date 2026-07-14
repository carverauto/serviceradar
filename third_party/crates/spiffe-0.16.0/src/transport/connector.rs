//! gRPC channel connector for SPIFFE endpoints.
//!
//! Builds a `tonic::transport::Channel` from a parsed [`Endpoint`].
//!
//! Supported transports:
//! - `unix:///path` or `unix:/path` (Unix domain sockets; Unix platforms only)
//! - `tcp://1.2.3.4:port` or `tcp:1.2.3.4:port`
//!
//! Available when the `transport-grpc` feature is enabled (or any feature that enables it,
//! such as `workload-api`).

use std::net::IpAddr;
use std::path::Path;

use hyper_util::rt::TokioIo;
#[cfg(unix)]
use tokio::net::UnixStream;
use tonic::transport::{Channel, Endpoint as TonicEndpoint, Uri};
use tower::service_fn;

use crate::transport::endpoint::Endpoint;
use crate::transport::TransportError;

const TONIC_DUMMY_URI: &str = "http://localhost";

/// Connect to a SPIFFE endpoint and return a `tonic` gRPC channel.
///
/// ## Errors
///
/// Returns [`TransportError`] if:
/// - the endpoint transport is unsupported on the current platform,
/// - the tonic endpoint could not be constructed,
/// - or the underlying connection fails.
pub async fn connect(endpoint: &Endpoint) -> Result<Channel, TransportError> {
    match endpoint {
        Endpoint::Unix(path) => connect_unix(path).await,
        Endpoint::Tcp { host, port } => connect_tcp(*host, *port).await,
    }
}

/// Format a TCP URI for the given host and port, bracketing IPv6 addresses
/// per RFC 2732.
fn tcp_uri(host: IpAddr, port: u16) -> String {
    match host {
        IpAddr::V4(v4) => format!("http://{v4}:{port}"),
        IpAddr::V6(v6) => format!("http://[{v6}]:{port}"),
    }
}

/// Connects over plaintext HTTP.
///
/// # Security
///
/// This transport does **not** use TLS. Private key material and JWT tokens
/// are transmitted in cleartext. Only use TCP transport on trusted networks
/// (e.g., loopback) or behind an external TLS layer. The SPIFFE specification
/// recommends Unix domain sockets for local Workload API communication.
async fn connect_tcp(host: IpAddr, port: u16) -> Result<Channel, TransportError> {
    let uri = tcp_uri(host, port);
    Ok(TonicEndpoint::try_from(uri)?.connect().await?)
}

async fn connect_unix(path: &Path) -> Result<Channel, TransportError> {
    #[cfg(not(unix))]
    {
        let _ = path;
        return Err(TransportError::UnsupportedEndpointTransport { scheme: "unix" });
    }

    #[cfg(unix)]
    {
        let path = path.to_owned();

        let channel = TonicEndpoint::try_from(TONIC_DUMMY_URI)?
            .connect_with_connector(service_fn(move |_: Uri| {
                let path = path.clone();
                async move {
                    let stream = UnixStream::connect(&path).await?;
                    Ok::<_, std::io::Error>(TokioIo::new(stream))
                }
            }))
            .await?;

        Ok(channel)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::net::{Ipv4Addr, Ipv6Addr};

    #[test]
    fn tcp_uri_formats_ipv4() {
        let uri = tcp_uri(IpAddr::V4(Ipv4Addr::LOCALHOST), 8080);
        assert_eq!(uri, "http://127.0.0.1:8080");
    }

    #[test]
    fn tcp_uri_brackets_ipv6() {
        let uri = tcp_uri(IpAddr::V6(Ipv6Addr::LOCALHOST), 443);
        assert_eq!(uri, "http://[::1]:443");
    }
}
