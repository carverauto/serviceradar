// Copyright 2026 Carver Automation Corporation.
//
// Licensed under the Apache License, Version 2.0 (the "License").
// SPDX-License-Identifier: Apache-2.0

//! Retained per-series detector state: the bounded rolling-window tail plus the
//! confirm-slot/episode/CUSUM bookkeeping that must persist between samples, and
//! the last cumulative-counter reading kept for rate normalization.

use std::collections::BTreeMap;

use serviceradar_anomaly_core::Cusum;

use super::counter::COUNTER_MAX_GAP_NS;
use super::types::CusumDirection;

/// A series/counter that has not been observed for this long is eligible for
/// eviction when a new key would otherwise hit the memory cap. This matches the
/// counter discontinuity gap: after two hours the old sample is no longer useful
/// for rate derivation or anomaly baseline continuity.
pub(crate) const STATE_EVICTION_MAX_AGE_NS: u64 = COUNTER_MAX_GAP_NS;

/// The retained baseline for one series. The rolling accumulator is recomputed
/// from `window_tail` each evaluation (the stateless path), so only the bounded
/// window tail and the confirm-slot counter need to persist between samples.
pub(crate) struct SeriesState {
    pub(crate) window_tail: Vec<f64>,
    pub(crate) consecutive_anomalous: usize,
    pub(crate) consecutive_clean: usize,
    /// Whether this series currently has an emitted-but-not-cleared anomaly.
    pub(crate) active_anomalous: bool,
    pub(crate) pending_episode_started_at_unix_nano: Option<u64>,
    pub(crate) pending_episode_peak_value: Option<f64>,
    pub(crate) pending_episode_peak_at_unix_nano: Option<u64>,
    pub(crate) active_episode_started_at_unix_nano: Option<u64>,
    pub(crate) active_episode_peak_value: Option<f64>,
    pub(crate) active_episode_peak_at_unix_nano: Option<u64>,
    /// Bounded raw observations, including breaching values. The rolling window
    /// gets winsorized values while a spike is active; this ring is the trusted
    /// source used when a stable new regime is explicitly adopted.
    pub(crate) raw_tail: Vec<f64>,
    /// Index into `raw_tail` where the current breaching run (pending or open
    /// spike episode) began. The recent-burst envelope is computed from raw
    /// history BEFORE this index only, so a sustained surge cannot train the
    /// envelope on itself and clear early as "recovered"; the marker is dropped
    /// once the run ends (recovered, adopted, or a blip that never confirmed),
    /// at which point the run's samples become ordinary burst history. Not
    /// checkpointed: a restart mid-run simply starts a fresh run.
    pub(crate) burst_run_start: Option<usize>,
    pub(crate) spike_active_samples: u64,
    pub(crate) spike_last_emitted_at_unix_nano: Option<u64>,
    pub(crate) spike_last_cleared_at_unix_nano: Option<u64>,
    pub(crate) spike_last_episode_started_at_unix_nano: Option<u64>,
    pub(crate) spike_reopen_count: u64,
    pub(crate) aggregation_slot_start_unix_nano: Option<u64>,
    pub(crate) aggregation_slot_value: Option<f64>,
    pub(crate) aggregation_slot_peak_at_unix_nano: Option<u64>,
    /// Two-sided CUSUM drift accumulator, lazily created once the rolling baseline
    /// first warms. `None` until then (or when the series profile disables drift).
    pub(crate) cusum: Option<Cusum>,
    /// The FROZEN `(target_mean, scale)` the CUSUM standardizes against, captured
    /// once when the rolling baseline first reaches `min_samples`. The residual is
    /// `(value - target) / scale`, where `target` is the seasonal bucket center
    /// when one is delivered for the sample's hour-of-week, else `target_mean`.
    pub(crate) cusum_anchor: Option<(f64, f64)>,
    /// Observed time when the CUSUM anchor center was captured. The center is
    /// intentionally frozen between episode clears/adoptions, but always-on raw
    /// drift can refresh an old idle anchor before it becomes a permanent alarm
    /// annuity.
    pub(crate) cusum_anchor_captured_at_unix_nano: Option<u64>,
    /// Number of samples accumulated into the current CUSUM run since the last
    /// alarm/reset. Used to estimate the sustained shift as `k + S/N`.
    pub(crate) cusum_run_samples: u64,
    /// Direction latched when one accumulator first crosses `h`; no drift emits
    /// until that same direction reaches the stronger confirmation threshold.
    pub(crate) cusum_pending_direction: Option<CusumDirection>,
    /// Samples evaluated after the pending latch was entered.
    pub(crate) cusum_pending_samples: u64,
    /// Whether a drift episode is currently open for this series.
    pub(crate) drift_active: bool,
    pub(crate) drift_active_direction: Option<CusumDirection>,
    pub(crate) drift_episode_started_at_unix_nano: Option<u64>,
    pub(crate) drift_episode_peak_value: Option<f64>,
    pub(crate) drift_episode_peak_at_unix_nano: Option<u64>,
    pub(crate) drift_episode_peak_shift: f64,
    pub(crate) drift_peak_severity_band: u8,
    pub(crate) drift_active_samples: u64,
    pub(crate) drift_clear_samples: u64,
    pub(crate) drift_last_emitted_at_unix_nano: Option<u64>,
    pub(crate) drift_last_cleared_at_unix_nano: Option<u64>,
    pub(crate) drift_last_episode_started_at_unix_nano: Option<u64>,
    pub(crate) drift_reopen_count: u64,
    /// Last externally emitted non-clear anomaly row for this detector series.
    pub(crate) last_non_clear_emitted_at_unix_nano: Option<u64>,
    /// Observed time of the most recent sample, for the restart staleness bound:
    /// a baseline whose last reading is too old is not reseeded (it would
    /// mis-score current traffic).
    pub(crate) last_observed_at_unix_nano: u64,
}

