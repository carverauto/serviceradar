use anyhow::{Context, Result};
use clap::Parser;
use env_logger::Env;
use log::{debug, info, warn};
use serde::Deserialize;
use std::{fs, path::PathBuf, time::Duration};

use async_nats::jetstream::{
    self,
    consumer::pull::Config as PullConfig,
    stream::{Config as StreamConfig, StorageType},
    Message,
};
use async_nats::{Client, ConnectOptions};
use futures::StreamExt;
use zen_engine::handler::custom_node_adapter::NoopCustomNode;

use cloudevents::{EventBuilder, EventBuilderV10};
use url::Url;
use uuid::Uuid;
use zen_engine::DecisionEngine;

mod kv_loader;
use kv_loader::KvLoader;

type EngineType = DecisionEngine<KvLoader, NoopCustomNode>;
type SharedEngine = std::sync::Arc<EngineType>;

const BATCH_TIMEOUT: Duration = Duration::from_secs(1);

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
    result_subject_suffix: Option<String>,
    #[serde(default)]
    decision_keys: Vec<String>,
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
        if self.decision_keys.is_empty() {
            anyhow::bail!("at least one decision_key is required");
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
    info!("connected to nats at {}", cfg.nats_url);
    let js = jetstream::new(client.clone());
    Ok((client, js))
}

async fn build_engine(cfg: &Config, js: &jetstream::Context) -> Result<SharedEngine> {
    let store = js.get_key_value(&cfg.kv_bucket).await?;
    let prefix = format!("agents/{}", cfg.agent_id);
    let loader = KvLoader::new(store, prefix);
    info!("initialized decision engine with bucket {}", cfg.kv_bucket);
    Ok(std::sync::Arc::new(DecisionEngine::new(
        std::sync::Arc::new(loader),
        std::sync::Arc::new(zen_engine::handler::custom_node_adapter::NoopCustomNode::default()),
    )))
}

async fn process_message(
    engine: &SharedEngine,
    cfg: &Config,
    js: &jetstream::Context,
    msg: &Message,
) -> Result<()> {
    debug!("processing message on subject {}", msg.subject);
    let event: serde_json::Value = serde_json::from_slice(&msg.payload)?;
    for key in &cfg.decision_keys {
        let dkey = format!("{}/{}/{}", cfg.stream_name, msg.subject, key);
        let resp = engine
            .evaluate(&dkey, event.clone().into())
            .await
            .map_err(|e| anyhow::anyhow!(e.to_string()))?;
        debug!("decision {} evaluated", dkey);
        let resp_json = serde_json::to_value(&resp)?;
        let ce = EventBuilderV10::new()
            .id(Uuid::new_v4().to_string())
            .source(Url::parse(&format!(
                "nats://{}/{}",
                cfg.stream_name, msg.subject
            ))?)
            .ty(key.clone())
            .data("application/json", resp_json)
            .build()?;
        let data = serde_json::to_vec(&ce)?;
        if let Some(suffix) = &cfg.result_subject_suffix {
            let result_subject = format!("{}.{}", msg.subject, suffix.trim_start_matches('.'));
            js.publish(result_subject.clone(), data.clone().into())
                .await?
                .await
                .map_err(|e| anyhow::anyhow!(e.to_string()))?;
            debug!("published result to {}", result_subject);
        } else if let Some(subject) = &cfg.result_subject {
            js.publish(subject.clone(), data.clone().into())
                .await?
                .await
                .map_err(|e| anyhow::anyhow!(e.to_string()))?;
            debug!("published result to {}", subject);
        }
    }
    Ok(())
}

