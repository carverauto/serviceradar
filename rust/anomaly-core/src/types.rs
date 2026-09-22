// Copyright 2026 Carver Automation Corporation.
//
// Licensed under the Apache License, Version 2.0 (the "License").
// SPDX-License-Identifier: Apache-2.0

//! Detector input/output types shared by the anomaly-core crate and edge add-on.

use crate::stats::WelfordAcc;

/// An absolute/directional breach gate for saturation gauges (cpu/mem/disk
/// used_percent). These series have a hard ceiling (100%) and a meaningful
/// direction (only *rising* utilization is interesting), so a pure symmetric
/// z-score over-fires: a benign downward wiggle, or any wiggle on a near-constant
/// low-utilization series, would breach. The gate suppresses a z-breach unless
/// the excursion is in the configured direction AND the absolute value clears a
/// floor. It is `None` for counters / interface-rate series, which stay purely
/// z-based (a rate has no fixed ceiling, and either direction can be anomalous).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct SaturationGate {
    /// When true, only an upward excursion (`sample_value > mean`) can breach; a
    /// downward move never alerts. When false the gate is direction-agnostic.
    pub directional: bool,
    /// Absolute floor in the metric's own units (percent for used_percent
    /// gauges): a sample at or below this value is benign and never breaches,
    /// regardless of how large its z-score is. A near-empty disk wiggling cannot
    /// alert; a disk climbing toward full still can.
    pub min_value: f64,
}

impl SaturationGate {
    /// Whether a z-breach is allowed to stand for this sample. A z-score over the
    /// threshold is necessary but not sufficient for a gated series: the move must
    /// also be in the gated direction and clear the absolute floor.
    pub fn allows_breach(&self, sample_value: f64, mean: f64) -> bool {
        if self.directional && sample_value <= mean {
            return false;
        }
        sample_value > self.min_value
    }
}

/// Per-series detector input: the baseline state plus configuration thresholds.
#[derive(Clone, Debug)]
pub struct ReasonContext {
    pub baseline: Vec<f64>,
    pub rolling_acc: Option<WelfordAcc>,
    pub window_tail: Option<Vec<f64>>,
    pub seasonal_baseline: Option<Vec<f64>>,
    pub trend_baseline: Option<Vec<f64>>,
    pub rolling_enabled: Option<bool>,
    pub seasonal_enabled: Option<bool>,
    pub trend_enabled: Option<bool>,
    pub min_samples: Option<usize>,
    pub seasonal_min_samples: Option<usize>,
    pub trend_min_samples: Option<usize>,
    pub window_size: Option<usize>,
    pub n_sigma: Option<f64>,
    pub seasonal_n_sigma: Option<f64>,
    pub trend_n_sigma: Option<f64>,
    /// Consecutive completed evaluation slots that must breach before the detector
    /// reports `anomalous`. `confirm_slots = N` means the first `N - 1` breaching
    /// slots are `pending_anomaly`, the Nth breaching slot confirms, and any clean
    /// slot resets the pending count to zero.
    pub confirm_slots: Option<usize>,
    pub consecutive_anomalous: Option<usize>,
    /// Absolute dispersion floor (metric units) applied before the z-score
    /// divides; see [`crate::stats::BaselineStats::effective_stddev`]. `None`/0.0
    /// preserves legacy pure-stddev behavior.
    pub min_std_floor: Option<f64>,
    /// Relative (coefficient-of-variation) dispersion floor, `min_cv * |mean|`.
    /// `None`/0.0 preserves legacy behavior.
    pub min_cv: Option<f64>,
    /// Optional absolute/directional breach gate for saturation gauges. `None`
    /// leaves the series purely z-based (counters / interface rates).
    pub saturation_gate: Option<SaturationGate>,
    /// Optional practical-significance ceiling for UPWARD moves, in the metric's
    /// own units: a sample above the rolling center but at or below this level
    /// is within the series' recent burst envelope and does not breach, whatever
    /// its rolling or seasonal z-score says. The caller derives it from the
    /// series' lagged raw history (a recurring bulk transfer leaves its own
    /// samples in that history, so the next one is "expected"). `None` keeps the
    /// pure z-based behavior; downward moves are never gated.
    pub burst_envelope: Option<f64>,
}