impl SeriesState {
    pub(crate) fn new(observed_at_unix_nano: u64) -> Self {
        Self {
            window_tail: Vec::new(),
            consecutive_anomalous: 0,
            consecutive_clean: 0,
            active_anomalous: false,
            pending_episode_started_at_unix_nano: None,
            pending_episode_peak_value: None,
            pending_episode_peak_at_unix_nano: None,
            active_episode_started_at_unix_nano: None,
            active_episode_peak_value: None,
            active_episode_peak_at_unix_nano: None,
            raw_tail: Vec::new(),
            burst_run_start: None,
            spike_active_samples: 0,
            spike_last_emitted_at_unix_nano: None,
            spike_last_cleared_at_unix_nano: None,
            spike_last_episode_started_at_unix_nano: None,
            spike_reopen_count: 0,
            aggregation_slot_start_unix_nano: None,
            aggregation_slot_value: None,
            aggregation_slot_peak_at_unix_nano: None,
            cusum: None,
            cusum_anchor: None,
            cusum_anchor_captured_at_unix_nano: None,
            cusum_run_samples: 0,
            cusum_pending_direction: None,
            cusum_pending_samples: 0,
            drift_active: false,
            drift_active_direction: None,
            drift_episode_started_at_unix_nano: None,
            drift_episode_peak_value: None,
            drift_episode_peak_at_unix_nano: None,
            drift_episode_peak_shift: 0.0,
            drift_peak_severity_band: 0,
            drift_active_samples: 0,
            drift_clear_samples: 0,
            drift_last_emitted_at_unix_nano: None,
            drift_last_cleared_at_unix_nano: None,
            drift_last_episode_started_at_unix_nano: None,
            drift_reopen_count: 0,
            last_non_clear_emitted_at_unix_nano: None,
            last_observed_at_unix_nano: observed_at_unix_nano,
        }
    }
}

/// Per-series cumulative-counter reading retained for rate normalization. The
/// detector cannot z-score a raw cumulative counter (SNMP interface octets,
/// etc.); central derives a per-second rate from consecutive readings on one
/// reset lineage and the edge mirrors that math so verdicts match.
#[derive(Clone, Debug)]
pub(crate) struct CounterState {
    pub(crate) value: f64,
    pub(crate) timestamp: u64,
    pub(crate) reset_anchor: String,
}

#[derive(Clone, Copy, Debug)]
pub(crate) struct HostCpuAggregateSample {
    pub(crate) mean_value: f64,
    pub(crate) observed_at_unix_nano: u64,
    pub(crate) slot_start_unix_nano: u64,
    pub(crate) core_count: u32,
    pub(crate) cores_above_gate: u32,
    pub(crate) fraction_above_gate: f64,
    pub(crate) peak_value: f64,
    pub(crate) peak_at_unix_nano: u64,
}

#[derive(Clone, Copy, Debug)]
pub(crate) struct HostCpuCoreSlot {
    pub(crate) value: f64,
    pub(crate) observed_at_unix_nano: u64,
}

#[derive(Clone, Debug)]
pub(crate) struct HostCpuSlotState {
    pub(crate) slot_start_unix_nano: u64,
    pub(crate) cores: BTreeMap<String, HostCpuCoreSlot>,
    pub(crate) last_observed_at_unix_nano: u64,
}

impl HostCpuSlotState {
    pub(crate) fn new(slot_start_unix_nano: u64) -> Self {
        Self {
            slot_start_unix_nano,
            cores: BTreeMap::new(),
            last_observed_at_unix_nano: slot_start_unix_nano,
        }
    }

    pub(crate) fn observe_core(&mut self, core_id: &str, value: f64, observed_at_unix_nano: u64) {
        self.last_observed_at_unix_nano =
            self.last_observed_at_unix_nano.max(observed_at_unix_nano);
        let entry = self
            .cores
            .entry(core_id.to_string())
            .or_insert(HostCpuCoreSlot {
                value,
                observed_at_unix_nano,
            });
        if value > entry.value {
            entry.value = value;
            entry.observed_at_unix_nano = observed_at_unix_nano;
        }
    }

    pub(crate) fn aggregate(&self, saturation_gate: f64) -> Option<HostCpuAggregateSample> {
        if self.cores.len() < 2 {
            return None;
        }

        let mut sum = 0.0;
        let mut cores_above_gate = 0_u32;
        let mut peak_value = f64::NEG_INFINITY;
        let mut peak_at_unix_nano = self.slot_start_unix_nano;

        for core in self.cores.values() {
            sum += core.value;
            if core.value >= saturation_gate {
                cores_above_gate = cores_above_gate.saturating_add(1);
            }
            if core.value >= peak_value {
                peak_value = core.value;
                peak_at_unix_nano = core.observed_at_unix_nano;
            }
        }

        let core_count = self.cores.len() as u32;
        let mean_value = sum / f64::from(core_count);
        Some(HostCpuAggregateSample {
            mean_value,
            observed_at_unix_nano: peak_at_unix_nano,
            slot_start_unix_nano: self.slot_start_unix_nano,
            core_count,
            cores_above_gate,
            fraction_above_gate: f64::from(cores_above_gate) / f64::from(core_count),
            peak_value,
            peak_at_unix_nano,
        })
    }
}
