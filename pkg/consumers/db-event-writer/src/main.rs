use anyhow::{Context, Result};
use async_nats::{jetstream, Client, ConnectOptions};
use clap::Parser;
use env_logger::Env;
use futures::StreamExt;
use log::{info, warn};
use serde::Deserialize;
use serde_json::Value;
use std::path::PathBuf;
use std::time::Duration;
use proton_client::prelude::{ProtonClient, Row};

#[derive(Parser, Debug)]
#[command(name = "serviceradar-db-event-writer")]
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
    #[serde(default)]
    subjects: Vec<String>,
    proton_url: String,
    #[serde(default = "default_table")]
    table_name: String,
    security: Option<SecurityConfig>,
}

fn default_table() -> String {
    "events".to_string()
}

impl Config {
    fn from_file<P: AsRef<std::path::Path>>(path: P) -> Result<Self> {
        let content = std::fs::read_to_string(path).context("failed to read config file")?;
        let cfg: Config = serde_json::from_str(&content).context("failed to parse config file")?;
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
        if self.subjects.is_empty() {
            anyhow::bail!("at least one subject is required");
        }
        if self.proton_url.is_empty() {
            anyhow::bail!("proton_url is required");
        }
        Ok(())
    }
}

#[derive(Debug, Row, serde::Serialize)]
struct EventRow {
    specversion: String,
    id: String,
    #[serde(rename = "type")]
    r#type: String,
    source: String,
    subject: Option<String>,
    datacontenttype: Option<String>,
    time: Option<String>,
    device_id: String,
    data: String,
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

async fn create_table(client: &ProtonClient, table: &str) -> Result<()> {
    let ddl = format!(
        "CREATE STREAM IF NOT EXISTS {table}(specversion string, id string, type string, source string, subject string, datacontenttype string, time string, device_id string, data string) ORDER BY id"
    );
    client.execute_query(&ddl).await.context("failed to create events table")?
        ;
    Ok(())
}

async fn process_message(client: &ProtonClient, table: &str, msg: &async_nats::Message) -> Result<()> {
    let ce: CloudEvent = serde_json::from_slice(&msg.payload)?;
    let device_id = ce
        .data
        .get("_remote_addr")
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_string();
    let row = EventRow {
        specversion: ce.specversion,
        id: ce.id,
        r#type: ce.r#type,
        source: ce.source,
        subject: ce.subject,
        datacontenttype: ce.datacontenttype,
        time: ce.time,
        device_id,
        data: serde_json::to_string(&ce.data)?,
    };
    let mut insert = client.insert(table).await?;
    insert.write(&row).await?;
    insert.end().await?;
    Ok(())
}

#[derive(Debug, Deserialize)]
struct CloudEvent {
    specversion: String,
    id: String,
    #[serde(rename = "type")]
    r#type: String,
    source: String,
    subject: Option<String>,
    datacontenttype: Option<String>,
    time: Option<String>,
    data: Value,
}

#[tokio::main]
async fn main() -> Result<()> {
    env_logger::Builder::from_env(Env::default().default_filter_or("info")).init();
    let cli = Cli::parse();
    let cfg = Config::from_file(&cli.config)?;

    let proton = ProtonClient::new(&cfg.proton_url);
    create_table(&proton, &cfg.table_name).await?;

    let (_nc, js) = connect_nats(&cfg).await?;
    let stream = js.get_stream(&cfg.stream_name).await?;
    let desired_cfg = jetstream::consumer::pull::Config {
        durable_name: Some(cfg.consumer_name.clone()),
        filter_subjects: cfg.subjects.clone(),
        ..Default::default()
    };
    let consumer = match stream.get_consumer(&cfg.consumer_name).await {
        Ok(c) => c,
        Err(_) => stream.create_consumer(desired_cfg.clone()).await?,
    };

    info!("waiting for messages on {:?}", cfg.subjects);
    loop {
        let mut messages = consumer
            .stream()
            .max_messages_per_batch(10)
            .expires(Duration::from_secs(1))
            .messages()
            .await
            .map_err(|e| anyhow::anyhow!(e.to_string()))?;
        while let Some(message) = messages.next().await {
            let message = message?;
            if let Err(e) = process_message(&proton, &cfg.table_name, &message).await {
                warn!("processing failed: {e}");
                message
                    .ack_with(jetstream::AckKind::Nak(None))
                    .await
                    .map_err(|e| anyhow::anyhow!(e.to_string()))?;
            } else {
                message
                    .ack()
                    .await
                    .map_err(|e| anyhow::anyhow!(e.to_string()))?;
            }
        }
    }
}
