use anyhow::{Context, Result};
use clap::Parser;
use env_logger::Env;
use log::{info, warn};
use serde::Deserialize;
use serde::Serialize;
use std::fs;
use std::path::PathBuf;

use async_nats::jetstream::{self, consumer::pull::Config as ConsumerConfig};
use async_nats::{Client, ConnectOptions};
use clickhouse::{Client as ChClient, Row};
use futures::StreamExt;

#[derive(Parser, Debug)]
#[command(name = "db-event-writer")]
struct Cli {
    /// Path to configuration file
    #[arg(short, long, env = "DB_EVENT_WRITER_CONFIG")]
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
    clickhouse_url: String,
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
        if self.clickhouse_url.is_empty() {
            anyhow::bail!("clickhouse_url is required");
        }
        Ok(())
    }
}

#[derive(Row, Serialize)]
struct EventRow<'a> {
    specversion: &'a str,
    id: &'a str,
    #[serde(rename = "type")]
    event_type: &'a str,
    source: &'a str,
    datacontenttype: &'a str,
    device_id: &'a str,
    data: &'a str,
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

async fn process_message(ch: &ChClient, msg: &jetstream::Message) -> Result<()> {
    let v: serde_json::Value = serde_json::from_slice(&msg.payload)?;
    let specversion = v["specversion"].as_str().unwrap_or("");
    let id = v["id"].as_str().unwrap_or("");
    let event_type = v["type"].as_str().unwrap_or("");
    let source = v["source"].as_str().unwrap_or("");
    let datacontenttype = v
        .get("datacontenttype")
        .and_then(|d| d.as_str())
        .unwrap_or("");
    let device_id = v
        .get("data")
        .and_then(|d| d.get("_remote_addr"))
        .and_then(|d| d.as_str())
        .unwrap_or("");
    let data_str = v
        .get("data")
        .map(|d| d.to_string())
        .unwrap_or_else(|| "{}".to_string());

    let mut insert = ch.insert("events")?;
    insert
        .write(&EventRow {
            specversion,
            id,
            event_type,
            source,
            datacontenttype,
            device_id,
            data: &data_str,
        })
        .await?;
    insert.end().await?;
    Ok(())
}

#[tokio::main]
async fn main() -> Result<()> {
    env_logger::Builder::from_env(Env::default().default_filter_or("info")).init();
    let cli = Cli::parse();
    let cfg = Config::from_file(&cli.config)?;

    let (_client, js) = connect_nats(&cfg).await?;
    let stream = js.get_stream(&cfg.stream_name).await?;
    let desired = ConsumerConfig {
        durable_name: Some(cfg.consumer_name.clone()),
        filter_subjects: vec![
            "events.syslog.processed".to_string(),
            "events.snmp.processed".to_string(),
        ],
        ..Default::default()
    };
    let consumer = match stream.get_consumer(&cfg.consumer_name).await {
        Ok(c) => c,
        Err(_) => stream.create_consumer(desired).await?,
    };

    let ch = ChClient::default().with_url(&cfg.clickhouse_url);
    ch.query(
        "CREATE TABLE IF NOT EXISTS events (
            specversion String,
            id String,
            `type` String,
            source String,
            datacontenttype String,
            device_id String,
            data String
        ) ENGINE=MergeTree ORDER BY id",
    )
    .execute()
    .await?;

    info!("waiting for messages on events.*.processed");
    loop {
        let mut messages = consumer
            .stream()
            .max_messages_per_batch(10)
            .messages()
            .await?;
        while let Some(msg) = messages.next().await {
            let msg = msg?;
            if let Err(e) = process_message(&ch, &msg).await {
                warn!("processing failed: {e}");
                msg.ack_with(jetstream::AckKind::Nak(None)).await.ok();
            } else {
                msg.ack().await.ok();
            }
        }
    }
}
