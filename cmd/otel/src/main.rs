use std::net::SocketAddr;
use tonic::transport::Server;
use log::{info, debug, warn, error};

use otel::cli::Cli;
use otel::config::Config;
use otel::opentelemetry::proto::collector::trace::v1::trace_service_server::TraceServiceServer;
use otel::opentelemetry::proto::collector::logs::v1::logs_service_server::LogsServiceServer;
use otel::ServiceRadarCollector;

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    // Parse command line arguments
    let args = Cli::parse_args();
    
    // Initialize logging
    let log_level = if args.is_debug_enabled() {
        "debug"
    } else {
        "info"
    };
    
    env_logger::Builder::from_env(env_logger::Env::default().default_filter_or(log_level))
        .init();
    
    debug!("Debug logging enabled");
    info!("ServiceRadar OTEL Collector starting up");
    
    // Handle generate-config flag
    if args.generate_config {
        info!("Generating example configuration");
        println!("{}", Config::example_toml());
        return Ok(());
    }
    
    // Load configuration from specified path or defaults
    debug!("Loading configuration from: {:?}", args.config);
    let config = match Config::load(args.config.as_deref()) {
        Ok(cfg) => {
            debug!("Configuration loaded successfully");
            cfg
        },
        Err(e) => {
            error!("Failed to load configuration: {e}");
            if args.config.is_some() {
                // If a specific config was requested and failed, exit
                return Err(e.into());
            } else {
                warn!("Using default configuration");
                Config::default()
            }
        }
    };
    
    // Parse bind address
    debug!("Parsing bind address: {}", config.bind_address());
    let addr: SocketAddr = config.bind_address().parse()
        .map_err(|e| format!("Invalid bind address '{}': {}", config.bind_address(), e))?;
    
    // Get NATS configuration if available
    let nats_config = config.nats_config();
    if let Some(ref nats) = nats_config {
        info!("NATS output enabled - URL: {}, Subject: {}, Stream: {}", 
              nats.url, nats.subject, nats.stream);
        debug!("NATS timeout: {:?}", nats.timeout);
        debug!("NATS TLS cert: {:?}", nats.tls_cert);
        debug!("NATS TLS key: {:?}", nats.tls_key);
        debug!("NATS TLS CA: {:?}", nats.tls_ca);
    } else {
        info!("NATS output disabled (no [nats] section in config)");
    }
    
    // Create collector with NATS config
    debug!("Creating ServiceRadar collector");
    let collector = match ServiceRadarCollector::new(nats_config).await {
        Ok(c) => {
            debug!("ServiceRadar collector created successfully");
            c
        },
        Err(e) => {
            error!("Failed to create ServiceRadar collector: {e}");
            return Err(e);
        }
    };

    info!("OTEL Collector listening on {addr}");
    
    debug!("Starting gRPC server");
    let result = Server::builder()
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

