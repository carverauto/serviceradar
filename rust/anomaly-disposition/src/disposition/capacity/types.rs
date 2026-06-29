// Copyright 2026 Carver Automation Corporation.
//
// Licensed under the Apache License, Version 2.0 (the "License").
// SPDX-License-Identifier: Apache-2.0

//! The capacity disposition channel types (D4): the public ABI carriers
//! ([`CapacityModelKind`], [`CapacityConfig`], [`CapacityPoint`], [`CapacityRow`],
//! [`CapacityDisposition`]) plus the internal flow types ([`NormPoint`],
//! [`CapacityState`], [`CapacityValue`]) and the `normalize_points` port.

use super::{DEFAULT_HORIZON_SECONDS, DEFAULT_MIN_POINTS, DEFAULT_PERIOD, MICROS_PER_SECOND};

/// Which model `model.ex` should run (the `:model` opt, `model.ex:49`). `Auto`
/// routes to seasonal Holt-Winters when [`super::is_seasonal`] detects seasonality,
/// else linear; `Seasonal`/`HoltWinters` force the seasonal path (falling back to
/// linear on insufficient seasonal history); `Linear` forces the linear path.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
#[cfg_attr(feature = "rustler", derive(rustler::NifUnitEnum))]
pub enum CapacityModelKind {
    /// `:auto` — seasonal-strength autodetect (`model.ex:56`).
    #[default]
    Auto,
    /// `:linear` — force the least-squares linear fit (`model.ex:59`).
    Linear,
    /// `:seasonal` / `:holt_winters` — force the additive Holt-Winters path
    /// (`model.ex:53`).
    Seasonal,
}

/// Read-only capacity context (the `Context` channel, D4): the threshold, horizon,
/// model choice, history gate, seasonal period, Holt-Winters smoothing ratios, and
/// optional physical value bounds for bounded signals such as utilization percent.
///
/// With the crate's `rustler` feature on this is a `NifMap`, so the worker passes a
/// plain Elixir map. `capacity_threshold` is `Option<f64>` because `model.ex`
/// treats a missing/non-numeric `:exhaustion_threshold` as "no ETA, scale by range"
/// (`model.ex:77,255,288,360`).
#[derive(Clone, Copy, Debug, PartialEq)]
#[cfg_attr(feature = "rustler", derive(rustler::NifMap))]
pub struct CapacityConfig {
    /// `:exhaustion_threshold` (`model.ex:77`). `None` ⇒ no ETA and the confidence
    /// scale falls back to range/mean (`model.ex:357-363`). The worker resolves the
    /// interface percent threshold before the NIF.
    pub capacity_threshold: Option<f64>,
    /// `:horizon_seconds` (`model.ex:74`). Positive; the worker already validated it.
    pub horizon_seconds: i64,
    /// `:model` (`model.ex:49`).
    pub model_kind: CapacityModelKind,
    /// `:min_points` (`model.ex:44`) — the `insufficient_history` gate
    /// (`model.ex:46`).
    pub min_history: usize,
    /// `:seasonal_period` (`model.ex:50`).
    pub period: usize,
    /// Holt-Winters level smoothing `:alpha` (`model.ex:128`, default 0.35).
    pub alpha: f64,
    /// Holt-Winters trend smoothing `:beta` (`model.ex:129`, default 0.05).
    pub beta: f64,
    /// Holt-Winters season smoothing `:gamma` (`model.ex:130`, default 0.25).
    pub gamma: f64,
    /// Optional lower physical bound for the emitted projection. `None` preserves
    /// the legacy unbounded forecast exactly; percent callers pass `Some(0.0)`.
    pub value_min: Option<f64>,
    /// Optional upper physical bound for the emitted projection. `None` preserves
    /// the legacy unbounded forecast exactly; percent callers pass `Some(100.0)`.
    pub value_max: Option<f64>,
}

impl Default for CapacityConfig {
    fn default() -> Self {
        Self {
            capacity_threshold: None,
            horizon_seconds: DEFAULT_HORIZON_SECONDS,
            model_kind: CapacityModelKind::Auto,
            min_history: DEFAULT_MIN_POINTS,
            period: DEFAULT_PERIOD,
            alpha: 0.35,
            beta: 0.05,
            gamma: 0.25,
            value_min: None,
            value_max: None,
        }
    }
}

