use otel::server::{create_collector, start_server, start_metrics_server};
use otel::setup::{
    handle_generate_config, load_configuration, log_configuration_info, parse_bind_address,
    setup_logging_and_parse_args,
};
use otel::tls::setup_grpc_tls;
use std::net::SocketAddr;

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let args = setup_logging_and_parse_args()?;

    if args.generate_config {
        return handle_generate_config();
    }

    let config = load_configuration(&args)?;
    let addr = parse_bind_address(&config)?;

    log_configuration_info(&config);

    let nats_config = config.nats_config();
    let grpc_tls_config = setup_grpc_tls(&config)?;
    let collector = create_collector(nats_config).await?;

    // Start metrics server if configured
    if let Some(metrics_addr_str) = config.metrics_address() {
        let metrics_addr: SocketAddr = metrics_addr_str.parse()?;
        println!("Starting metrics server on {}", metrics_addr);
        tokio::spawn(async move {
            if let Err(e) = start_metrics_server(metrics_addr).await {
                eprintln!("Metrics server error: {}", e);
            }
        });
    }

    start_server(addr, grpc_tls_config, collector).await
}
