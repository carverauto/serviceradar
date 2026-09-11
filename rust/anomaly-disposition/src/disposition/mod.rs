// Copyright 2026 Carver Automation Corporation.
//
// Licensed under the Apache License, Version 2.0 (the "License").
// SPDX-License-Identifier: Apache-2.0

//! The disposition Value channel and its configuration carriers.
//!
//! [`Disposition`] is the `Value` channel of every disposition `CausalFlow` (D4):
//! the only thing an intervene arm writes. Its `rustler` feature gate makes it the
//! typed NIF ABI directly (a `NifTaggedEnum`) without forcing a JSON string at the
//! boundary, while keeping the kernel crate rustler-free for bazel/tests.

pub mod capacity;
pub mod peak_profile;
pub mod seasonal;

/// The disposition a kernel assigns to the latest complete bucket under test.
///
/// This is the `Value` channel of the seasonal `CausalFlow` (design D4). It is the
/// *only* channel the intervene/breach arm writes, and it is the typed result the
/// NIF marshals back to the BEAM. Every gate — insufficient baseline, zero
/// variance, non-finite sample — resolves to one of these variants, **never** a
/// panic (graft #1), so a malformed input degrades to a value, not an FFI unwind.
///
/// With the crate's `rustler` feature on, this derives `NifTaggedEnum`, so on the
/// Elixir side a unit variant encodes as e.g. `:suppress` and a payload variant as
/// `{:seasonal_breach, %{score: 4.2}}`. That is the typed ABI the spec mandates in
/// place of a JSON string.
#[derive(Clone, Debug, PartialEq)]
#[cfg_attr(feature = "rustler", derive(rustler::NifTaggedEnum))]
pub enum Disposition {
    /// The bucket is within its seasonal baseline; withhold (no surface). Maps to
    /// the clean arm of the underlying `CausalFlow` branch.
    Suppress,
    /// The deseasonalized residual z cleared `seasonal_n_sigma` for the latest
    /// complete bucket. `score` is the residual z-score.
    SeasonalBreach { score: f64 },
    /// The residual cleared the breach threshold but has not yet met the
    /// confirm-slot hysteresis (carried `consecutive_anomalous`), so it is a
    /// pending drift rather than a confirmed breach. `score` is the residual z.
    SeasonalDrift { score: f64 },
    /// The matching `(dow,hod)` bucket has fewer than `min_bucket_samples`
    /// effective samples (after the latest-bucket exclusion, D6), so no verdict
    /// can be issued. The baseline-sufficiency gate, returned as a value.
    InsufficientSeasonalBaseline,
    /// A guard short-circuited the evaluation (zero-variance / non-finite sample /
    /// missing config / empty bucket / `insufficient_history`). Carries a stable
    /// machine reason string. This is the error channel surfaced as a value
    /// (graft #1) — never a panic.
    Skipped { reason: String },
    /// A successful **capacity** forecast (the `{:ok, forecast}` path of
    /// `CapacityForecasting.Model`, `model.ex:84-104`/`163-195`). Carries every
    /// numeric output field the parity gate compares to within `1e-9` via the boxed
    /// [`CapacityForecast`] payload. The model always yields a `Projected` on a
    /// successful fit; whether it is "at risk" or downgraded to
    /// [`Disposition::Inactive`] is the worker's `at_risk?` policy (`worker.ex:412`),
    /// NOT the kernel's — so the kernel emits a `Projected` even when
    /// `projected_exhaustion_at_unix_micros` is `None` (no exhaustion in horizon).
    ///
    /// The payload is **boxed** so this large variant does not bloat the shared
    /// `Disposition` (the small seasonal gate variants ride the enum by value in a
    /// `Result<_, Disposition>` on the seasonal path). With the `rustler` feature on,
    /// rustler encodes `Box<CapacityForecast>` identically to the inner struct, so
    /// the Elixir ABI is `{:projected, %{model: ..., slope_per_second: ..., ...}}`.
    Projected(Box<CapacityForecast>),
    /// A capacity forecast that is NOT at risk within the warning horizon — the
    /// worker's `at_risk?`-false downgrade (`worker.ex:407`). Included in the Value
    /// channel for ABI completeness (the spec's `Disposition ∈ {Projected, Inactive,
    /// Skipped}`); the **kernel never emits it** because the at-risk decision is
    /// orchestration that stays in Elixir (task 7.4). A `Projected` with
    /// `projected_exhaustion_at_unix_micros = None` is the kernel's "no exhaustion",
    /// which the worker maps onto `Inactive`/`projected` as policy dictates.
    Inactive,
}

