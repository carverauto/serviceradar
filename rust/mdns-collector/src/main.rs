mod config;
mod converter;
mod dedup;
mod error;
mod listener;
mod metrics;
mod publisher;

use anyhow::Result;
use clap::Parser;
use config::Config;
use dedup::DedupCache;
use listener::Listener;
use metrics::MetricsReporter;
use publisher::Publisher;
use std::sync::Arc;
use tokio::sync::mpsc;

#[derive(Parser, Debug)]
#[command(author, version, about, long_about = None)]
struct Args {
    /// Path to configuration file
    #[arg(short, long, default_value = "mdns-collector.json")]
    config: String,
}

#[tokio::main]
async fn main() -> Result<()> {
    env_logger::Builder::from_env(env_logger::Env::default().default_filter_or("info")).init();

    let args = Args::parse();

    log::info!("Starting ServiceRadar mDNS Collector");
    log::info!("Loading configuration from: {}", args.config);

    let config = Arc::new(Config::from_file(&args.config)?);

    log::info!("Configuration loaded successfully");
    log::info!("  Listen address: {}", config.listen_addr);
    log::info!("  Multicast groups: {:?}", config.multicast_groups);
    log::info!("  NATS URL: {}", config.nats_url);
    log::info!("  Stream name: {}", config.stream_name);
    log::info!("  Subject: {}", config.subject);
    log::info!("  Channel size: {}", config.channel_size);
    log::info!("  Batch size: {}", config.batch_size);
    log::info!("  Drop policy: {:?}", config.drop_policy);
    log::info!(
        "  Dedup: ttl={}s, max_entries={}, cleanup_interval={}s",
        config.dedup_ttl_secs,
        config.dedup_max_entries,
        config.dedup_cleanup_interval_secs
    );

    // Create dedup cache
    let dedup = Arc::new(DedupCache::new(
        config.dedup_ttl_secs,
        config.dedup_max_entries,
    ));

    // Create bounded channel between listener and publisher
    let (tx, rx) = mpsc::channel(config.channel_size);

    // Create and spawn publisher task
    let publisher_config = Arc::clone(&config);
    let publisher = Publisher::new(publisher_config, rx);
    let publisher_handle = tokio::spawn(async move {
        if let Err(e) = publisher.run().await {
            log::error!("mDNS publisher error: {}", e);
        }
    });

    // Create listener
    let listener_config = Arc::clone(&config);
    let listener_dedup = Arc::clone(&dedup);
    let listener = Arc::new(Listener::new(listener_config, listener_dedup, tx).await?);

    // Spawn metrics/cleanup task
    let metrics_dedup = Arc::clone(&dedup);
    let cleanup_interval = config.dedup_cleanup_interval_secs;
    let metrics_handle = tokio::spawn(async move {
        MetricsReporter::run(metrics_dedup, cleanup_interval).await;
    });

    // Spawn listener task
    let listener_handle = tokio::spawn(async move {
        if let Err(e) = listener.run().await {
            log::error!("mDNS listener error: {}", e);
        }
    });

    log::info!("mDNS collector started successfully");

    // Wait for all tasks
    tokio::select! {
        result = listener_handle => {
            match result {
                Ok(_) => log::info!("mDNS listener task completed"),
                Err(e) => log::error!("mDNS listener task panicked: {}", e),
            }
        }
        result = publisher_handle => {
            match result {
                Ok(_) => log::info!("mDNS publisher task completed"),
                Err(e) => log::error!("mDNS publisher task panicked: {}", e),
            }
        }
        result = metrics_handle => {
            match result {
                Ok(_) => log::info!("mDNS metrics task completed"),
                Err(e) => log::error!("mDNS metrics task panicked: {}", e),
            }
        }
    }

    log::info!("mDNS collector shutting down");
    Ok(())
}
