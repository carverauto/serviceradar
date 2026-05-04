mod config;
mod error;
pub mod flowpb;
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
use listener::{Listener, build_handler};
use metrics::{ListenerMetrics, MetricsReporter, run_prometheus_server};
use netflow_parser::TemplateStore;
use publisher::Publisher;
use std::sync::Arc;
use std::sync::Once;
use std::time::Duration;
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
    log::info!("  Channel size: {}", config.channel_size);
    log::info!("  Batch size: {}", config.batch_size);
    log::info!("  Drop policy: {:?}", config.drop_policy);
    log::info!("  Listeners: {}", config.listeners.len());

    for (i, listener_cfg) in config.listeners.iter().enumerate() {
        log::info!(
            "  Listener[{}]: protocol={}, addr={}, subject={}",
            i,
            listener_cfg.protocol_name(),
            listener_cfg.listen_addr(),
            listener_cfg.subject()
        );
    }

    // Create shared channel: all listeners send (subject, encoded_bytes) to one publisher
    let (tx, rx) = mpsc::channel(config.channel_size);

    // Spawn publisher
    let publisher_config = Arc::clone(&config);
    let publisher = Publisher::new(publisher_config, rx);
    let publisher_handle = tokio::spawn(async move {
        if let Err(e) = publisher.run().await {
            log::error!("Publisher error: {}", e);
        }
    });

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

        let listener = Listener::new(
            handler,
            socket,
            listener_cfg.buffer_size(),
            listener_cfg.subject().to_string(),
            tx.clone(),
            metrics,
        );

        let protocol = listener_cfg.protocol_name().to_string();
        let addr = listener_cfg.listen_addr().to_string();
        listener_handles.push(tokio::spawn(async move {
            if let Err(e) = listener.run().await {
                log::error!("[{}@{}] Listener error: {}", protocol, addr, e);
            }
        }));
    }

    // Drop the original sender so the publisher will shut down when all listeners stop
    drop(tx);

    // Spawn metrics reporter (periodic stdout log)
    let reporter_metrics = all_metrics.clone();
    let metrics_handle = tokio::spawn(async move {
        MetricsReporter::run(reporter_metrics).await;
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
        let _ = rustls::crypto::aws_lc_rs::default_provider().install_default();
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
