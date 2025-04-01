/*
 * Copyright 2025 Carver Automation Corporation.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

use anyhow::{Context, Result};
use clap::{App, Arg};
use log::{info, warn};
use std::path::PathBuf;
use std::sync::Arc;

use serviceradar_rperf_checker::config::Config;
use serviceradar_rperf_checker::server::RPerfTestOrchestrator;

#[tokio::main]
async fn main() -> Result<()> {
    // Initialize logging
    env_logger::init_from_env(
        env_logger::Env::default().filter_or(env_logger::DEFAULT_FILTER_ENV, "info"),
    );

    // Define command-line arguments using the same clap version as rperf
    let matches = App::new("serviceradar-rperf-checker")
        .version(env!("CARGO_PKG_VERSION"))
        .author(env!("CARGO_PKG_AUTHORS"))
        .about("ServiceRadar gRPC checker for running rperf network performance tests")
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
    let server = RPerfTestOrchestrator::new(Arc::new(config))
        .context("Failed to create rperf server")?;

    // Start the server
    let server_handle = server.start().await?;
    info!("rperf gRPC server started");

    // Wait for shutdown signal
    tokio::signal::ctrl_c().await?;
    info!("Shutdown signal received, stopping server...");

    // Stop the server gracefully
    match server_handle.stop().await {
        Ok(_) => info!("Server stopped gracefully"),
        Err(e) => warn!("Error during server shutdown: {}", e),
    }

    Ok(())
}