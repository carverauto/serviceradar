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
use config_bootstrap::{Bootstrap, BootstrapOptions, ConfigFormat, RestartHandle};
use log::{info, warn};
use std::path::PathBuf;
use std::sync::Arc;

use serviceradar_rperf_checker::{config::Config, server::RPerfTestOrchestrator, template};

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
        .arg(
            Arg::with_name("config")
                .short("c")
                .long("config")
                .value_name("FILE")
                .help("Path to configuration file")
                .takes_value(true)
                .required(true),
        )
        .get_matches();

    // Extract the config path
    let config_path = matches.value_of("config").unwrap(); // Safe because it's required
    let config_path = PathBuf::from(config_path);

    // Load configuration
    info!("Loading configuration from {config_path:?}");
    template::ensure_config_file(&config_path)
        .with_context(|| format!("failed to install default config at {config_path:?}"))?;
    let config_path_str = config_path.display().to_string();
    let use_kv = std::env::var("CONFIG_SOURCE").ok().as_deref() == Some("kv");
    let kv_key = use_kv.then(|| "config/rperf-checker.json".to_string());
    let mut bootstrap = Bootstrap::new(BootstrapOptions {
        service_name: "rperf-checker".to_string(),
        config_path: config_path_str.clone(),
        format: ConfigFormat::Json,
        kv_key,
        seed_kv: use_kv,
        watch_kv: use_kv,
    })
    .await?;
    let config: Config = bootstrap
        .load()
        .await
        .with_context(|| format!("failed to load configuration from {config_path_str}"))?;

    if use_kv {
        if let Some(watcher) = bootstrap.watch::<Config>().await? {
            let restarter = RestartHandle::new("rperf-checker", "config/rperf-checker.json");
            tokio::spawn(async move {
                let mut cfg_watcher = watcher;
                while cfg_watcher.recv().await.is_some() {
                    restarter.trigger();
                }
            });
        }
    }

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
