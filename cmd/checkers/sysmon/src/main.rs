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
use edge_onboarding::{ComponentType, MtlsBootstrapConfig};
use log::{debug, info, warn};
use std::path::PathBuf;
use std::sync::Arc;
use tokio::sync::RwLock;

use serviceradar_sysmon_checker::{
    config::Config, poller::MetricsCollector, server::SysmonService, template,
};

const SYSTEMD_SERVICE_NAME: &str = "serviceradar-sysmon-checker";

/// Persist the mTLS config from the bootstrap location to the systemd expected path.
fn persist_mtls_config(source_path: &str, dest_path: &PathBuf) -> Result<()> {
    use std::fs;

    // Ensure parent directory exists
    if let Some(parent) = dest_path.parent() {
        fs::create_dir_all(parent)
            .with_context(|| format!("Failed to create config directory {:?}", parent))?;
    }

    // Copy the config file
    fs::copy(source_path, dest_path).with_context(|| {
        format!(
            "Failed to copy config from {} to {:?}",
            source_path, dest_path
        )
    })?;

    info!("Persisted mTLS config to {:?}", dest_path);
    Ok(())
}

/// Restart the systemd service to pick up the new configuration.
fn restart_systemd_service() -> Result<()> {
    use std::process::Command;

    // Check if running as root
    if unsafe { libc::geteuid() } != 0 {
        warn!(
            "Not running as root; cannot restart systemd service automatically. \
             Please run: sudo systemctl restart {}",
            SYSTEMD_SERVICE_NAME
        );
        return Ok(());
    }

    info!(
        "Restarting systemd service {} to apply new configuration...",
        SYSTEMD_SERVICE_NAME
    );

    let output = Command::new("systemctl")
        .args(["restart", SYSTEMD_SERVICE_NAME])
        .output()
        .context("Failed to execute systemctl")?;

    if output.status.success() {
        info!("Service restart initiated successfully");
    } else {
        let stderr = String::from_utf8_lossy(&output.stderr);
        warn!(
            "systemctl restart may have failed (exit code {:?}): {}",
            output.status.code(),
            stderr
        );
        warn!(
            "You may need to manually restart: sudo systemctl restart {}",
            SYSTEMD_SERVICE_NAME
        );
    }

    Ok(())
}

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
                .required(false),
        )
        .arg(
            Arg::with_name("mtls")
                .long("mtls")
                .help("Enable mTLS bootstrap mode")
                .takes_value(false),
        )
        .arg(
            Arg::with_name("token")
                .long("token")
                .value_name("TOKEN")
                .help("Edge onboarding token (edgepkg-v1 format)")
                .takes_value(true),
        )
        .arg(
            Arg::with_name("host")
                .long("host")
                .value_name("HOST")
                .help("Core API host for mTLS bundle download")
                .takes_value(true),
        )
        .arg(
            Arg::with_name("bundle")
                .long("bundle")
                .value_name("PATH")
                .help("Path to pre-fetched mTLS bundle")
                .takes_value(true),
        )
        .arg(
            Arg::with_name("cert-dir")
                .long("cert-dir")
                .value_name("PATH")
                .help("Directory to store certificates")
                .takes_value(true),
        )
        .arg(
            Arg::with_name("mtls-bootstrap-only")
                .long("mtls-bootstrap-only")
                .help("Run mTLS bootstrap, persist config to systemd path, restart service, then exit")
                .takes_value(false),
        )
        .get_matches();

    // Check for edge onboarding modes
    let mut config_path: Option<PathBuf> = matches.value_of("config").map(PathBuf::from);
    let mtls_mode = matches.is_present("mtls");
    let mtls_bootstrap_only = matches.is_present("mtls-bootstrap-only");
    let token = matches.value_of("token").map(String::from);
    let host = matches.value_of("host").map(String::from);
    let bundle_path = matches.value_of("bundle").map(String::from);
    let cert_dir = matches.value_of("cert-dir").map(String::from);

    // Try mTLS bootstrap first if --mtls flag is set
    if mtls_mode {
        let mtls_token = token
            .clone()
            .or_else(|| std::env::var("ONBOARDING_TOKEN").ok());
        if let Some(t) = mtls_token {
            info!("mTLS bootstrap mode enabled");
            let mtls_config = MtlsBootstrapConfig {
                token: t,
                host,
                bundle_path,
                cert_dir,
                service_name: Some("sysmon".to_string()),
            };

            match edge_onboarding::mtls_bootstrap(&mtls_config) {
                Ok(result) => {
                    info!("mTLS bootstrap successful");
                    info!("Generated config at: {}", result.config_path);
                    info!("Certificates installed to: {}", result.cert_dir);

                    // If --mtls-bootstrap-only, persist config and exit
                    if mtls_bootstrap_only {
                        let systemd_config_path =
                            PathBuf::from("/etc/serviceradar/checkers/sysmon.json");
                        persist_mtls_config(&result.config_path, &systemd_config_path)?;
                        restart_systemd_service()?;
                        info!("mTLS bootstrap-only mode complete; exiting");
                        return Ok(());
                    }

                    config_path = Some(PathBuf::from(&result.config_path));
                }
                Err(e) => {
                    return Err(anyhow::anyhow!("mTLS bootstrap failed: {}", e));
                }
            }
        } else {
            return Err(anyhow::anyhow!(
                "--mtls requires --token or ONBOARDING_TOKEN environment variable"
            ));
        }
    }

    // Try environment-based edge onboarding if no config path yet
    if config_path.is_none() {
        match edge_onboarding::try_onboard(ComponentType::Checker) {
            Ok(Some(result)) => {
                info!("Edge onboarding successful");
                info!("Generated config at: {}", result.config_path);
                if let Some(ref spiffe_id) = result.spiffe_id {
                    info!("SPIFFE ID: {}", spiffe_id);
                }
                config_path = Some(PathBuf::from(&result.config_path));
            }
            Ok(None) => {
                // No onboarding token, need a config file
                return Err(anyhow::anyhow!(
                    "No configuration provided. Use --config, --mtls, or set ONBOARDING_TOKEN"
                ));
            }
            Err(e) => {
                return Err(anyhow::anyhow!("Edge onboarding failed: {}", e));
            }
        }
    }

    let config_path = config_path.expect("config path should be set at this point");
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
        pinned_path: config_bootstrap::pinned_path_from_env(),
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
