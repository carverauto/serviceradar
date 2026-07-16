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
    CriContainerLookup, CriEndpoint, CriRuntimeClient, DockerEndpoint, DockerRuntimeClient,
    discover_cri_endpoint, discover_docker_endpoint,
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
    #[serde(default, deserialize_with = "deserialize_optional_nonempty_path")]
    root: Option<PathBuf>,
    #[serde(default)]
    cri_endpoint: Option<PathBuf>,
    #[serde(default)]
    docker_endpoint: Option<PathBuf>,
    #[serde(default)]
    runtime: Option<RuntimeConfig>,
    #[serde(default = "default_refresh_interval_s")]
    refresh_interval_s: u64,
    #[serde(
        default = "default_spool_dir",
        deserialize_with = "deserialize_spool_dir"
    )]
    spool_dir: PathBuf,
    #[serde(default = "default_max_identities")]
    max_identities: usize,
    #[serde(default, deserialize_with = "deserialize_optional_trimmed_string")]
    context_name: Option<String>,
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
            docker_endpoint: None,
            runtime: None,
            refresh_interval_s: default_refresh_interval_s(),
            spool_dir: default_spool_dir(),
            max_identities: default_max_identities(),
            context_name: None,
            cluster_id: None,
            cluster_name: None,
        }
    }
}

#[derive(Clone, Debug, Default, Deserialize)]
struct RuntimeConfig {
    #[serde(
        default,
        rename = "type",
        deserialize_with = "deserialize_optional_trimmed_string"
    )]
    kind: Option<String>,
    #[serde(default)]
    socket: Option<PathBuf>,
}

#[derive(Debug, Serialize)]
#[serde(tag = "type", content = "endpoint")]
enum SnapshotEndpoint {
    Cri(CriEndpoint),
    Docker(DockerEndpoint),
}

#[derive(Debug, Serialize)]
struct Snapshot {
    observed_at_unix_nano: u128,
    enabled: bool,
    endpoint: Option<SnapshotEndpoint>,
    count: usize,
    identities: Vec<CriContainerLookup>,
    degradation_reason: Option<String>,
    context_name: Option<String>,
    cluster_id: Option<String>,
    cluster_name: Option<String>,
}

struct CollectedIdentities {
    endpoint: Option<SnapshotEndpoint>,
    identities: Vec<CriContainerLookup>,
    degradation_reason: Option<String>,
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
            context_name: config.context_name.clone(),
            cluster_id: config.cluster_id.clone(),
            cluster_name: config.cluster_name.clone(),
        };
        return write_snapshot(&config.spool_dir, &snapshot);
    }

    let root = config.root.as_deref().unwrap_or_else(|| Path::new("/"));
    let mut collected = collect_identities(config, root).await?;
    let endpoint = collected.endpoint;
    let mut identities = collected.identities;
    let count = identities.len();
    identities.truncate(config.max_identities);
    let degradation_reason = if count > config.max_identities {
        Some("identity_limit_truncated".to_owned())
    } else {
        collected.degradation_reason.take()
    };

    let snapshot = Snapshot {
        observed_at_unix_nano: now_unix_nano(),
        enabled: true,
        endpoint,
        count,
        identities,
        degradation_reason,
        context_name: config.context_name.clone(),
        cluster_id: config.cluster_id.clone(),
        cluster_name: config.cluster_name.clone(),
    };

    write_snapshot(&config.spool_dir, &snapshot)
}

#[cfg(unix)]
async fn collect_identities(config: &Config, root: &Path) -> Result<CollectedIdentities> {
    match runtime_kind(config).as_deref() {
        None | Some("auto") => match collect_cri_identities(config, root).await {
            Ok(result) => Ok(result),
            Err(cri_err) => match collect_docker_identities(config, root).await {
                Ok(result) => Ok(result),
                Err(docker_err) => {
                    if let Some(reason) = no_endpoint_snapshot_reason(config, root) {
                        return Ok(CollectedIdentities {
                            endpoint: None,
                            identities: Vec::new(),
                            degradation_reason: Some(reason.to_owned()),
                        });
                    }

                    anyhow::bail!(
                        "auto runtime discovery failed; CRI error: {cri_err:#}; Docker error: {docker_err:#}"
                    );
                }
            },
        },
        Some("docker") => collect_docker_identities(config, root).await,
        Some("containerd") | Some("crio") | Some("cri") => {
            collect_cri_identities(config, root).await
        }
        Some(other) => anyhow::bail!("unsupported workload identity runtime type {other:?}"),
    }
}

#[cfg(unix)]
async fn collect_cri_identities(config: &Config, root: &Path) -> Result<CollectedIdentities> {
    let endpoint_path = config
        .cri_endpoint
        .as_deref()
        .or_else(|| runtime_socket_for(config, "cri"));
    let Some(endpoint) = discover_cri_endpoint(root, endpoint_path) else {
        anyhow::bail!("no_cri_endpoint_discovered");
    };

    let mut client = CriRuntimeClient::connect(&endpoint).await?;
    let identities = client.list_container_identities().await?;

    Ok(CollectedIdentities {
        endpoint: Some(SnapshotEndpoint::Cri(endpoint)),
        identities,
        degradation_reason: None,
    })
}

