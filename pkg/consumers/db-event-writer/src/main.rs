use anyhow::Result;
use async_nats::jetstream::{self, consumer::{PullConsumer, pull::Config as PullConfig}, stream::Config as StreamConfig, stream::StorageType, Message, AckKind};
use async_nats::{Client, ConnectOptions};
use clap::Parser;
use env_logger::Env;
use futures::StreamExt;
use log::{info, warn};
use proton_client::prelude::{ProtonClient, Row};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::path::PathBuf;
use clickhouse::insert::Insert;

#[derive(Debug, Deserialize)]
struct SecurityConfig {
    cert_file: Option<String>,
    key_file: Option<String>,
    ca_file: Option<String>,
}

#[derive(Debug, Deserialize)]
struct Config {
    nats_url: String,
    stream_name: String,
    consumer_name: String,
    #[serde(default)]
    subjects: Vec<String>,
    proton_url: String,
    #[serde(default = "default_table")]
    table: String,
    security: Option<SecurityConfig>,
}

fn default_table() -> String {
    "events".to_string()
}

impl Config {
    fn from_file<P: AsRef<std::path::Path>>(path: P) -> Result<Self> {
        let content = std::fs::read_to_string(path)?;
        let mut cfg: Config = serde_json::from_str(&content)?;
        if cfg.subjects.is_empty() {
            cfg.subjects = vec![
                "events.syslog.processed".to_string(),
                "events.snmp.processed".to_string(),
            ];
        }
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
        if self.proton_url.is_empty() {
            anyhow::bail!("proton_url is required");
        }
        Ok(())
    }
}

#[derive(Debug, Parser)]
struct Cli {
    /// Path to configuration file
    #[arg(short, long, env = "DB_EVENT_WRITER_CONFIG")]
    config: String,
}

#[derive(Debug, Deserialize)]
struct CloudEvent {
    specversion: String,
    id: String,
    #[serde(rename = "type")]
    event_type: String,
    source: String,
    datacontenttype: Option<String>,
    data: Value,
}

#[derive(Row, Serialize)]
struct EventRow {
    specversion: String,
    id: String,
    #[serde(rename = "type")]
    r#type: String,
    source: String,
    datacontenttype: String,
    device_id: String,
    data: String,
}

impl EventRow {
    fn from_event(event: &CloudEvent, device_id: String, data: String) -> Self {
        Self {
            specversion: event.specversion.clone(),
            id: event.id.clone(),
            r#type: event.event_type.clone(),
            source: event.source.clone(),
            datacontenttype: event.datacontenttype.clone().unwrap_or_default(),
            device_id,
            data,
        }
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

async fn connect_proton(cfg: &Config) -> Result<ProtonClient> {
    Ok(ProtonClient::new(&cfg.proton_url))
}

async fn ensure_stream(js: &jetstream::Context, cfg: &Config) -> Result<jetstream::stream::Stream> {
    match js.get_stream(&cfg.stream_name).await {
        Ok(s) => Ok(s),
        Err(_) => {
            let sc = StreamConfig {
                name: cfg.stream_name.clone(),
                subjects: cfg.subjects.clone(),
                storage: StorageType::File,
                ..Default::default()
            };
            Ok(js.get_or_create_stream(sc).await?)
        }
    }
}

async fn ensure_consumer(stream: &jetstream::stream::Stream, cfg: &Config) -> Result<PullConsumer> {
    let desired = PullConfig {
        durable_name: Some(cfg.consumer_name.clone()),
        filter_subjects: cfg.subjects.clone(),
        ..Default::default()
    };
    match stream.consumer_info(&cfg.consumer_name).await {
        Ok(info) => {
            if info.config.filter_subjects != cfg.subjects {
                stream.delete_consumer(&cfg.consumer_name).await?;
                Ok(stream
                    .create_consumer(desired)
                    .await
                    .map_err(|e| anyhow::anyhow!(e.to_string()))?)
            } else {
                Ok(stream
                    .get_consumer(&cfg.consumer_name)
                    .await
                    .map_err(|e| anyhow::anyhow!(e.to_string()))?)
            }
        }
        Err(_) => Ok(stream
            .create_consumer(desired)
            .await
            .map_err(|e| anyhow::anyhow!(e.to_string()))?),
    }
}

async fn process_message(insert: &mut Insert<EventRow>, msg: &Message) -> Result<()> {
    let ce: CloudEvent = serde_json::from_slice(&msg.payload)?;
    let device_id = ce
        .data
        .get("_remote_addr")
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .to_string();
    let data_str = serde_json::to_string(&ce.data)?;
    insert.write(&EventRow::from_event(&ce, device_id, data_str)).await?;
    Ok(())
}

#[tokio::main]
async fn main() -> Result<()> {
    env_logger::Builder::from_env(Env::default().default_filter_or("info")).init();
    let cli = Cli::parse();
    let cfg = Config::from_file(&cli.config)?;
    cfg.validate()?;

    let (_client, js) = connect_nats(&cfg).await?;
    let stream = ensure_stream(&js, &cfg).await?;
    let consumer = ensure_consumer(&stream, &cfg).await?;

    let proton = connect_proton(&cfg).await?;
    let mut inserter = proton.insert(&cfg.table).await?;

    info!("waiting for messages on {:?}", cfg.subjects);

    loop {
        let mut messages = consumer
            .stream()
            .max_messages_per_batch(10)
            .expires(std::time::Duration::from_secs(30))
            .messages()
            .await?;
        while let Some(message) = messages.next().await {
            let message = message?;
            if let Err(e) = process_message(&mut inserter, &message).await {
                warn!("failed to process message: {e}");
                message
                    .ack_with(AckKind::Nak(None))
                    .await
                    .ok();
            } else {
                message.ack().await.ok();
            }
        }
    }
}

