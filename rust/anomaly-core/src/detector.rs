// Copyright 2026 Carver Automation Corporation.
//
// Licensed under the Apache License, Version 2.0 (the "License").
// SPDX-License-Identifier: Apache-2.0

//! The DeepCausality detector flow: hydrate window state, evaluate the rolling /
//! seasonal / trend signals, apply confirm-slot hysteresis, and emit a verdict.

use crate::signal::{evaluate_rolling_signal, evaluate_signal, reason_for_state};
use crate::stats::{WelfordAcc, clean_threshold};
use crate::types::{ReasonContext, ReasonSample, ReasonVerdict, SignalVerdict};
use crate::window::compact_rolling_state;
use crate::{DEFAULT_CONFIRM_SLOTS, DEFAULT_MIN_SAMPLES, DEFAULT_N_SIGMA, DEFAULT_WINDOW_SIZE};
use deep_causality_core::CausalFlow;

struct DetectorThresholds {
    rolling_enabled: bool,
    min_samples: usize,
    window_size: usize,
    n_sigma: f64,
    confirm_slots: usize,
    seasonal_baseline: Vec<f64>,
    seasonal_enabled: bool,
    seasonal_min_samples: usize,
    seasonal_n_sigma: f64,
    trend_baseline: Vec<f64>,
    trend_enabled: bool,
    trend_min_samples: usize,
    trend_n_sigma: f64,
}

struct DetectorState {
    window_tail: Vec<f64>,
    rolling_acc: WelfordAcc,
    window_size: usize,
    consecutive_anomalous: usize,
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
    let state = DetectorState::from_context(context, sample, thresholds.window_size);

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
                    state
                })
            },
            |clean| {
                clean.update_state(|mut state, _value| {
                    state.consecutive_anomalous = 0;
                    state.admit_clean_sample();
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

        Self {
            rolling_enabled: context.rolling_enabled.unwrap_or(true),
            min_samples,
            window_size,
            n_sigma,
            confirm_slots,
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
    fn from_context(context: ReasonContext, sample: ReasonSample, window_size: usize) -> Self {
        let (window_tail, rolling_acc) = compact_rolling_state(&context, window_size);

        Self {
            window_tail,
            rolling_acc,
            window_size,
            consecutive_anomalous: context.consecutive_anomalous.unwrap_or_default(),
            sample,
        }
    }

    fn admit_clean_sample(&mut self) {
        if !self.sample.value.is_finite() {
            return;
        }

        if self.window_tail.len() >= self.window_size.max(1)
            && let Some(evicted) = self.window_tail.first().copied()
        {
            self.rolling_acc.remove(evicted);
            self.window_tail.remove(0);
        }

        self.window_tail.push(self.sample.value);
        self.rolling_acc.add(self.sample.value);
    }

    fn window_tail(&self) -> Vec<f64> {
        self.window_tail.clone()
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
    let signals = vec![
        evaluate_rolling_signal(
            "rolling",
            state.rolling_acc,
            thresholds.rolling_enabled,
            thresholds.min_samples,
            thresholds.n_sigma,
            state.sample.value,
        ),
        evaluate_signal(
            "seasonal",
            &thresholds.seasonal_baseline,
            thresholds.seasonal_enabled,
            thresholds.seasonal_min_samples,
            thresholds.window_size,
            thresholds.seasonal_n_sigma,
            state.sample.value,
        ),
        evaluate_signal(
            "trend",
            &thresholds.trend_baseline,
            thresholds.trend_enabled,
            thresholds.trend_min_samples,
            thresholds.window_size,
            thresholds.trend_n_sigma,
            state.sample.value,
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
    state: DetectorState,
    context: Option<DetectorThresholds>,
) -> (DetectorValue, DetectorState, Option<DetectorThresholds>) {
    let DetectorValue::Evaluation(evaluation) = value else {
        return (value, state, context);
    };
    let Some(thresholds) = context.as_ref() else {
        return (DetectorValue::Evaluation(evaluation), state, context);
    };

    let anomalous = evaluation.breached && state.consecutive_anomalous >= thresholds.confirm_slots;
    let include_in_baseline = !evaluation.breached;
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
            next_window_tail: state.window_tail(),
            sample_value: state.sample.value,
            observed_at_unix_nano: state.sample.observed_at_unix_nano,
            signals: evaluation.signals,
        }),
        state,
        context,
    )
}