#[cfg(unix)]
async fn collect_docker_identities(config: &Config, root: &Path) -> Result<CollectedIdentities> {
    let endpoint_path = config
        .docker_endpoint
        .as_deref()
        .or_else(|| runtime_socket_for(config, "docker"));
    let Some(endpoint) = discover_docker_endpoint(root, endpoint_path) else {
        anyhow::bail!("no_docker_endpoint_discovered");
    };

    let mut client = DockerRuntimeClient::connect(&endpoint).await?;
    let identities = client.list_container_identities().await?;

    Ok(CollectedIdentities {
        endpoint: Some(SnapshotEndpoint::Docker(endpoint)),
        identities,
        degradation_reason: None,
    })
}

fn runtime_kind(config: &Config) -> Option<String> {
    config
        .runtime
        .as_ref()
        .and_then(|runtime| runtime.kind.as_deref())
        .map(|kind| kind.trim().to_ascii_lowercase())
}

fn runtime_socket_for<'a>(config: &'a Config, wanted: &str) -> Option<&'a Path> {
    let runtime = config.runtime.as_ref()?;
    let kind = runtime.kind.as_deref()?.trim().to_ascii_lowercase();
    match (wanted, kind.as_str()) {
        ("docker", "docker") => runtime.socket.as_deref(),
        ("cri", "containerd" | "crio" | "cri") => runtime.socket.as_deref(),
        _ => None,
    }
}

#[cfg(unix)]
fn no_endpoint_snapshot_reason(config: &Config, root: &Path) -> Option<&'static str> {
    let has_cri = discover_cri_endpoint(root, config.cri_endpoint.as_deref()).is_some();
    let has_docker = discover_docker_endpoint(root, config.docker_endpoint.as_deref()).is_some();
    (!has_cri && !has_docker).then_some("no_runtime_endpoint_discovered")
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

fn deserialize_optional_nonempty_path<'de, D>(deserializer: D) -> Result<Option<PathBuf>, D::Error>
where
    D: serde::Deserializer<'de>,
{
    let value = Option::<String>::deserialize(deserializer)?;
    Ok(value.and_then(|path| {
        let path = path.trim();
        (!path.is_empty()).then(|| PathBuf::from(path))
    }))
}

fn deserialize_spool_dir<'de, D>(deserializer: D) -> Result<PathBuf, D::Error>
where
    D: serde::Deserializer<'de>,
{
    Ok(deserialize_optional_nonempty_path(deserializer)?.unwrap_or_else(default_spool_dir))
}

fn default_max_identities() -> usize {
    DEFAULT_MAX_IDENTITIES
}

#[cfg(test)]
mod addon_config_contract_tests {
    use super::{Config, DEFAULT_SPOOL_DIR};
    use std::path::PathBuf;

    /// fj#4383 add-on config contract test: decodes the committed
    /// core-emitted `config_json` fixture with the REAL daemon decoder so
    /// core's delivery-path emitter and this struct cannot drift apart.
    /// Regenerate the fixture with
    /// `cd elixir/serviceradar_core && mix serviceradar.gen.addon_contract_fixtures`.
    const CORE_EMITTED_FIXTURE: &str = include_str!(
        "../../../../go/pkg/agent/testdata/addonconfig_contract/workload-identity.json"
    );

    #[test]
    fn decodes_core_emitted_contract_fixture() {
        let cfg: Config = serde_json::from_str(CORE_EMITTED_FIXTURE)
            .expect("core-emitted workload-identity config_json must decode with the real decoder");

        assert!(cfg.enabled);
        assert_eq!(cfg.root, Some(PathBuf::from("/")));
        assert_eq!(cfg.refresh_interval_s, 120);
        assert_eq!(cfg.max_identities, 50_000);
        assert_eq!(cfg.cluster_name.as_deref(), Some("demo-cluster"));

        let runtime = cfg.runtime.expect("runtime section present");
        assert_eq!(runtime.kind.as_deref(), Some("containerd"));
        assert_eq!(
            runtime.socket,
            Some(PathBuf::from("/run/containerd/containerd.sock"))
        );
    }

    #[test]
    fn explicit_blank_paths_use_operational_defaults() {
        let cfg: Config = serde_json::from_str(
            r#"{
                "root": "  ",
                "spool_dir": "",
                "refresh_interval_s": 60,
                "max_identities": 50000
            }"#,
        )
        .expect("blank path config must decode");

        assert_eq!(
            cfg.root, None,
            "blank root must retain live-node / behavior"
        );
        assert_eq!(cfg.spool_dir, PathBuf::from(DEFAULT_SPOOL_DIR));
    }
}
