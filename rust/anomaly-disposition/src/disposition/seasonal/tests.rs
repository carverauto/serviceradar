// Copyright 2026 Carver Automation Corporation.
//
// Licensed under the Apache License, Version 2.0 (the "License").
// SPDX-License-Identifier: Apache-2.0

//! Seasonal kernel unit tests: the deseasonalized residual-z behavior, the
//! bucket-exclusion invariant, the gate variants, confirm-slot hysteresis, and the
//! robust-statistic paths.

use crate::disposition::seasonal::*;
use crate::disposition::{Disposition, RobustStatistic};

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
    assert!(
        out.score >= 3.0,
        "residual z {} must clear sigma",
        out.score
    );
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
    let out = dispose_seasonal(
        mean_stddev_row(&[1.0, 2.0, 3.0, 4.0, 5.0], f64::NAN, 0),
        &config(),
    );
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

    // With 1 carried slot this is the 2nd of 3 → still pending.
    let second = dispose_seasonal(mean_stddev_row(&baseline, 800.0, 1), &cfg);
    assert!(
        matches!(second.disposition, Disposition::SeasonalDrift { .. }),
        "the N-1 over-threshold slot must remain pending, got {:?}",
        second.disposition
    );
    assert_eq!(second.next_consecutive_anomalous, 2);

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
fn suppress_resets_pending_confirmation() {
    let cfg = SeasonalConfig {
        confirm_slots: 3,
        ..config()
    };
    let baseline: Vec<f64> = (0..20).map(|i| 800.0 + (i % 3) as f64 * 0.5).collect();
    let clean = dispose_seasonal(mean_stddev_row(&baseline, 800.0, 2), &cfg);
    assert_eq!(clean.disposition, Disposition::Suppress);
    assert_eq!(clean.next_consecutive_anomalous, 0);
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
