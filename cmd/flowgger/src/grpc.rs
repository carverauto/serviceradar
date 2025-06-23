use std::net::SocketAddr;
use tonic::transport::{Server, ServerTlsConfig, Certificate, Identity};
use tonic_health::server::health_reporter;
use tonic_reflection::server::Builder as ReflectionBuilder;

/// Start a basic gRPC server exposing the standard health service.
/// TLS is enabled when cert, key and ca paths are provided.
pub async fn serve(addr: SocketAddr, cert: Option<String>, key: Option<String>, ca: Option<String>) -> Result<(), Box<dyn std::error::Error>> {
    let (mut health_reporter, health_service) = health_reporter();
    // Report this service as serving immediately
    health_reporter
        .set_service_status("flowgger", tonic_health::ServingStatus::Serving)
        .await;

    let mut builder = Server::builder();

    if let (Some(cert), Some(key), Some(ca)) = (cert, key, ca) {
        let cert = tokio::fs::read(cert).await?;
        let key = tokio::fs::read(key).await?;
        let identity = Identity::from_pem(cert, key);
        let ca = tokio::fs::read(ca).await?;
        let ca = Certificate::from_pem(ca);
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
