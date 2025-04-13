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
use sysinfo::System;

use serviceradar_sysmon_checker::config::Config;
use serviceradar_sysmon_checker::poller::MetricsCollector;
use serviceradar_sysmon_checker::server::SysmonService;

#[tokio::main]
async fn main() -> Result<()> {
    env_logger::init_from_env(
        env_logger::Env::default().filter_or(env_logger::DEFAULT_FILTER_ENV, "info"),
    );

    let matches = App::new("serviceradar-sysmon-checker")
        .version(env!("CARGO_PKG_VERSION"))
        .author(env!("CARGO_PKG_AUTHORS"))
        .about("ServiceRadar gRPC checker for system metrics")
        .arg(Arg::with_name("config")
            .short("c")
            .long("config")
            .value_name("FILE")
            .help("Path to configuration file")
            .takes_value(true)
            .required(true))
        .get_matches();

    let config_path = matches.value_of("config").unwrap();
    let config_path = PathBuf::from(config_path);

    info!("Loading configuration from {:?}", config_path);
    let config = Config::from_file(&config_path).context("Failed to load configuration")?;
    info!("Server will listen on {}", config.listen_addr);

    // Initialize MetricsCollector
    let filesystems = config.filesystems.iter()
        .filter(|fs| fs.monitor)
        .map(|fs| fs.name.clone())
        .collect();
    let (zfs_pools, zfs_datasets) = config.zfs.as_ref()
        .map(|z| (z.pools.clone(), z.include_datasets))
        .unwrap_or_default();
    let host_id = std::env::var("HOSTNAME")
        .unwrap_or_else(|_| {
            warn!("HOSTNAME env var not set, using 'unknown'");
            "unknown".to_string()
        });
    let collector = MetricsCollector::new(host_id, filesystems, zfs_pools, zfs_datasets);

    // Start server
    let service = SysmonService::new(collector);
    let server_handle = service.start(Arc::new(config)).await?;
    info!("Sysmon gRPC server started");

    tokio::signal::ctrl_c().await?;
    info!("Shutdown signal received, stopping server...");
    server_handle.stop().await?;
    info!("Server stopped gracefully");

    Ok(())
}