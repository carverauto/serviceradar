// Copyright 2026 Carver Automation Corporation.
//
// Licensed under the Apache License, Version 2.0 (the "License").
// SPDX-License-Identifier: Apache-2.0

//! The serialized per-series detector + counter checkpoint and the engine
//! export/restore that re-warms baselines after a restart instead of rebuilding
//! them from scratch (which would storm false positives while the windows refill).

use serviceradar_anomaly_core::Cusum;

use super::DetectorEngine;
use super::state::{CounterState, SeriesState};
use super::types::CusumDirection;

/// One series' retained detector baseline, serialized for the restart checkpoint.
#[derive(Clone, Debug, serde::Serialize, serde::Deserialize)]
pub struct SeriesCheckpoint {
    pub series_key: String,
    pub window_tail: Vec<f64>,
    pub consecutive_anomalous: usize,
    #[serde(default)]
    pub consecutive_clean: usize,
    #[serde(default)]
    pub active_anomalous: bool,
    #[serde(default)]
    pub pending_episode_started_at_unix_nano: Option<u64>,
    #[serde(default)]
    pub pending_episode_peak_value: Option<f64>,
    #[serde(default)]
    pub pending_episode_peak_at_unix_nano: Option<u64>,
    #[serde(default)]
    pub active_episode_started_at_unix_nano: Option<u64>,
    #[serde(default)]
    pub active_episode_peak_value: Option<f64>,
    #[serde(default)]
    pub active_episode_peak_at_unix_nano: Option<u64>,
    #[serde(default)]
    pub raw_tail: Vec<f64>,
    #[serde(default)]
    pub spike_active_samples: u64,
    #[serde(default)]
    pub spike_last_emitted_at_unix_nano: Option<u64>,
    #[serde(default)]
    pub spike_last_cleared_at_unix_nano: Option<u64>,
    #[serde(default)]
    pub spike_last_episode_started_at_unix_nano: Option<u64>,
    #[serde(default)]
    pub spike_reopen_count: u64,
    #[serde(default)]
    pub aggregation_slot_start_unix_nano: Option<u64>,
    #[serde(default)]
    pub aggregation_slot_value: Option<f64>,
    #[serde(default)]
    pub aggregation_slot_peak_at_unix_nano: Option<u64>,
    /// Frozen CUSUM anchor mean — `Some` once the rolling baseline warmed and the
    /// drift detector anchored. Absent in pre-CUSUM checkpoints (`serde(default)`),
    /// so an upgrade re-anchors cleanly the next time the window warms.
    #[serde(default)]
    pub cusum_anchor_mean: Option<f64>,
    /// Frozen CUSUM anchor scale (the floored dispersion the residual divides by).
    #[serde(default)]
    pub cusum_anchor_scale: Option<f64>,
    /// Observed time when the frozen CUSUM anchor center was captured.
    #[serde(default)]
    pub cusum_anchor_captured_at_unix_nano: Option<u64>,
    /// CUSUM upper accumulator `S+` at checkpoint time, so a drift mid-accumulation
    /// re-alarms on schedule after a restart instead of restarting from zero.
    #[serde(default)]
    pub cusum_pos: Option<f64>,
    /// CUSUM lower accumulator `S-` at checkpoint time.
    #[serde(default)]
    pub cusum_neg: Option<f64>,
    /// Samples accumulated into the current CUSUM run since the last reset.
    #[serde(default)]
    pub cusum_run_samples: u64,
    /// Pending CUSUM direction latched at `h` but not yet confirmed at `h_confirm`.
    #[serde(default)]
    pub cusum_pending_direction: Option<CusumDirection>,
    /// Samples evaluated since entering the pending CUSUM latch.
    #[serde(default)]
    pub cusum_pending_samples: u64,
    /// Whether a drift episode was open at checkpoint time.
    #[serde(default)]
    pub drift_active: bool,
    #[serde(default)]
    pub drift_active_direction: Option<CusumDirection>,
    #[serde(default)]
    pub drift_episode_started_at_unix_nano: Option<u64>,
    #[serde(default)]
    pub drift_episode_peak_value: Option<f64>,
    #[serde(default)]
    pub drift_episode_peak_at_unix_nano: Option<u64>,
    #[serde(default)]
    pub drift_episode_peak_shift: f64,
    #[serde(default)]
    pub drift_peak_severity_band: u8,
    #[serde(default)]
    pub drift_active_samples: u64,
    #[serde(default)]
    pub drift_clear_samples: u64,
    #[serde(default)]
    pub drift_last_emitted_at_unix_nano: Option<u64>,
    #[serde(default)]
    pub drift_last_cleared_at_unix_nano: Option<u64>,
    #[serde(default)]
    pub drift_last_episode_started_at_unix_nano: Option<u64>,
    #[serde(default)]
    pub drift_reopen_count: u64,
    #[serde(default)]
    pub last_non_clear_emitted_at_unix_nano: Option<u64>,
    pub last_observed_at_unix_nano: u64,
}

