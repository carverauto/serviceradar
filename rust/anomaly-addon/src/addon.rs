// Copyright 2026 Carver Automation Corporation.
//
// Licensed under the Apache License, Version 2.0 (the "License").
// SPDX-License-Identifier: Apache-2.0

//! The `AnomalyAddon`: consumes the agent's local metric feed
//! (`metric-feed:v1`), runs the shared detector per series, and emits anomaly
//! verdicts upstream over the native telemetry stream (`native-telemetry:v1`).

use std::sync::{Arc, Mutex, MutexGuard};

use addon_sdk::pb::{MetricFeedAck, TelemetryBatch};
use addon_sdk::{
    Addon, CAPABILITY_METRIC_FEED_V1, CAPABILITY_NATIVE_TELEMETRY_V1, ConfigureResult, Health,
    Info, MetricFeedAckStream, MetricFeedStream, TelemetryStream,
};
use async_trait::async_trait;
use sha2::{Digest as _, Sha256};
use tokio::sync::{broadcast, mpsc};
use tokio::task::JoinHandle;
use tokio_stream::StreamExt as _;
use tokio_stream::wrappers::ReceiverStream;
use tonic::Status;

use crate::checkpoint::{
    load_checkpoint, resolve_checkpoint_settings, resolve_scoring_stale_after_ns, write_checkpoint,
};
use crate::config::{
    ACK_CHANNEL_DEPTH, ADDON_ID, ADDON_VERSION, AddonConfig, CheckpointSettings,
    NativeTelemetryDropCounters, VERDICT_CHANNEL_DEPTH,
};
use crate::engine::{DetectorEngine, EngineConfig};
use crate::frame::{process_frame, telemetry_stream_from_receiver};
use crate::health::{EngineHealthSnapshot, ScoringHealth};

/// Edge anomaly add-on. Shared (`Arc`) across concurrent gRPC calls, so all
/// mutable state is behind a `Mutex`.
pub struct AnomalyAddon {
    pub(crate) engine: Arc<Mutex<DetectorEngine>>,
    pub(crate) verdict_tx: broadcast::Sender<TelemetryBatch>,
    pub(crate) telemetry_drops: Arc<NativeTelemetryDropCounters>,
    pub(crate) scoring_health: Arc<Mutex<ScoringHealth>>,
    /// Resolved at `configure`; read when a feed stream opens.
    checkpoint: Mutex<CheckpointSettings>,
    /// The metric feed is single-owner: reconnecting replaces the prior scorer.
    feed_task: Mutex<Option<JoinHandle<()>>>,
}

impl Default for AnomalyAddon {
    fn default() -> Self {
        Self::new()
    }
}

impl AnomalyAddon {
    pub fn new() -> Self {
        let (verdict_tx, _) = broadcast::channel(VERDICT_CHANNEL_DEPTH);
        Self {
            engine: Arc::new(Mutex::new(DetectorEngine::new(EngineConfig::default()))),
            verdict_tx,
            telemetry_drops: Arc::new(NativeTelemetryDropCounters::default()),
            scoring_health: Arc::new(Mutex::new(ScoringHealth::default())),
            checkpoint: Mutex::new(CheckpointSettings::default()),
            feed_task: Mutex::new(None),
        }
    }

    async fn stop_feed_task(&self) {
        let handle = lock_feed_task(&self.feed_task).take();

        if let Some(handle) = handle {
            handle.abort();
            let _ = handle.await;
        }
    }
}

impl Drop for AnomalyAddon {
    fn drop(&mut self) {
        if let Ok(slot) = self.feed_task.get_mut()
            && let Some(handle) = slot.take()
        {
            handle.abort();
        }
    }
}

pub(crate) fn lock_engine(engine: &Arc<Mutex<DetectorEngine>>) -> MutexGuard<'_, DetectorEngine> {
    match engine.lock() {
        Ok(guard) => guard,
        Err(poisoned) => {
            let mut guard = poisoned.into_inner();
            let config = guard.config();
            *guard = DetectorEngine::new(config);
            engine.clear_poison();
            guard
        }
    }
}

