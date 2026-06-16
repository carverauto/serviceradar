// Copyright 2026 Carver Automation Corporation.
//
// Licensed under the Apache License, Version 2.0 (the "License").
// SPDX-License-Identifier: Apache-2.0

//! Detector input/output types shared across the BEAM/NIF boundary and the edge
//! add-on. The `rustler` feature adds the `NifMap` derive so the NIF can pass
//! them to/from Elixir; without it these are plain structs.

use crate::stats::WelfordAcc;

/// Per-series detector input: the baseline state plus configuration thresholds.
#[cfg_attr(feature = "rustler", derive(rustler::NifMap))]
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
    pub confirm_slots: Option<usize>,
    pub consecutive_anomalous: Option<usize>,
}

/// A single observed sample.
#[cfg_attr(feature = "rustler", derive(rustler::NifMap))]
#[derive(Clone, Copy, Debug)]
pub struct ReasonSample {
    pub value: f64,
    pub observed_at_unix_nano: Option<u64>,
}

/// The full per-sample verdict, including the next baseline state to persist.
#[cfg_attr(feature = "rustler", derive(rustler::NifMap))]
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
#[cfg_attr(feature = "rustler", derive(rustler::NifMap))]
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
#[cfg_attr(feature = "rustler", derive(rustler::NifMap))]
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
