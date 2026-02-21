use anyhow::Result;
use log::{error, info};
use std::net::SocketAddr;
use tonic::transport::Server;

use crate::profiler::profiler_service_server::ProfilerServiceServer;
use crate::ServiceRadarProfiler;

pub async fn create_profiler() -> Result<ServiceRadarProfiler> {
    info!("Creating ServiceRadar eBPF Profiler");

    let profiler = ServiceRadarProfiler::new();

    info!("eBPF Profiler created successfully");
    Ok(profiler)
}

pub async fn start_server(
    addr: SocketAddr,
    profiler: ServiceRadarProfiler,
) -> Result<(), Box<dyn std::error::Error>> {
    info!("Starting gRPC server on {}", addr);

    let profiler_service = ProfilerServiceServer::new(profiler);

    let server = Server::builder().add_service(profiler_service).serve(addr);

    info!("eBPF Profiler gRPC server listening on {}", addr);

    match server.await {
        Ok(_) => {
            info!("Server shut down gracefully");
            Ok(())
        }
        Err(e) => {
            error!("Server error: {}", e);
            Err(e.into())
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::time::{timeout, Duration};

    #[tokio::test]
    async fn test_create_profiler() {
        let profiler = create_profiler().await;
        assert!(profiler.is_ok());
    }

    #[tokio::test]
    async fn test_server_startup_and_shutdown() {
        let profiler = create_profiler().await.unwrap();
        let addr = "127.0.0.1:0".parse().unwrap(); // Use port 0 for OS to assign

        // Start server in background and immediately cancel it
        let server_future = start_server(addr, profiler);

        // Use timeout to ensure server can start (it will timeout, which is expected for this test)
        let result = timeout(Duration::from_millis(100), server_future).await;

        // We expect timeout since the server runs indefinitely
        assert!(result.is_err());
    }
}
