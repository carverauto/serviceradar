use anyhow::{Context, Result};
use clap::{App, Arg};
use log::{info, warn};
use std::path::PathBuf;
use std::sync::Arc;

use rperf_grpc::config::Config;
use rperf_grpc::server::RPerfServer;

#[tokio::main]
async fn main() -> Result<()> {
    // Initialize logging
    env_logger::init_from_env(
        env_logger::Env::default().filter_or(env_logger::DEFAULT_FILTER_ENV, "info"),
    );

    // Define command-line arguments using the same clap version as rperf
    let matches = App::new("rperf-grpc")
        .version(env!("CARGO_PKG_VERSION"))
        .author(env!("CARGO_PKG_AUTHORS"))
        .about("gRPC checker for running rperf network performance tests")
        .arg(Arg::with_name("config")
            .short("c")
            .long("config")
            .value_name("FILE")
            .help("Path to configuration file")
            .takes_value(true)
            .required(true))
        .get_matches();

    // Extract the config path
    let config_path = matches.value_of("config").unwrap(); // Safe because it's required
    let config_path = PathBuf::from(config_path);

    // Load configuration
    info!("Loading configuration from {:?}", config_path);
    let config = Config::from_file(&config_path)
        .context("Failed to load configuration")?;

    // Print configuration summary
    info!("Loaded configuration with {} targets", config.targets.len());
    info!("Server will listen on {}", config.listen_addr);

    // Create the server instance
    let server = RPerfServer::new(Arc::new(config))
        .context("Failed to create rperf server")?;

    // Start the server
    let server_handle = server.start().await?;
    info!("rperf gRPC server started");

    // Wait for shutdown signal
    tokio::signal::ctrl_c().await?;
    info!("Shutdown signal received, stopping server...");

    // Ensure any running clients stop
    rperf::client::kill();

    // Stop the server gracefully
    match server_handle.stop().await {
        Ok(_) => info!("Server stopped gracefully"),
        Err(e) => warn!("Error during server shutdown: {}", e),
    }

    Ok(())
}