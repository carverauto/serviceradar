mod addon_config_json;
mod addon_service;
#[allow(dead_code, unused_imports)]
mod af_xdp;
#[allow(dead_code)]
mod af_xdp_classifier;
#[allow(dead_code)]
mod attribution;
mod banner_command;
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
mod kernel_layout;
#[allow(dead_code)]
mod lifecycle;
#[allow(dead_code)]
mod mdns;
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
mod uds;
use std::{
    path::{Path, PathBuf},
    sync::{Arc, Mutex},
    time::Duration,
};

use anyhow::{Context, Result};
use clap::{Parser, ValueEnum};
use tokio::sync::{broadcast, watch};

use crate::{
    capture::service::{AfPacketActivator, CaptureService},
    config::Config,
    external_flow::SharedExternalFlowMatcher,
    lifecycle::SystemStartupOps,
    metrics::{Metrics, serve_metrics},
    runtime_config::{DpiEventGate, FingerprintEventGate, RuntimeConfig},
    server::IpcServer,
};

#[cfg(target_os = "linux")]
use crate::lifecycle::{drop_runtime_privileges, prepare_ebpf_privileged_resources};

/// The AddonService socket, when `--addon-socket` is not given: a sibling of
/// the legacy IPC socket named `addon.sock`.
///
/// Derived rather than required, because the systemd unit is installed verbatim
/// next to the binary. A unit that named the flag would fail to start any
/// netprobe too old to parse it -- strictly worse than the agent falling back
/// to the legacy channel, which is the case this whole path exists to make
/// survivable. Binding is already best-effort (see the spawn below), so a
/// derived path that cannot be bound costs a log line, not a start.
fn default_addon_socket_path(ipc_socket: &Path) -> PathBuf {
    ipc_socket.with_file_name("addon.sock")
}

#[derive(Debug, Parser)]
#[command(author, version, about)]
struct Args {
    #[arg(long, env = "SERVICERADAR_NETPROBE_SOCKET")]
    socket: PathBuf,

