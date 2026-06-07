use std::{
    fs,
    io::Write,
    path::{Path, PathBuf},
    time::{Duration, SystemTime, UNIX_EPOCH},
};

use anyhow::{Context, Result};
use clap::Parser;
use serde::{Deserialize, Serialize};
use serviceradar_workload_identity::{
    discover_cri_endpoint, CriContainerLookup, CriEndpoint, CriRuntimeClient,
};

const DEFAULT_CONFIG_PATH: &str =
    "/var/lib/serviceradar/agent/addons/workload-identity/current/workload-identity.json";
const DEFAULT_SPOOL_DIR: &str = "/var/lib/serviceradar/workload-identity/spool";
const DEFAULT_REFRESH_INTERVAL_S: u64 = 60;
const MIN_REFRESH_INTERVAL_S: u64 = 10;
const DEFAULT_MAX_IDENTITIES: usize = 50_000;

#[derive(Debug, Parser)]
#[command(
    author,
    version,
    about = "Collect node-local workload identity metadata"
)]
struct Args {
    /// JSON config file path.
    #[arg(long, default_value = DEFAULT_CONFIG_PATH)]
    config: PathBuf,

    /// Root directory for endpoint discovery. Use / for live nodes.
    #[arg(long)]
    root: Option<PathBuf>,

    /// Run one collection cycle and exit.
    #[arg(long)]
    once: bool,
}

#[derive(Clone, Debug, Deserialize)]
struct Config {
    #[serde(default = "default_enabled")]
    enabled: bool,
    #[serde(default)]
    root: Option<PathBuf>,
    #[serde(default)]
    cri_endpoint: Option<PathBuf>,
    #[serde(default = "default_refresh_interval_s")]
    refresh_interval_s: u64,
    #[serde(default = "default_spool_dir")]
    spool_dir: PathBuf,
    #[serde(default = "default_max_identities")]
    max_identities: usize,
    #[serde(default, deserialize_with = "deserialize_optional_trimmed_string")]
    cluster_id: Option<String>,
    #[serde(default, deserialize_with = "deserialize_optional_trimmed_string")]
    cluster_name: Option<String>,
}

impl Default for Config {
    fn default() -> Self {
        Self {
            enabled: default_enabled(),
            root: None,
            cri_endpoint: None,
            refresh_interval_s: default_refresh_interval_s(),
            spool_dir: default_spool_dir(),
            max_identities: default_max_identities(),
            cluster_id: None,
            cluster_name: None,
        }
    }
}

#[derive(Debug, Serialize)]
struct Snapshot {
    observed_at_unix_nano: u128,
    enabled: bool,
    endpoint: Option<CriEndpoint>,
    count: usize,
    identities: Vec<CriContainerLookup>,
    degradation_reason: Option<String>,
    cluster_id: Option<String>,
    cluster_name: Option<String>,
}

#[cfg(unix)]
#[tokio::main]
async fn main() -> Result<()> {
    let args = Args::parse();
    let mut config = load_config(&args.config)?;
    if let Some(root) = args.root {
        config.root = Some(root);
    }

    loop {
        if let Err(err) = collect_once(&config).await {
            eprintln!("workload identity collection failed: {err:#}");
        }

        if args.once {
            return Ok(());
        }

        tokio::time::sleep(refresh_interval(config.refresh_interval_s)).await;
    }
}

#[cfg(not(unix))]
fn main() -> Result<()> {
    anyhow::bail!("workload identity collection requires Unix sockets")
}

#[cfg(unix)]
async fn collect_once(config: &Config) -> Result<()> {
    if !config.enabled {
        let snapshot = Snapshot {
            observed_at_unix_nano: now_unix_nano(),
            enabled: false,
            endpoint: None,
            count: 0,
            identities: Vec::new(),
            degradation_reason: Some("disabled".to_owned()),
            cluster_id: config.cluster_id.clone(),
            cluster_name: config.cluster_name.clone(),
        };
        return write_snapshot(&config.spool_dir, &snapshot);
    }

    let root = config.root.as_deref().unwrap_or_else(|| Path::new("/"));
    let Some(endpoint) = discover_cri_endpoint(root, config.cri_endpoint.as_deref()) else {
        let snapshot = Snapshot {
            observed_at_unix_nano: now_unix_nano(),
            enabled: true,
            endpoint: None,
            count: 0,
            identities: Vec::new(),
            degradation_reason: Some("no_cri_endpoint_discovered".to_owned()),
            cluster_id: config.cluster_id.clone(),
            cluster_name: config.cluster_name.clone(),
        };
        return write_snapshot(&config.spool_dir, &snapshot);
    };

    let mut client = CriRuntimeClient::connect(&endpoint).await?;
    let mut identities = client.list_container_identities().await?;
    let count = identities.len();
    identities.truncate(config.max_identities);

    let snapshot = Snapshot {
        observed_at_unix_nano: now_unix_nano(),
        enabled: true,
        endpoint: Some(endpoint),
        count,
        identities,
        degradation_reason: (count > config.max_identities)
            .then(|| "identity_limit_truncated".to_owned()),
        cluster_id: config.cluster_id.clone(),
        cluster_name: config.cluster_name.clone(),
    };

    write_snapshot(&config.spool_dir, &snapshot)
}

fn deserialize_optional_trimmed_string<'de, D>(deserializer: D) -> Result<Option<String>, D::Error>
where
    D: serde::Deserializer<'de>,
{
    let value = Option::<String>::deserialize(deserializer)?;
    Ok(value.and_then(|value| {
        let trimmed = value.trim();
        (!trimmed.is_empty()).then(|| trimmed.to_owned())
    }))
}

fn load_config(path: &Path) -> Result<Config> {
    match fs::read(path) {
        Ok(bytes) => serde_json::from_slice(&bytes)
            .with_context(|| format!("parse workload identity config {}", path.display())),
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => Ok(Config::default()),
        Err(err) => {
            Err(err).with_context(|| format!("read workload identity config {}", path.display()))
        }
    }
}

fn write_snapshot(spool_dir: &Path, snapshot: &Snapshot) -> Result<()> {
    fs::create_dir_all(spool_dir)
        .with_context(|| format!("create spool dir {}", spool_dir.display()))?;
    let data = serde_json::to_vec_pretty(snapshot)?;
    let latest = spool_dir.join("latest.json");
    let tmp = spool_dir.join(format!(".latest.{}.tmp", std::process::id()));

    {
        let mut file =
            fs::File::create(&tmp).with_context(|| format!("create {}", tmp.display()))?;
        file.write_all(&data)?;
        file.write_all(b"\n")?;
        file.sync_all()?;
    }

    fs::rename(&tmp, &latest)
        .with_context(|| format!("publish workload identity snapshot {}", latest.display()))?;

    Ok(())
}

fn refresh_interval(seconds: u64) -> Duration {
    Duration::from_secs(seconds.max(MIN_REFRESH_INTERVAL_S))
}

fn now_unix_nano() -> u128 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos()
}

fn default_enabled() -> bool {
    true
}

fn default_refresh_interval_s() -> u64 {
    DEFAULT_REFRESH_INTERVAL_S
}

fn default_spool_dir() -> PathBuf {
    PathBuf::from(DEFAULT_SPOOL_DIR)
}

fn default_max_identities() -> usize {
    DEFAULT_MAX_IDENTITIES
}
