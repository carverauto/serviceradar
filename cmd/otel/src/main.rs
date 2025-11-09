use config_bootstrap::{Bootstrap, BootstrapOptions, ConfigFormat};
use otel::server::{create_collector, start_metrics_server, start_server};
use otel::setup::{
    handle_generate_config, log_configuration_info, parse_bind_address,
    setup_logging_and_parse_args,
};
use otel::tls::setup_grpc_tls;
use std::net::SocketAddr;
use std::path::{Path, PathBuf};
use std::sync::Arc;

const CONFIG_PATH: &str = "config/otel.toml";

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let args = setup_logging_and_parse_args()?;

    if args.generate_config {
        return handle_generate_config();
    }

    let config_path = resolve_config_path(&args);
    log::debug!("Loading OTEL config from {}", config_path.display());

    let use_kv = std::env::var("CONFIG_SOURCE").ok().as_deref() == Some("kv")
        && !std::env::var("KV_ADDRESS").unwrap_or_default().is_empty();
    let kv_key = use_kv.then(|| CONFIG_PATH.to_string());
    let mut bootstrap = Bootstrap::new(BootstrapOptions {
        service_name: "otel".to_string(),
        config_path: config_path
            .to_str()
            .unwrap_or("/etc/serviceradar/otel.toml")
            .to_string(),
        format: ConfigFormat::Toml,
        kv_key,
        seed_kv: use_kv,
        watch_kv: use_kv,
    })
    .await?;

    let config: otel::config::Config = bootstrap.load().await?;

    let addr = parse_bind_address(&config)?;

    log_configuration_info(&config);

    let nats_config = config.nats_config();
    let grpc_tls_config = setup_grpc_tls(&config)?;
    let collector = create_collector(nats_config).await?;

    if let Some(mut watcher) = bootstrap.watch::<otel::config::Config>().await? {
        let shared_cfg = Arc::new(tokio::sync::RwLock::new(config.clone()));
        let shared_for_watch = shared_cfg.clone();
        let collector_for_watch = collector.clone();
        tokio::spawn(async move {
            while let Some(updated) = watcher.recv().await {
                let mut guard = shared_for_watch.write().await;
                let previous = guard.clone();
                *guard = updated.clone();
                let new_nats = guard.nats_config();
                collector_for_watch.reconfigure_nats(new_nats).await;
                let prev_bind = previous.bind_address();
                let new_bind = guard.bind_address();
                if prev_bind != new_bind || previous.grpc_tls.as_ref() != guard.grpc_tls.as_ref() {
                    eprintln!("OTEL server bind/TLS changed; restart required to apply");
                }
            }
        });
    }

    // Start metrics server if configured
    if let Some(metrics_addr_str) = config.metrics_address() {
        let metrics_addr: SocketAddr = metrics_addr_str.parse()?;
        println!("Starting metrics server on {metrics_addr}");
        tokio::spawn(async move {
            if let Err(e) = start_metrics_server(metrics_addr).await {
                eprintln!("Metrics server error: {e}");
            }
        });
    }

    start_server(addr, grpc_tls_config, collector).await
}

fn resolve_config_path(args: &otel::cli::CLI) -> PathBuf {
    if let Some(path) = &args.config {
        return PathBuf::from(path);
    }

    let mut candidates = vec![
        PathBuf::from("./otel.toml"),
        PathBuf::from("/etc/serviceradar/otel.toml"),
    ];

    if let Some(home) = std::env::var_os("HOME") {
        let mut home_path = PathBuf::from(home);
        home_path.push(".config/serviceradar/otel.toml");
        candidates.push(home_path);
    }

    for candidate in &candidates {
        if Path::new(candidate).exists() {
            return candidate.clone();
        }
    }

    PathBuf::from("/etc/serviceradar/otel.toml")
}
