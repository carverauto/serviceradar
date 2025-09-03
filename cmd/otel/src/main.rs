use otel::server::{create_collector, start_server, start_metrics_server};
use otel::setup::{
    handle_generate_config, load_configuration, log_configuration_info, parse_bind_address,
    setup_logging_and_parse_args,
};
use otel::tls::setup_grpc_tls;
use std::net::SocketAddr;
use kvutil::KvClient;

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let args = setup_logging_and_parse_args()?;

    if args.generate_config {
        return handle_generate_config();
    }

    // Load config from file first, then overlay/replace from KV if configured
    let mut config = load_configuration(&args)?;
    let use_kv = std::env::var("CONFIG_SOURCE").ok().as_deref() == Some("kv")
        && !std::env::var("KV_ADDRESS").unwrap_or_default().is_empty();
    let mut kv_client: Option<KvClient> = None;
    if use_kv
        && let Ok(mut kv) = KvClient::connect_from_env().await
    {
        // Initial fetch
        if let Ok(Some(bytes)) = kv.get("config/otel.toml").await
            && let Ok(s) = std::str::from_utf8(&bytes)
            && let Ok(new_cfg) = toml::from_str::<otel::config::Config>(s)
        {
            config = new_cfg;
        }
        // Bootstrap current config if missing
        if let Ok(None) = kv.get("config/otel.toml").await
            && let Ok(content) = toml::to_string_pretty(&config)
        {
            let _ = kv.put_if_absent("config/otel.toml", content.into_bytes()).await;
        }
        kv_client = Some(kv);
    }
    let addr = parse_bind_address(&config)?;

    log_configuration_info(&config);

    let nats_config = config.nats_config();
    let grpc_tls_config = setup_grpc_tls(&config)?;
    let collector = create_collector(nats_config).await?;

    // If using KV, set up a watcher to hot-apply config overlays and reconfigure subsystems
    if let Some(mut kv) = kv_client {
        let shared_cfg = std::sync::Arc::new(tokio::sync::RwLock::new(config.clone()));
        let shared_for_cb = shared_cfg.clone();
        let collector_for_cb = collector.clone();
        let _ = kv.watch_apply("config/otel.toml", move |bytes| {
            let shared = shared_for_cb.clone();
            let coll = collector_for_cb.clone();
            let b = bytes.to_vec();
            tokio::spawn(async move {
                {
                    let mut guard = shared.write().await;
                    // Snapshot previous values
                    let prev = guard.clone();
                    // Apply overlay into config
                    let _ = kvutil::overlay_toml(&mut *guard, &b);
                    // Reconfigure NATS output with new config (idempotent)
                    let new_nats = guard.nats_config();
                    coll.reconfigure_nats(new_nats).await;
                    // Log advisory if bind address/port or TLS changed
                    let prev_bind = prev.bind_address();
                    let new_bind = guard.bind_address();
                    if prev_bind != new_bind || prev.grpc_tls.as_ref() != guard.grpc_tls.as_ref() {
                        eprintln!("OTEL server bind/TLS changed; restart required to apply");
                    }
                }
            });
        }).await;
    }

    // (KV bootstrap and watch now done above via kvutil)

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

// (kvutil-based helpers used inline above; no local tonic glue)
