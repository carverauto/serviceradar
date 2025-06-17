use anyhow::{Context, Result};
use clap::Parser;
use serde::Deserialize;
use std::fs;
use std::path::PathBuf;

use async_nats::jetstream::{self};
use async_nats::ConnectOptions;

#[derive(Parser, Debug)]
#[command(name = "zen-put-rule")]
struct Cli {
    /// Path to configuration file
    #[arg(short, long, env = "ZEN_CONFIG")]
    config: String,
    /// Path to decision JSON file
    #[arg(short, long)]
    file: String,
    /// Subject of the messages this rule applies to
    #[arg(short, long)]
    subject: String,
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
        Ok(cfg)
    }
}

async fn connect_nats(cfg: &Config) -> Result<jetstream::Context> {
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
    Ok(jetstream::new(client))
}

#[tokio::main]
async fn main() -> Result<()> {
    let cli = Cli::parse();
    let cfg = Config::from_file(&cli.config)?;
    let js = connect_nats(&cfg).await?;
    let store = js.get_key_value(&cfg.kv_bucket).await?;
    let data = fs::read(&cli.file).context("Failed to read rule file")?;
    let key = format!(
        "agents/{}/{}/{}/{}.json",
        cfg.agent_id, cfg.stream_name, cli.subject, cfg.decision_key
    );
    store.put(key, data.into()).await?;
    println!("Inserted rule for subject {}", cli.subject);
    Ok(())
}
