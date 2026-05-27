mod capabilities;
mod capture;
mod config;
mod fingerprint;
mod framing;
mod lifecycle;
mod metrics;
mod proto;
mod runtime_config;
mod server;
#[cfg(feature = "pcap-capture")]
mod tls_server;

use std::{
    path::PathBuf,
    sync::{Arc, Mutex},
    time::Duration,
};

use anyhow::{Context, Result};
use clap::{Parser, ValueEnum};
use tokio::sync::{broadcast, watch};

use crate::{
    capture::CaptureWorkers,
    config::Config,
    lifecycle::{initialize_privileged_resources, SystemStartupOps},
    metrics::{serve_metrics, Metrics},
    runtime_config::{FingerprintEventGate, RuntimeConfig},
    server::IpcServer,
};

#[derive(Debug, Parser)]
#[command(author, version, about)]
struct Args {
    #[arg(long, env = "SERVICERADAR_NETPROBE_SOCKET")]
    socket: PathBuf,

    #[arg(long, env = "SERVICERADAR_NETPROBE_CONFIG")]
    config: Option<PathBuf>,

    #[arg(
        long,
        value_enum,
        default_value = "text",
        env = "SERVICERADAR_NETPROBE_LOG_FORMAT"
    )]
    log_format: LogFormat,

    #[arg(
        long,
        default_value_t = 9417,
        env = "SERVICERADAR_NETPROBE_HEALTH_PORT"
    )]
    health_port: u16,

    #[arg(long, env = "SERVICERADAR_NETPROBE_DROP_USER")]
    drop_user: Option<String>,

    #[arg(
        long,
        default_value_t = false,
        env = "SERVICERADAR_NETPROBE_SKIP_CAP_CHECK"
    )]
    skip_cap_check: bool,

    #[arg(
        long,
        default_value_t = false,
        env = "SERVICERADAR_NETPROBE_ALLOW_ROOT"
    )]
    allow_root: bool,
}

#[derive(Debug, Clone, Copy, ValueEnum)]
enum LogFormat {
    Text,
    Json,
}

#[tokio::main]
async fn main() -> Result<()> {
    let args = Args::parse();
    init_logging(args.log_format);

    let config = load_config(args.config.as_ref())?;
    if !config.enabled {
        log::info!("netprobe config is disabled; lifecycle IPC remains available");
    }

    let mut startup_ops = SystemStartupOps;
    let capture_handles = initialize_privileged_resources(
        &mut startup_ops,
        &config,
        args.drop_user.as_deref(),
        args.skip_cap_check,
        args.allow_root,
    )?;
    log::info!("opened {} capture interface(s)", capture_handles.len());

    let (shutdown_tx, shutdown_rx) = watch::channel(false);
    let (fingerprint_event_tx, _) = broadcast::channel(4096);
    let runtime_config = RuntimeConfig::new(&config);
    let fingerprint_gate = Arc::new(Mutex::new(FingerprintEventGate::new(
        runtime_config.clone(),
    )));
    let metrics = Metrics::new()?;
    let _capture_workers = CaptureWorkers::start(
        capture_handles,
        metrics.clone(),
        fingerprint_event_tx.clone(),
        fingerprint_gate,
    )
    .context("failed to start capture workers")?;
    let metrics_task = tokio::spawn(serve_metrics(
        args.health_port,
        metrics.clone(),
        shutdown_rx.clone(),
    ));
    let ipc_task = tokio::spawn(
        IpcServer::new(args.socket, fingerprint_event_tx, runtime_config).run(shutdown_rx),
    );

    wait_for_shutdown().await;
    let _ = shutdown_tx.send(true);

    let shutdown_deadline = tokio::time::timeout(Duration::from_secs(5), async {
        let metrics_result = metrics_task.await.context("metrics task join failed")?;
        metrics_result.context("metrics task failed")?;
        let ipc_result = ipc_task.await.context("IPC task join failed")?;
        ipc_result.context("IPC task failed")?;
        Ok::<(), anyhow::Error>(())
    })
    .await;

    match shutdown_deadline {
        Ok(result) => result,
        Err(_) => anyhow::bail!("netprobe did not shut down within 5 seconds"),
    }
}

fn init_logging(format: LogFormat) {
    match format {
        LogFormat::Text => {
            env_logger::Builder::from_env(env_logger::Env::default().default_filter_or("info"))
                .init();
        }
        LogFormat::Json => {
            env_logger::Builder::from_env(env_logger::Env::default().default_filter_or("info"))
                .format(|buf, record| {
                    use std::io::Write;
                    writeln!(
                        buf,
                        "{{\"level\":\"{}\",\"target\":\"{}\",\"message\":{}}}",
                        record.level(),
                        record.target(),
                        serde_json::to_string(&record.args().to_string())
                            .unwrap_or_else(|_| "\"\"".to_string())
                    )
                })
                .init();
        }
    }
}

fn load_config(path: Option<&PathBuf>) -> Result<Config> {
    let Some(path) = path else {
        return Ok(Config::default());
    };

    let contents = std::fs::read_to_string(path)
        .with_context(|| format!("failed to read config {}", path.display()))?;
    let config = serde_json::from_str(&contents)
        .with_context(|| format!("failed to parse config {}", path.display()))?;

    Ok(config)
}

async fn wait_for_shutdown() {
    #[cfg(unix)]
    {
        let mut sigterm = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())
            .expect("failed to install SIGTERM handler");
        tokio::select! {
            _ = tokio::signal::ctrl_c() => {}
            _ = sigterm.recv() => {}
        }
    }

    #[cfg(not(unix))]
    {
        let _ = tokio::signal::ctrl_c().await;
    }
}
