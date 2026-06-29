// Copyright 2026 Carver Automation Corporation.
//
// Licensed under the Apache License, Version 2.0 (the "License").
// SPDX-License-Identifier: Apache-2.0

//! The bucket-exclusion + robust-statistic logic: building the excluded baseline
//! (center, scale) the residual is scored against. This is where the
//! bucket-exclusion invariant (D6, graft #2) is enforced inside the kernel.

use crate::disposition::{Disposition, MAD_TO_STDDEV, P05P95_TO_STDDEV, RobustStatistic};

use super::types::{ExcludedBaseline, SeasonalConfig, SeasonalState};

impl SeasonalState {
    /// Build the excluded baseline per the configured robust statistic. Returns
    /// `None` (a gate, never a panic) on non-finite inputs, an empty/too-thin
    /// bucket, a contract violation (robust stats not excluded), or zero variance
    /// — the caller maps `None` to the appropriate [`Disposition`] gate variant.
    pub(super) fn excluded_baseline(
        &self,
        config: &SeasonalConfig,
    ) -> Result<ExcludedBaseline, Disposition> {
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
