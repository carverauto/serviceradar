use std::net::SocketAddr;
use tonic::transport::Server;

use otel::opentelemetry::proto::collector::trace::v1::trace_service_server::TraceServiceServer;
use otel::MyCollector;

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let addr: SocketAddr = "0.0.0.0:4317".parse()?;
    let collector = MyCollector {};

    println!("OTEL Collector listening on {}", addr);

    Server::builder()
        .add_service(TraceServiceServer::new(collector))
        .serve(addr)
        .await?;

    Ok(())
}

