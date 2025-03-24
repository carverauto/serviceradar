use anyhow::{Context, Result};
use log::info;
use rperf_grpc::config::Config;
use rperf_grpc::server::RPerfServer;
use std::path::PathBuf;
use std::sync::Arc;
use tokio::signal;
use clap::{App, Arg};

fn main() -> Result<()> {
    // Initialize logging
    env_logger::init_from_env(
        env_logger::Env::default().filter_or(env_logger::DEFAULT_FILTER_ENV, "info"),
    );

    // Define command-line arguments with clap v2
    let matches = App::new("rperf-grpc")
        .version("0.1.0")
        .author("Your Name <your.email@example.com>")
        .about("rperf gRPC checker for ServiceRadar")
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

    // Run the server (blocking in v2 style, we'll handle async separately)
    let runtime = tokio::runtime::Runtime::new()?;
    runtime.block_on(async {
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
        Ok::<(), anyhow::Error>(())
    })?;

    Ok(())
}