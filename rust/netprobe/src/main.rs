#[allow(dead_code, unused_imports)]
mod af_xdp;
#[allow(dead_code)]
mod af_xdp_classifier;
#[allow(dead_code)]
mod attribution;
#[allow(dead_code)]
mod capabilities;
#[allow(dead_code)]
mod capture;
// The census module is shared with the library crate, which uses the whole of
// it. The binary drives only the runtime, so the record constants and the
// classification helpers its tests exercise look dead here. Same reason
// `capture` above carries this.
#[allow(dead_code)]
mod census;
mod config;
mod dpi;
#[cfg(target_os = "linux")]
mod ebpf_loader;
#[cfg(target_os = "linux")]
#[allow(dead_code)]
mod ebpf_runtime;
mod event_queue;
mod external_flow;
#[allow(dead_code)]
mod fingerprint;
mod framing;
#[allow(dead_code)]
mod hassh;
mod ipc;
#[allow(dead_code)]
mod ja4;
mod kernel;
#[allow(dead_code)]
mod lifecycle;
mod metrics;
#[allow(dead_code)]
mod muonfp;
#[allow(dead_code)]
mod os_matcher;
#[allow(dead_code)]
mod p0f_corpus;
mod p0f_encode;
#[allow(dead_code)]
mod p0f_matcher;
mod proto;
#[allow(dead_code)]
mod recog;
#[allow(dead_code)]
mod runtime_config;
#[allow(dead_code)]
mod satori;
mod server;
#[cfg(feature = "remote-capture")]
#[allow(dead_code)]
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
    config::Config,
    external_flow::SharedExternalFlowMatcher,
    lifecycle::{StartupOps, SystemStartupOps},
    metrics::{Metrics, serve_metrics},
    runtime_config::{DpiEventGate, FingerprintEventGate, RuntimeConfig},
    server::IpcServer,
};

#[cfg(target_os = "linux")]
use crate::lifecycle::{drop_runtime_privileges, prepare_ebpf_privileged_resources};

#[derive(Debug, Parser)]
#[command(author, version, about)]
struct Args {
    #[arg(long, env = "SERVICERADAR_NETPROBE_SOCKET")]
    socket: PathBuf,

    #[arg(long, env = "SERVICERADAR_NETPROBE_CONFIG")]
    config: Option<PathBuf>,

