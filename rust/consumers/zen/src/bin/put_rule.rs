use anyhow::{Context, Result};
use clap::Parser;
use serde::Deserialize;
use std::fs;
use std::path::PathBuf;
use std::sync::Once;

use async_nats::jetstream::kv::{Config as KvConfig, Store};
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
    /// Name of the decision key to store under
    #[arg(long)]
    key: String,
    /// Rule order for the subject index. Existing order is preserved when omitted.
    #[arg(long)]
    order: Option<u32>,
    /// Skip publishing when the KV entry already matches the file contents
    #[arg(long, default_value_t = false)]
    skip_if_unchanged: bool,
}

#[derive(Debug, Deserialize, Clone)]
struct SecurityConfig {
    cert_file: Option<String>,
    key_file: Option<String>,
    ca_file: Option<String>,
}

#[derive(Debug, Deserialize, Clone)]
#[allow(dead_code)]
struct Config {
    nats_url: String,
    #[serde(default)]
    nats_creds_file: Option<String>,
    #[serde(default)]
    domain: Option<String>,
    stream_name: String,
    consumer_name: String,
    #[serde(default)]
    subjects: Vec<String>,
    result_subject: Option<String>,
    result_subject_suffix: Option<String>,
    #[serde(default = "default_kv_bucket")]
    kv_bucket: String,
    agent_id: String,
    security: Option<SecurityConfig>,
}

#[derive(Debug, Clone, Deserialize, serde::Serialize)]
struct RuleIndex {
    version: u32,
    subject: String,
    rules: Vec<RuleIndexEntry>,
}

#[derive(Debug, Clone, Deserialize, serde::Serialize)]
struct RuleIndexEntry {
    key: String,
    order: u32,
}

fn default_kv_bucket() -> String {
    "serviceradar-datasvc".to_string()
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
    if let Some(creds_file) = &cfg.nats_creds_file {
        let creds_path = creds_file.trim();
        if !creds_path.is_empty() {
            opts = opts.credentials_file(PathBuf::from(creds_path)).await?;
        }
    }
    let client = opts.connect(&cfg.nats_url).await?;
    let js = if let Some(domain) = &cfg.domain {
        jetstream::with_domain(client, domain)
    } else {
        jetstream::new(client)
    };
    Ok(js)
}

#[tokio::main]
async fn main() -> Result<()> {
    ensure_rustls_provider_installed();
    let cli = Cli::parse();
    let cfg = Config::from_file(&cli.config)?;
    let js = connect_nats(&cfg).await?;
    let store = match js.get_key_value(&cfg.kv_bucket).await {
        Ok(store) => store,
        Err(_) => {
            let kv_config = KvConfig {
                bucket: cfg.kv_bucket.clone(),
                ..Default::default()
            };
            js.create_key_value(kv_config).await?;
            js.get_key_value(&cfg.kv_bucket).await?
        }
    };
    let data = fs::read(&cli.file).context("Failed to read rule file")?;
    let rule_key = cli.key;
    let key = format!(
        "agents/{}/{}/{}/{}.json",
        cfg.agent_id, cfg.stream_name, cli.subject, rule_key
    );
    if cli.skip_if_unchanged {
        if let Some(existing) = store.get(key.clone()).await? {
            if existing.as_ref() == data.as_slice() {
                println!(
                    "Rule {} unchanged for subject {}, skipping",
                    rule_key, cli.subject
                );
                return Ok(());
            }
        }
    }
    store.put(key, data.into()).await?;
    sync_rule_index(&store, &cfg, &cli.subject, &rule_key, cli.order).await?;
    println!("Inserted rule {} for subject {}", rule_key, cli.subject);
    Ok(())
}

async fn sync_rule_index(
    store: &Store,
    cfg: &Config,
    subject: &str,
    rule_key: &str,
    order: Option<u32>,
) -> Result<()> {
    let index_key = format!(
        "agents/{}/{}/{}/_rules.json",
        cfg.agent_id, cfg.stream_name, subject
    );

    let mut index = match store.get(index_key.clone()).await? {
        Some(bytes) => serde_json::from_slice::<RuleIndex>(&bytes).unwrap_or_else(|_| RuleIndex {
            version: 1,
            subject: subject.to_string(),
            rules: Vec::new(),
        }),
        None => RuleIndex {
            version: 1,
            subject: subject.to_string(),
            rules: Vec::new(),
        },
    };

    let next_order = order.unwrap_or_else(|| {
        index
            .rules
            .iter()
            .find(|entry| entry.key == rule_key)
            .map(|entry| entry.order)
            .or_else(|| {
                index
                    .rules
                    .iter()
                    .map(|entry| entry.order)
                    .max()
                    .map(|max| max + 10)
            })
            .unwrap_or(100)
    });

    index.rules.retain(|entry| entry.key != rule_key);
    index.rules.push(RuleIndexEntry {
        key: rule_key.to_string(),
        order: next_order,
    });
    index
        .rules
        .sort_by_key(|entry| (entry.order, entry.key.clone()));

    store
        .put(index_key, serde_json::to_vec(&index)?.into())
        .await?;

    Ok(())
}

fn ensure_rustls_provider_installed() {
    static ONCE: Once = Once::new();
    ONCE.call_once(|| {
        let _ = rustls::crypto::aws_lc_rs::default_provider().install_default();
    });
}
