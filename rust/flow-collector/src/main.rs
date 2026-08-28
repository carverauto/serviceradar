mod config;
mod error;
pub mod flowpb;
mod host_slice;
mod listener;
mod metrics;
mod nats_client;
mod netflow;
mod publisher;
mod sflow;
mod template_store;

use anyhow::{Context, Result};
use async_nats::jetstream;
use clap::Parser;
use config::{Config, TemplateStoreConfig};
use host_slice::HostSliceRouter;
use listener::{Listener, build_handler};
use metrics::{
    HostSliceMetricsRegistry, ListenerMetrics, MetricsReporter, SubjectDropRegistry,
    run_prometheus_server,
};
use netflow_parser::TemplateStore;
use publisher::{OutboundFlow, Publisher};
use std::sync::Arc;
use std::sync::Once;
use std::time::{Duration, Instant};
use template_store::NatsKvTemplateStore;
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
    let (publisher_tx, publisher_rx) = mpsc::channel::<OutboundFlow>(config.channel_size);

    // Spawn publisher
    let publisher_config = Arc::clone(&config);
    let publisher = Publisher::new(
        publisher_config,
        publisher_rx,
        Arc::clone(&host_slice_metrics),
    );
    let publisher_handle = tokio::spawn(async move { publisher.run().await });

    // If a template store is configured, open a separate NATS connection
    // for KV access and bootstrap the bucket. Kept independent of the
    // publisher's connection so KV failures cannot stall publishing and
    // vice versa.
    let template_store = match config.template_store.as_ref() {
        Some(ts_config) => {
            log::info!(
                "Template store enabled (NATS KV bucket: {})",
                ts_config.kv_bucket
            );
            Some(bootstrap_template_store(&config, ts_config).await?)
        }
        None => None,
    };

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

        let handler = build_handler(listener_cfg, template_store.clone(), Arc::clone(&metrics));

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
        let (listener_tx, mut listener_rx) = mpsc::channel::<OutboundFlow>(cap);

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
    // all forwarders complete (which happens when all listeners stop or we
    // abort them on SIGTERM).
    drop(publisher_tx);

    // Spawn metrics reporter (periodic stdout log)
    let subject_drops_for_reporter = Arc::clone(&subject_drops);
    let reporter_metrics = all_metrics.clone();
    let metrics_handle = tokio::spawn(async move {
        MetricsReporter::run(
            reporter_metrics,
            host_slice_metrics,
            subject_drops_for_reporter,
        )
        .await;
    });

    // Spawn the Prometheus exposition server if metrics_addr is set.
    // Lives independently of the publisher so a scrape failure can never
    // backpressure flow ingestion.
    if let Some(addr) = config.metrics_addr.clone() {
        let prom_metrics = all_metrics.clone();
        tokio::spawn(async move {
            if let Err(e) = run_prometheus_server(addr, prom_metrics).await {
                log::error!("Prometheus metrics server error: {}", e);
            }
        });
    }

    log::info!("Flow collector started successfully");

    // Wait for publisher, or SIGTERM/SIGINT for a graceful drain of the retry
    // queue (Kubernetes termination must enter this path — not only SIGKILL).
    // Use &mut on the JoinHandle so a signal branch does NOT drop/abort the
    // publisher task (dropping a JoinHandle aborts it and skips the drain).
    let mut publisher_handle = publisher_handle;
    let mut draining = false;
    tokio::select! {
        result = &mut publisher_handle => {
            match result {
                Ok(Ok(())) => log::info!("Publisher task completed"),
                Ok(Err(e)) => log::error!("Publisher task failed: {}", e),
                Err(e) => log::error!("Publisher task panicked: {}", e),
            }
        }
        _ = metrics_handle => {
            log::info!("Metrics reporter task completed");
        }
        _ = shutdown_signal() => {
            log::info!(
                "Shutdown signal received; stopping UDP listeners (not forwarders) so queued flows drain"
            );
            // Abort only listeners. Each aborted listener drops its mpsc Sender;
            // forwarders keep draining their Receivers, then drop publisher Senders.
            for handle in listener_handles {
                handle.abort();
            }
            draining = true;
        }
    }

    if draining {
        // One absolute deadline from signal receipt for forwarder + publisher drain.
        let grace_secs: u64 = std::env::var("TERMINATION_GRACE_PERIOD_SECONDS")
            .ok()
            .and_then(|s| s.parse().ok())
            .unwrap_or(45)
            .max(1);
        // Leave a small teardown margin; never invent a floor above configured grace.
        let budget_secs = grace_secs.saturating_sub(2).max(1);
        let deadline = Instant::now() + Duration::from_secs(budget_secs);
        log::info!(
            "Drain deadline {:?} from now (grace={}s, budget={}s)",
            deadline.saturating_duration_since(Instant::now()),
            grace_secs,
            budget_secs
        );

        for handle in _forwarder_handles {
            let remaining = deadline.saturating_duration_since(Instant::now());
            if remaining.is_zero() {
                log::warn!("Drain deadline hit while awaiting forwarders");
                break;
            }
            match tokio::time::timeout(remaining, handle).await {
                Ok(_) => {}
                Err(_) => log::warn!("Forwarder drain timed out against absolute deadline"),
            }
        }

        let remaining = deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() {
            log::error!("No time left for publisher drain after forwarders");
        } else {
            match tokio::time::timeout(remaining, publisher_handle).await {
                Ok(Ok(Ok(()))) => log::info!("Publisher drained and exited cleanly"),
                Ok(Ok(Err(e))) => log::error!("Publisher exited with error during drain: {}", e),
                Ok(Err(e)) => log::error!("Publisher task panicked during drain: {}", e),
                Err(_) => {
                    log::error!("Timed out waiting for publisher drain against absolute deadline")
                }
            }
        }
    }

    log::info!("Flow collector shutting down");
    Ok(())
}

