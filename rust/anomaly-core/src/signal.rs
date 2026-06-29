// Copyright 2026 Carver Automation Corporation.
//
// Licensed under the Apache License, Version 2.0 (the "License").
// SPDX-License-Identifier: Apache-2.0

//! Rolling / seasonal / trend signal evaluation.

use crate::stats::{BaselineStats, RobustStats, robust_score, sample_stats, z_score};
use crate::types::{SaturationGate, SignalVerdict};
use crate::window::window_values;

/// The dispersion floors + optional saturation gate applied to one signal's
/// breach decision. Grouped so the per-signal call sites stay readable as more
/// fidelity knobs are added. Defaults (`0.0`/`0.0`/`None`) reproduce the prior
/// pure-symmetric-z behavior exactly.
#[derive(Clone, Copy, Debug, Default)]
pub struct SignalGate {
    pub min_std_floor: f64,
    pub min_cv: f64,
    pub saturation_gate: Option<SaturationGate>,
}

/// Decide whether a z-score over the threshold actually breaches, applying the
/// saturation gate (if any). The score is *not* modified here — only the breach
/// boolean — so edge/central z-score parity is preserved (the gate is `None` for
/// the counter/interface series the parity test exercises, and the score field is
/// always the raw z-score regardless).
fn gated_breach(
    score: f64,
    threshold: f64,
    sample_value: f64,
    stats: BaselineStats,
    gate: &SignalGate,
) -> bool {
    if score < threshold {
        return false;
    }
    match gate.saturation_gate {
        Some(saturation) => saturation.allows_breach(sample_value, stats.mean),
        None => true,
    }
}

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

    pub(crate) fn not_ready(
        name: &str,
        threshold: f64,
        sample_count: usize,
        reason: String,
    ) -> Self {
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

// The fidelity knobs are already bundled into one `SignalGate`; the remaining
// parameters are the signal's distinct primitive inputs (name/baseline/enable/
// min_samples/window_size/threshold/sample) that the detector passes positionally
// per signal, so a wrapper struct would not aid the call sites. One over the lint.
#[allow(clippy::too_many_arguments)]
pub fn evaluate_signal(
    name: &str,
    baseline: &[f64],
    enabled: bool,
    min_samples: usize,
    window_size: usize,
    threshold: f64,
    sample_value: f64,
    gate: SignalGate,
) -> SignalVerdict {
    if !enabled {
        return SignalVerdict::disabled(name, threshold);
    }

    let window = window_values(baseline, window_size);
    evaluate_signal_window(
        name,
        window,
        enabled,
        min_samples,
        threshold,
        sample_value,
        gate,
    )
}

/// Evaluate the rolling signal against the robust median/MAD ([`RobustStats`])
/// dispersion over the clean window. `sample_count` is the clean-window length
/// (used for the readiness gate); `stats` is the precomputed center/scale.
///
/// The score is the robust `(value - center) / scale` deviation — the Hampel
/// identifier that does not self-mask — but the breach/gate/threshold semantics
/// are identical to the prior mean/std path: `|deviation| >= threshold`, then the
/// saturation gate (which compares the sample against the robust `center`).
// The fidelity knobs are bundled into one `SignalGate`; the rest are the signal's
// distinct primitive inputs passed positionally, so a wrapper struct would not aid
// the call site. One over the lint (mirrors `evaluate_signal`).
#[allow(clippy::too_many_arguments)]
pub fn evaluate_rolling_signal(
    name: &str,
    stats: RobustStats,
    sample_count: usize,
    enabled: bool,
    min_samples: usize,
    threshold: f64,
    sample_value: f64,
    gate: SignalGate,
) -> SignalVerdict {
    if !enabled {
        return SignalVerdict::disabled(name, threshold);
    }

    if sample_count < min_samples || sample_count < 2 {
        return SignalVerdict::not_ready(
            name,
            threshold,
            sample_count,
            format!(
                "{name} baseline has {} clean samples; requires at least {}",
                sample_count,
                min_samples.max(2)
            ),
        );
    }

    let score = robust_score(
        sample_value,
        stats,
        threshold,
        gate.min_std_floor,
        gate.min_cv,
    );
    // The robust center/scale are reported through the verdict's mean/stddev fields
    // (the robust analogues), and the saturation gate's directional check uses the
    // robust `center`.
    let display = BaselineStats {
        mean: stats.center,
        stddev: stats.scale,
    };
    let breached = gated_breach(score, threshold, sample_value, display, &gate);
    let reason = breach_reason(name, score, threshold, breached);

    SignalVerdict::ready(
        name,
        breached,
        score,
        threshold,
        sample_count,
        display,
        reason,
    )
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
    gate: SignalGate,
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
    let score = z_score(
        sample_value,
        stats,
        threshold,
        gate.min_std_floor,
        gate.min_cv,
    );
    let breached = gated_breach(score, threshold, sample_value, stats, &gate);
    let reason = breach_reason(name, score, threshold, breached);

    SignalVerdict::ready(
        name,
        breached,
        score,
        threshold,
        window.len(),
        stats,
        reason,
    )
}

/// Human-readable reason for a signal's outcome. A z-score over the threshold
/// that the saturation gate suppressed reads as "below" the threshold for the
/// purpose of breaching — it is intentionally not an alert — so the message
/// reflects the final breach decision, not just the raw score comparison.
fn breach_reason(name: &str, score: f64, threshold: f64, breached: bool) -> String {
    if breached {
        format!("{name} z-score {score:.3} breached {threshold:.3}")
    } else if score >= threshold {
        format!("{name} z-score {score:.3} over {threshold:.3} but suppressed by saturation gate")
    } else {
        format!("{name} z-score {score:.3} is below {threshold:.3}")
    }
}

#[cfg(test)]
mod tests {
    use super::{SignalGate, evaluate_rolling_signal};
    use crate::stats::RobustStats;
    use crate::types::{SaturationGate, SignalVerdict};

    /// Score the rolling signal over `values` (robust median/MAD), with the window
    /// length as the readiness count.
    fn rolling(
        values: &[f64],
        enabled: bool,
        min_samples: usize,
        threshold: f64,
        sample_value: f64,
        gate: SignalGate,
    ) -> SignalVerdict {
        evaluate_rolling_signal(
            "rolling",
            RobustStats::from_values(values),
            values.len(),
            enabled,
            min_samples,
            threshold,
            sample_value,
            gate,
        )
    }

    #[test]
    fn ungated_signal_breaches_on_symmetric_z() {
        // Baseline ~50 with small noise; a big spike breaches with the default
        // (empty) gate — pure symmetric z, the prior behavior.
        let baseline: Vec<f64> = (0..40).map(|i| 50.0 + (i % 5) as f64).collect();
        let v = rolling(&baseline, true, 5, 3.0, 200.0, SignalGate::default());
        assert!(v.ready && v.breached, "spike must breach without a gate");
    }

    #[test]
    fn saturation_gate_suppresses_benign_and_downward_but_keeps_real_rise() {
        // Tight baseline at ~85% so the floored denominator (max of the 1.0 std
        // floor and the 0.05*85 CV floor) still lets a rise to the 100% ceiling
        // clear the 3-sigma threshold.
        let baseline: Vec<f64> = (0..40).map(|i| 85.0 + 0.2 * ((i % 2) as f64)).collect();
        let gate = SignalGate {
            min_std_floor: 1.0,
            min_cv: 0.05,
            saturation_gate: Some(SaturationGate {
                directional: true,
                min_value: 80.0,
            }),
        };

        // Upward to the 100% ceiling (over the floor, rising): breaches.
        let up = rolling(&baseline, true, 5, 3.0, 100.0, gate);
        assert!(
            up.breached,
            "a real upward saturation must breach (score {})",
            up.score
        );

        // Downward to 60% (below mean, still above the 80% absolute floor would be
        // suppressed too, but 60<80 also fails the floor): a large-z drop is gated
        // off — utilization easing is never an incident.
        let down = rolling(&baseline, true, 5, 3.0, 60.0, gate);
        assert!(
            down.score >= 3.0,
            "premise: the downward move is large-z ({})",
            down.score
        );
        assert!(!down.breached, "a downward move must not breach a gauge");

        // A benign low gauge (1.36% disk) wiggling: gate floor blocks it.
        let low_baseline: Vec<f64> = (0..40).map(|i| 1.36 + 0.01 * (i % 2) as f64).collect();
        let benign = rolling(&low_baseline, true, 5, 3.0, 1.5, gate);
        assert!(!benign.breached, "a benign low gauge must not breach");
    }

    #[test]
    fn std_floor_in_gate_tames_near_constant_series() {
        // Near-constant ~50 with sub-0.05 jitter: tiny nonzero stddev. Without a
        // floor a 0.1 bump is a huge z; the gate's std floor collapses it, while a
        // genuinely large spike on the same series still breaches.
        let baseline: Vec<f64> = (0..40).map(|i| 50.0 + 0.02 * ((i % 2) as f64)).collect();
        let floor_gate = SignalGate {
            min_std_floor: 1.0,
            min_cv: 0.05,
            saturation_gate: None,
        };

        let wiggle = rolling(&baseline, true, 5, 3.0, 50.1, floor_gate);
        assert!(!wiggle.breached, "a sub-floor wiggle must not breach");

        let spike = rolling(&baseline, true, 5, 3.0, 250.0, floor_gate);
        assert!(
            spike.breached,
            "a real spike must still breach despite the floor"
        );
    }
}