#[tokio::main]
async fn main() -> Result<()> {
    env_logger::Builder::from_env(Env::default().default_filter_or("info")).init();
    let cli = Cli::parse();
    let cfg = Config::from_file(&cli.config)?;

    let (_client, js) = connect_nats(&cfg).await?;
    let stream = match js.get_stream(&cfg.stream_name).await {
        Ok(s) => s,
        Err(_) => {
            let mut subjects = cfg.subjects.clone();
            if let Some(res) = &cfg.result_subject {
                subjects.push(res.clone());
            }
            if let Some(suffix) = &cfg.result_subject_suffix {
                for s in &cfg.subjects {
                    subjects.push(format!("{}.{}", s, suffix.trim_start_matches('.')));
                }
            }
            let sc = StreamConfig {
                name: cfg.stream_name.clone(),
                subjects,
                storage: StorageType::File,
                ..Default::default()
            };
            js.get_or_create_stream(sc).await?
        }
    };
    info!("using stream {}", cfg.stream_name);
    let desired_cfg = PullConfig {
        durable_name: Some(cfg.consumer_name.clone()),
        filter_subjects: cfg.subjects.clone(),
        ..Default::default()
    };
    let consumer = match stream.consumer_info(&cfg.consumer_name).await {
        Ok(info) => {
            if info.config.filter_subjects != cfg.subjects {
                warn!(
                    "consumer {} configuration changed, recreating",
                    cfg.consumer_name
                );
                stream
                    .delete_consumer(&cfg.consumer_name)
                    .await
                    .map_err(|e| anyhow::anyhow!(e.to_string()))?;
                stream
                    .create_consumer(desired_cfg.clone())
                    .await
                    .map_err(|e| anyhow::anyhow!(e.to_string()))?
            } else {
                stream
                    .get_consumer(&cfg.consumer_name)
                    .await
                    .map_err(|e| anyhow::anyhow!(e.to_string()))?
            }
        }
        Err(_) => stream
            .create_consumer(desired_cfg.clone())
            .await
            .map_err(|e| anyhow::anyhow!(e.to_string()))?,
    };
    info!("using consumer {}", cfg.consumer_name);

    let engine = build_engine(&cfg, &js).await?;
    let watch_engine = engine.clone();
    let watch_cfg = cfg.clone();
    let watch_js = js.clone();
    tokio::spawn(async move {
        if let Err(e) = watch_rules(watch_engine, watch_cfg, watch_js).await {
            warn!("rule watch failed: {e}");
        }
    });

    info!("waiting for messages on subjects: {:?}", cfg.subjects);

    loop {
        let mut messages = consumer
            .stream()
            .max_messages_per_batch(10)
            .expires(BATCH_TIMEOUT)
            .messages()
            .await?;
        debug!(
            "waiting for up to 10 messages or {:?} timeout",
            BATCH_TIMEOUT
        );
        while let Some(message) = messages.next().await {
            let message = message.map_err(|e| anyhow::anyhow!(e.to_string()))?;
            if let Err(e) = process_message(&engine, &cfg, &js, &message).await {
                warn!("processing failed: {e}");
                if let Err(e) = message
                    .ack_with(async_nats::jetstream::AckKind::Nak(None))
                    .await
                {
                    warn!("failed to NAK: {e}");
                }
                if let Ok(info) = message.info() {
                    debug!("nacked message {}", info.stream_sequence);
                }
            } else {
                message
                    .ack()
                    .await
                    .map_err(|e| anyhow::anyhow!(e.to_string()))?;
                if let Ok(info) = message.info() {
                    debug!("acknowledged message {}", info.stream_sequence);
                }
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
        assert_eq!(cfg.subjects, vec!["events.syslog".to_string()]);
        assert_eq!(cfg.decision_keys, vec!["example-decision".to_string()]);
        assert_eq!(cfg.agent_id, "agent-01");
        assert_eq!(cfg.kv_bucket, "serviceradar-kv");
        assert_eq!(cfg.result_subject_suffix.as_deref(), Some(".processed"));
    }

    #[test]
    fn test_config_validate_missing_fields() {
        let cfg = Config {
            nats_url: String::new(),
            stream_name: String::new(),
            consumer_name: String::new(),
            subjects: Vec::new(),
            result_subject: None,
            result_subject_suffix: None,
            decision_keys: Vec::new(),
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

async fn watch_rules(engine: SharedEngine, cfg: Config, js: jetstream::Context) -> Result<()> {
    let store = js.get_key_value(&cfg.kv_bucket).await?;
    let prefix = format!("agents/{}/{}/", cfg.agent_id, cfg.stream_name);
    let mut watcher = store.watch(format!("{}>", prefix)).await?;
    info!("watching rules under {}", prefix);
    while let Some(entry) = watcher.next().await {
        match entry {
            Ok(e) if matches!(e.operation, async_nats::jetstream::kv::Operation::Put) => {
                let key = e.key.trim_start_matches(&prefix).trim_end_matches(".json");
                if let Err(err) = engine.get_decision(key).await {
                    warn!("failed to reload rule {}: {}", key, err);
                } else {
                    log::info!("reloaded rule {} revision {}", key, e.revision);
                }
            }
            Ok(_) => {}
            Err(err) => {
                warn!("watch error: {err}");
                break;
            }
        }
    }
    Ok(())
}
