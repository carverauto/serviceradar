use std::net::SocketAddr;
use anyhow::{Context, Result};
use tonic::transport::{Certificate, Identity, Server, ServerTlsConfig};
use tonic_health::server::health_reporter;
use tonic_reflection::server::Builder as ReflectionBuilder;

/// Start a basic gRPC server exposing the standard health service.
/// TLS is enabled when cert, key and ca paths are provided.
pub async fn serve(addr: SocketAddr, cert: Option<String>, key: Option<String>, ca: Option<String>) -> Result<()> {
    let (mut health_reporter, health_service) = health_reporter();
    // Report the overall server as serving immediately
    health_reporter
        .set_service_status("", tonic_health::ServingStatus::Serving)
        .await;

    let mut builder = Server::builder();

    if let (Some(cert), Some(key), Some(ca)) = (cert, key, ca) {
        let cert = std::fs::read_to_string(&cert)
            .with_context(|| format!("failed to read cert file: {cert}"))?;
        let key = std::fs::read_to_string(&key)
            .with_context(|| format!("failed to read key file: {key}"))?;
        let identity = Identity::from_pem(cert.as_bytes(), key.as_bytes());
        let ca_data = std::fs::read_to_string(&ca)
            .with_context(|| format!("failed to read ca file: {ca}"))?;
        let ca = Certificate::from_pem(ca_data.as_bytes());
        let tls = ServerTlsConfig::new().identity(identity).client_ca_root(ca);
        builder = builder.tls_config(tls)?;
    }

    let reflection = ReflectionBuilder::configure().build()?;

    builder
        .add_service(health_service)
        .add_service(reflection)
        .serve(addr)
        .await?;

    Ok(())
}