/// One aggregate sample (`@type point`, `model.ex:23`): the bucket timestamp as a
/// unix-microsecond epoch plus the value. The kernel sorts/diffs these exactly as
/// `normalize_points` does (`model.ex:217-232`); the worker resolves interface
/// bytes→percent into `value` before the NIF (`worker.ex:488`).
#[derive(Clone, Copy, Debug, PartialEq)]
#[cfg_attr(feature = "rustler", derive(rustler::NifMap))]
pub struct CapacityPoint {
    /// `point.at` as unix microseconds (`DateTime.to_unix(_, :microsecond)`, the sort
    /// key at `model.ex:221`). The kernel derives integer-second offsets from this
    /// exactly as `DateTime.diff(_, _, :second)` does.
    pub at_unix_micros: i64,
    /// `point.value` (coerced to `f64` by `* 1.0` at `model.ex:225`).
    pub value: f64,
}

/// One per-row capacity request: the series key plus the ordered points.
///
/// `NifMap` with the `rustler` feature, so the worker passes
/// `%{series_key: ..., points: [%{at_unix_micros: ..., value: ...}, ...]}`.
#[derive(Clone, Debug, PartialEq)]
#[cfg_attr(feature = "rustler", derive(rustler::NifMap))]
pub struct CapacityRow {
    /// Stable series identifier (echoed back so the worker can re-key the forecast).
    pub series_key: String,
    /// The aggregate samples. May be unordered/duplicated; the kernel normalizes
    /// (sort ascending by `at_unix_micros`) exactly as `model.ex` does.
    pub points: Vec<CapacityPoint>,
}

/// One per-row capacity result: the echoed key plus the [`super::Disposition`]
/// verdict.
///
/// `NifMap` with the `rustler` feature, so the worker reads back
/// `%{series_key: ..., disposition: {...}}` and threads the projected fields into
/// the Ash upsert.
#[derive(Clone, Debug, PartialEq)]
#[cfg_attr(feature = "rustler", derive(rustler::NifMap))]
pub struct CapacityDisposition {
    /// Echoed series identifier.
    pub series_key: String,
    /// The assigned disposition (the Value channel result).
    pub disposition: super::Disposition,
}

/// A normalized point: the integer-second offset from the window start plus the
/// value, mirroring the `{xs, ys}` pair `linear_forecast` builds (`model.ex:69-70`).
#[derive(Clone, Copy, Debug)]
pub(super) struct NormPoint {
    /// `DateTime.diff(at, first_at, :second)` (`model.ex:69`).
    pub(super) offset_seconds: i64,
    /// `at` as unix microseconds (carried so seasonal step-median and ETA can
    /// reconstruct absolute timestamps).
    pub(super) at_unix_micros: i64,
    /// `value * 1.0` (`model.ex:70`).
    pub(super) value: f64,
}

/// The `State` channel (D4): the normalized window plus the config-derived window
/// metadata the flow threads through fit → project → finalize.
pub(super) struct CapacityState {
    pub(super) row: CapacityRow,
    /// Normalized + ascending-sorted points (`normalize_points`, `model.ex:217`).
    /// Empty until [`super::hydrate_window`] populates it.
    pub(super) points: Vec<NormPoint>,
}

/// Internal Value of the capacity flow before the verdict is written.
pub(super) enum CapacityValue {
    /// Pre-evaluation marker.
    Evaluate,
    /// The disposition the flow resolved to.
    Disposed(super::Disposition),
}

impl CapacityState {
    /// Normalize the raw points exactly as `normalize_points` (`model.ex:217-232`):
    /// coerce values to `f64`, drop non-finite/garbage (the `normalize_point/1`
    /// `nil` reject), and **stable**-sort ascending by unix-microsecond timestamp.
    pub(super) fn normalize(&self) -> Vec<NormPoint> {
        let mut pts: Vec<(i64, f64)> = self
            .row
            .points
            .iter()
            // `normalize_point/1` only accepts numeric values; a NaN/Inf is not a
            // valid Elixir number for our purposes (it would never come from a CAGG
            // numeric column), so drop it like the `nil` reject branch.
            .filter(|p| p.value.is_finite())
            .map(|p| (p.at_unix_micros, p.value))
            .collect();
        // `Enum.sort_by(&DateTime.to_unix(&1.at, :microsecond))` — Elixir's sort is
        // STABLE; `sort_by_key` is stable, so ties keep input order identically.
        pts.sort_by_key(|(at, _)| *at);

        let Some((first_at, _)) = pts.first().copied() else {
            return Vec::new();
        };

        pts.into_iter()
            .map(|(at, value)| NormPoint {
                // `DateTime.diff(at, first_at, :second)`: the points are sorted
                // ascending and `first_at` is the minimum, so the difference is
                // always >= 0 and `div_euclid` == truncation == Elixir's floor.
                offset_seconds: (at - first_at).div_euclid(MICROS_PER_SECOND),
                at_unix_micros: at,
                value,
            })
            .collect()
    }
}
