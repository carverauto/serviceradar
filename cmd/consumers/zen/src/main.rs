use anyhow::Result;
use clap::Parser;
use env_logger::Env;
use log::{debug, info, warn};
use std::time::Duration;

use async_nats::jetstream::{
    self,
    consumer::pull::Config as PullConfig,
    stream::{Config as StreamConfig, StorageType},
};
use futures::StreamExt;

mod config;
mod engine;
mod grpc_server;
#[cfg(test)]
mod integration_tests;
mod kv_loader;
mod message_processor;
mod nats;
mod otel_logs;
mod otel_metrics;
mod rule_watcher;

use config::Config;
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
    env_logger::Builder::from_env(Env::default().default_filter_or("info")).init();
    let cli = Cli::parse();
    let cfg = Config::from_file(&cli.config)?;

    let (_client, js) = connect_nats(&cfg).await?;
    let stream = match js.get_stream(&cfg.stream_name).await {
        Ok(s) => s,
        Err(_) => {
            let mut subjects = cfg.subjects.clone();
            if let Some(res) = &cfg.result_subject {
                subjects.push(res.clone());
            }
            if let Some(suffix) = &cfg.result_subject_suffix {
                for s in &cfg.subjects {
                    subjects.push(format!("{}.{}", s, suffix.trim_start_matches('.')));
                }
            }
            let sc = StreamConfig {
                name: cfg.stream_name.clone(),
                subjects,
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
    let consumer = match stream.consumer_info(&cfg.consumer_name).await {
        Ok(info) => {
            if info.config.filter_subjects != cfg.subjects {
                warn!(
                    "consumer {} configuration changed, recreating",
                    cfg.consumer_name
                );
                stream
                    .delete_consumer(&cfg.consumer_name)
                    .await
                    .map_err(|e| anyhow::anyhow!(e.to_string()))?;
                stream
                    .create_consumer(desired_cfg.clone())
                    .await
                    .map_err(|e| anyhow::anyhow!(e.to_string()))?
            } else {
                stream
                    .get_consumer(&cfg.consumer_name)
                    .await
                    .map_err(|e| anyhow::anyhow!(e.to_string()))?
            }
        }
        Err(_) => stream
            .create_consumer(desired_cfg.clone())
            .await
            .map_err(|e| anyhow::anyhow!(e.to_string()))?,
    };
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

    let grpc_cfg = cfg.clone();
    tokio::spawn(async move {
        if let Err(e) = start_grpc_server(grpc_cfg).await {
            warn!("gRPC server failed: {e}");
        }
    });

    info!("waiting for messages on subjects: {:?}", cfg.subjects);

    loop {
        let mut messages = consumer
            .stream()
            .max_messages_per_batch(10)
            .expires(BATCH_TIMEOUT)
            .messages()
            .await?;
        debug!("waiting for up to 10 messages or {BATCH_TIMEOUT:?} timeout");
        while let Some(message) = messages.next().await {
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

#[cfg(test)]
mod tests;
