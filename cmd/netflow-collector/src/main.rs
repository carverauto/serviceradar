mod config;
mod converter;
mod listener;
mod publisher;
mod spiffe;

use anyhow::Result;
use clap::Parser;
use config::Config;
use listener::Listener;
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

    // Create and spawn listener task
    let listener_config = Arc::clone(&config);
    let listener = Listener::new(listener_config, tx).await?;
    let listener_handle = tokio::spawn(async move {
        if let Err(e) = listener.run().await {
            log::error!("Listener error: {}", e);
        }
    });

    log::info!("NetFlow collector started successfully");

    // Wait for both tasks (they should run indefinitely)
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
    }

    log::info!("NetFlow collector shutting down");
    Ok(())
}
