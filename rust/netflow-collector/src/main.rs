mod config;
mod converter;
mod error;
mod listener;
mod metrics;
mod publisher;

use anyhow::Result;
use clap::Parser;
use config::Config;
use listener::Listener;
use metrics::MetricsReporter;
use publisher::Publisher;
use std::sync::Arc;
use tokio::sync::mpsc;

#[derive(Parser, Debug)]
#[command(author, version, about, long_about = None)]
struct Args {
    /// Path to configuration file
    #[arg(short, long, default_value = "netflow-collector.json")]
    config: String,
}

#[tokio::main]
async fn main() -> Result<()> {
    env_logger::Builder::from_env(env_logger::Env::default().default_filter_or("info")).init();

    let args = Args::parse();

    log::info!("Starting ServiceRadar NetFlow Collector");
    log::info!("Loading configuration from: {}", args.config);

    // Load configuration
    let config = Arc::new(Config::from_file(&args.config)?);

    log::info!("Configuration loaded successfully");
    log::info!("  Listen address: {}", config.listen_addr);
    log::info!("  NATS URL: {}", config.nats_url);
    log::info!("  Stream name: {}", config.stream_name);
    log::info!("  Subject: {}", config.subject);
    log::info!("  Channel size: {}", config.channel_size);
    log::info!("  Batch size: {}", config.batch_size);
    log::info!("  Drop policy: {:?}", config.drop_policy);
    match &config.pending_flows {
        Some(pf) => {
            log::info!(
                "  Pending flow cache: enabled (max_pending_flows={}, max_entries_per_template={}, max_entry_size_bytes={})",
                pf.max_pending_flows,
                pf.max_entries_per_template,
                pf.max_entry_size_bytes
            );
        }
        None => {
            log::info!("  Pending flow cache: disabled");
        }
    }

    // Create bounded channel between listener and publisher
    let (tx, rx) = mpsc::channel(config.channel_size);

    // Create and spawn publisher task
    let publisher_config = Arc::clone(&config);
    let publisher = Publisher::new(publisher_config, rx);
    let publisher_handle = tokio::spawn(async move {
        if let Err(e) = publisher.run().await {
            log::error!("Publisher error: {}", e);
        }
    });

    // Create listener and wrap in Arc for sharing with metrics reporter
    let listener_config = Arc::clone(&config);
    let listener = Arc::new(Listener::new(listener_config, tx).await?);

    // Spawn metrics reporter task
    let metrics_listener = Arc::clone(&listener);
    let metrics_handle = tokio::spawn(async move {
        MetricsReporter::run(metrics_listener).await;
    });

    // Spawn listener task
    let listener_handle = tokio::spawn(async move {
        if let Err(e) = listener.run().await {
            log::error!("Listener error: {}", e);
        }
    });

    log::info!("NetFlow collector started successfully");

    // Wait for all tasks (they should run indefinitely)
    tokio::select! {
        result = listener_handle => {
            match result {
                Ok(_) => log::info!("Listener task completed"),
                Err(e) => log::error!("Listener task panicked: {}", e),
            }
        }
        result = publisher_handle => {
            match result {
                Ok(_) => log::info!("Publisher task completed"),
                Err(e) => log::error!("Publisher task panicked: {}", e),
            }
        }
        result = metrics_handle => {
            match result {
                Ok(_) => log::info!("Metrics reporter task completed"),
                Err(e) => log::error!("Metrics reporter task panicked: {}", e),
            }
        }
    }

    log::info!("NetFlow collector shutting down");
    Ok(())
}
