mod config;

use anyhow::Result;
use clap::{Arg, Command};
use config_bootstrap::{Bootstrap, BootstrapOptions, ConfigFormat};
use log::{error, info};
use std::io::{Write, stderr};
use std::net::SocketAddr;
use std::sync::Once;
#[cfg(feature = "otel")]
use std::time::Duration;
use tokio::task::{JoinError, JoinSet};
use tonic_health::ServingStatus;
use tonic_health::server::health_reporter;

const VERSION: &str = env!("CARGO_PKG_VERSION");

#[tokio::main]
async fn main() {
    ensure_rustls_provider_installed();
    let _ = env_logger::Builder::from_env(env_logger::Env::default().default_filter_or("info"))
        .format(|buf, record| {
            writeln!(
                buf,
                "{} {} {}",
                buf.timestamp_seconds(),
                record.level(),
                record.args()
            )
        })
        .try_init();

    if let Err(err) = run().await {
        let _ = writeln!(stderr(), "serviceradar-log-collector error: {err}");
        std::process::exit(1);
    }
}

fn ensure_rustls_provider_installed() {
    static ONCE: Once = Once::new();
    ONCE.call_once(|| {
        let _ = rustls::crypto::ring::default_provider().install_default();
    });
}

async fn run() -> Result<()> {
    let matches = Command::new("serviceradar-log-collector")
        .version(VERSION)
        .about("Unified log collector for ServiceRadar (syslog/GELF + OpenTelemetry)")
        .arg(
            Arg::new("config_file")
                .short('c')
                .long("config")
                .help("Path to the log-collector config file")
                .value_name("FILE"),
        )
        .get_matches();

    let config_file = matches
        .get_one::<String>("config_file")
        .map(|s| s.as_ref())
        .unwrap_or("/etc/serviceradar/log-collector.toml");

    let pinned_path = config_bootstrap::pinned_path_from_env();
    let mut bootstrap = Bootstrap::new(BootstrapOptions {
        service_name: "log-collector".to_string(),
        config_path: config_file.to_string(),
        format: ConfigFormat::Toml,
        pinned_path,
    })
    .await?;

    let cfg: config::Config = bootstrap.load().await?;

    info!(
        "serviceradar-log-collector v{VERSION} starting (flowgger={}, otel={})",
        cfg.flowgger.enabled, cfg.otel.enabled
    );

    let mut pipelines: JoinSet<&'static str> = JoinSet::new();

    // --- Flowgger (syslog/GELF) pipeline ---
    #[cfg(feature = "syslog")]
    if cfg.flowgger.enabled {
        let flowgger_config = cfg.flowgger.config_file.clone();
        info!("Starting Flowgger pipeline with config: {flowgger_config}");

        // Flowgger uses sync threads internally, so we run it in a blocking task.
        pipelines.spawn_blocking(move || {
            flowgger::start(&flowgger_config);
            "flowgger"
        });
    }

    // --- OTEL gRPC collector ---
    #[cfg(feature = "otel")]
    if cfg.otel.enabled {
        let otel_config_path = cfg.otel.config_file.clone();
        info!("Starting OTEL collector with config: {otel_config_path}");

        pipelines.spawn(async move {
            let mut backoff_secs: u64 = 1;
            loop {
                if let Err(e) = start_otel(&otel_config_path).await {
                    error!("OTEL collector error: {e}");
                } else {
                    error!("OTEL collector exited unexpectedly; restarting");
                }
                tokio::time::sleep(Duration::from_secs(backoff_secs)).await;
                backoff_secs = (backoff_secs * 2).min(30);
            }
        });
    }

    if pipelines.is_empty() {
        anyhow::bail!("No inputs enabled — enable at least one of [flowgger] or [otel]");
    }

    // --- Unified gRPC health check ---
    let health_addr: SocketAddr = cfg.health.listen_addr.parse()?;
    let (reporter, health_service) = health_reporter();

    reporter
        .set_service_status("", ServingStatus::Serving)
        .await;
    reporter
        .set_service_status("log-collector", ServingStatus::Serving)
        .await;

    #[cfg(feature = "syslog")]
    if cfg.flowgger.enabled {
        reporter
            .set_service_status("flowgger", ServingStatus::Serving)
            .await;
    }
    #[cfg(feature = "otel")]
    if cfg.otel.enabled {
        reporter
            .set_service_status("otel", ServingStatus::Serving)
            .await;
    }

    info!("gRPC health server on {health_addr}");
    tokio::spawn(async move {
        if let Err(e) = tonic::transport::Server::builder()
            .add_service(health_service)
            .serve(health_addr)
            .await
        {
            error!("gRPC health server error: {e}");
        }
    });

    tokio::select! {
        shutdown = tokio::signal::ctrl_c() => {
            shutdown?;
            info!("Shutdown signal received, stopping...");
            Ok(())
        }
        completed = pipelines.join_next() => unexpected_pipeline_exit(completed),
    }
}