/// One series' last cumulative-counter reading, serialized for the checkpoint.
#[derive(Clone, Debug, serde::Serialize, serde::Deserialize)]
pub struct CounterCheckpoint {
    pub series_key: String,
    pub value: f64,
    pub timestamp: u64,
    pub reset_anchor: String,
}

/// A point-in-time snapshot of all per-series detector + counter state, written
/// to the add-on's local checkpoint so a restart re-warms baselines instead of
/// rebuilding them from scratch (which would storm false positives while the
/// windows refill). Heavy seasonal/contextual state stays central, so this
/// snapshot is intentionally small.
#[derive(Clone, Debug, Default, serde::Serialize, serde::Deserialize)]
pub struct EngineCheckpoint {
    pub series: Vec<SeriesCheckpoint>,
    pub counters: Vec<CounterCheckpoint>,
}

impl DetectorEngine {
    /// Snapshot the current per-series detector + counter state for persistence.
    pub fn export_checkpoint(&self) -> EngineCheckpoint {
        EngineCheckpoint {
            series: self
                .series
                .iter()
                .map(|(key, state)| SeriesCheckpoint {
                    series_key: key.clone(),
                    window_tail: state.window_tail.clone(),
                    consecutive_anomalous: state.consecutive_anomalous,
                    consecutive_clean: state.consecutive_clean,
                    active_anomalous: state.active_anomalous,
                    pending_episode_started_at_unix_nano: state
                        .pending_episode_started_at_unix_nano,
                    pending_episode_peak_value: state.pending_episode_peak_value,
                    pending_episode_peak_at_unix_nano: state.pending_episode_peak_at_unix_nano,
                    active_episode_started_at_unix_nano: state.active_episode_started_at_unix_nano,
                    active_episode_peak_value: state.active_episode_peak_value,
                    active_episode_peak_at_unix_nano: state.active_episode_peak_at_unix_nano,
                    raw_tail: state.raw_tail.clone(),
                    spike_active_samples: state.spike_active_samples,
                    spike_last_emitted_at_unix_nano: state.spike_last_emitted_at_unix_nano,
                    spike_last_cleared_at_unix_nano: state.spike_last_cleared_at_unix_nano,
                    spike_last_episode_started_at_unix_nano: state
                        .spike_last_episode_started_at_unix_nano,
                    spike_reopen_count: state.spike_reopen_count,
                    aggregation_slot_start_unix_nano: state.aggregation_slot_start_unix_nano,
                    aggregation_slot_value: state.aggregation_slot_value,
                    aggregation_slot_peak_at_unix_nano: state.aggregation_slot_peak_at_unix_nano,
                    cusum_anchor_mean: state.cusum_anchor.map(|(mean, _scale)| mean),
                    cusum_anchor_scale: state.cusum_anchor.map(|(_mean, scale)| scale),
                    cusum_anchor_captured_at_unix_nano: state.cusum_anchor_captured_at_unix_nano,
                    cusum_pos: state.cusum.as_ref().map(Cusum::pos),
                    cusum_neg: state.cusum.as_ref().map(Cusum::neg),
                    cusum_run_samples: state.cusum_run_samples,
                    cusum_pending_direction: state.cusum_pending_direction,
                    cusum_pending_samples: state.cusum_pending_samples,
                    drift_active: state.drift_active,
                    drift_active_direction: state.drift_active_direction,
                    drift_episode_started_at_unix_nano: state.drift_episode_started_at_unix_nano,
                    drift_episode_peak_value: state.drift_episode_peak_value,
                    drift_episode_peak_at_unix_nano: state.drift_episode_peak_at_unix_nano,
                    drift_episode_peak_shift: state.drift_episode_peak_shift,
                    drift_peak_severity_band: state.drift_peak_severity_band,
                    drift_active_samples: state.drift_active_samples,
                    drift_clear_samples: state.drift_clear_samples,
                    drift_last_emitted_at_unix_nano: state.drift_last_emitted_at_unix_nano,
                    drift_last_cleared_at_unix_nano: state.drift_last_cleared_at_unix_nano,
                    drift_last_episode_started_at_unix_nano: state
                        .drift_last_episode_started_at_unix_nano,
                    drift_reopen_count: state.drift_reopen_count,
                    last_non_clear_emitted_at_unix_nano: state.last_non_clear_emitted_at_unix_nano,
                    last_observed_at_unix_nano: state.last_observed_at_unix_nano,
                })
                .collect(),
            counters: self
                .counters
                .iter()
                .map(|(key, counter)| CounterCheckpoint {
                    series_key: key.clone(),
                    value: counter.value,
                    timestamp: counter.timestamp,
                    reset_anchor: counter.reset_anchor.clone(),
                })
                .collect(),
        }
    }

