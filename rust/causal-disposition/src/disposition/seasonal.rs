// Copyright 2026 Carver Automation Corporation.
//
// Licensed under the Apache License, Version 2.0 (the "License").
// SPDX-License-Identifier: Apache-2.0

//! The seasonal disposition kernel: deseasonalized residual-z over the historical
//! hour-of-week profile, on the shared `anomaly-core` `CausalFlow` substrate.
//!
//! # Channel mapping (design D4)
//! - **Value** = [`Disposition`] — the only channel the intervene arm writes.
//! - **State** = [`SeasonalState`] — the `(dow,hod)` bucket accumulators with the
//!   **latest bucket excluded** (the bucket-exclusion invariant, D6), plus the
//!   `consecutive_anomalous` carried in from Postgres.
//! - **Context** = [`SeasonalConfig`] — `{seasonal_n_sigma, min_bucket_samples,
//!   confirm_slots, robust_statistic}`, read-only.
//!
//! The 168-bucket hour-of-week profile aggregation STAYS in SQL (data gravity, D6);
//! this kernel receives one [`SeasonalRow`] per series-under-test carrying the
//! pre-aggregated bucket summary statistics, and moves only the residual-z, breach,
//! baseline-sufficiency gate, and robust-statistic selection.
//!
//! # The bucket-exclusion invariant (D6, graft #2)
//! Because the seasonal baseline is the historical hour-of-week profile (NOT a
//! self-masking sliding window like the rolling detector), the withhold-from-
//! baseline trick does not apply automatically. **The latest complete bucket under
//! test MUST be excluded from the mean/stddev it is scored against** — otherwise a
//! real drift inflates its own baseline and hides. For the mean/stddev statistic
//! this kernel performs the exclusion *algebraically* from the SQL-supplied bucket
//! sums (see [`SeasonalState::excluded_baseline`]). For the robust statistics
//! (median/MAD, p05–p95) the order statistics cannot be de-aggregated by one point,
//! so SQL supplies them already computed over the excluded historical profile; the
//! kernel trusts that contract and asserts it via [`SeasonalRow::baseline_excludes_latest`].

use crate::disposition::{Disposition, MAD_TO_STDDEV, P05P95_TO_STDDEV, RobustStatistic};
use deep_causality_core::{CausalFlow, CausalityError, CausalityErrorEnum};

/// Read-only seasonal thresholds — the `Context` channel (D4).
///
/// Defaults mirror the detector defaults in `anomaly-core`. With the crate's
/// `rustler` feature on this is a `NifMap`, so the worker passes a plain Elixir
/// map: `%{seasonal_n_sigma: 3.0, min_bucket_samples: 4, confirm_slots: 1,
/// robust_statistic: :mean_stddev}`.
#[derive(Clone, Copy, Debug, PartialEq)]
#[cfg_attr(feature = "rustler", derive(rustler::NifMap))]
pub struct SeasonalConfig {
    /// Residual z-score breach threshold (sigma) for the deseasonalized residual.
    pub seasonal_n_sigma: f64,
    /// Minimum *effective* bucket samples (after latest-bucket exclusion) before a
    /// verdict can be issued; below this the row resolves to
    /// [`Disposition::InsufficientSeasonalBaseline`].
    pub min_bucket_samples: usize,
    /// Consecutive anomalous slots required to confirm a breach. With the carried
    /// `consecutive_anomalous`, a residual over threshold reads as
    /// [`Disposition::SeasonalDrift`] until it reaches `confirm_slots`, then
    /// [`Disposition::SeasonalBreach`].
    pub confirm_slots: usize,
    /// Which robust statistic to score the residual against (D6 / task 3.4).
    pub robust_statistic: RobustStatistic,
}

