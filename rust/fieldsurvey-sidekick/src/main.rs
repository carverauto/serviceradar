use anyhow::{Context, Result};
use clap::Parser;
use serviceradar_fieldsurvey_sidekick::api::{AppState, router};
use serviceradar_fieldsurvey_sidekick::config::SidekickConfig;
use std::net::SocketAddr;
use std::path::PathBuf;
use tokio::net::TcpListener;
use tracing::info;

#[derive(Debug, Parser)]
#[command(author, version, about)]
struct Args {
    #[arg(
        short,
        long,
        default_value = "/etc/serviceradar/fieldsurvey-sidekick.toml"
    )]
    config: PathBuf,

    #[arg(long)]
    listen_addr: Option<SocketAddr>,

    #[arg(long)]
    sysfs_net_path: Option<PathBuf>,
}

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| "serviceradar_fieldsurvey_sidekick=info,info".into()),
        )
        .init();

    let args = Args::parse();
    let config = match SidekickConfig::load(&args.config).await {
        Ok(config) => config,
        Err(err) if err.downcast_ref::<std::io::Error>().is_some() => {
            info!(
                path = %args.config.display(),
                "config file unavailable, using defaults"
            );
            SidekickConfig::default()
        }
        Err(err) => return Err(err),
    }
    .with_overrides(args.listen_addr, args.sysfs_net_path);

    let listener = TcpListener::bind(config.listen_addr)
        .await
        .with_context(|| format!("failed to bind {}", config.listen_addr))?;

    info!(
        listen_addr = %config.listen_addr,
        sysfs_net_path = %config.sysfs_net_path.display(),
        "starting FieldSurvey Sidekick daemon"
    );

    axum::serve(listener, router(AppState::new(config)))
        .with_graceful_shutdown(shutdown_signal())
        .await
        .context("sidekick HTTP server failed")
}

async fn shutdown_signal() {
    let ctrl_c = async {
        if let Err(err) = tokio::signal::ctrl_c().await {
            tracing::warn!(error = %err, "failed to install Ctrl-C handler");
        }
    };

    #[cfg(unix)]
    let terminate = async {
        match tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate()) {
            Ok(mut signal) => {
                signal.recv().await;
            }
            Err(err) => tracing::warn!(error = %err, "failed to install SIGTERM handler"),
        }
    };

    #[cfg(not(unix))]
    let terminate = std::future::pending::<()>();

    tokio::select! {
        _ = ctrl_c => {}
        _ = terminate => {}
    }
}
