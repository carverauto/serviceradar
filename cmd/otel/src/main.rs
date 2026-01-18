use config_bootstrap::{Bootstrap, BootstrapOptions, ConfigFormat};
use otel::server::{create_collector, start_metrics_server, start_server};
use otel::setup::{
    handle_generate_config, log_configuration_info, parse_bind_address,
    setup_logging_and_parse_args,
};
use otel::tls::setup_grpc_tls;
use std::net::SocketAddr;
use std::path::{Path, PathBuf};

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let args = setup_logging_and_parse_args()?;

    if args.generate_config {
        return handle_generate_config();
    }

    let config_path = resolve_config_path(&args);
    log::debug!("Loading OTEL config from {}", config_path.display());

    let pinned_path = config_bootstrap::pinned_path_from_env();
    let mut bootstrap = Bootstrap::new(BootstrapOptions {
        service_name: "otel".to_string(),
        config_path: config_path
            .to_str()
            .unwrap_or("/etc/serviceradar/otel.toml")
            .to_string(),
        format: ConfigFormat::Toml,
        pinned_path: pinned_path.clone(),
    })
    .await?;

    let config: otel::config::Config = bootstrap.load().await?;

    let addr = parse_bind_address(&config)?;

    log_configuration_info(&config);

    let nats_config = config.nats_config();
    let grpc_tls_config = setup_grpc_tls(&config)?;
    let collector = create_collector(nats_config).await?;

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
