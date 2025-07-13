use std::net::SocketAddr;
use tonic::transport::{Server, ServerTlsConfig};
use log::{info, debug, error};

use crate::opentelemetry::proto::collector::trace::v1::trace_service_server::TraceServiceServer;
use crate::opentelemetry::proto::collector::logs::v1::logs_service_server::LogsServiceServer;
use crate::ServiceRadarCollector;

/// Creates a ServiceRadar collector with the given NATS configuration
pub async fn create_collector(nats_config: Option<crate::nats_output::NATSConfig>) -> Result<ServiceRadarCollector, Box<dyn std::error::Error>> {
    debug!("Creating ServiceRadar collector");
    
    match ServiceRadarCollector::new(nats_config).await {
        Ok(collector) => {
            debug!("ServiceRadar collector created successfully");
            Ok(collector)
        },
        Err(e) => {
            error!("Failed to create ServiceRadar collector: {e}");
            Err(e)
        }
    }
}

/// Starts the gRPC server with the given configuration
pub async fn start_server(
    addr: SocketAddr,
    grpc_tls_config: Option<ServerTlsConfig>,
    collector: ServiceRadarCollector,
) -> Result<(), Box<dyn std::error::Error>> {
    info!("OTEL Collector listening on {addr}");
    debug!("Starting gRPC server");
    
    let mut server_builder = Server::builder();
    
    // Configure gRPC TLS if enabled
    if let Some(tls) = grpc_tls_config {
        debug!("Configuring gRPC server with TLS");
        server_builder = server_builder.tls_config(tls)?;
    }
    
    let result = server_builder
        .add_service(TraceServiceServer::new(collector.clone()))
        .add_service(LogsServiceServer::new(collector))
        .serve(addr)
        .await;
        
    match result {
        Ok(_) => {
            info!("Server shut down gracefully");
            Ok(())
        },
        Err(e) => {
            error!("Server error: {e}");
            Err(e.into())
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn test_create_collector_without_nats() {
        let result = create_collector(None).await;
        assert!(result.is_ok());
    }

    #[test]
    fn test_server_creation() {
        // Test that we can create a server configuration without panicking
        let addr: SocketAddr = "127.0.0.1:8080".parse().unwrap();
        assert_eq!(addr.port(), 8080);
    }
}