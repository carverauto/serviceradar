// Copyright 2026 Carver Automation Corporation.
//
// Licensed under the Apache License, Version 2.0 (the "License").
// SPDX-License-Identifier: Apache-2.0

//! The detector flow: hydrate window state, evaluate the rolling / seasonal / trend
//! signals, apply confirm-slot hysteresis, and emit a verdict. The flow is staged
//! with `deep_causality_core::CausalFlow` as a pipeline/state-machine combinator that
//! HOSTS the statistics — the detection itself is a rolling robust z-score, not
//! causal inference (no SCM, intervention, or counterfactual).

use crate::signal::{SignalGate, evaluate_rolling_signal, evaluate_signal, reason_for_state};
use crate::stats::{RobustStats, WelfordAcc, clean_threshold, effective_scoring_scale};
use crate::types::{ReasonContext, ReasonSample, ReasonVerdict, SaturationGate, SignalVerdict};
use crate::window::compact_rolling_state;
use crate::{DEFAULT_CONFIRM_SLOTS, DEFAULT_MIN_SAMPLES, DEFAULT_N_SIGMA, DEFAULT_WINDOW_SIZE};
use deep_causality_core::CausalFlow;

struct DetectorThresholds {
    rolling_enabled: bool,
    min_samples: usize,
    window_size: usize,
    n_sigma: f64,
    confirm_slots: usize,
    /// Dispersion floors (fix #2) and the optional saturation gate (fix #3),
    /// applied to every signal so edge and central score and gate identically.
    min_std_floor: f64,
    min_cv: f64,
    saturation_gate: Option<SaturationGate>,
    seasonal_baseline: Vec<f64>,
    seasonal_enabled: bool,
    seasonal_min_samples: usize,
    seasonal_n_sigma: f64,
    trend_baseline: Vec<f64>,
    trend_enabled: bool,
    trend_min_samples: usize,
    trend_n_sigma: f64,
}

impl DetectorThresholds {
    /// The breach gate shared by all three signals: the dispersion floors plus the
    /// saturation gate. Bundling it here keeps the per-signal call sites uniform
    /// and guarantees edge/central apply the *same* floors and gate.
    fn signal_gate(&self) -> SignalGate {
        SignalGate {
            min_std_floor: self.min_std_floor,
            min_cv: self.min_cv,
            saturation_gate: self.saturation_gate,
        }
    }
}

struct DetectorState {
    window_tail: Vec<f64>,
    /// Welford mean/std summary of the clean window, retained only as the persisted
    /// `next_rolling_acc` next-state. The rolling SCORE is the robust
    /// [`Self::rolling_stats`], not this acc.
    rolling_acc: WelfordAcc,
    /// The robust median/MAD estimator over the pre-sample clean window — the
    /// dispersion the rolling signal scores against (the Hampel identifier that
    /// does not self-mask).
    rolling_stats: RobustStats,
    window_size: usize,
    consecutive_anomalous: usize,
    /// The current sample bounded to the pre-sample rolling decision interval.
    /// A breach admits this value rather than dropping the sample completely, so
    /// the fixed-size window continues to age even during a sustained regime.
    breach_admission_value: f64,
    sample: ReasonSample,
}

enum DetectorCommand {
    EvaluateSample,
}

enum DetectorValue {
    Command(DetectorCommand),
    Evaluation(DetectionEvaluation),
    Verdict(ReasonVerdict),
}

struct DetectionEvaluation {
    signals: Vec<SignalVerdict>,
    ready: bool,
    breached: bool,
    score: f64,
    rolling_sample_count: usize,
}

