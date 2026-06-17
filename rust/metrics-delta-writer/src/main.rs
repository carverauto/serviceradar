// Copyright 2026 Carver Automation Corporation.
//
// Licensed under the Apache License, Version 2.0 (the "License").
// SPDX-License-Identifier: Apache-2.0

//! `metrics-delta-writer` binary — consume the metrics JetStream durable, decode
//! `MetricBatch` protobuf, buffer rows, and flush them to the Delta sink.
//!
//! Skeleton (OpenSpec: `add-delta-metrics-lakehouse`). Uses [`LoggingSink`]
//! until the real `deltalake` writer is wired (task 3.1).

use std::time::Duration;

use futures::StreamExt;
use tracing::{error, info, warn};

use serviceradar_metrics_delta_writer::config::Config;
use serviceradar_metrics_delta_writer::pipeline::batch_to_rows;
use serviceradar_metrics_delta_writer::sink::{DeltaSink, LoggingSink, MetricRow};

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    init_tracing();

    let config = Config::from_env()?;
    info!(?config, "starting metrics-delta-writer");

    // TODO(task 3.1): construct the real Delta sink from `config.delta_table_uri`
    // (object-store backend selected by URI scheme). The placeholder keeps the
    // ingest path runnable today.
    let sink = LoggingSink;

    run(&config, &sink).await
}

/// Bind the durable pull consumer and run the buffered write loop until the
/// stream ends.
async fn run<S: DeltaSink>(config: &Config, sink: &S) -> anyhow::Result<()> {
    let client = async_nats::connect(&config.nats_url).await?;
    let jetstream = async_nats::jetstream::new(client);

    let consumer = jetstream
        .get_stream(&config.stream)
        .await?
        .get_or_create_consumer(
            &config.durable,
            async_nats::jetstream::consumer::pull::Config {
                durable_name: Some(config.durable.clone()),
                filter_subject: config.filter_subject.clone(),
                ack_policy: async_nats::jetstream::consumer::AckPolicy::Explicit,
                ..Default::default()
            },
        )
        .await?;

    let mut messages = consumer.messages().await?;
    let mut buffer: Vec<MetricRow> = Vec::with_capacity(config.flush_rows);
    let mut pending_acks: Vec<async_nats::jetstream::Message> = Vec::new();
    let mut flush = tokio::time::interval(Duration::from_millis(config.flush_interval_ms));

    loop {
        tokio::select! {
            maybe_msg = messages.next() => {
                let Some(msg) = maybe_msg else {
                    warn!("jetstream message stream ended; flushing and exiting");
                    flush_buffer(sink, &mut buffer, &mut pending_acks).await?;
                    return Ok(());
                };
                let msg = match msg {
                    Ok(m) => m,
                    Err(err) => {
                        error!(error = %err, "pull message error");
                        continue;
                    }
                };
                match batch_to_rows(&config.tenant_id, msg.payload.as_ref()) {
                    Ok(mut rows) => buffer.append(&mut rows),
                    Err(err) => {
                        // Poison payload: never block the cursor on it.
                        // TODO(task 3.3): route to a dead-letter subject instead
                        // of term + drop.
                        error!(error = %err, "failed to decode MetricBatch; terminating message");
                        let _ = msg
                            .ack_with(async_nats::jetstream::AckKind::Term)
                            .await;
                        continue;
                    }
                }
                pending_acks.push(msg);
                if buffer.len() >= config.flush_rows {
                    flush_buffer(sink, &mut buffer, &mut pending_acks).await?;
                }
            }
            _ = flush.tick() => {
                flush_buffer(sink, &mut buffer, &mut pending_acks).await?;
            }
        }
    }
}

/// Write the buffered rows, then ack the JetStream messages they came from.
///
/// Order matters: ack only after a durable write so a crash re-delivers
/// unwritten points (at-least-once into Delta; dedup is task 3.2).
async fn flush_buffer<S: DeltaSink>(
    sink: &S,
    buffer: &mut Vec<MetricRow>,
    pending_acks: &mut Vec<async_nats::jetstream::Message>,
) -> anyhow::Result<()> {
    if buffer.is_empty() {
        pending_acks.clear();
        return Ok(());
    }

    let rows = std::mem::take(buffer);
    let count = rows.len();
    sink.write_batch(rows).await.map_err(anyhow::Error::from)?;

    for msg in pending_acks.drain(..) {
        if let Err(err) = msg.double_ack().await {
            warn!(error = %err, "ack failed after delta write");
        }
    }

    info!(rows = count, "flushed batch to delta sink");
    Ok(())
}

fn init_tracing() {
    use tracing_subscriber::{EnvFilter, fmt};

    let filter =
        EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("info"));
    fmt().with_env_filter(filter).init();
}