/// The numeric payload of a [`Disposition::Projected`] capacity forecast — every
/// field the golden-fixture parity gate (graft #4) compares to `model.ex` within
/// `1e-9`. Boxed inside the enum to keep `Disposition` small.
///
/// With the crate's `rustler` feature on this is a `NifMap`, so on the Elixir side
/// the worker reads `{:projected, %{model: ..., current_value: ..., ...}}` and
/// threads the fields into the Ash `CapacityForecast` upsert. Timestamps are unix
/// **microseconds** so the worker rebuilds the `DateTime` preserving the window
/// start's sub-second component (`DateTime.add(first_at, round(cross_x), :second)`
/// keeps `first_at`'s micros, `model.ex:273`).
#[derive(Clone, Debug, PartialEq)]
#[cfg_attr(feature = "rustler", derive(rustler::NifMap))]
pub struct CapacityForecast {
    /// `"linear"` or `"holt_winters_additive"` (`model.ex:86,165`).
    pub model: String,
    /// `current_value` (`model.ex:87` / `158`): the last sample's value.
    pub current_value: f64,
    /// `slope_per_second` (`model.ex:88` / `159`).
    pub slope_per_second: f64,
    /// `intercept` (`model.ex:89`); for Holt-Winters this is the final `level`
    /// (`model.ex:168`).
    pub intercept: f64,
    /// `projected_value` at `last_x + horizon` (`model.ex:90` / `157`).
    pub projected_value: f64,
    /// The unconstrained model projection before optional physical value bounds are
    /// applied. For unbounded configs this is identical to `projected_value`; for
    /// percent/capacity-bounded configs it preserves the regression output for
    /// diagnostics while `projected_value` remains an operator-facing physical value.
    pub raw_projected_value: f64,
    /// Whether `projected_value`, `lower_bound`, or `upper_bound` were clamped to
    /// the configured physical value bounds.
    pub projection_bounded: bool,
    /// `projected_exhaustion_at` as unix microseconds (`model.ex:91` / `170`), or
    /// `None` for the no-ETA cases (non-positive slope, missing threshold,
    /// already-crossed, beyond-`10×`-horizon, or beyond the history-relative
    /// extrapolation cap).
    pub projected_exhaustion_at_unix_micros: Option<i64>,
    /// The projected crossing before the history-relative extrapolation cap is
    /// applied: `Some` whenever the fitted trend crosses the threshold after the
    /// last sample and inside the `10×`-horizon noise cap, even when
    /// [`Self::projected_exhaustion_at_unix_micros`] is `None`. Lets the worker
    /// report *when* a capped series would cross instead of "no exhaustion".
    pub raw_projected_exhaustion_at_unix_micros: Option<i64>,
    /// `true` when the ETA was withheld ONLY because the crossing lies beyond the
    /// history-relative extrapolation cap (twice the observed span). Never `true`
    /// for a series with no crossing or one beyond the noise cap.
    pub exhaustion_history_capped: bool,
    /// The extrapolation cap the ETA was checked against, in seconds past the last
    /// sample: `min(2 × observed span, 10 × horizon)`. Surfaced so the worker's
    /// diagnostics carry the kernel's number rather than re-deriving it.
    pub exhaustion_extrapolation_cap_seconds: i64,
    /// The emitted prediction interval's nominal coverage level (`0.95`). Surfaced in
    /// this field for ABI stability, but it is the INTERVAL's coverage level — NOT a
    /// fit-quality probability. The old `clamp(1 - rmse/scale)` heuristic was an
    /// overclaim and was removed (D2).
    pub confidence: f64,
    /// Lower bound of the 95% prediction interval — closed-form OLS for the linear
    /// path, residual-bootstrap for Holt-Winters, clamped to any physical value
    /// bounds. Widens with the horizon (not the old constant `projected - 1.96·RMSE`).
    pub lower_bound: f64,
    /// Upper bound of the 95% prediction interval (see [`Self::lower_bound`]).
    pub upper_bound: f64,
    /// `diagnostics["rmse"]` (`model.ex:100` / `189`) — surfaced so the worker can
    /// rebuild the diagnostics map and the parity test compares it directly.
    pub rmse: f64,
    /// `sample_count` (`model.ex:96` / `185`).
    pub sample_count: usize,
    /// `window_started_at` as unix microseconds (`model.ex:97` / `186`).
    pub window_started_at_unix_micros: i64,
    /// `window_ended_at` as unix microseconds (`model.ex:98` / `187`).
    pub window_ended_at_unix_micros: i64,
}

