// Copyright 2026 Carver Automation Corporation.
//
// Licensed under the Apache License, Version 2.0 (the "License").
// SPDX-License-Identifier: Apache-2.0

//! Retained per-series detector state: the bounded rolling-window tail plus the
//! confirm-slot/episode/CUSUM bookkeeping that must persist between samples, and
//! the last cumulative-counter reading kept for rate normalization.

use serviceradar_anomaly_core::Cusum;

use super::counter::COUNTER_MAX_GAP_NS;

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
    pub(crate) aggregation_slot_start_unix_nano: Option<u64>,
    pub(crate) aggregation_slot_value: Option<f64>,
    pub(crate) aggregation_slot_peak_at_unix_nano: Option<u64>,
    /// Two-sided CUSUM drift accumulator, lazily created once the rolling baseline
    /// first warms. `None` until then (or when CUSUM is disabled).
    pub(crate) cusum: Option<Cusum>,
    /// The FROZEN `(target_mean, scale)` the CUSUM standardizes against, captured
    /// once when the rolling baseline first reaches `min_samples`. The residual is
    /// `(value - target) / scale`, where `target` is the seasonal bucket center
    /// when one is delivered for the sample's hour-of-week, else `target_mean`.
    pub(crate) cusum_anchor: Option<(f64, f64)>,
    /// Observed time of the most recent sample, for the restart staleness bound:
    /// a baseline whose last reading is too old is not reseeded (it would
    /// mis-score current traffic).
    pub(crate) last_observed_at_unix_nano: u64,
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