pub fn reason_impl(context: ReasonContext, sample: ReasonSample) -> Result<ReasonVerdict, String> {
    if !sample.value.is_finite() {
        return Err("sample value must be finite".to_string());
    }

    let thresholds = DetectorThresholds::from_context(&context);
    let state = DetectorState::from_context(context, sample, &thresholds);

    CausalFlow::process(state)
        .context(thresholds)
        .map(|()| DetectorValue::Command(DetectorCommand::EvaluateSample))
        .update_value_state_context(evaluate_detector_command)
        .branch_with(
            |value, _state, _context| {
                matches!(value, DetectorValue::Evaluation(evaluation) if evaluation.breached)
            },
            |breach| {
                breach.update_state(|mut state, _value| {
                    state.consecutive_anomalous = state.consecutive_anomalous.saturating_add(1);
                    state.admit_sample(state.breach_admission_value);
                    state
                })
            },
            |clean| {
                clean.update_state(|mut state, _value| {
                    state.consecutive_anomalous = 0;
                    state.admit_sample(state.sample.value);
                    state
                })
            },
        )
        .update_value_state_context(finalize_detector_verdict)
        .finish()
        .and_then(|value| match value {
            DetectorValue::Verdict(verdict) => Ok(verdict),
            _ => Err(deep_causality_core::CausalityError::new(
                deep_causality_core::CausalityErrorEnum::ValueNotAvailable,
            )),
        })
        .map_err(|err| err.to_string())
}

impl DetectorThresholds {
    fn from_context(context: &ReasonContext) -> Self {
        let window_size = context.window_size.unwrap_or(DEFAULT_WINDOW_SIZE).max(1);
        let min_samples = context.min_samples.unwrap_or(DEFAULT_MIN_SAMPLES).max(1);
        let n_sigma = clean_threshold(context.n_sigma.unwrap_or(DEFAULT_N_SIGMA));
        let confirm_slots = context
            .confirm_slots
            .unwrap_or(DEFAULT_CONFIRM_SLOTS)
            .max(1);
        let seasonal_enabled = context.seasonal_enabled.unwrap_or_else(|| {
            context
                .seasonal_baseline
                .as_ref()
                .is_some_and(|values| !values.is_empty())
        });
        let trend_enabled = context.trend_enabled.unwrap_or_else(|| {
            context
                .trend_baseline
                .as_ref()
                .is_some_and(|values| !values.is_empty())
        });

        let min_std_floor = context
            .min_std_floor
            .filter(|v| v.is_finite() && *v > 0.0)
            .unwrap_or(0.0);
        let min_cv = context
            .min_cv
            .filter(|v| v.is_finite() && *v > 0.0)
            .unwrap_or(0.0);

        Self {
            rolling_enabled: context.rolling_enabled.unwrap_or(true),
            min_samples,
            window_size,
            n_sigma,
            confirm_slots,
            min_std_floor,
            min_cv,
            saturation_gate: context.saturation_gate,
            seasonal_baseline: context.seasonal_baseline.clone().unwrap_or_default(),
            seasonal_enabled,
            seasonal_min_samples: context.seasonal_min_samples.unwrap_or(min_samples).max(1),
            seasonal_n_sigma: clean_threshold(context.seasonal_n_sigma.unwrap_or(n_sigma)),
            trend_baseline: context.trend_baseline.clone().unwrap_or_default(),
            trend_enabled,
            trend_min_samples: context.trend_min_samples.unwrap_or(min_samples).max(1),
            trend_n_sigma: clean_threshold(context.trend_n_sigma.unwrap_or(n_sigma)),
        }
    }
}

impl DetectorState {
    fn from_context(
        context: ReasonContext,
        sample: ReasonSample,
        thresholds: &DetectorThresholds,
    ) -> Self {
        let (window_tail, rolling_acc, rolling_stats) =
            compact_rolling_state(&context, thresholds.window_size);
        let scale =
            effective_scoring_scale(rolling_stats, thresholds.min_std_floor, thresholds.min_cv);
        let radius = thresholds.n_sigma * scale;
        let breach_admission_value =
            if rolling_stats.center.is_finite() && radius.is_finite() && radius > 0.0 {
                sample
                    .value
                    .clamp(rolling_stats.center - radius, rolling_stats.center + radius)
            } else {
                sample.value
            };

        Self {
            window_tail,
            rolling_acc,
            rolling_stats,
            window_size: thresholds.window_size,
            consecutive_anomalous: context.consecutive_anomalous.unwrap_or_default(),
            breach_admission_value,
            sample,
        }
    }

