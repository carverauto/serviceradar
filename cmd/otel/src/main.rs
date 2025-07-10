use std::net::SocketAddr;
use tonic::transport::Server;

use otel::opentelemetry::proto::collector::trace::v1::trace_service_server::TraceServiceServer;
use otel::{ServiceRadarCollector, nats_output::NatsConfig};

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let addr: SocketAddr = "0.0.0.0:4317".parse()?;
    
    // Configure NATS output based on environment variables
    let nats_config = if let Ok(nats_url) = std::env::var("NATS_URL") {
        println!("Configuring NATS output to: {}", nats_url);
        
        let mut config = NatsConfig::default();
        config.url = nats_url;
        
        // Optional: Override default subject
        if let Ok(subject) = std::env::var("NATS_SUBJECT") {
            config.subject = subject;
        }
        
        // Optional: Override default stream
        if let Ok(stream) = std::env::var("NATS_STREAM") {
            config.stream = stream;
        }
        
        // Optional: Configure TLS
        if let Ok(tls_cert) = std::env::var("NATS_TLS_CERT") {
            config.tls_cert = Some(tls_cert.into());
        }
        if let Ok(tls_key) = std::env::var("NATS_TLS_KEY") {
            config.tls_key = Some(tls_key.into());
        }
        if let Ok(tls_ca) = std::env::var("NATS_TLS_CA") {
            config.tls_ca = Some(tls_ca.into());
        }
        
        Some(config)
    } else {
        println!("NATS output disabled (set NATS_URL to enable)");
        None
    };
    
    let collector = ServiceRadarCollector::new(nats_config).await?;

    println!("OTEL Collector listening on {}", addr);

    Server::builder()
        .add_service(TraceServiceServer::new(collector))
        .serve(addr)
        .await?;

    Ok(())
}

