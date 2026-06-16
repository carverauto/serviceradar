// Copyright 2026 Carver Automation Corporation.
//
// Licensed under the Apache License, Version 2.0 (the "License").
// SPDX-License-Identifier: Apache-2.0

//! Rolling / seasonal / trend signal evaluation.

use crate::stats::{BaselineStats, WelfordAcc, sample_stats, z_score};
use crate::types::SignalVerdict;
use crate::window::window_values;

impl SignalVerdict {
    pub(crate) fn disabled(name: &str, threshold: f64) -> Self {
        Self {
            name: name.to_string(),
            enabled: false,
            ready: false,
            breached: false,
            score: 0.0,
            threshold,
            sample_count: 0,
            mean: None,
            stddev: None,
            reason: "signal disabled".to_string(),
        }
    }

    pub(crate) fn not_ready(name: &str, threshold: f64, sample_count: usize, reason: String) -> Self {
        Self {
            name: name.to_string(),
            enabled: true,
            ready: false,
            breached: false,
            score: 0.0,
            threshold,
            sample_count,
            mean: None,
            stddev: None,
            reason,
        }
    }

    pub(crate) fn ready(
        name: &str,
        breached: bool,
        score: f64,
        threshold: f64,
        sample_count: usize,
        stats: BaselineStats,
        reason: String,
    ) -> Self {
        Self {
            name: name.to_string(),
            enabled: true,
            ready: true,
            breached,
            score,
            threshold,
            sample_count,
            mean: Some(stats.mean),
            stddev: Some(stats.stddev),
            reason,
        }
    }
}

pub fn evaluate_signal(
    name: &str,
    baseline: &[f64],
    enabled: bool,
    min_samples: usize,
    window_size: usize,
    threshold: f64,
    sample_value: f64,
) -> SignalVerdict {
    if !enabled {
        return SignalVerdict::disabled(name, threshold);
    }

    let window = window_values(baseline, window_size);
    evaluate_signal_window(name, window, enabled, min_samples, threshold, sample_value)
}

pub fn evaluate_rolling_signal(
    name: &str,
    acc: WelfordAcc,
    enabled: bool,
    min_samples: usize,
    threshold: f64,
    sample_value: f64,
) -> SignalVerdict {
    if !enabled {
        return SignalVerdict::disabled(name, threshold);
    }

    if acc.count < min_samples || acc.count < 2 {
        return SignalVerdict::not_ready(
            name,
            threshold,
            acc.count,
            format!(
                "{name} baseline has {} clean samples; requires at least {}",
                acc.count,
                min_samples.max(2)
            ),
        );
    }

    let Some(stats) = acc.stats() else {
        return SignalVerdict::not_ready(
            name,
            threshold,
            acc.count,
            format!("{name} baseline statistics are invalid"),
        );
    };

    let score = z_score(sample_value, stats, threshold);
    let breached = score >= threshold;
    let reason = if breached {
        format!("{name} z-score {score:.3} breached {threshold:.3}")
    } else {
        format!("{name} z-score {score:.3} is below {threshold:.3}")
    };

    SignalVerdict::ready(name, breached, score, threshold, acc.count, stats, reason)
}

pub fn reason_for_state(
    state: &str,
    signals: &[SignalVerdict],
    confirm_slots: usize,
    next_consecutive_anomalous: usize,
) -> String {
    match state {
        "insufficient_baseline" => {
            let reasons = signals
                .iter()
                .filter(|signal| signal.enabled && !signal.ready)
                .map(|signal| signal.reason.as_str())
                .collect::<Vec<_>>()
                .join("; ");

            if reasons.is_empty() {
                "no enabled signal has enough clean baseline samples".to_string()
            } else {
                reasons
            }
        }
        "anomalous" => format!(
            "breach confirmed after {next_consecutive_anomalous}/{confirm_slots} consecutive anomalous slots"
        ),
        "pending_anomaly" => format!(
            "breach pending confirmation at {next_consecutive_anomalous}/{confirm_slots} consecutive anomalous slots"
        ),
        _ => "all ready signals are clean; consecutive anomalous slots reset".to_string(),
    }
}

fn evaluate_signal_window(
    name: &str,
    window: Vec<f64>,
    enabled: bool,
    min_samples: usize,
    threshold: f64,
    sample_value: f64,
) -> SignalVerdict {
    if !enabled {
        return SignalVerdict::disabled(name, threshold);
    }

    if window.len() < min_samples || window.len() < 2 {
        return SignalVerdict::not_ready(
            name,
            threshold,
            window.len(),
            format!(
                "{name} baseline has {} clean samples; requires at least {}",
                window.len(),
                min_samples.max(2)
            ),
        );
    }

    let stats = sample_stats(&window);
    let score = z_score(sample_value, stats, threshold);
    let breached = score >= threshold;
    let reason = if breached {
        format!("{name} z-score {score:.3} breached {threshold:.3}")
    } else {
        format!("{name} z-score {score:.3} is below {threshold:.3}")
    };

    SignalVerdict::ready(name, breached, score, threshold, window.len(), stats, reason)
}