async fn shutdown_signal() {
    let ctrl_c = tokio::signal::ctrl_c();
    #[cfg(unix)]
    {
        let mut sigterm =
            match tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate()) {
                Ok(s) => s,
                Err(err) => {
                    log::warn!("Failed to install SIGTERM handler: {}", err);
                    let _ = ctrl_c.await;
                    return;
                }
            };
        tokio::select! {
            _ = ctrl_c => {},
            _ = sigterm.recv() => {},
        }
    }
    #[cfg(not(unix))]
    {
        let _ = ctrl_c.await;
    }
}

fn ensure_rustls_provider_installed() {
    static INIT: Once = Once::new();
    INIT.call_once(|| {
        let _ = rustls::crypto::ring::default_provider().install_default();
    });
}

/// Connect to NATS, get-or-create the JetStream KV bucket, and wrap it in
/// a [`NatsKvTemplateStore`]. The connection is independent of the
/// publisher's connection so KV health and publish health can fail
/// independently — but it shares the publisher's TLS/creds settings via
/// `nats_client::connect_with_retry`, otherwise mTLS / creds-protected
/// NATS clusters would silently fail at TLS handshake here.
///
/// The connection target is `cfg.nats_url` if set, otherwise the
/// top-level `config.nats_url`, allowing template state to live on a
/// different NATS cluster from publish traffic.
async fn bootstrap_template_store(
    config: &Config,
    cfg: &TemplateStoreConfig,
) -> Result<Arc<dyn TemplateStore>> {
    let url = cfg.nats_url.as_deref().unwrap_or(&config.nats_url);
    let (_, js) = nats_client::connect_with_retry(url, config, "template-store").await?;

    // `create_or_update_key_value` returns the existing bucket if one with
    // this name exists, even if its settings differ — preferable to the
    // strict `create_key_value` which would error on config drift between
    // chart upgrades.
    let kv_config = jetstream::kv::Config {
        bucket: cfg.kv_bucket.clone(),
        // async-nats stores history as i64 internally but the server
        // caps at 64; the u8 in our config matches that ceiling and the
        // range is enforced in `Config::validate`.
        history: i64::from(cfg.kv_history),
        max_age: if cfg.kv_ttl_secs > 0 {
            Duration::from_secs(cfg.kv_ttl_secs)
        } else {
            Duration::from_secs(0)
        },
        ..Default::default()
    };
    let kv = js
        .create_or_update_key_value(kv_config)
        .await
        .with_context(|| format!("opening NATS KV bucket {}", cfg.kv_bucket))?;

    Ok(Arc::new(NatsKvTemplateStore::new(kv)))
}