fn unexpected_pipeline_exit(
    completed: Option<std::result::Result<&'static str, JoinError>>,
) -> Result<()> {
    match completed {
        Some(Ok(name)) => anyhow::bail!("{name} pipeline exited unexpectedly"),
        Some(Err(err)) => anyhow::bail!("log collector pipeline task failed: {err}"),
        None => anyhow::bail!("all log collector pipelines exited unexpectedly"),
    }
}

/// Boot the OTEL collector from its own config file.
#[cfg(feature = "otel")]
async fn start_otel(config_path: &str) -> Result<()> {
    use otel::config::Config as OtelConfig;
    use otel::server::{create_collector, start_metrics_server, start_server};
    use otel::tls::setup_grpc_tls;

    let pinned_path = config_bootstrap::pinned_path_from_env();
    let mut bootstrap = Bootstrap::new(BootstrapOptions {
        service_name: "otel".to_string(),
        config_path: config_path.to_string(),
        format: ConfigFormat::Toml,
        pinned_path,
    })
    .await?;

    let otel_cfg: OtelConfig = bootstrap.load().await?;
    let addr = otel_cfg.bind_address().parse()?;
    // nats_config() returns Result since it materializes [nats.tls] material to disk, so a
    // broken TLS section now fails startup here instead of silently yielding no NATS output.
    // Propagated with `?` to match otel/src/server.rs.
    let nats_config = otel_cfg.nats_config()?;
    let grpc_tls_config = setup_grpc_tls(&otel_cfg).map_err(|e| anyhow::anyhow!("{e}"))?;
    // Ingestion-token auth shared by the OTLP/gRPC interceptor and the
    // OTLP/HTTP listener (which builds its own copy from the same [auth]
    // section). Fails fast on unreadable token files / invalid entries.
    let ingest_auth = std::sync::Arc::new(
        otel::auth::IngestAuth::from_config(&otel_cfg.auth)
            .map_err(|e| anyhow::anyhow!("invalid [auth] configuration: {e}"))?,
    );
    if ingest_auth.enabled() {
        info!("OTLP ingestion authentication enforced");
    }
    let collector = create_collector(nats_config)
        .await
        .map_err(|e| anyhow::anyhow!("{e}"))?;

    // Start metrics server if configured
    if let Some(metrics_addr_str) = otel_cfg.metrics_address() {
        let metrics_addr = metrics_addr_str.parse()?;
        info!("OTEL metrics server on {metrics_addr}");
        tokio::spawn(async move {
            if let Err(e) = start_metrics_server(metrics_addr).await {
                error!("OTEL metrics server error: {e}");
            }
        });
    }

    // Start OTLP/HTTP listener (default port 4318) unless disabled.
    match otel::http_server::HttpServerOptions::from_config(&otel_cfg) {
        Ok(Some(http_options)) => {
            let http_collector = collector.clone();
            tokio::spawn(async move {
                if let Err(e) =
                    otel::http_server::start_http_server(http_options, http_collector).await
                {
                    error!("OTLP/HTTP server error: {e}");
                }
            });
        }
        Ok(None) => info!("OTLP/HTTP listener disabled by configuration"),
        Err(e) => error!("Failed to configure OTLP/HTTP listener: {e}"),
    }

    start_server(
        addr,
        grpc_tls_config,
        collector,
        otel_cfg.server.max_request_bytes,
        ingest_auth,
    )
    .await
    .map_err(|e| anyhow::anyhow!("{e}"))?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn completed_pipeline_is_an_error() {
        let err = unexpected_pipeline_exit(Some(Ok("flowgger"))).unwrap_err();

        assert_eq!(err.to_string(), "flowgger pipeline exited unexpectedly");
    }

    #[tokio::test]
    async fn panicked_pipeline_is_an_error() {
        let join_error = tokio::spawn(async { panic!("pipeline panic") })
            .await
            .unwrap_err();

        let err = unexpected_pipeline_exit(Some(Err(join_error))).unwrap_err();

        assert!(err.to_string().contains("pipeline task failed"));
        assert!(err.to_string().contains("panicked"));
    }
}
