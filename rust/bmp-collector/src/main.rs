mod config;
mod model;
mod publisher;

use crate::config::Config;
use crate::publisher::Publisher;
use anyhow::{Context, Result};
use clap::Parser;
use log::{error, info};
use serde::Deserialize;
use std::path::PathBuf;
use std::sync::Arc;
use tokio::io::{self, AsyncBufReadExt, BufReader};

#[derive(Parser, Debug)]
#[command(name = "serviceradar-bmp-collector")]
#[command(about = "Publishes risotto-decoded BMP events to NATS JetStream")]
struct Cli {
    /// Path to bmp collector JSON config.
    #[arg(long, default_value = "rust/bmp-collector/bmp-collector.json")]
    config: PathBuf,

    /// Optional NDJSON input file of decoded BMP events. If omitted, reads stdin.
    #[arg(long)]
    input: Option<PathBuf>,
}

#[tokio::main]
async fn main() -> Result<()> {
    env_logger::init();

    let cli = Cli::parse();
    let cfg = Config::from_file(path_to_string(&cli.config)?)?;

    info!(
        "starting bmp collector publisher stream={} prefix={}",
        cfg.stream_name, cfg.subject_prefix
    );

    let publisher = Publisher::connect(Arc::new(cfg)).await?;
    run_publish_loop(&publisher, cli.input).await
}

async fn run_publish_loop(publisher: &Publisher, input: Option<PathBuf>) -> Result<()> {
    if let Some(path) = input {
        let file = tokio::fs::File::open(&path)
            .await
            .with_context(|| format!("failed opening {}", path.display()))?;
        let mut lines = BufReader::new(file).lines();

        while let Some(line) = lines.next_line().await? {
            publish_line(publisher, line).await?;
        }

        return Ok(());
    }

    let stdin = io::stdin();
    let mut lines = BufReader::new(stdin).lines();

    while let Some(line) = lines.next_line().await? {
        publish_line(publisher, line).await?;
    }

    Ok(())
}

async fn publish_line(publisher: &Publisher, line: String) -> Result<()> {
    if line.trim().is_empty() {
        return Ok(());
    }

    // Parse only envelope keys as borrowed refs, then publish original bytes.
    // This avoids full deserialize/serialize churn on hot BMP paths.
    let envelope: BorrowedEnvelope<'_> = serde_json::from_str(line.as_str())
        .with_context(|| format!("invalid BMP event JSON envelope: {}", line))?;
    let event_type = envelope.event_type.to_owned();
    let event_id = envelope.event_id.to_owned();

    if let Err(err) = publisher
        .publish_raw_event(event_type.as_str(), event_id.as_str(), line.into_bytes())
        .await
    {
        error!("failed publishing event {}: {}", event_id, err);
        return Err(err);
    }

    Ok(())
}

fn path_to_string(path: &PathBuf) -> Result<&str> {
    path.to_str()
        .ok_or_else(|| anyhow::anyhow!("config path contains non-UTF-8 characters"))
}

#[derive(Debug, Deserialize)]
struct BorrowedEnvelope<'a> {
    event_id: &'a str,
    event_type: &'a str,
}