    /// Reseed detector + counter state from a checkpoint, skipping any series
    /// whose last reading is older than `max_age_ns` before `now_unix_nano` (a
    /// stale baseline would mis-score current traffic), honoring the `max_series`
    /// cap, and truncating a restored window to the current `window_size` in case
    /// the configured window shrank. Returns the number of detector series
    /// reseeded. Existing in-memory state for a key is overwritten.
    pub fn restore_checkpoint(
        &mut self,
        checkpoint: EngineCheckpoint,
        now_unix_nano: u64,
        max_age_ns: u64,
    ) -> usize {
        let fresh = |ts: u64| now_unix_nano.saturating_sub(ts) <= max_age_ns;
        let mut restored = 0;

        let mut series_entries = checkpoint.series;
        series_entries.sort_by(|left, right| {
            right
                .last_observed_at_unix_nano
                .cmp(&left.last_observed_at_unix_nano)
        });

        for series in series_entries {
            if !fresh(series.last_observed_at_unix_nano) {
                continue;
            }
            if !self.series.contains_key(&series.series_key)
                && self.series.len() >= self.config.max_series
            {
                continue;
            }

            let mut window_tail = series.window_tail;
            if window_tail.len() > self.config.window_size {
                let drop = window_tail.len() - self.config.window_size;
                window_tail.drain(0..drop);
            }

            // Re-warm the CUSUM drift detector: the frozen anchor and the `S+`/`S-`
            // partial sums survive the restart, so a drift mid-accumulation
            // re-alarms on schedule. `k`/`h` come from the current config so a
            // retuned decision interval applies immediately. Pre-CUSUM checkpoints
            // (no anchor) simply re-anchor when the window next warms.
            let cusum_anchor = series.cusum_anchor_mean.zip(series.cusum_anchor_scale);
            let cusum = cusum_anchor.map(|_| {
                Cusum::with_state(
                    self.config.cusum_k,
                    self.config.cusum_h,
                    series.cusum_pos.unwrap_or(0.0),
                    series.cusum_neg.unwrap_or(0.0),
                )
            });
            let restore_cusum_latch = cusum.is_some();
            let restore_open_drift = series.drift_active
                && series.drift_active_direction.is_some()
                && series.drift_episode_started_at_unix_nano.is_some()
                && series.drift_episode_peak_value.is_some()
                && series.drift_episode_peak_at_unix_nano.is_some();

            let mut restored_state = SeriesState::new(series.last_observed_at_unix_nano);
            restored_state.window_tail = window_tail;
            restored_state.consecutive_anomalous = series.consecutive_anomalous;
            restored_state.consecutive_clean = series.consecutive_clean;
            restored_state.active_anomalous = series.active_anomalous;
            restored_state.pending_episode_started_at_unix_nano =
                series.pending_episode_started_at_unix_nano;
            restored_state.pending_episode_peak_value = series.pending_episode_peak_value;
            restored_state.pending_episode_peak_at_unix_nano =
                series.pending_episode_peak_at_unix_nano;
            restored_state.active_episode_started_at_unix_nano =
                series.active_episode_started_at_unix_nano;
            restored_state.active_episode_peak_value = series.active_episode_peak_value;
            restored_state.active_episode_peak_at_unix_nano =
                series.active_episode_peak_at_unix_nano;
            restored_state.raw_tail = series.raw_tail;
            if restored_state.raw_tail.len() > self.config.window_size {
                let drop = restored_state.raw_tail.len() - self.config.window_size;
                restored_state.raw_tail.drain(0..drop);
            }
            restored_state.spike_active_samples = series.spike_active_samples;
            restored_state.spike_last_emitted_at_unix_nano = series.spike_last_emitted_at_unix_nano;
            restored_state.spike_last_cleared_at_unix_nano = series.spike_last_cleared_at_unix_nano;
            restored_state.spike_last_episode_started_at_unix_nano =
                series.spike_last_episode_started_at_unix_nano;
            restored_state.spike_reopen_count = series.spike_reopen_count;
            restored_state.aggregation_slot_start_unix_nano =
                series.aggregation_slot_start_unix_nano;
            restored_state.aggregation_slot_value = series.aggregation_slot_value;
            restored_state.aggregation_slot_peak_at_unix_nano =
                series.aggregation_slot_peak_at_unix_nano;
            restored_state.cusum = cusum;
            restored_state.cusum_anchor = cusum_anchor;
            restored_state.cusum_anchor_captured_at_unix_nano = series
                .cusum_anchor_captured_at_unix_nano
                .or(cusum_anchor.map(|_| series.last_observed_at_unix_nano));
            restored_state.cusum_run_samples = if restore_cusum_latch {
                series.cusum_run_samples
            } else {
                0
            };
            restored_state.cusum_pending_direction = restore_cusum_latch
                .then_some(series.cusum_pending_direction)
                .flatten();
            restored_state.cusum_pending_samples =
                if restored_state.cusum_pending_direction.is_some() {
                    series.cusum_pending_samples
                } else {
                    0
                };
            restored_state.drift_active = restore_open_drift;
            if restore_open_drift {
                restored_state.drift_active_direction = series.drift_active_direction;
                restored_state.drift_episode_started_at_unix_nano =
                    series.drift_episode_started_at_unix_nano;
                restored_state.drift_episode_peak_value = series.drift_episode_peak_value;
                restored_state.drift_episode_peak_at_unix_nano =
                    series.drift_episode_peak_at_unix_nano;
                restored_state.drift_episode_peak_shift = series.drift_episode_peak_shift;
                restored_state.drift_peak_severity_band = series.drift_peak_severity_band;
                restored_state.drift_active_samples = series.drift_active_samples;
                restored_state.drift_clear_samples = series.drift_clear_samples;
                restored_state.drift_last_emitted_at_unix_nano =
                    series.drift_last_emitted_at_unix_nano;
            }
            restored_state.drift_last_cleared_at_unix_nano = series.drift_last_cleared_at_unix_nano;
            restored_state.drift_last_episode_started_at_unix_nano =
                series.drift_last_episode_started_at_unix_nano;
            restored_state.drift_reopen_count = series.drift_reopen_count;
            restored_state.last_non_clear_emitted_at_unix_nano =
                series.last_non_clear_emitted_at_unix_nano;

            self.series.insert(series.series_key, restored_state);
            restored += 1;
        }

        let mut counter_entries = checkpoint.counters;
        counter_entries.sort_by_key(|entry| std::cmp::Reverse(entry.timestamp));

        for counter in counter_entries {
            if !fresh(counter.timestamp) {
                continue;
            }
            if !self.counters.contains_key(&counter.series_key)
                && self.counters.len() >= self.config.max_series
            {
                continue;
            }
            self.counters.insert(
                counter.series_key,
                CounterState {
                    value: counter.value,
                    timestamp: counter.timestamp,
                    reset_anchor: counter.reset_anchor,
                },
            );
        }

        restored
    }
}