    #[arg(long, env = "SERVICERADAR_NETPROBE_EBPF_OBJECT")]
    ebpf_object: Option<PathBuf>,

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

#[derive(Debug, PartialEq, Eq)]
enum VisibilityStartupMode {
    Disabled,
    Ebpf,
}

#[allow(dead_code)]
enum VisibilityRuntime {
    Disabled,
    #[cfg(target_os = "linux")]
    Ebpf(Box<ebpf_runtime::NetprobeEbpfRuntime>),
}

#[tokio::main(worker_threads = 2)]
async fn main() -> Result<()> {
    let args = Args::parse();
    init_logging(args.log_format);

    let config = load_config(args.config.as_ref())?;
    if !config.enabled {
        log::info!("netprobe config is disabled; lifecycle IPC remains available");
    }

    let (shutdown_tx, shutdown_rx) = watch::channel(false);
    let (_fingerprint_event_tx, fingerprint_event_rx) = event_queue::bounded(4096);
    let (_dpi_event_tx, dpi_event_rx) = event_queue::bounded(4096);
    // Flow attribution events can arrive in short bursts on busy worker nodes.
    // Keep the local IPC queue bounded, but large enough that the single agent
    // client can absorb bursty ring-buffer drains before its upstream push loop
    // batches them to the gateway.
    let (flow_attribution_event_tx, flow_attribution_event_rx) = event_queue::bounded(65_536);
    let (process_snapshot_tx, _) = broadcast::channel(128);
    let runtime_config = RuntimeConfig::new(&config);
    let external_flow_matcher =
        SharedExternalFlowMatcher::new(runtime_config.external_flow_match_window_ms());
    let _fingerprint_gate = Arc::new(Mutex::new(FingerprintEventGate::new(
        runtime_config.clone(),
    )));
    let _dpi_gate = Arc::new(DpiEventGate::new(runtime_config.clone()));
    let metrics = Metrics::new()?;
    let mut startup_ops = SystemStartupOps;
    let _visibility_runtime = match select_visibility_startup(&config, args.ebpf_object.is_some())?
    {
        VisibilityStartupMode::Disabled => {
            startup_ops.drop_privileges(args.drop_user.as_deref(), args.allow_root)?;
            VisibilityRuntime::Disabled
        }
        VisibilityStartupMode::Ebpf => {
            #[cfg(not(target_os = "linux"))]
            {
                anyhow::bail!("--ebpf-object is only supported on Linux");
            }

            #[cfg(target_os = "linux")]
            {
                let ebpf_object = args
                    .ebpf_object
                    .as_deref()
                    .expect("checked ebpf_object is present");
                prepare_ebpf_privileged_resources(&mut startup_ops, &config, args.skip_cap_check)?;
                let runtime = ebpf_runtime::NetprobeEbpfRuntime::start(
                    ebpf_object,
                    &config,
                    metrics.clone(),
                    _fingerprint_event_tx.clone(),
                    _dpi_event_tx.clone(),
                    config
                        .emit_raw_flow_attribution_events
                        .then(|| flow_attribution_event_tx.clone()),
                    process_snapshot_tx.clone(),
                    external_flow_matcher.clone(),
                    Arc::clone(&_fingerprint_gate),
                    Arc::clone(&_dpi_gate),
                )
                .context("failed to start eBPF/AF_XDP visibility runtime")?;
                drop_runtime_privileges(
                    &mut startup_ops,
                    args.drop_user.as_deref(),
                    args.allow_root,
                )?;
                log::info!(
                    "started eBPF/AF_XDP visibility runtime for {} capture interface(s)",
                    config.capture_interfaces.len()
                );
                VisibilityRuntime::Ebpf(Box::new(runtime))
            }
        }
    };
    let mut metrics_task = tokio::spawn(serve_metrics(
        args.health_port,
        metrics.clone(),
        shutdown_rx.clone(),
    ));
    let mut ipc_task = tokio::spawn(
        IpcServer::new(
            args.socket,
            fingerprint_event_rx,
            dpi_event_rx,
            flow_attribution_event_tx,
            flow_attribution_event_rx,
            process_snapshot_tx,
            external_flow_matcher,
            runtime_config,
            metrics,
        )
        .run(shutdown_rx),
    );

    tokio::select! {
        _ = wait_for_shutdown() => {}
        result = &mut metrics_task => {
            result.context("metrics task join failed")?.context("metrics task failed")?;
            anyhow::bail!("metrics task exited unexpectedly");
        }
        result = &mut ipc_task => {
            result.context("IPC task join failed")?.context("IPC task failed")?;
            anyhow::bail!("IPC task exited unexpectedly");
        }
    }

    let _ = shutdown_tx.send(true);

    let shutdown_deadline = tokio::time::timeout(Duration::from_secs(5), async {
        let (metrics_result, ipc_result) = tokio::try_join!(
            async { metrics_task.await.context("metrics task join failed") },
            async { ipc_task.await.context("IPC task join failed") }
        )?;
        metrics_result.context("metrics task failed")?;
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
                        "{{\"timestamp_unix_nano\":{},\"level\":\"{}\",\"target\":\"{}\",\"message\":{}}}",
                        current_unix_nano(),
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

fn current_unix_nano() -> i128 {
    let Ok(duration) = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH) else {
        return 0;
    };

    i128::from(duration.as_secs()) * 1_000_000_000 + i128::from(duration.subsec_nanos())
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

fn select_visibility_startup(
    config: &Config,
    ebpf_object_present: bool,
) -> Result<VisibilityStartupMode> {
    if !config.enabled {
        return Ok(VisibilityStartupMode::Disabled);
    }

    if ebpf_object_present {
        return Ok(VisibilityStartupMode::Ebpf);
    }

    anyhow::bail!("netprobe continuous capture requires --ebpf-object after Phase 3 eBPF cutover")
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

#[cfg(test)]
mod tests {
    use super::{VisibilityStartupMode, select_visibility_startup};
    use crate::config::Config;

    #[test]
    fn disabled_config_does_not_start_ebpf_when_object_is_present() {
        let config = Config {
            enabled: false,
            ..Config::default()
        };

        let mode = select_visibility_startup(&config, true).expect("startup mode");

        assert_eq!(mode, VisibilityStartupMode::Disabled);
    }

    #[test]
    fn enabled_config_starts_ebpf_when_object_is_present() {
        let config = Config {
            enabled: true,
            ..Config::default()
        };

        let mode = select_visibility_startup(&config, true).expect("startup mode");

        assert_eq!(mode, VisibilityStartupMode::Ebpf);
    }

    #[test]
    fn enabled_config_requires_ebpf_object() {
        let config = Config {
            enabled: true,
            ..Config::default()
        };

        let err = select_visibility_startup(&config, false).expect_err("missing object must fail");

        assert!(
            err.to_string()
                .contains("netprobe continuous capture requires --ebpf-object")
        );
    }
}
