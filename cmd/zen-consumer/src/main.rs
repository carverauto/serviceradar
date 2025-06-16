use anyhow::{Context, Result};
use clap::Parser;
use env_logger::Env;
use log::warn;
use serde::Deserialize;
use std::{fs, path::PathBuf};

use async_nats::jetstream::{self, consumer::pull::Config as PullConfig, Message};
use async_nats::{ConnectOptions, Client};
use futures::StreamExt;
use zen_engine::{DecisionEngine};
use zen_engine::loader::{FilesystemLoader, FilesystemLoaderOptions};
use zen_engine::handler::custom_node_adapter::NoopCustomNode;

type EngineType = DecisionEngine<FilesystemLoader, NoopCustomNode>;

#[derive(Parser, Debug)]
#[command(name = "serviceradar-zen-consumer")]
struct Cli {
    /// Path to configuration file
    #[arg(short, long, env = "ZEN_CONFIG")]
    config: String,
}

#[derive(Debug, Deserialize, Clone)]
struct SecurityConfig {
    cert_file: Option<String>,
    key_file: Option<String>,
    ca_file: Option<String>,
}

#[derive(Debug, Deserialize, Clone)]
struct Config {
    nats_url: String,
    stream_name: String,
    consumer_name: String,
    result_subject: Option<String>,
    decision_key: String,
    rules_dir: String,
    security: Option<SecurityConfig>,
}

impl Config {
    fn from_file<P: AsRef<std::path::Path>>(path: P) -> Result<Self> {
        let content = fs::read_to_string(path).context("Failed to read config file")?;
        let cfg: Config = serde_json::from_str(&content).context("Failed to parse config file")?;
        cfg.validate()?;
        Ok(cfg)
    }

    fn validate(&self) -> Result<()> {
        if self.nats_url.is_empty() {
            anyhow::bail!("nats_url is required");
        }
        if self.stream_name.is_empty() {
            anyhow::bail!("stream_name is required");
        }
        if self.consumer_name.is_empty() {
            anyhow::bail!("consumer_name is required");
        }
        if self.decision_key.is_empty() {
            anyhow::bail!("decision_key is required");
        }
        if self.rules_dir.is_empty() {
            anyhow::bail!("rules_dir is required");
        }
        Ok(())
    }
}

async fn connect_nats(cfg: &Config) -> Result<(Client, jetstream::Context)> {
    let mut opts = ConnectOptions::new();
    if let Some(sec) = &cfg.security {
        if let Some(ca) = &sec.ca_file {
            opts = opts.add_root_certificates(PathBuf::from(ca));
        }
        if let (Some(cert), Some(key)) = (&sec.cert_file, &sec.key_file) {
            opts = opts.add_client_certificate(PathBuf::from(cert), PathBuf::from(key));
        }
    }
    let client = opts.connect(&cfg.nats_url).await?;
    let js = jetstream::new(client.clone());
    Ok((client, js))
}

fn build_engine(cfg: &Config) -> Result<EngineType> {
    let options = FilesystemLoaderOptions {
        keep_in_memory: true,
        root: cfg.rules_dir.clone(),
    };
    let loader = FilesystemLoader::new(options);
    Ok(DecisionEngine::new(
        std::sync::Arc::new(loader),
        std::sync::Arc::new(zen_engine::handler::custom_node_adapter::NoopCustomNode::default()),
    ))
}

async fn process_message(engine: &EngineType, cfg: &Config, client: &Client, msg: &Message) -> Result<()> {
    let event: serde_json::Value = serde_json::from_slice(&msg.payload)?;
    let resp = engine
        .evaluate(&cfg.decision_key, event.into())
        .await
        .map_err(|e| anyhow::anyhow!(e.to_string()))?;
    if let Some(subject) = &cfg.result_subject {
        let data = serde_json::to_vec(&resp)?;
        client
            .publish(subject.clone(), data.into())
            .await
            .map_err(|e| anyhow::anyhow!(e.to_string()))?;
    }
    Ok(())
}

#[tokio::main]
async fn main() -> Result<()> {
    env_logger::Builder::from_env(Env::default().default_filter_or("info")).init();
    let cli = Cli::parse();
    let cfg = Config::from_file(&cli.config)?;

    let (client, js) = connect_nats(&cfg).await?;
    let stream = js.get_stream(&cfg.stream_name).await?;
    let consumer = stream
        .get_or_create_consumer(
            &cfg.consumer_name,
            PullConfig {
                durable_name: Some(cfg.consumer_name.clone()),
                ..Default::default()
            },
        )
        .await?;

    let engine = build_engine(&cfg)?;

    loop {
        let mut messages = consumer
            .stream()
            .max_messages_per_batch(10)
            .messages()
            .await?;
        while let Some(message) = messages.next().await {
            let message = message.map_err(|e| anyhow::anyhow!(e.to_string()))?;
            if let Err(e) = process_message(&engine, &cfg, &client, &message).await {
                warn!("processing failed: {e}");
                if let Err(e) = message.ack_with(async_nats::jetstream::AckKind::Nak(None)).await {
                    warn!("failed to NAK: {e}");
                }
            } else {
                message.ack().await.map_err(|e| anyhow::anyhow!(e.to_string()))?;
            }
        }
    }
}
