use anyhow::Result;
use clap::Parser;
use config_bootstrap::{Bootstrap, BootstrapOptions, ConfigFormat};
use env_logger::Env;
use log::{debug, info, warn};
use std::pin::pin;
use std::sync::Once;
use std::time::Duration;

use async_nats::jetstream::{
    self,
    consumer::pull::Config as PullConfig,
    stream::{Config as StreamConfig, StorageType},
};
use futures::StreamExt;

mod config;
mod engine;
mod flow_proto;
mod grpc_server;
#[cfg(test)]
mod integration_tests;
mod kv_loader;
mod message_processor;
mod nats;
mod otel_logs;
mod otel_metrics;
mod rule_watcher;
mod spiffe;

use config::{subject_matches, Config};
use engine::build_engine;
use grpc_server::start_grpc_server;
use message_processor::process_message;
use nats::connect_nats;
use rule_watcher::watch_rules;

const BATCH_TIMEOUT: Duration = Duration::from_secs(1);
const MAX_RETRIES: i64 = 3;

#[derive(Parser, Debug)]
#[command(name = "serviceradar-zen")]
struct Cli {
    /// Path to configuration file
    #[arg(short, long, env = "ZEN_CONFIG")]
    config: String,
}

#[tokio::main]
async fn main() -> Result<()> {
    ensure_rustls_provider_installed();
    env_logger::Builder::from_env(Env::default().default_filter_or("info")).init();
    let cli = Cli::parse();
    let pinned_path = config_bootstrap::pinned_path_from_env();
    let mut bootstrap = Bootstrap::new(BootstrapOptions {
        service_name: "zen-consumer".to_string(),
        config_path: cli.config.clone(),
        format: ConfigFormat::Json,
        pinned_path: pinned_path.clone(),
    })
    .await?;
    let cfg: Config = bootstrap.load().await?;
    cfg.validate()?;

    let (client, js) = connect_nats(&cfg).await?;

    // Build the complete list of subjects we need (input + result subjects)
    let mut required_subjects = cfg.subjects.clone();
    if let Some(res) = &cfg.result_subject {
        required_subjects.push(res.clone());
    }
    if let Some(suffix) = &cfg.result_subject_suffix {
        for s in &cfg.subjects {
            required_subjects.push(format!("{}.{}", s, suffix.trim_start_matches('.')));
        }
    }

    let stream = match js.get_stream(&cfg.stream_name).await {
        Ok(mut existing_stream) => {
            // Stream exists - check if it has all required subjects
            let info = existing_stream.info().await?;
            let mut current_subjects = info.config.subjects.clone();
            let mut needs_update = false;

            for required in &required_subjects {
                if !current_subjects
                    .iter()
                    .any(|existing| subject_matches(existing, required))
                {
                    info!(
                        "adding missing subject {} to stream {}",
                        required, cfg.stream_name
                    );
                    current_subjects.push(required.clone());
                    needs_update = true;
                }
            }

            if needs_update {
                let mut updated_config = info.config.clone();
                updated_config.subjects = current_subjects;
                js.update_stream(updated_config).await?;
                js.get_stream(&cfg.stream_name).await?
            } else {
                existing_stream
            }
        }
        Err(_) => {
            // Stream doesn't exist - create it with all required subjects
            let sc = StreamConfig {
                name: cfg.stream_name.clone(),
                subjects: required_subjects.clone(),
                storage: StorageType::File,
                ..Default::default()
            };
            js.get_or_create_stream(sc).await?
        }
    };
    info!("using stream {}", cfg.stream_name);
    let desired_cfg = PullConfig {
        durable_name: Some(cfg.consumer_name.clone()),
        filter_subjects: cfg.subjects.clone(),
        ..Default::default()
    };
    let consumer =
        ensure_pull_consumer(&stream, &cfg.consumer_name, &cfg.subjects, &desired_cfg).await?;
    info!("using consumer {}", cfg.consumer_name);

    let engine = build_engine(&cfg, &js).await?;
    let watch_engine = engine.clone();
    let watch_cfg = cfg.clone();
    let watch_js = js.clone();
    tokio::spawn(async move {
        if let Err(e) = watch_rules(watch_engine, watch_cfg, watch_js).await {
            warn!("rule watch failed: {e}");
        }
    });

    if cfg.listen_addr.is_some() {
        let grpc_cfg = cfg.clone();
        tokio::spawn(async move {
            if let Err(e) = start_grpc_server(grpc_cfg).await {
                warn!("gRPC server failed: {e}");
            }
        });
    }

    info!("waiting for messages on subjects: {:?}", cfg.subjects);
    let mut shutdown = pin!(shutdown_signal());

    loop {
        let mut messages = consumer
            .stream()
            .max_messages_per_batch(10)
            .expires(BATCH_TIMEOUT)
            .messages()
            .await?;
        debug!("waiting for up to 10 messages or {BATCH_TIMEOUT:?} timeout");
        loop {
            tokio::select! {
                _ = &mut shutdown => {
                    info!("shutdown signal received; draining zen NATS client");
                    if let Err(err) = client.drain().await {
                        warn!("failed to drain zen NATS client: {err}");
                    }

                    return Ok(());
                }
                maybe_message = messages.next() => {
                    let Some(message) = maybe_message else {
                        break;
                    };

                    let message = message.map_err(|e| anyhow::anyhow!(e.to_string()))?;
                    if let Err(e) = process_message(&engine, &cfg, &js, &message).await {
                        warn!("processing failed: {e}");
                        match message.info() {
                            Ok(info) if info.delivered >= MAX_RETRIES => {
                                if let Err(e) = message.ack().await {
                                    warn!("failed to Ack: {e}");
                                } else {
                                    debug!(
                                        "acknowledged message {} after {} retries",
                                        info.stream_sequence, info.delivered
                                    );
                                }
                            }
                            Ok(info) => {
                                if let Err(e) = message.ack_with(jetstream::AckKind::Nak(None)).await {
                                    warn!("failed to NAK: {e}");
                                } else {
                                    debug!("nacked message {}", info.stream_sequence);
                                }
                            }
                            Err(_) => {
                                if let Err(e) = message.ack_with(jetstream::AckKind::Nak(None)).await {
                                    warn!("failed to NAK: {e}");
                                }
                            }
                        }
                    } else {
                        message
                            .ack()
                            .await
                            .map_err(|e| anyhow::anyhow!(e.to_string()))?;
                        if let Ok(info) = message.info() {
                            debug!("acknowledged message {}", info.stream_sequence);
                        }
                    }
                }
            }
        }
    }
}