    fn admit_sample(&mut self, value: f64) {
        if !value.is_finite() {
            return;
        }

        if self.window_tail.len() >= self.window_size.max(1)
            && let Some(evicted) = self.window_tail.first().copied()
        {
            self.rolling_acc.remove(evicted);
            self.window_tail.remove(0);
        }

        self.window_tail.push(value);
        self.rolling_acc.add(value);
    }
}

fn evaluate_detector_command(
    value: DetectorValue,
    state: DetectorState,
    context: Option<DetectorThresholds>,
) -> (DetectorValue, DetectorState, Option<DetectorThresholds>) {
    let Some(thresholds) = context.as_ref() else {
        return (value, state, context);
    };

    let value = match value {
        DetectorValue::Command(DetectorCommand::EvaluateSample) => {
            DetectorValue::Evaluation(evaluate_detector(&state, thresholds))
        }
        value => value,
    };

    (value, state, context)
}

fn evaluate_detector(
    state: &DetectorState,
    thresholds: &DetectorThresholds,
) -> DetectionEvaluation {
    let gate = thresholds.signal_gate();
    let signals = vec![
        evaluate_rolling_signal(
            "rolling",
            state.rolling_stats,
            state.window_tail.len(),
            thresholds.rolling_enabled,
            thresholds.min_samples,
            thresholds.n_sigma,
            state.sample.value,
            gate,
        ),
        evaluate_signal(
            "seasonal",
            &thresholds.seasonal_baseline,
            thresholds.seasonal_enabled,
            thresholds.seasonal_min_samples,
            thresholds.window_size,
            thresholds.seasonal_n_sigma,
            state.sample.value,
            gate,
        ),
        evaluate_signal(
            "trend",
            &thresholds.trend_baseline,
            thresholds.trend_enabled,
            thresholds.trend_min_samples,
            thresholds.window_size,
            thresholds.trend_n_sigma,
            state.sample.value,
            gate,
        ),
    ];

    let ready = signals.iter().any(|signal| signal.ready);
    let breached = signals.iter().any(|signal| signal.breached);
    let score = signals
        .iter()
        .filter(|signal| signal.ready)
        .map(|signal| signal.score)
        .fold(0.0, f64::max);
    let rolling_sample_count = signals
        .iter()
        .find(|signal| signal.name == "rolling")
        .map(|signal| signal.sample_count)
        .unwrap_or_default();

    DetectionEvaluation {
        signals,
        ready,
        breached,
        score,
        rolling_sample_count,
    }
}

fn finalize_detector_verdict(
    value: DetectorValue,
    mut state: DetectorState,
    context: Option<DetectorThresholds>,
) -> (DetectorValue, DetectorState, Option<DetectorThresholds>) {
    let DetectorValue::Evaluation(evaluation) = value else {
        return (value, state, context);
    };
    let Some(thresholds) = context.as_ref() else {
        return (DetectorValue::Evaluation(evaluation), state, context);
    };

    let anomalous = evaluation.breached && state.consecutive_anomalous >= thresholds.confirm_slots;

    // A breach is admitted only at the pre-sample decision boundary. This keeps
    // a real burst from self-masking while also advancing the bounded window so
    // a stable new regime cannot freeze a night-level baseline forever.
    let include_in_baseline = true;
    let verdict_state = if !evaluation.ready {
        "insufficient_baseline"
    } else if anomalous {
        "anomalous"
    } else if evaluation.breached {
        "pending_anomaly"
    } else {
        "clean"
    };
    let reason = reason_for_state(
        verdict_state,
        &evaluation.signals,
        thresholds.confirm_slots,
        state.consecutive_anomalous,
    );

    (
        DetectorValue::Verdict(ReasonVerdict {
            state: verdict_state.to_string(),
            anomalous,
            breached: evaluation.breached,
            include_in_baseline,
            next_consecutive_anomalous: state.consecutive_anomalous,
            score: evaluation.score,
            reason,
            baseline_count: evaluation.rolling_sample_count,
            next_rolling_acc: state.rolling_acc,
            // Move the window tail out of the about-to-be-discarded state rather
            // than cloning it: after this finalize transform the pipeline's
            // `.finish()` extracts the verdict and drops `state`, so nothing reads
            // `state.window_tail` again.
            next_window_tail: std::mem::take(&mut state.window_tail),
            sample_value: state.sample.value,
            observed_at_unix_nano: state.sample.observed_at_unix_nano,
            signals: evaluation.signals,
        }),
        state,
        context,
    )
}

