use std::path::{Path, PathBuf};

use anyhow::{Context, Result};
use clap::Parser;
use serde::Serialize;
use serviceradar_workload_identity::{
    CriContainerLookup, CriEndpoint, CriRuntimeClient, discover_cri_endpoint,
};

#[derive(Debug, Parser)]
#[command(
    author,
    version,
    about = "Validate node-local CRI workload identity enrichment"
)]
struct Args {
    /// Explicit CRI Unix socket path.
    #[arg(long, env = "SERVICERADAR_NETPROBE_CRI_ENDPOINT")]
    endpoint: Option<PathBuf>,

    /// Root directory for endpoint discovery. Use / for live nodes.
    #[arg(long, default_value = "/")]
    root: PathBuf,

    /// Return only one container identity.
    #[arg(long)]
    container_id: Option<String>,

    /// Maximum listed identities to print.
    #[arg(long, default_value_t = 25)]
    limit: usize,
}

#[derive(Debug, Serialize)]
struct CheckOutput {
    endpoint: CriEndpoint,
    count: usize,
    identities: Vec<CriContainerLookup>,
}

#[cfg(unix)]
#[tokio::main]
async fn main() -> Result<()> {
    let args = Args::parse();
    let endpoint = discover_cri_endpoint(&args.root, args.endpoint.as_deref())
        .with_context(|| discovery_error(&args.root, args.endpoint.as_deref()))?;
    let mut client = CriRuntimeClient::connect(&endpoint).await?;

    let mut identities = if let Some(container_id) = args.container_id.as_deref() {
        client
            .container_identity(container_id)
            .await?
            .map(|identity| {
                vec![CriContainerLookup {
                    container_id: container_id.to_string(),
                    identity,
                }]
            })
            .unwrap_or_default()
    } else {
        client.list_container_identities().await?
    };

    let count = identities.len();
    identities.truncate(args.limit);

    println!(
        "{}",
        serde_json::to_string_pretty(&CheckOutput {
            endpoint,
            count,
            identities,
        })?
    );

    Ok(())
}

#[cfg(not(unix))]
fn main() -> Result<()> {
    anyhow::bail!("CRI workload identity validation requires Unix sockets")
}

fn discovery_error(root: &Path, explicit: Option<&Path>) -> String {
    match explicit {
        Some(path) => format!(
            "no CRI socket found at explicit endpoint {} under root {}",
            path.display(),
            root.display()
        ),
        None => format!("no CRI socket discovered under root {}", root.display()),
    }
}