impl Default for SeasonalConfig {
    fn default() -> Self {
        Self {
            seasonal_n_sigma: serviceradar_anomaly_core::DEFAULT_N_SIGMA,
            min_bucket_samples: 4,
            confirm_slots: 1,
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
struct SeasonalState {
    row: SeasonalRow,
    /// Center/scale already deseasonalized: the bucket baseline with the latest
    /// sample excluded (the invariant). `None` when the gate failed.
    baseline: Option<ExcludedBaseline>,
}

/// The deseasonalized baseline the residual is scored against: a (center, scale)
/// pair with the latest complete bucket EXCLUDED, plus the effective sample count.
#[derive(Clone, Copy, Debug, PartialEq)]
struct ExcludedBaseline {
    center: f64,
    /// Stddev-equivalent scale (already rescaled for robust statistics).
    scale: f64,
    /// Effective baseline samples AFTER excluding the latest bucket.
    effective_samples: usize,
}

/// Internal Value of the seasonal flow before the verdict is written.
enum SeasonalValue {
    /// Pre-evaluation marker.
    Evaluate,
    /// The disposition the flow resolved to.
    Disposed(Disposition),
}

impl SeasonalState {
    /// Build the excluded baseline per the configured robust statistic. Returns
    /// `None` (a gate, never a panic) on non-finite inputs, an empty/too-thin
    /// bucket, a contract violation (robust stats not excluded), or zero variance
    /// — the caller maps `None` to the appropriate [`Disposition`] gate variant.
    fn excluded_baseline(&self, config: &SeasonalConfig) -> Result<ExcludedBaseline, Disposition> {
        let row = &self.row;
        if !row.sample_value.is_finite() {
            return Err(Disposition::Skipped {
                reason: "sample value is non-finite".to_string(),
            });
        }

        match config.robust_statistic {
            RobustStatistic::MeanStddev => self.mean_stddev_baseline(config),
            RobustStatistic::MedianMad | RobustStatistic::P05P95 => self.robust_baseline(config),
        }
    }

    /// Algebraically remove the latest sample from the SQL-supplied bucket sums to
    /// form the excluded mean/stddev baseline (the bucket-exclusion invariant for
    /// the mean/stddev statistic — performed inside the kernel so the unit test can
    /// prove it).
    fn mean_stddev_baseline(
        &self,
        config: &SeasonalConfig,
    ) -> Result<ExcludedBaseline, Disposition> {
        let row = &self.row;
        // The bucket totals INCLUDE the sample under test; the excluded baseline is
        // the remaining (bucket_count - 1) samples.
        let effective_samples = row.bucket_count.saturating_sub(1);
        if effective_samples < config.min_bucket_samples || effective_samples < 2 {
            return Err(Disposition::InsufficientSeasonalBaseline);
        }
        if !row.bucket_sum.is_finite() || !row.bucket_sum_sq.is_finite() {
            return Err(Disposition::Skipped {
                reason: "bucket sums are non-finite".to_string(),
            });
        }

        let n = effective_samples as f64;
        // Exclude the latest sample: subtract it from the sums (the invariant).
        let excl_sum = row.bucket_sum - row.sample_value;
        let excl_sum_sq = row.bucket_sum_sq - row.sample_value * row.sample_value;
        let center = excl_sum / n;
        // Sample variance over the excluded baseline (Bessel-corrected, n-1).
        let variance = (excl_sum_sq - excl_sum * center) / (n - 1.0);
        if !center.is_finite() || !variance.is_finite() {
            return Err(Disposition::Skipped {
                reason: "excluded baseline statistics are non-finite".to_string(),
            });
        }
        // Guard catastrophic-cancellation negatives from the one-pass form.
        let scale = variance.max(0.0).sqrt();
        if scale <= f64::EPSILON {
            return Err(Disposition::Skipped {
                reason: "zero-variance seasonal bucket".to_string(),
            });
        }

        Ok(ExcludedBaseline {
            center,
            scale,
            effective_samples,
        })
    }

    /// Use the SQL-supplied robust order statistics. SQL MUST have computed them
    /// over the latest-bucket-excluded profile; the kernel asserts that contract
    /// (refusing self-masking inputs) and rescales the robust scale to a
    /// stddev-equivalent so the same `seasonal_n_sigma` applies.
    fn robust_baseline(&self, config: &SeasonalConfig) -> Result<ExcludedBaseline, Disposition> {
        let row = &self.row;
        if !row.baseline_excludes_latest {
            // The bucket-exclusion invariant: order statistics cannot be
            // de-aggregated by one point, so SQL must exclude the latest sample. A
            // caller that did not is rejected as a gate, never scored.
            return Err(Disposition::Skipped {
                reason: "robust baseline did not exclude the latest bucket".to_string(),
            });
        }
        // For the robust path `bucket_count` is already the excluded-baseline count.
        let effective_samples = row.bucket_count;
        if effective_samples < config.min_bucket_samples || effective_samples < 2 {
            return Err(Disposition::InsufficientSeasonalBaseline);
        }

        let (center, raw_scale) = match config.robust_statistic {
            RobustStatistic::MedianMad => (row.center, row.mad * MAD_TO_STDDEV),
            RobustStatistic::P05P95 => (row.center, (row.p95 - row.p05) * P05P95_TO_STDDEV),
            // mean/stddev never routes here.
            RobustStatistic::MeanStddev => (row.center, 0.0),
        };
        if !center.is_finite() || !raw_scale.is_finite() {
            return Err(Disposition::Skipped {
                reason: "robust baseline statistics are non-finite".to_string(),
            });
        }
        if raw_scale <= f64::EPSILON {
            return Err(Disposition::Skipped {
                reason: "zero-dispersion seasonal bucket".to_string(),
            });
        }

        Ok(ExcludedBaseline {
            center,
            scale: raw_scale,
            effective_samples,
        })
    }
}

/// Score one seasonal row. The public seam the NIF's per-row loop calls. Always
/// returns a [`SeasonalDisposition`]; gates resolve to a [`Disposition`] variant,
/// never a panic (graft #1).
pub fn dispose_seasonal(row: SeasonalRow, config: &SeasonalConfig) -> SeasonalDisposition {
    let series_key = row.series_key.clone();

    let (disposition, next_consecutive_anomalous, score) =
        match run_seasonal_flow(row, config) {
            Ok(outcome) => outcome,
            // The flow itself never returns Err in practice (every gate is a Value),
            // but the monadic `finish()` is fallible — degrade to a Skipped value.
            Err(err) => (
                Disposition::Skipped {
                    reason: format!("seasonal flow error: {err}"),
                },
                0,
                0.0,
            ),
        };

    SeasonalDisposition {
        series_key,
        disposition,
        next_consecutive_anomalous,
        score,
    }
}

/// Drive the seasonal `CausalFlow`: process state, hydrate the excluded baseline
/// into Context, branch breach/clean, finalize the verdict. Mirrors the
/// `reason_impl` chain in `anomaly-core` (`detector.rs:84-114`).
fn run_seasonal_flow(
    row: SeasonalRow,
    config: &SeasonalConfig,
) -> Result<(Disposition, usize, f64), String> {
    let carried = row.consecutive_anomalous;
    let state = SeasonalState {
        row,
        baseline: None,
    };

    let value = CausalFlow::process(state)
        .context(*config)
        .map(|()| SeasonalValue::Evaluate)
        .update_value_state_context(hydrate_baseline)
        .branch_with(
            |value, _state, _context| {
                // The breach arm: a residual that cleared the threshold.
                matches!(value, SeasonalValue::Disposed(d) if d.surfaces_or_pending())
            },
            |breach| breach,
            |clean| clean,
        )
        .update_value_state_context(finalize_seasonal_verdict)
        .finish()
        .map_err(|err| err.to_string())?;

    let disposition = match value {
        SeasonalValue::Disposed(d) => d,
        SeasonalValue::Evaluate => {
            return Err(CausalityError::new(CausalityErrorEnum::ValueNotAvailable).to_string());
        }
    };

    // Confirm-slot hysteresis: a residual over threshold increments the carried
    // counter; a clean row resets it.
    let next_consecutive_anomalous = match &disposition {
        Disposition::SeasonalBreach { .. } | Disposition::SeasonalDrift { .. } => {
            carried.saturating_add(1)
        }
        Disposition::Suppress => 0,
        // Gate variants neither confirm nor reset; preserve the carried counter so a
        // transient thin/skip cycle does not erase confirmation progress.
        Disposition::InsufficientSeasonalBaseline | Disposition::Skipped { .. } => carried,
    };

    let score = disposition.score().unwrap_or(0.0);
    Ok((disposition, next_consecutive_anomalous, score))
}

impl Disposition {
    /// Whether this disposition took the breach arm of the flow (a confirmed breach
    /// OR a pending drift — both cleared the residual threshold).
    fn surfaces_or_pending(&self) -> bool {
        matches!(
            self,
            Disposition::SeasonalBreach { .. } | Disposition::SeasonalDrift { .. }
        )
    }
}

/// Stage 1 of the flow: build the excluded baseline and pre-classify the residual
/// into a [`Disposition`]. Mirrors `evaluate_detector_command` (`detector.rs:203`).
fn hydrate_baseline(
    _value: SeasonalValue,
    mut state: SeasonalState,
    context: Option<SeasonalConfig>,
) -> (SeasonalValue, SeasonalState, Option<SeasonalConfig>) {
    let Some(config) = context.as_ref() else {
        return (
            SeasonalValue::Disposed(Disposition::Skipped {
                reason: "seasonal config missing".to_string(),
            }),
            state,
            context,
        );
    };

    match state.excluded_baseline(config) {
        Ok(baseline) => {
            state.baseline = Some(baseline);
            let score = residual_z(state.row.sample_value, baseline);
            let disposition = if !score.is_finite() {
                Disposition::Skipped {
                    reason: "residual z is non-finite".to_string(),
                }
            } else if score >= config.seasonal_n_sigma {
                // Confirm-slot decision is finalized in stage 2 against the
                // carried counter; here we only mark "over threshold".
                Disposition::SeasonalDrift { score }
            } else {
                Disposition::Suppress
            };
            (SeasonalValue::Disposed(disposition), state, context)
        }
        // Every gate is a value, never an unwind (graft #1).
        Err(gate) => (SeasonalValue::Disposed(gate), state, context),
    }
}

/// Stage 2 of the flow: apply confirm-slot hysteresis to promote a pending drift to
/// a confirmed breach. Mirrors `finalize_detector_verdict` (`detector.rs:281`).
fn finalize_seasonal_verdict(
    value: SeasonalValue,
    state: SeasonalState,
    context: Option<SeasonalConfig>,
) -> (SeasonalValue, SeasonalState, Option<SeasonalConfig>) {
    let SeasonalValue::Disposed(disposition) = value else {
        return (value, state, context);
    };
    let Some(config) = context.as_ref() else {
        return (SeasonalValue::Disposed(disposition), state, context);
    };

    let promoted = match disposition {
        Disposition::SeasonalDrift { score } => {
            // The carried counter plus this slot. confirm_slots == 1 means a single
            // over-threshold bucket confirms immediately.
            let confirmed_slots = state.row.consecutive_anomalous.saturating_add(1);
            if confirmed_slots >= config.confirm_slots.max(1) {
                Disposition::SeasonalBreach { score }
            } else {
                Disposition::SeasonalDrift { score }
            }
        }
        other => other,
    };

    (SeasonalValue::Disposed(promoted), state, context)
}

/// Deseasonalized residual z: `|v - center| / scale` against the excluded
/// baseline. The center/scale are already deseasonalized (the seasonal profile)
/// and exclude the latest bucket (the invariant), so this is a residual z over the
/// historical hour-of-week baseline, not a raw z.
fn residual_z(sample_value: f64, baseline: ExcludedBaseline) -> f64 {
    if baseline.scale <= f64::EPSILON {
        return f64::INFINITY;
    }
    ((sample_value - baseline.center) / baseline.scale).abs()
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Build a mean/stddev row from explicit baseline points (the historical
    /// hour-of-week profile, EXCLUDING the sample under test) plus the sample. The
    /// SQL aggregate would include the sample, so we add it back into the sums here
    /// — exactly the shape the kernel de-aggregates.
    fn mean_stddev_row(
        baseline_points: &[f64],
        sample_value: f64,
        consecutive_anomalous: usize,
    ) -> SeasonalRow {
        let mut sum = sample_value;
        let mut sum_sq = sample_value * sample_value;
        for &p in baseline_points {
            sum += p;
            sum_sq += p * p;
        }
        SeasonalRow {
            series_key: "svc/cpu".to_string(),
            dow: 2,
            hod: 9,
            sample_value,
            // bucket_count INCLUDES the sample (the natural CAGG aggregate).
            bucket_count: baseline_points.len() + 1,
            bucket_sum: sum,
            bucket_sum_sq: sum_sq,
            center: 0.0,
            mad: 0.0,
            p05: 0.0,
            p95: 0.0,
            consecutive_anomalous,
            baseline_excludes_latest: true,
        }
    }

    fn config() -> SeasonalConfig {
        SeasonalConfig {
            seasonal_n_sigma: 3.0,
            min_bucket_samples: 4,
            confirm_slots: 1,
            robust_statistic: RobustStatistic::MeanStddev,
        }
    }

    #[test]
    fn busy_tuesday_ramp_does_not_breach() {
        // The Tuesday-9am bucket historically sits high (a busy ramp): values
        // around 800 with normal jitter. A fresh Tuesday-9am sample at 805 is
        // typical for the hour-of-week and its deseasonalized residual ~0 — it must
        // NOT breach, even though 805 is huge in absolute terms.
        let baseline: Vec<f64> = (0..20).map(|i| 800.0 + (i % 5) as f64 * 2.0).collect();
        let out = dispose_seasonal(mean_stddev_row(&baseline, 805.0, 0), &config());
        assert_eq!(
            out.disposition,
            Disposition::Suppress,
            "a typical busy-Tuesday value must be suppressed (residual ~0), got {:?} score {}",
            out.disposition,
            out.score
        );
    }

    #[test]
    fn sunday_3am_at_tuesday_9am_levels_breaches() {
        // The Sunday-3am bucket historically sits low (idle): ~5 with small jitter.
        // A Sunday-3am sample at Tuesday-9am levels (800) is wildly off ITS OWN
        // hour-of-week baseline and MUST breach, even though 800 is normal for a
        // different bucket. This is the whole point of deseasonalizing.
        let baseline: Vec<f64> = (0..20).map(|i| 5.0 + (i % 3) as f64 * 0.5).collect();
        let mut row = mean_stddev_row(&baseline, 800.0, 0);
        row.dow = 0; // Sunday
        row.hod = 3; // 3am
        let out = dispose_seasonal(row, &config());
        assert_eq!(
            out.disposition,
            Disposition::SeasonalBreach { score: out.score },
            "an off-season value must breach, got {:?}",
            out.disposition
        );
        assert!(out.score >= 3.0, "residual z {} must clear sigma", out.score);
        assert_eq!(out.next_consecutive_anomalous, 1);
    }

    #[test]
    fn thin_bucket_is_insufficient_seasonal_baseline() {
        // Only 3 historical points → effective baseline after exclusion = 3, below
        // min_bucket_samples=4. No verdict can be issued.
        let baseline = vec![10.0, 11.0, 9.0];
        let out = dispose_seasonal(mean_stddev_row(&baseline, 50.0, 0), &config());
        assert_eq!(
            out.disposition,
            Disposition::InsufficientSeasonalBaseline,
            "a thin bucket must gate to InsufficientSeasonalBaseline, got {:?}",
            out.disposition
        );
        assert_eq!(out.score, 0.0);
    }

    /// The bucket-exclusion invariant (D6, graft #2): the latest complete bucket
    /// MUST be excluded from the mean/stddev it is scored against, or a real drift
    /// inflates its own baseline and hides. We prove it by constructing a baseline
    /// whose self-inclusion would suppress a genuine drift, and asserting exclusion
    /// still breaches.
    #[test]
    fn bucket_exclusion_invariant_holds() {
        // Historical Tuesday-9am baseline: very tight around 100 (stddev ~1).
        let baseline: Vec<f64> = (0..30).map(|i| 100.0 + (i % 3) as f64 * 0.5).collect();
        // A genuine drift to 130 — ~30 sigma off the historical baseline.
        let drift_sample = 130.0;

        // EXCLUDED (correct): scored against the historical baseline only → breaches.
        let excluded = dispose_seasonal(mean_stddev_row(&baseline, drift_sample, 0), &config());
        assert!(
            matches!(excluded.disposition, Disposition::SeasonalBreach { .. }),
            "with the latest bucket excluded a genuine drift must breach, got {:?}",
            excluded.disposition
        );

        // INCLUDED (the bug we forbid): fold the drift sample INTO the baseline and
        // score it against that self-masked profile. We synthesize the included
        // baseline directly to demonstrate the hazard the invariant prevents.
        let mut included_points = baseline.clone();
        included_points.push(drift_sample);
        let included_stats = naive_mean_stddev(&included_points);
        let self_masked_z = (drift_sample - included_stats.0).abs() / included_stats.1;
        let excluded_stats = naive_mean_stddev(&baseline);
        let excluded_z = (drift_sample - excluded_stats.0).abs() / excluded_stats.1;
        assert!(
            self_masked_z < excluded_z,
            "premise: self-inclusion deflates the z ({self_masked_z} < {excluded_z}) — \
             scoring against the self-masked baseline hides the drift, which the \
             exclusion invariant prevents"
        );
        // The kernel's excluded score must equal the correctly-excluded z, not the
        // deflated self-masked one.
        assert!(
            (excluded.score - excluded_z).abs() < 1e-9,
            "kernel score {} must match the latest-bucket-EXCLUDED z {excluded_z}, \
             not the self-masked {self_masked_z}",
            excluded.score
        );
    }

    #[test]
    fn non_finite_sample_is_skipped_not_panicked() {
        let out = dispose_seasonal(mean_stddev_row(&[1.0, 2.0, 3.0, 4.0, 5.0], f64::NAN, 0), &config());
        assert!(
            matches!(out.disposition, Disposition::Skipped { .. }),
            "a non-finite sample must Skip, never panic, got {:?}",
            out.disposition
        );
    }

    #[test]
    fn zero_variance_bucket_is_skipped() {
        // A perfectly flat historical baseline (all 50.0): zero variance. The kernel
        // must gate to Skipped, never divide-by-zero or panic.
        let out = dispose_seasonal(mean_stddev_row(&[50.0; 10], 55.0, 0), &config());
        assert!(
            matches!(out.disposition, Disposition::Skipped { .. }),
            "a zero-variance bucket must Skip, got {:?}",
            out.disposition
        );
    }

    #[test]
    fn drift_pending_until_confirm_slots_met() {
        // confirm_slots = 3: a single over-threshold bucket with no carried history
        // is a pending SeasonalDrift, not yet a confirmed breach.
        let cfg = SeasonalConfig {
            confirm_slots: 3,
            ..config()
        };
        let baseline: Vec<f64> = (0..20).map(|i| 5.0 + (i % 3) as f64 * 0.5).collect();
        let first = dispose_seasonal(mean_stddev_row(&baseline, 800.0, 0), &cfg);
        assert!(
            matches!(first.disposition, Disposition::SeasonalDrift { .. }),
            "first over-threshold slot must be pending drift, got {:?}",
            first.disposition
        );
        assert_eq!(first.next_consecutive_anomalous, 1);

        // With 2 carried slots this is the 3rd → confirmed breach.
        let third = dispose_seasonal(mean_stddev_row(&baseline, 800.0, 2), &cfg);
        assert!(
            matches!(third.disposition, Disposition::SeasonalBreach { .. }),
            "the confirm_slots-th over-threshold slot must confirm, got {:?}",
            third.disposition
        );
        assert_eq!(third.next_consecutive_anomalous, 3);
    }

    #[test]
    fn median_mad_robust_path_breaches_off_season() {
        // Robust path: SQL supplies excluded order statistics directly.
        let row = SeasonalRow {
            series_key: "svc/lat".to_string(),
            dow: 0,
            hod: 3,
            sample_value: 800.0,
            bucket_count: 20, // excluded-baseline count for the robust path
            bucket_sum: 0.0,
            bucket_sum_sq: 0.0,
            center: 5.0,
            mad: 0.5,
            p05: 0.0,
            p95: 0.0,
            consecutive_anomalous: 0,
            baseline_excludes_latest: true,
        };
        let cfg = SeasonalConfig {
            robust_statistic: RobustStatistic::MedianMad,
            ..config()
        };
        let out = dispose_seasonal(row, &cfg);
        assert!(
            matches!(out.disposition, Disposition::SeasonalBreach { .. }),
            "median/MAD off-season value must breach, got {:?}",
            out.disposition
        );
    }

    #[test]
    fn p05_p95_band_is_narrowed_to_one_sigma_not_inflated() {
        // The p05-p95 band must be NARROWED to a stddev-equivalent (band / 3.2897 ≈
        // band * 0.304), not widened (the inflate-by-10.8x bug). This test is chosen
        // to DISCRIMINATE the two: a tight band of width 1.0 → correct scale ≈ 0.304,
        // buggy scale ≈ 3.29. A residual of 3.0 then gives z ≈ 9.9 (breach) under the
        // correct scale but z ≈ 0.91 (suppress) under the inflated one.
        let base = SeasonalRow {
            series_key: "svc/lat".to_string(),
            dow: 0,
            hod: 3,
            sample_value: 0.0,
            bucket_count: 20, // excluded-baseline count for the robust path
            bucket_sum: 0.0,
            bucket_sum_sq: 0.0,
            center: 5.0,
            mad: 0.0,
            // Historical band: p05..p95 spans 1.0 around the median 5.0, so the
            // stddev-equivalent scale ≈ 1.0/3.2897 ≈ 0.304.
            p05: 4.5,
            p95: 5.5,
            consecutive_anomalous: 0,
            baseline_excludes_latest: true,
        };
        let cfg = SeasonalConfig {
            robust_statistic: RobustStatistic::P05P95,
            ..config()
        };

        // residual = 8.0 - 5.0 = 3.0. Correct scale 0.304 → z ≈ 9.87 (breach);
        // inflated scale 3.29 → z ≈ 0.91 (would suppress — catches the bug).
        let breach = dispose_seasonal(
            SeasonalRow {
                sample_value: 8.0,
                ..base.clone()
            },
            &cfg,
        );
        assert!(
            matches!(breach.disposition, Disposition::SeasonalBreach { .. }),
            "a residual of 3.0 against a band-width-1.0 profile must breach (band must be \
             narrowed to ~0.304σ, not inflated to ~3.29σ), got {:?} score {}",
            breach.disposition,
            breach.score
        );
        assert!(
            breach.score >= 9.0,
            "residual z must reflect the narrowed scale (~9.9), got {}",
            breach.score
        );

        // An in-band sample (5.2, residual 0.2 → z ≈ 0.66) must suppress.
        let in_band = dispose_seasonal(
            SeasonalRow {
                sample_value: 5.2,
                ..base
            },
            &cfg,
        );
        assert_eq!(
            in_band.disposition,
            Disposition::Suppress,
            "an in-band p05-p95 value must suppress, got {:?}",
            in_band.disposition
        );
    }

    #[test]
    fn robust_path_rejects_non_excluded_baseline() {
        // If SQL did NOT exclude the latest bucket, the robust path cannot honor the
        // invariant (order stats can't be de-aggregated) and must Skip, not score.
        let row = SeasonalRow {
            series_key: "svc/lat".to_string(),
            dow: 0,
            hod: 3,
            sample_value: 800.0,
            bucket_count: 20,
            bucket_sum: 0.0,
            bucket_sum_sq: 0.0,
            center: 5.0,
            mad: 0.5,
            p05: 0.0,
            p95: 0.0,
            consecutive_anomalous: 0,
            baseline_excludes_latest: false, // contract violated
        };
        let cfg = SeasonalConfig {
            robust_statistic: RobustStatistic::MedianMad,
            ..config()
        };
        let out = dispose_seasonal(row, &cfg);
        assert!(
            matches!(out.disposition, Disposition::Skipped { .. }),
            "a non-excluded robust baseline must Skip, got {:?}",
            out.disposition
        );
    }

    /// Naive two-pass mean/stddev for the invariant test's premise assertions.
    fn naive_mean_stddev(values: &[f64]) -> (f64, f64) {
        let n = values.len() as f64;
        let mean = values.iter().sum::<f64>() / n;
        let var = values.iter().map(|v| (v - mean).powi(2)).sum::<f64>() / (n - 1.0);
        (mean, var.sqrt())
    }
}
