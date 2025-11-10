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

// main.rs

use anyhow::{Context, Result};
use clap::{App, Arg};
use config_bootstrap::{Bootstrap, BootstrapOptions, ConfigFormat, RestartHandle};
use log::{debug, info, warn};
use std::path::PathBuf;
use std::sync::Arc;
use tokio::sync::RwLock;

use serviceradar_sysmon_checker::{
    config::Config, poller::MetricsCollector, server::SysmonService, template,
};

#[tokio::main]
async fn main() -> Result<()> {
    env_logger::init_from_env(
        env_logger::Env::default().filter_or(env_logger::DEFAULT_FILTER_ENV, "debug"),
    );

    info!(
        "Starting serviceradar-sysmon-checker version {}",
        env!("CARGO_PKG_VERSION")
    );

    let matches = App::new("serviceradar-sysmon-checker")
        .version(env!("CARGO_PKG_VERSION"))
        .author(env!("CARGO_PKG_AUTHORS"))
        .about("ServiceRadar gRPC checker for system metrics")
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

    let config_path = matches.value_of("config").unwrap();
    let config_path = PathBuf::from(config_path);
    info!("Loading configuration from {config_path:?}");
    template::ensure_config_file(&config_path)
        .with_context(|| format!("failed to install default config at {config_path:?}"))?;

    let config_path_str = config_path.display().to_string();
    let use_kv = std::env::var("CONFIG_SOURCE").ok().as_deref() == Some("kv");
    let kv_key = use_kv.then(|| "config/sysmon-checker.json".to_string());
    let mut bootstrap = Bootstrap::new(BootstrapOptions {
        service_name: "sysmon-checker".to_string(),
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
            let restarter = RestartHandle::new("sysmon-checker", "config/sysmon-checker.json");
            tokio::spawn(async move {
                let mut cfg_watcher = watcher;
                while cfg_watcher.recv().await.is_some() {
                    restarter.trigger();
                }
            });
        }
    }

    info!("Server will listen on {}", config.listen_addr);
    debug!(
        "Config details: listen_addr={}, poll_interval={}, filesystems_count={}",
        config.listen_addr,
        config.poll_interval,
        config.filesystems.len()
    );

    // Initialize MetricsCollector
    debug!("Initializing MetricsCollector");
    let filesystems = config
        .filesystems
        .iter()
        .filter(|fs| fs.monitor)
        .map(|fs| fs.name.clone())
        .collect::<Vec<_>>();
    debug!("Monitoring filesystems: {filesystems:?}");

    let (zfs_pools, zfs_datasets) = config
        .zfs
        .as_ref()
        .map(|z| (z.pools.clone(), z.include_datasets))
        .unwrap_or_default();
    debug!("ZFS config: pools={zfs_pools:?}, datasets={zfs_datasets}");

    let host_id = std::env::var("HOSTNAME").unwrap_or_else(|_| {
        // Try to get the actual hostname from the system
        match hostname::get() {
            Ok(hostname) => {
                let hostname_str = hostname.to_string_lossy().to_string();
                info!("HOSTNAME env var not set, using system hostname: {hostname_str}");
                hostname_str
            }
            Err(e) => {
                warn!("Failed to get system hostname: {e}, using 'unknown'");
                "unknown".to_string()
            }
        }
    });
    debug!("Using host_id: {host_id}");

    let partition = config.partition.clone();
    debug!("Using partition: {partition:?}");

    let collector = Arc::new(RwLock::new(MetricsCollector::new(
        host_id,
        partition,
        filesystems,
        zfs_pools,
        zfs_datasets,
    )));
    debug!("MetricsCollector initialized");

    // Start server
    info!("Starting Sysmon gRPC server");
    let service = SysmonService::new(collector);
    let server_handle = service
        .start(Arc::new(config))
        .await
        .context("Failed to start sysmon service")?;
    info!("Sysmon gRPC server started");

    tokio::signal::ctrl_c().await?;
    info!("Shutdown signal received, stopping server...");
    server_handle.stop().await?;
    info!("Server stopped gracefully");

    Ok(())
}