#[cfg(test)]
mod tests {
    use super::reason_impl;
    use crate::types::{ReasonContext, ReasonSample};

    fn context(confirm_slots: usize, consecutive_anomalous: usize) -> ReasonContext {
        ReasonContext {
            baseline: (0..20)
                .map(|i| 100.0 + if i % 2 == 0 { 0.5 } else { -0.5 })
                .collect(),
            rolling_acc: None,
            window_tail: None,
            seasonal_baseline: None,
            trend_baseline: None,
            rolling_enabled: Some(true),
            seasonal_enabled: Some(false),
            trend_enabled: Some(false),
            min_samples: Some(5),
            seasonal_min_samples: None,
            trend_min_samples: None,
            window_size: Some(50),
            n_sigma: Some(3.0),
            seasonal_n_sigma: None,
            trend_n_sigma: None,
            confirm_slots: Some(confirm_slots),
            consecutive_anomalous: Some(consecutive_anomalous),
            min_std_floor: None,
            min_cv: None,
            saturation_gate: None,
        }
    }

    fn sample(value: f64) -> ReasonSample {
        ReasonSample {
            value,
            observed_at_unix_nano: None,
        }
    }

    #[test]
    fn confirm_slots_nth_breach_confirms_not_before() {
        let first = reason_impl(context(3, 0), sample(1_000.0)).expect("first pending verdict");
        assert_eq!(first.state, "pending_anomaly");
        assert!(!first.anomalous);
        assert_eq!(first.next_consecutive_anomalous, 1);

        let pending = reason_impl(context(3, 1), sample(1_000.0)).expect("pending verdict");
        assert_eq!(pending.state, "pending_anomaly");
        assert!(!pending.anomalous);
        assert_eq!(pending.next_consecutive_anomalous, 2);

        let confirmed = reason_impl(context(3, 2), sample(1_000.0)).expect("confirmed verdict");
        assert_eq!(confirmed.state, "anomalous");
        assert!(confirmed.anomalous);
        assert_eq!(confirmed.next_consecutive_anomalous, 3);
    }

    #[test]
    fn confirm_slots_one_confirms_first_breach() {
        let confirmed = reason_impl(context(1, 0), sample(1_000.0)).expect("confirmed verdict");
        assert_eq!(confirmed.state, "anomalous");
        assert!(confirmed.anomalous);
        assert_eq!(confirmed.next_consecutive_anomalous, 1);
    }

    #[test]
    fn clean_slot_resets_pending_confirmation() {
        let clean = reason_impl(context(3, 2), sample(100.0)).expect("clean verdict");
        assert_eq!(clean.state, "clean");
        assert!(!clean.anomalous);
        assert!(!clean.breached);
        assert_eq!(clean.next_consecutive_anomalous, 0);
        assert!(clean.include_in_baseline);
    }

    #[test]
    fn breaching_sample_ages_the_window_at_the_decision_boundary() {
        let breached = reason_impl(context(1, 0), sample(1_000.0)).expect("breaching verdict");

        assert!(breached.breached);
        assert!(breached.include_in_baseline);
        assert_eq!(breached.next_window_tail.len(), 21);
        assert!(
            breached
                .next_window_tail
                .last()
                .copied()
                .unwrap_or_default()
                < 1_000.0,
            "the raw breach must not enter the baseline unbounded"
        );
    }
}
