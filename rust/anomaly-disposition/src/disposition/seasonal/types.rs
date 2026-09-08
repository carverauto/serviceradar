// Copyright 2026 Carver Automation Corporation.
//
// Licensed under the Apache License, Version 2.0 (the "License").
// SPDX-License-Identifier: Apache-2.0

//! The seasonal kernel data carriers: the public NIF-facing ABI types
//! ([`SeasonalConfig`], [`SeasonalRow`], [`SeasonalDisposition`]) and the internal
//! flow channels ([`SeasonalState`], [`ExcludedBaseline`], [`SeasonalValue`]).

use crate::disposition::{Disposition, RobustStatistic};

/// Read-only seasonal thresholds — the `Context` channel (D4).
///
/// Defaults mirror the detector defaults in `anomaly-core`. With the crate's
/// `rustler` feature on this is a `NifMap`, so the worker passes a plain Elixir
/// map: `%{seasonal_n_sigma: 3.0, min_bucket_samples: 4, confirm_slots: 2,
/// robust_statistic: :median_mad}`.
#[derive(Clone, Copy, Debug, PartialEq)]
#[cfg_attr(feature = "rustler", derive(rustler::NifMap))]
pub struct SeasonalConfig {
    /// Residual z-score breach threshold (sigma) for the deseasonalized residual.
    pub seasonal_n_sigma: f64,
    /// Minimum *effective* bucket samples (after latest-bucket exclusion) before a
    /// verdict can be issued; below this the row resolves to
    /// [`Disposition::InsufficientSeasonalBaseline`].
    pub min_bucket_samples: usize,
    /// Consecutive completed evaluation slots that must breach before the kernel
    /// reports [`Disposition::SeasonalBreach`]. `confirm_slots = N` means the
    /// first `N - 1` breaching slots are [`Disposition::SeasonalDrift`], the Nth
    /// breaching slot confirms, and any clean slot resets the pending count to
    /// zero.
    pub confirm_slots: usize,
    /// Which robust statistic to score the residual against (D6 / task 3.4).
    pub robust_statistic: RobustStatistic,
}

impl Default for SeasonalConfig {
    fn default() -> Self {
        Self {
            seasonal_n_sigma: serviceradar_anomaly_core::DEFAULT_N_SIGMA,
            min_bucket_samples: 4,
            // Default = 2 (D-Q3): one over-threshold hourly bucket is a pending drift;
            // a second consecutive one confirms — light hysteresis against a single
            // noisy bucket. Operators can lower it to 1 or raise it further.
            confirm_slots: 2,
            robust_statistic: RobustStatistic::default(),
        }
    }
}

/// One series-under-test row: the latest complete bucket's value plus the
/// SQL-aggregated summary statistics for its matching `(dow,hod)` bucket.
///
/// This is the per-row input ABI the NIF wraps (`NifMap` with the `rustler`
/// feature). The 168-bucket aggregation already ran in SQL (D6); the kernel
/// receives the *summary* for the one bucket the sample falls into, never raw
/// points.
///
/// # Bucket statistics and the exclusion contract
/// - For [`RobustStatistic::MeanStddev`]: `bucket_count` / `bucket_sum` /
///   `bucket_sum_sq` are the bucket totals **including** `sample_value` (the
///   natural CAGG aggregate). The kernel removes `sample_value` algebraically to
///   form the excluded baseline, so `min_bucket_samples` is checked against
///   `bucket_count - 1`.
/// - For [`RobustStatistic::MedianMad`] / [`RobustStatistic::P05P95`]: the order
///   statistics (`center`, plus `mad` or `p05`/`p95`) MUST already be computed by
///   SQL over the bucket **excluding** the latest sample, and `bucket_count` is the
///   excluded-baseline sample count. `baseline_excludes_latest` records that the
///   caller honored the contract.
#[derive(Clone, Debug, PartialEq)]
#[cfg_attr(feature = "rustler", derive(rustler::NifMap))]
pub struct SeasonalRow {
    /// Stable series identifier (echoed back so the worker can re-key verdicts).
    pub series_key: String,
    /// Day-of-week bucket (0–6) the sample falls in. Carried for diagnostics; the
    /// kernel does not re-derive the bucket (SQL owns bucketing).
    pub dow: u8,
    /// Hour-of-day bucket (0–23) the sample falls in.
    pub hod: u8,
    /// The latest complete bucket's observed value, the thing under test.
    pub sample_value: f64,
    /// Number of samples in the matching `(dow,hod)` bucket. For `MeanStddev` this
    /// INCLUDES `sample_value`; for the robust statistics this is the
    /// excluded-baseline count (see the type-level doc).
    pub bucket_count: usize,
    /// Sum of bucket values INCLUDING `sample_value` (`MeanStddev` only).
    pub bucket_sum: f64,
    /// Sum of squared bucket values INCLUDING `sample_value` (`MeanStddev` only).
    pub bucket_sum_sq: f64,
    /// Robust center (median) over the excluded baseline (`MedianMad`/`P05P95`).
    pub center: f64,
    /// Median absolute deviation over the excluded baseline (`MedianMad`).
    pub mad: f64,
    /// 5th percentile over the excluded baseline (`P05P95`).
    pub p05: f64,
    /// 95th percentile over the excluded baseline (`P05P95`).
    pub p95: f64,
    /// `consecutive_anomalous` carried in from Postgres for confirm-slot hysteresis.
    pub consecutive_anomalous: usize,
    /// Whether the caller computed the robust order statistics over the
    /// latest-bucket-EXCLUDED profile. Always `true` from SQL; surfaced so the
    /// kernel can assert the invariant and refuse to score self-masking inputs.
    pub baseline_excludes_latest: bool,
}

/// One per-row result: the disposition plus the `consecutive_anomalous` to persist.
///
/// `NifMap` with the `rustler` feature, so the worker reads back
/// `%{series_key: ..., disposition: {...}, next_consecutive_anomalous: ...,
/// score: ...}` per row.
#[derive(Clone, Debug, PartialEq)]
#[cfg_attr(feature = "rustler", derive(rustler::NifMap))]
pub struct SeasonalDisposition {
    /// Echoed series identifier.
    pub series_key: String,
    /// The assigned disposition (the Value channel result).
    pub disposition: Disposition,
    /// The `consecutive_anomalous` the worker persists back to Postgres.
    pub next_consecutive_anomalous: usize,
    /// The residual z-score, when computed; `0.0` for non-scored gate variants.
    pub score: f64,
}

/// The `State` channel (D4): the excluded-baseline center/scale and the carried
/// confirm-slot counter.
pub(super) struct SeasonalState {
    pub(super) row: SeasonalRow,
    /// Center/scale already deseasonalized: the bucket baseline with the latest
    /// sample excluded (the invariant). `None` when the gate failed.
    pub(super) baseline: Option<ExcludedBaseline>,
}

/// The deseasonalized baseline the residual is scored against: a (center, scale)
/// pair with the latest complete bucket EXCLUDED, plus the effective sample count.
#[derive(Clone, Copy, Debug, PartialEq)]
pub(super) struct ExcludedBaseline {
    pub(super) center: f64,
    /// Stddev-equivalent scale (already rescaled for robust statistics).
    pub(super) scale: f64,
    /// Effective baseline samples AFTER excluding the latest bucket.
    pub(super) effective_samples: usize,
}

/// Internal Value of the seasonal flow before the verdict is written.
pub(super) enum SeasonalValue {
    /// Pre-evaluation marker.
    Evaluate,
    /// The disposition the flow resolved to.
    Disposed(Disposition),
}