/// A single observed sample.
#[derive(Clone, Copy, Debug)]
pub struct ReasonSample {
    pub value: f64,
    pub observed_at_unix_nano: Option<u64>,
}

/// The full per-sample verdict, including the next baseline state to persist.
#[derive(Debug, PartialEq)]
pub struct ReasonVerdict {
    pub state: String,
    pub anomalous: bool,
    pub breached: bool,
    pub include_in_baseline: bool,
    pub next_consecutive_anomalous: usize,
    pub score: f64,
    pub reason: String,
    pub baseline_count: usize,
    pub next_rolling_acc: WelfordAcc,
    pub next_window_tail: Vec<f64>,
    pub sample_value: f64,
    pub observed_at_unix_nano: Option<u64>,
    pub signals: Vec<SignalVerdict>,
}

/// A reduced verdict for the event-batch path: omits the next-state fields a
/// stateful caller does not need to persist.
#[derive(Debug, PartialEq)]
pub struct ReasonEventVerdict {
    pub state: String,
    pub anomalous: bool,
    pub breached: bool,
    pub include_in_baseline: bool,
    pub next_consecutive_anomalous: usize,
    pub score: f64,
    pub reason: String,
    pub baseline_count: usize,
    pub sample_value: f64,
    pub observed_at_unix_nano: Option<u64>,
    pub signals: Vec<SignalVerdict>,
}

impl ReasonEventVerdict {
    pub fn from_verdict(verdict: ReasonVerdict) -> Self {
        let signals = if verdict.anomalous || verdict.breached {
            verdict.signals
        } else {
            Vec::new()
        };

        Self {
            state: verdict.state,
            anomalous: verdict.anomalous,
            breached: verdict.breached,
            include_in_baseline: verdict.include_in_baseline,
            next_consecutive_anomalous: verdict.next_consecutive_anomalous,
            score: verdict.score,
            reason: verdict.reason,
            baseline_count: verdict.baseline_count,
            sample_value: verdict.sample_value,
            observed_at_unix_nano: verdict.observed_at_unix_nano,
            signals,
        }
    }
}

/// The per-signal (rolling / seasonal / trend) evaluation detail.
#[derive(Clone, Debug, PartialEq)]
pub struct SignalVerdict {
    pub name: String,
    pub enabled: bool,
    pub ready: bool,
    pub breached: bool,
    pub score: f64,
    pub threshold: f64,
    pub sample_count: usize,
    pub mean: Option<f64>,
    pub stddev: Option<f64>,
    pub reason: String,
}

#[cfg(test)]
mod tests {
    use super::SaturationGate;

    #[test]
    fn directional_gate_blocks_downward_excursions() {
        let gate = SaturationGate {
            directional: true,
            min_value: 80.0,
        };
        // Above the floor but moving DOWN from the mean: not an incident.
        assert!(!gate.allows_breach(82.0, 90.0));
        // Above the floor and moving UP: allowed.
        assert!(gate.allows_breach(95.0, 90.0));
    }

    #[test]
    fn absolute_floor_blocks_benign_low_values() {
        let gate = SaturationGate {
            directional: true,
            min_value: 80.0,
        };
        // Upward, but still benign (1.36% disk / 6.4% mem / 18% core): blocked.
        assert!(!gate.allows_breach(1.46, 1.36));
        assert!(!gate.allows_breach(18.0, 4.0));
        // At the floor exactly is still benign (strictly greater required).
        assert!(!gate.allows_breach(80.0, 10.0));
        // Above the floor: allowed.
        assert!(gate.allows_breach(80.001, 10.0));
    }

    #[test]
    fn non_directional_gate_allows_either_direction_above_floor() {
        let gate = SaturationGate {
            directional: false,
            min_value: 50.0,
        };
        // Direction-agnostic: a downward move above the floor still passes.
        assert!(gate.allows_breach(60.0, 90.0));
        assert!(gate.allows_breach(95.0, 90.0));
        // Below the floor: still blocked.
        assert!(!gate.allows_breach(40.0, 90.0));
    }
}
