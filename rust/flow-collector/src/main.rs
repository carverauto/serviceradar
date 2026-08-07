mod config;
mod error;
pub mod flowpb;
mod host_slice;
mod listener;
mod metrics;
mod netflow;
mod publisher;
mod sflow;

use anyhow::Result;
use clap::Parser;
use config::Config;
use host_slice::HostSliceRouter;
use listener::{Listener, build_handler};
use metrics::{HostSliceMetricsRegistry, ListenerMetrics, MetricsReporter, SubjectDropRegistry};
use publisher::Publisher;
use std::sync::Arc;
use std::sync::Once;
use tokio::net::UdpSocket;
use tokio::sync::mpsc;
use tokio::task::JoinHandle;

#[derive(Parser, Debug)]
#[command(author, version, about, long_about = None)]
struct Args {
    /// Path to configuration file
    #[arg(short, long, default_value = "flow-collector.json")]
    config: String,
}

#[tokio::main]
async fn main() -> Result<()> {
    ensure_rustls_provider_installed();
    env_logger::Builder::from_env(env_logger::Env::default().default_filter_or("info")).init();

    let args = Args::parse();

    log::info!("Starting ServiceRadar Flow Collector");
    log::info!("Loading configuration from: {}", args.config);

    let config = Arc::new(Config::from_file(&args.config)?);

    log::info!("Configuration loaded successfully");
    log::info!("  NATS URL: {}", config.nats_url);
    log::info!("  Stream name: {}", config.stream_name);
    log::info!("  Default channel size: {}", config.channel_size);
    log::info!("  Batch size: {}", config.batch_size);
    log::info!("  Backpressure policy: DropNewest (tokio mpsc::try_send; see config.rs comment)");
    log::info!("  Listeners: {}", config.listeners.len());

    for (i, listener_cfg) in config.listeners.iter().enumerate() {
        log::info!(
            "  Listener[{}]: protocol={}, addr={}, subject={}, channel_size={}",
            i,
            listener_cfg.protocol_name(),
            listener_cfg.listen_addr(),
            listener_cfg.subject(),
            listener_cfg.channel_size(config.channel_size)
        );
    }

    let host_slice_router = Arc::new(HostSliceRouter::from_config(&config));
    let host_slice_metrics = Arc::new(HostSliceMetricsRegistry::new(
        HostSliceRouter::metric_slices(&config),
    ));
    let subject_drops = Arc::new(SubjectDropRegistry::new());

    // Publisher fan-in: each listener owns a bounded per-listener mpsc and the
    // publisher consumes from a single merged channel. This isolates noisy
    // listeners from quiet ones — a saturated sflow stream no longer steals
    // capacity from a sparse netflow stream.
    let (publisher_tx, publisher_rx) = mpsc::channel::<(String, Vec<u8>)>(config.channel_size);

    // Spawn publisher
    let publisher_config = Arc::clone(&config);
    let publisher = Publisher::new(
        publisher_config,
        publisher_rx,
        Arc::clone(&host_slice_metrics),
    );
    let publisher_handle = tokio::spawn(async move {
        if let Err(e) = publisher.run().await {
            log::error!("Publisher error: {}", e);
        }
    });

    // Spawn listeners
    let mut listener_handles: Vec<JoinHandle<()>> = Vec::new();
    let mut all_metrics: Vec<Arc<ListenerMetrics>> = Vec::new();
    let mut _forwarder_handles: Vec<JoinHandle<()>> = Vec::new();

    for listener_cfg in &config.listeners {
        let metrics = Arc::new(ListenerMetrics::new(
            listener_cfg.protocol_name(),
            listener_cfg.listen_addr().to_string(),
        ));
        all_metrics.push(Arc::clone(&metrics));

        let handler = build_handler(listener_cfg, Arc::clone(&metrics));

        let socket = UdpSocket::bind(listener_cfg.listen_addr()).await?;
        log::info!(
            "{} listener bound to {}",
            listener_cfg.protocol_name(),
            listener_cfg.listen_addr()
        );

        // Per-listener bounded channel. Capacity defaults to the global
        // `channel_size` but can be overridden per listener so operators can
        // give sflow more headroom than netflow (or vice versa).
        let cap = listener_cfg.channel_size(config.channel_size);
        let (listener_tx, mut listener_rx) = mpsc::channel::<(String, Vec<u8>)>(cap);

        // Forwarder: drains this listener's channel into the shared publisher
        // channel. We use `send().await` here (not `try_send`) — by the time
        // a message reaches this point the listener has already accepted it,
        // so applying backpressure between the forwarder and the publisher
        // is correct (it pushes the queue depth back into the listener's
        // own channel, where drops are accounted per-subject).
        let publisher_tx_for_listener = publisher_tx.clone();
        let protocol_for_forwarder = listener_cfg.protocol_name().to_string();
        let addr_for_forwarder = listener_cfg.listen_addr().to_string();
        _forwarder_handles.push(tokio::spawn(async move {
            while let Some(msg) = listener_rx.recv().await {
                if publisher_tx_for_listener.send(msg).await.is_err() {
                    log::warn!(
                        "[{}@{}] Publisher channel closed; forwarder stopping",
                        protocol_for_forwarder,
                        addr_for_forwarder
                    );
                    break;
                }
            }
        }));

        let listener = Listener::new(
            handler,
            socket,
            listener_cfg.buffer_size(),
            listener_cfg.subject().to_string(),
            Arc::clone(&host_slice_router),
            listener_tx,
            metrics,
            Arc::clone(&subject_drops),
        );

        let protocol = listener_cfg.protocol_name().to_string();
        let addr = listener_cfg.listen_addr().to_string();
        listener_handles.push(tokio::spawn(async move {
            if let Err(e) = listener.run().await {
                log::error!("[{}@{}] Listener error: {}", protocol, addr, e);
            }
        }));
    }

    // Drop the original publisher sender so the publisher will shut down when
    // all forwarders complete (which happens when all listeners stop).
    drop(publisher_tx);

    // Spawn metrics reporter
    let subject_drops_for_reporter = Arc::clone(&subject_drops);
    let metrics_handle = tokio::spawn(async move {
        MetricsReporter::run(all_metrics, host_slice_metrics, subject_drops_for_reporter).await;
    });

    log::info!("Flow collector started successfully");

    // Wait for publisher — if it dies, we exit
    tokio::select! {
        result = publisher_handle => {
            match result {
                Ok(_) => log::info!("Publisher task completed"),
                Err(e) => log::error!("Publisher task panicked: {}", e),
            }
        }
        _ = metrics_handle => {
            log::info!("Metrics reporter task completed");
        }
    }

    log::info!("Flow collector shutting down");
    Ok(())
}

fn ensure_rustls_provider_installed() {
    static INIT: Once = Once::new();
    INIT.call_once(|| {
        let _ = rustls::crypto::ring::default_provider().install_default();
    });
}