fn lock_checkpoint_settings(
    checkpoint: &Mutex<CheckpointSettings>,
) -> MutexGuard<'_, CheckpointSettings> {
    match checkpoint.lock() {
        Ok(guard) => guard,
        Err(poisoned) => {
            let guard = poisoned.into_inner();
            checkpoint.clear_poison();
            guard
        }
    }
}

fn lock_feed_task(slot: &Mutex<Option<JoinHandle<()>>>) -> MutexGuard<'_, Option<JoinHandle<()>>> {
    match slot.lock() {
        Ok(guard) => guard,
        Err(poisoned) => {
            let guard = poisoned.into_inner();
            slot.clear_poison();
            guard
        }
    }
}

pub(crate) fn lock_scoring_health(
    health: &Arc<Mutex<ScoringHealth>>,
) -> MutexGuard<'_, ScoringHealth> {
    match health.lock() {
        Ok(guard) => guard,
        Err(poisoned) => {
            let guard = poisoned.into_inner();
            health.clear_poison();
            guard
        }
    }
}

#[async_trait]
impl Addon for AnomalyAddon {
    async fn info(&self) -> anyhow::Result<Info> {
        Ok(Info {
            id: ADDON_ID.to_string(),
            version: ADDON_VERSION.to_string(),
            capabilities: vec![
                CAPABILITY_METRIC_FEED_V1.to_string(),
                CAPABILITY_NATIVE_TELEMETRY_V1.to_string(),
            ],
        })
    }

    async fn configure(&self, config_json: &[u8]) -> anyhow::Result<ConfigureResult> {
        let config_hash = hex::encode(Sha256::digest(config_json));

        let parsed: AddonConfig = if config_json.is_empty() {
            AddonConfig::default()
        } else {
            match serde_json::from_slice(config_json) {
                Ok(cfg) => cfg,
                Err(err) => {
                    return Ok(ConfigureResult {
                        config_hash,
                        accepted: false,
                        error: format!("invalid anomaly add-on config: {err}"),
                    });
                }
            }
        };

        let settings = resolve_checkpoint_settings(&parsed);
        let scoring_stale_after_ns = resolve_scoring_stale_after_ns(&parsed);
        // Resolve before `into_engine_config` consumes `parsed`. Empty when no
        // baselines were delivered, leaving the engine rolling-only (back-compat).
        let seasonal_baselines = parsed.resolve_seasonal_baselines();
        let seasonal_settings = parsed.resolve_seasonal_settings();

        let engine_config = match parsed.into_engine_config() {
            Ok(config) => config,
            Err(err) => {
                return Ok(ConfigureResult {
                    config_hash,
                    accepted: false,
                    error: format!("invalid anomaly add-on config: {err}"),
                });
            }
        };

        {
            let mut engine = lock_engine(&self.engine);
            engine.set_config(engine_config);
            engine.set_seasonal_settings(seasonal_settings);
            engine.set_seasonal_baselines(seasonal_baselines);
        }
        lock_scoring_health(&self.scoring_health).set_stale_after_ns(scoring_stale_after_ns);

        // Re-warm from the on-disk checkpoint before scoring resumes, so a
        // restart does not storm false positives while windows refill.
        if let Some(path) = settings.path.clone() {
            load_checkpoint(&self.engine, &path, settings.max_age_ns);
        }
        *lock_checkpoint_settings(&self.checkpoint) = settings;

        Ok(ConfigureResult {
            config_hash,
            accepted: true,
            error: String::new(),
        })
    }

