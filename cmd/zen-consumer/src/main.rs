use anyhow::{Context, Result};
use clap::Parser;
use env_logger::Env;
use log::warn;
use serde::Deserialize;
use std::{fs, path::PathBuf};

use async_nats::jetstream::{self, consumer::pull::Config as PullConfig, Message};
use async_nats::{Client, ConnectOptions};
use futures::StreamExt;
use zen_engine::handler::custom_node_adapter::NoopCustomNode;

use zen_engine::DecisionEngine;

mod kv_loader;
use kv_loader::KvLoader;

type EngineType = DecisionEngine<KvLoader, NoopCustomNode>;

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
    #[serde(default)]
    subjects: Vec<String>,
    result_subject: Option<String>,
    decision_key: String,
    #[serde(default = "default_kv_bucket")]
    kv_bucket: String,
    agent_id: String,
    security: Option<SecurityConfig>,
}

fn default_kv_bucket() -> String {
    "serviceradar-kv".to_string()
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
        if self.agent_id.is_empty() {
            anyhow::bail!("agent_id is required");
        }
        if self.subjects.is_empty() {
            anyhow::bail!("at least one subject is required");
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

async fn build_engine(cfg: &Config, js: &jetstream::Context) -> Result<EngineType> {
    let store = js.get_key_value(&cfg.kv_bucket).await?;
    let prefix = format!("agents/{}", cfg.agent_id);
    let loader = KvLoader::new(store, prefix);
    Ok(DecisionEngine::new(
        std::sync::Arc::new(loader),
        std::sync::Arc::new(zen_engine::handler::custom_node_adapter::NoopCustomNode::default()),
    ))
}

async fn process_message(
    engine: &EngineType,
    cfg: &Config,
    client: &Client,
    msg: &Message,
) -> Result<()> {
    let event: serde_json::Value = serde_json::from_slice(&msg.payload)?;
    let decision_key = format!("{}/{}/{}", cfg.stream_name, msg.subject, cfg.decision_key);
    let resp = engine
        .evaluate(&decision_key, event.into())
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
                filter_subjects: cfg.subjects.clone(),
                ..Default::default()
            },
        )
        .await?;

    let engine = build_engine(&cfg, &js).await?;

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
                if let Err(e) = message
                    .ack_with(async_nats::jetstream::AckKind::Nak(None))
                    .await
                {
                    warn!("failed to NAK: {e}");
                }
            } else {
                message
                    .ack()
                    .await
                    .map_err(|e| anyhow::anyhow!(e.to_string()))?;
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_config_from_file() {
        let path = concat!(env!("CARGO_MANIFEST_DIR"), "/zen-consumer.json");
        let cfg = Config::from_file(path).unwrap();
        assert_eq!(cfg.nats_url, "nats://127.0.0.1:4222");
        assert_eq!(cfg.stream_name, "events");
        assert_eq!(cfg.consumer_name, "zen-consumer");
        assert_eq!(cfg.subjects, vec!["events".to_string()]);
        assert_eq!(cfg.decision_key, "example-decision");
        assert_eq!(cfg.agent_id, "agent-01");
        assert_eq!(cfg.kv_bucket, "serviceradar-kv");
        assert_eq!(cfg.result_subject.as_deref(), Some("events.processed"));
    }

    #[test]
    fn test_config_validate_missing_fields() {
        let cfg = Config {
            nats_url: String::new(),
            stream_name: String::new(),
            consumer_name: String::new(),
            subjects: Vec::new(),
            result_subject: None,
            decision_key: String::new(),
            kv_bucket: String::new(),
            agent_id: String::new(),
            security: None,
        };
        assert!(cfg.validate().is_err());
    }

    #[test]
    fn test_host_switch_testdata_parses() {
        let path = concat!(env!("CARGO_MANIFEST_DIR"), "/testdata/host_switch.json");
        let data = std::fs::read_to_string(path).unwrap();
        let parsed: zen_engine::model::DecisionContent = serde_json::from_str(&data).unwrap();
        assert!(!parsed.nodes.is_empty());
    }
}
