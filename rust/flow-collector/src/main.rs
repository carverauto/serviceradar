mod config;
mod error;
pub mod flowpb;
mod listener;
mod metrics;
mod netflow;
mod publisher;
mod sflow;

use anyhow::Result;
use clap::Parser;
use config::Config;
use listener::{Listener, build_handler};
use metrics::{ListenerMetrics, MetricsReporter};
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

    // Spawn listeners
    let mut listener_handles: Vec<JoinHandle<()>> = Vec::new();
    let mut all_metrics: Vec<Arc<ListenerMetrics>> = Vec::new();

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

    // Spawn metrics reporter
    let metrics_handle = tokio::spawn(async move {
        MetricsReporter::run(all_metrics).await;
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
        let _ = rustls::crypto::aws_lc_rs::default_provider().install_default();
    });
}