    async fn health(&self) -> anyhow::Result<Health> {
        let drop_snapshot = self.telemetry_drops.snapshot();
        let engine = lock_engine(&self.engine);
        let counter_drop_message = engine.counter_drop_counts.health_message();
        let engine_snapshot = EngineHealthSnapshot {
            tracked_series: engine.series_count(),
            tracked_counters: engine.counter_count(),
            max_series: engine.max_series(),
            dropped_total: engine.dropped_at_capacity,
            drift_inactive_no_baseline_total: engine.drift_inactive_no_baseline,
            clamped_samples_total: engine.clamped_samples,
        };
        drop(engine);

        let scoring = lock_scoring_health(&self.scoring_health).clone();
        let summary = scoring.health_summary(engine_snapshot);

        let mut degradation_reason = if drop_snapshot.total() == 0 {
            summary.detail
        } else if summary.detail.is_empty() {
            drop_snapshot.health_message()
        } else {
            format!("{};{}", summary.detail, drop_snapshot.health_message())
        };

        if let Some(message) = counter_drop_message {
            if degradation_reason.is_empty() {
                degradation_reason = message;
            } else {
                degradation_reason.push(';');
                degradation_reason.push_str(&message);
            }
        }

        Ok(Health {
            status: summary.status,
            version: ADDON_VERSION.to_string(),
            degradation_reason,
            details: Default::default(),
        })
    }

    async fn shutdown(&self) -> anyhow::Result<()> {
        self.stop_feed_task().await;
        Ok(())
    }

    /// Hand the agent a verdict stream subscription. Every call gets a fresh
    /// receiver; lagging clients drop locally and reconnecting clients can
    /// subscribe without restarting the add-on. Native telemetry is at-most-once:
    /// records produced while no subscriber exists or while a receiver lags are
    /// dropped and counted in health diagnostics, not replayed.
    fn stream_telemetry(&self) -> TelemetryStream {
        telemetry_stream_from_receiver(self.verdict_tx.subscribe(), self.telemetry_drops.clone())
    }

    /// Consume the agent's local metric feed, score each sample, and ack frames.
    /// Verdicts are pushed onto the telemetry channel drained by
    /// [`Self::stream_telemetry`].
    fn stream_metric_feed(&self, frames: MetricFeedStream) -> Result<MetricFeedAckStream, Status> {
        let engine = self.engine.clone();
        let verdict_tx = self.verdict_tx.clone();
        let telemetry_drops = self.telemetry_drops.clone();
        let scoring_health = self.scoring_health.clone();
        let checkpoint = lock_checkpoint_settings(&self.checkpoint).clone();
        let (ack_tx, ack_rx) = mpsc::channel::<Result<MetricFeedAck, Status>>(ACK_CHANNEL_DEPTH);

        if let Some(prior) = lock_feed_task(&self.feed_task).take() {
            prior.abort();
        }

        let handle = tokio::spawn(async move {
            let mut frames = frames;
            let mut frame_count: u64 = 0;
            while let Some(item) = frames.next().await {
                let frame = match item {
                    Ok(frame) => frame,
                    Err(_) => break,
                };
                process_frame(
                    &engine,
                    &verdict_tx,
                    &telemetry_drops,
                    &scoring_health,
                    &frame,
                )
                .await;

                // Persist the re-warm checkpoint on a frame cadence (best-effort;
                // a write failure never blocks or fails the feed).
                frame_count += 1;
                if let Some(path) = checkpoint.path.as_ref()
                    && frame_count.is_multiple_of(checkpoint.write_every)
                {
                    write_checkpoint(&engine, path);
                }

                // Cumulative ack: the agent uses this to bound in-flight frames.
                if ack_tx
                    .send(Ok(MetricFeedAck {
                        acked_feed_id: frame.feed_id,
                    }))
                    .await
                    .is_err()
                {
                    break;
                }
            }

            // Flush a final checkpoint on graceful stream end so the freshest
            // baselines survive an expected restart.
            if let Some(path) = checkpoint.path.as_ref() {
                write_checkpoint(&engine, path);
            }
        });
        *lock_feed_task(&self.feed_task) = Some(handle);

        Ok(Box::pin(ReceiverStream::new(ack_rx)))
    }
}