impl Disposition {
    /// Whether this disposition should surface upstream as an anomaly verdict.
    /// `Suppress` / `InsufficientSeasonalBaseline` / `Skipped` are withheld; only a
    /// confirmed `SeasonalBreach` surfaces. `SeasonalDrift` is pending and does not
    /// surface until confirmed (the worker carries `consecutive_anomalous`).
    pub fn surfaces(&self) -> bool {
        matches!(self, Disposition::SeasonalBreach { .. })
    }

    /// The residual z-score, when one was computed (`SeasonalBreach`/`SeasonalDrift`).
    pub fn score(&self) -> Option<f64> {
        match self {
            Disposition::SeasonalBreach { score } | Disposition::SeasonalDrift { score } => {
                Some(*score)
            }
            _ => None,
        }
    }
}

/// Robust-statistic selection for the seasonal residual (D6 / task 3.4).
///
/// `MeanStddev` is the default and consumes the per-bucket mean/stddev SQL already
/// aggregates. `MedianMad` and `P05P95` consume the per-bucket **order statistics**
/// SQL computes (`percentile_cont` / MAD via `percentile_disc` of abs-deviation),
/// keeping the boundary small: the kernel never sees raw points, only the per-bucket
/// summary statistics for the chosen estimator.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
#[cfg_attr(feature = "rustler", derive(rustler::NifUnitEnum))]
pub enum RobustStatistic {
    /// Mean / stddev z-score (default). Center = mean, scale = stddev.
    #[default]
    MeanStddev,
    /// Median / MAD (median absolute deviation). Center = median, scale = MAD
    /// rescaled to a stddev-equivalent by 1.4826 (the normal-consistency constant).
    MedianMad,
    /// p05–p95 inter-percentile band. Center = median, scale = (p95 − p05) mapped
    /// to a stddev-equivalent by the 90%-coverage normal constant (≈3.2897).
    P05P95,
}

/// 1.4826: rescales MAD to a stddev-equivalent under normality so the same
/// `n_sigma` threshold applies across robust statistics. `1 / Φ⁻¹(0.75)`.
pub(crate) const MAD_TO_STDDEV: f64 = 1.482_602_218_505_602;

/// ≈0.3040: maps a p05–p95 (90%-coverage) inter-percentile range to a
/// stddev-equivalent under normality. Under normality `p95 − p05 = (Φ⁻¹(0.95) −
/// Φ⁻¹(0.05))·σ = 2·1.644853·σ ≈ 3.2897·σ`, so the stddev-equivalent scale is the
/// band width *divided* by `3.2897`, i.e. multiplied by `1 / 3.2897 ≈ 0.30397`.
/// (The MAD constant above is a true multiplier — `MAD·1.4826 = σ` — but the
/// inter-percentile band must be *narrowed* to a single σ, so this constant is the
/// reciprocal, not `3.2897`. Using `3.2897` here would inflate the scale ~10.8× and
/// silently suppress every robust-band breach.)
pub(crate) const P05P95_TO_STDDEV: f64 = 0.303_975_897_309_837;