async fn ensure_pull_consumer(
    stream: &jetstream::stream::Stream,
    consumer_name: &str,
    subjects: &[String],
    desired_cfg: &PullConfig,
) -> Result<jetstream::consumer::Consumer<PullConfig>> {
    match stream.consumer_info(consumer_name).await {
        Ok(info) => {
            if !consumer_config_matches(&info.config, desired_cfg, subjects) {
                warn!("consumer {} configuration changed, updating", consumer_name);
                stream
                    .update_consumer(desired_cfg.clone())
                    .await
                    .map_err(|e| anyhow::anyhow!(e.to_string()))
            } else {
                stream
                    .get_consumer(consumer_name)
                    .await
                    .map_err(|e| anyhow::anyhow!(e.to_string()))
            }
        }
        Err(_) => create_or_get_consumer(stream, consumer_name, desired_cfg).await,
    }
}

async fn create_or_get_consumer(
    stream: &jetstream::stream::Stream,
    consumer_name: &str,
    desired_cfg: &PullConfig,
) -> Result<jetstream::consumer::Consumer<PullConfig>> {
    match stream.create_consumer(desired_cfg.clone()).await {
        Ok(consumer) => Ok(consumer),
        Err(create_err) => {
            warn!(
                "create_consumer for {} failed, retrying get_consumer: {}",
                consumer_name, create_err
            );
            stream.get_consumer(consumer_name).await.map_err(|get_err| {
                anyhow::anyhow!("create failed: {create_err}; get failed: {get_err}")
            })
        }
    }
}

fn consumer_config_matches(
    current: &jetstream::consumer::Config,
    desired: &PullConfig,
    subjects: &[String],
) -> bool {
    current.durable_name == desired.durable_name
        && normalized_subjects(current.filter_subjects.as_slice()) == normalized_subjects(subjects)
}

fn normalized_subjects(subjects: &[String]) -> Vec<&str> {
    let mut normalized: Vec<&str> = subjects
        .iter()
        .map(String::as_str)
        .filter(|subject| !subject.trim().is_empty())
        .collect();
    normalized.sort_unstable();
    normalized
}

async fn shutdown_signal() {
    #[cfg(unix)]
    {
        let mut terminate =
            tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())
                .expect("failed to install SIGTERM handler");

        tokio::select! {
            _ = tokio::signal::ctrl_c() => {}
            _ = terminate.recv() => {}
        }
    }

    #[cfg(not(unix))]
    {
        let _ = tokio::signal::ctrl_c().await;
    }
}

fn ensure_rustls_provider_installed() {
    static ONCE: Once = Once::new();
    ONCE.call_once(|| {
        let _ = rustls::crypto::aws_lc_rs::default_provider().install_default();
    });
}

#[cfg(test)]
mod tests;

#[cfg(test)]
mod consumer_config_tests {
    use super::*;

    #[test]
    fn consumer_config_match_is_order_insensitive() {
        let current = jetstream::consumer::Config {
            durable_name: Some("zen".to_string()),
            filter_subjects: vec!["logs.b".to_string(), "logs.a".to_string()],
            ..Default::default()
        };

        let desired = PullConfig {
            durable_name: Some("zen".to_string()),
            filter_subjects: vec!["logs.a".to_string(), "logs.b".to_string()],
            ..Default::default()
        };

        assert!(consumer_config_matches(
            &current,
            &desired,
            &desired.filter_subjects
        ));
    }

    #[test]
    fn consumer_config_match_detects_filter_changes() {
        let current = jetstream::consumer::Config {
            durable_name: Some("zen".to_string()),
            filter_subjects: vec!["logs.a".to_string()],
            ..Default::default()
        };

        let desired = PullConfig {
            durable_name: Some("zen".to_string()),
            filter_subjects: vec!["logs.b".to_string()],
            ..Default::default()
        };

        assert!(!consumer_config_matches(
            &current,
            &desired,
            &desired.filter_subjects
        ));
    }
}
