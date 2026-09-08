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
use clap::{Arg, Command};
use config_bootstrap::{Bootstrap, BootstrapOptions, ConfigFormat};
use log::{info, warn};
use std::path::PathBuf;
use std::sync::{Arc, Once};

use serviceradar_rperf_checker::{config::Config, server::RPerfTestOrchestrator, template};

#[tokio::main]
async fn main() -> Result<()> {
    ensure_rustls_provider_installed();

    // Initialize logging
    env_logger::init_from_env(
        env_logger::Env::default().filter_or(env_logger::DEFAULT_FILTER_ENV, "info"),
    );

    let matches = Command::new("serviceradar-rperf-checker")
        .version(env!("CARGO_PKG_VERSION"))
        .author(env!("CARGO_PKG_AUTHORS"))
        .about("ServiceRadar gRPC checker for running rperf network performance tests")
        .arg(
            Arg::new("config")
                .short('c')
                .long("config")
                .value_name("FILE")
                .help("Path to configuration file")
                .required(true),
        )
        .get_matches();

    let config_path = matches
        .get_one::<String>("config")
        .expect("required by clap");
    let config_path = PathBuf::from(config_path);

    // Load configuration
    info!("Loading configuration from {config_path:?}");
    template::ensure_config_file(&config_path)
        .with_context(|| format!("failed to install default config at {config_path:?}"))?;
    let config_path_str = config_path.display().to_string();
    let pinned_path = config_bootstrap::pinned_path_from_env();
    let mut bootstrap = Bootstrap::new(BootstrapOptions {
        service_name: "rperf-checker".to_string(),
        config_path: config_path_str.clone(),
        format: ConfigFormat::Json,
        pinned_path: pinned_path.clone(),
    })
    .await?;
    let config: Config = bootstrap
        .load()
        .await
        .with_context(|| format!("failed to load configuration from {config_path_str}"))?;

    // Print configuration summary
    info!("Loaded configuration with {} targets", config.targets.len());
    info!("Server will listen on {}", config.listen_addr);

    // Create the server instance
    let server =
        RPerfTestOrchestrator::new(Arc::new(config)).context("Failed to create rperf server")?;

    // Start the server
    let server_handle = server.start().await?;
    info!("rperf gRPC server started");

    // Wait for shutdown signal
    tokio::signal::ctrl_c().await?;
    info!("Shutdown signal received, stopping server...");

    // Stop the server gracefully
    match server_handle.stop().await {
        Ok(_) => info!("Server stopped gracefully"),
        Err(e) => warn!("Error during server shutdown: {e}"),
    }

    Ok(())
}

fn ensure_rustls_provider_installed() {
    static ONCE: Once = Once::new();
    ONCE.call_once(|| {
        let _ = rustls::crypto::ring::default_provider().install_default();
    });
}
