// Copyright 2026 Carver Automation Corporation.
//
// Licensed under the Apache License, Version 2.0 (the "License").
// SPDX-License-Identifier: Apache-2.0

use addon_sdk::Addon;
use tokio::sync::broadcast;
use tokio::time::{Duration, timeout};
use tokio_stream::StreamExt as _;

use super::support::{
    empty_telemetry_batch, metric_feed_frame, metric_feed_stream, telemetry_drop_counters,
};
use crate::AnomalyAddon;
use crate::config::VERDICT_CHANNEL_DEPTH;
use crate::frame::telemetry_stream_from_receiver;

#[tokio::test]
async fn telemetry_stream_can_reconnect_and_survives_lag() {
    let (tx, rx) = broadcast::channel(1);
    let telemetry_drops = telemetry_drop_counters();
    let mut stream = telemetry_stream_from_receiver(rx, telemetry_drops.clone());

    let _ = tx.send(empty_telemetry_batch("old-1"));
    let _ = tx.send(empty_telemetry_batch("old-2"));
    let _ = tx.send(empty_telemetry_batch("latest"));

    let received = stream
        .next()
        .await
        .expect("stream item after lag")
        .expect("batch ok");
    assert_eq!(
        received
            .source
            .as_ref()
            .map(|source| source.source_instance.as_str()),
        Some("latest")
    );
    assert_eq!(telemetry_drops.snapshot().lagged_batches, 2);

    let mut first = telemetry_stream_from_receiver(tx.subscribe(), telemetry_drops.clone());
    let mut second = telemetry_stream_from_receiver(tx.subscribe(), telemetry_drops.clone());
    let _ = tx.send(empty_telemetry_batch("after-reconnect"));

    for stream in [&mut first, &mut second] {
        let received = stream
            .next()
            .await
            .expect("reconnected stream item")
            .expect("batch ok");
        assert_eq!(
            received
                .source
                .as_ref()
                .map(|source| source.source_instance.as_str()),
            Some("after-reconnect")
        );
    }
}

#[tokio::test]
async fn metric_feed_reopen_aborts_prior_scorer() {
    let addon = AnomalyAddon::new();
    let (old_tx, old_frames) = metric_feed_stream();
    let mut old_acks = addon
        .stream_metric_feed(old_frames)
        .expect("old metric feed opens");

    old_tx
        .send(Ok(metric_feed_frame(1, 100.0)))
        .await
        .expect("old feed receiver");
    let old_ack = old_acks
        .next()
        .await
        .expect("old ack item")
        .expect("old ack ok");
    assert_eq!(old_ack.acked_feed_id, 1);

    let (new_tx, new_frames) = metric_feed_stream();
    let mut new_acks = addon
        .stream_metric_feed(new_frames)
        .expect("new metric feed opens");

    let old_end = timeout(Duration::from_secs(1), old_acks.next())
        .await
        .expect("old ack stream closes after feed replacement");
    assert!(old_end.is_none(), "old feed ack stream must close");
    assert!(
        old_tx.send(Ok(metric_feed_frame(2, 200.0))).await.is_err(),
        "old feed sender must observe the aborted receiver"
    );

    new_tx
        .send(Ok(metric_feed_frame(3, 300.0)))
        .await
        .expect("new feed receiver");
    let new_ack = new_acks
        .next()
        .await
        .expect("new ack item")
        .expect("new ack ok");
    assert_eq!(new_ack.acked_feed_id, 3);
}

#[tokio::test]
async fn shutdown_aborts_open_metric_feed_promptly() {
    let addon = AnomalyAddon::new();
    let (feed_tx, frames) = metric_feed_stream();
    let mut acks = addon.stream_metric_feed(frames).expect("metric feed opens");

    feed_tx
        .send(Ok(metric_feed_frame(1, 100.0)))
        .await
        .expect("feed receiver");
    let ack = acks.next().await.expect("ack item").expect("ack ok");
    assert_eq!(ack.acked_feed_id, 1);

    timeout(Duration::from_millis(200), addon.shutdown())
        .await
        .expect("shutdown completes inside grace window")
        .expect("shutdown ok");

    let end = timeout(Duration::from_millis(200), acks.next())
        .await
        .expect("ack stream closes after shutdown");
    assert!(end.is_none(), "shutdown must close the ack stream");
    assert!(
        feed_tx.send(Ok(metric_feed_frame(2, 200.0))).await.is_err(),
        "shutdown must drop the feed receiver"
    );
}

#[tokio::test]
async fn telemetry_stream_counts_outbound_queue_drops() {
    let (tx, rx) = broadcast::channel(VERDICT_CHANNEL_DEPTH + 32);
    let telemetry_drops = telemetry_drop_counters();
    let mut stream = telemetry_stream_from_receiver(rx, telemetry_drops.clone());

    for idx in 0..(VERDICT_CHANNEL_DEPTH + 8) {
        let _ = tx.send(empty_telemetry_batch(&format!("batch-{idx}")));
    }

    tokio::time::timeout(std::time::Duration::from_secs(1), async {
        loop {
            if telemetry_drops.snapshot().outbound_full_batches > 0 {
                break;
            }
            tokio::task::yield_now().await;
        }
    })
    .await
    .expect("stream bridge must count full outbound queue");

    drop(stream.next().await);
}
