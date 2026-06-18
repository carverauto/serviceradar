// Copyright 2026 Carver Automation Corporation.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

//! Shared per-series anomaly detector core.
//!
//! This crate is the single source of truth for ServiceRadar's per-series
//! anomaly detection: the O(1) Welford rolling accumulator ([`stats`]), the
//! sliding-window helpers ([`window`]), the rolling/seasonal/trend signal
//! evaluation ([`signal`]), and the DeepCausality detector flow ([`detector`]).
//! It is consumed by the edge anomaly add-on (OpenSpec:
//! `move-anomaly-detection-to-edge`) so per-series scoring does not run in
//! core-elx.

pub mod detector;
pub mod signal;
pub mod stats;
pub mod types;
pub mod window;

/// Default z-score breach threshold (sigma).
pub const DEFAULT_N_SIGMA: f64 = 3.0;
/// Default rolling window size (samples).
pub const DEFAULT_WINDOW_SIZE: usize = 300;
/// Default minimum samples before a baseline is considered ready.
pub const DEFAULT_MIN_SAMPLES: usize = 30;
/// Default consecutive breaches required to confirm an anomaly.
pub const DEFAULT_CONFIRM_SLOTS: usize = 5;
/// Capacity multiple for the backing sliding-window storage.
pub const WINDOW_CAPACITY_MULTIPLE: usize = 2;

pub use detector::reason_impl;
pub use stats::{BaselineStats, WelfordAcc, clean_threshold, sample_stats, z_score};
pub use types::{
    ReasonContext, ReasonEventVerdict, ReasonSample, ReasonVerdict, SaturationGate, SignalVerdict,
};