    /// Socket for the generic AddonService contract, served alongside the
    /// legacy IPC socket above.
    ///
    /// Optional on purpose: when unset it defaults to a sibling of `--socket`,
    /// so the contract is served without the systemd unit naming it. See
    /// `default_addon_socket_path`.
    #[arg(long, env = "SERVICERADAR_NETPROBE_ADDON_SOCKET")]
    addon_socket: Option<PathBuf>,

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
    // Broadcast, not mpsc: the AddonService subscribes once per StreamTelemetry
    // RPC, and a single mpsc receiver could be handed out once only -- an agent
    // pump reconnect would then never see another fingerprint until netprobe
    // restarted. Same shape as census, mDNS and the process snapshots.
    let (fingerprint_event_tx, _) = broadcast::channel(4096);
    let (dpi_event_tx, _) = broadcast::channel(4096);
    // Flow attribution events can arrive in short bursts on busy worker nodes.
    // Keep the local IPC queue bounded, but large enough that the single agent
    // client can absorb bursty ring-buffer drains before its upstream push loop
    // batches them to the gateway.
    let (flow_attribution_event_tx, flow_attribution_event_rx) = event_queue::bounded(65_536);
    let (process_snapshot_tx, _) = broadcast::channel(128);
    // Census snapshots are whole-segment refreshes published every couple of
    // minutes, so a small buffer is plenty -- and a lagging receiver SHOULD drop
    // the older ones rather than replay them: each snapshot supersedes the last
    // completely, so the newest is the only one worth delivering.
    let (census_snapshot_tx, _) = broadcast::channel(4);
    // Same reasoning as the census channel: each mDNS snapshot completely
    // replaces the last, so a lagging receiver should get the newest rather
    // than a backlog of superseded views.
    let (mdns_snapshot_tx, _) = broadcast::channel(4);
    let runtime_config = RuntimeConfig::new(&config);
    let external_flow_matcher =
        SharedExternalFlowMatcher::new(runtime_config.external_flow_match_window_ms());
    let _fingerprint_gate = Arc::new(Mutex::new(FingerprintEventGate::new(
        runtime_config.clone(),
    )));
    let _dpi_gate = Arc::new(DpiEventGate::new(runtime_config.clone()));
    let metrics = Metrics::new()?;
    let mut startup_ops = SystemStartupOps;
    // Held for the life of the process. These are the AF_PACKET descriptors a
    // capture session takes later over IPC; dropping this closes them, and
    // they cannot be reopened once privileges are gone.
    let _capture_handles;
    let _visibility_runtime = match select_visibility_startup(&config, args.ebpf_object.is_some())?
    {
        VisibilityStartupMode::Disabled => {
            // Opens the capture descriptors and drops privileges, in that
            // order. This branch previously dropped without opening.
            _capture_handles = Some(lifecycle::initialize_privileged_resources(
                &mut startup_ops,
                &config,
                args.drop_user.as_deref(),
                args.skip_cap_check,
                args.allow_root,
            )?);
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
                let opened_captures = prepare_ebpf_privileged_resources(
                    &mut startup_ops,
                    &config,
                    args.skip_cap_check,
                )?;
                let runtime = ebpf_runtime::NetprobeEbpfRuntime::start(
                    ebpf_object,
                    &config,
                    metrics.clone(),
                    fingerprint_event_tx.clone(),
                    dpi_event_tx.clone(),
                    config
                        .emit_raw_flow_attribution_events
                        .then(|| flow_attribution_event_tx.clone()),
                    process_snapshot_tx.clone(),
                    census_snapshot_tx.clone(),
                    mdns_snapshot_tx.clone(),
                    external_flow_matcher.clone(),
                    Arc::clone(&_fingerprint_gate),
                    Arc::clone(&_dpi_gate),
                )
                .context("failed to start eBPF/AF_XDP visibility runtime")?;
                _capture_handles = Some(drop_runtime_privileges(
                    &mut startup_ops,
                    opened_captures,
                    args.drop_user.as_deref(),
                    args.allow_root,
                )?);
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
    // Served on its own socket, bound after privileges are dropped so it is
    // owned by the unprivileged runtime user. The legacy IPC socket below is
    // untouched: both run until the agent is confirmed to consume this one.
    {
        let addon_socket = args
            .addon_socket
            .clone()
            .unwrap_or_else(|| default_addon_socket_path(&args.socket));
        let addon = addon_service::NetprobeAddon::new(
            env!("CARGO_PKG_VERSION"),
            addon_service::TelemetryChannels {
                census: census_snapshot_tx.clone(),
                mdns: mdns_snapshot_tx.clone(),
                process: process_snapshot_tx.clone(),
                fingerprint: fingerprint_event_tx.clone(),
                dpi: dpi_event_tx.clone(),
            },
            // The SAME RuntimeConfig the IPC server holds, so both channels
            // converge on one VisibilityState rather than two that can disagree
            // about what is currently applied.
            runtime_config.clone(),
            // What this process actually booted with. The startup-only checks
            // must compare against the running values, not against the last
            // config netprobe was handed.
            addon_service::StartupSnapshot {
                capture_interfaces: config.capture_interfaces.clone(),
                flow_table_max_entries: crate::config::effective_flow_table_max_entries(
                    config.flow_table_max_entries,
                    config.capture_interfaces.len(),
                ),
            },
        );

        // Deliberately NOT selected on below. A failure to serve the new
        // contract must not stop netprobe serving the legacy IPC the agent
        // still depends on, so this is logged rather than fatal. The agent
        // notices a dead socket by failing to connect.
        tokio::spawn(async move {
            if let Err(err) = addon_service::serve(addon, addon_socket).await {
                log::error!("AddonService terminated: {err:#}");
            }
        });
    }

    // The descriptors opened above, now shared with the IPC surface that hands
    // them to capture sessions. `_capture_handles` moves in here: the Arc is
    // what keeps them open for the life of the process from this point on.
    let capture_service = _capture_handles.map(|handles| {
        Arc::new(CaptureService::new(
            Arc::new(Mutex::new(handles)),
            AfPacketActivator::default(),
        ))
    });

    let mut ipc_task = tokio::spawn(
        IpcServer::new(
            args.socket,
            flow_attribution_event_tx,
            flow_attribution_event_rx,
            census_snapshot_tx,
            mdns_snapshot_tx,
            external_flow_matcher,
            runtime_config,
            metrics,
            capture_service,
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
    use super::{VisibilityStartupMode, default_addon_socket_path, select_visibility_startup};
    use crate::config::Config;
    use std::path::{Path, PathBuf};

    #[test]
    fn addon_socket_defaults_beside_the_ipc_socket() {
        assert_eq!(
            default_addon_socket_path(Path::new("/run/serviceradar/netprobe/ipc.sock")),
            PathBuf::from("/run/serviceradar/netprobe/addon.sock")
        );
    }

    #[test]
    fn addon_socket_default_follows_a_relocated_ipc_socket() {
        // The agent derives the same sibling from whatever --socket the unit
        // names, so a non-default runtime dir must stay in agreement.
        assert_eq!(
            default_addon_socket_path(Path::new("/tmp/np-test/ipc.sock")),
            PathBuf::from("/tmp/np-test/addon.sock")
        );
    }

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
