use anyhow::{Context, Result};
use clap::Parser;
use log::{debug, error, info, warn};
use rperf_grpc::config::Config;
use rperf_grpc::server::RPerfServer;
use std::path::PathBuf;
use std::sync::Arc;
use tokio::signal;

#[derive(Parser, Debug)]
#[command(author, version, about = "rperf gRPC checker for ServiceRadar")]
struct Args {
    /// Path to configuration file
    #[arg(short, long)]
    config: PathBuf,
}

#[tokio::main]
async fn main() -> Result<()> {
    // Initialize logging
    env_logger::init_from_env(
        env_logger::Env::default().filter_or(env_logger::DEFAULT_FILTER_ENV, "info"),
    );

    // Parse command line arguments
    let args = Args::parse();
    
    // Load configuration
    info!("Loading configuration from {:?}", args.config);
    let config = Config::from_file(&args.config)
        .context("Failed to load configuration")?;
    
    // Create the server instance
    let server = RPerfServer::new(Arc::new(config))
        .context("Failed to create rperf server")?;
    
    // Start the server
    let server_handle = server.start().await?;
    info!("rperf gRPC server started");

    signal::ctrl_c().await?;
    info!("Shutdown signal received, stopping server...");
    rperf::client::kill(); // Ensure clients stop
    server_handle.stop().await?;
    info!("Server stopped gracefully");
    Ok(())
}