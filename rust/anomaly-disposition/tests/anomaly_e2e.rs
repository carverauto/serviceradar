// Copyright 2026 Carver Automation Corporation.
//
// Licensed under the Apache License, Version 2.0 (the "License").
// SPDX-License-Identifier: Apache-2.0

//! End-to-end proof that the ServiceRadar anomaly engine works across BOTH halves
//! from a single synthetic scenario:
//!
//! - the AGENT edge detector ([`serviceradar_anomaly_core::reason_impl`]), which
//!   judges a sample against its recent ROLLING baseline, and
//! - the CORE disposition ([`serviceradar_anomaly_disposition::dispose_seasonal`]),
//!   which judges the SAME sample value against that series' SEASONAL `(dow,hod)`
//!   cell.
//!
//! Each test feeds ONE synthetic scenario, chaining the same sample value through
//! both engines, and asserts the joint verdict. The three behaviors proven here are
//! the whole point of the two-stage design:
//!
//! 1. `e2e_real_anomaly_escalates`     — a true spike (high vs rolling AND vs the
//!    seasonal cell) escalates: detector `anomalous`, core `SeasonalBreach`.
//! 2. `e2e_recurring_normal_suppressed`— a recurring-normal value (the onset jump
//!    looks anomalous to the edge's rolling window, but the seasonal cell expects
//!    it) is SUPPRESSED by the seasonal stage even though the edge flagged it.
//!    THIS IS THE CENTERPIECE: the core stage is what keeps a predictable weekly
//!    peak from paging.
//! 3. `e2e_normal_stays_clean`         — normal data is quiet at the edge: detector
//!    `clean`, never breaches.
//!
//! # On the seasonal synthetic inputs
//! [`SeasonalConfig::default()`] uses [`RobustStatistic::MeanStddev`], so the kernel
//! does NOT read `center`/`mad` directly — it reconstructs the excluded-baseline
//! mean and stddev algebraically from `bucket_count`/`bucket_sum`/`bucket_sum_sq`
//! (the CAGG sums INCLUDING `sample_value`), excluding the sample under test (the
//! bucket-exclusion invariant, see `seasonal/baseline.rs`). The residual z is then
//! `|sample_value - excl_center| / excl_scale` compared to `seasonal_n_sigma`
//! (default 3.0). So the synthetic rows below set the sums — not `center`/`mad` —
//! to land the residual where each behavior requires. The construction puts the
//! `n = bucket_count - 1` excluded baseline samples symmetrically at `mu ± d` (mean
//! `mu`, per-sample squared deviation `d^2`), which makes the resulting excluded
//! mean/stddev exact and legible.

use serviceradar_anomaly_core::{ReasonContext, ReasonSample, ReasonVerdict, reason_impl};
use serviceradar_anomaly_disposition::{
    Disposition, SeasonalConfig, SeasonalRow, dispose_seasonal,
};

/// The flat rolling baseline every case shares: ~100 with a tiny ±0.5 jitter so the
/// rolling stddev is strictly > 0 (a degenerate zero-variance window would make the
/// z-score undefined). 20 samples clears `min_samples = 5`.
fn flat_rolling_baseline() -> Vec<f64> {
    (0..20)
        .map(|i| 100.0 + if i % 2 == 0 { 0.5 } else { -0.5 })
        .collect()
}

/// The AGENT edge detector context: a rolling-only detector over the flat baseline.
/// `confirm_slots = 1, consecutive_anomalous = 0` means a single breaching slot
/// confirms immediately (no multi-slot hysteresis), which is what we want to prove a
/// spike escalates from one sample.
fn agent_context(baseline: Vec<f64>) -> ReasonContext {
    ReasonContext {
        baseline,
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
        confirm_slots: Some(1),
        consecutive_anomalous: Some(0),
        min_std_floor: None,
        min_cv: None,
        saturation_gate: None,
        burst_envelope: None,
    }
}

/// Run the AGENT edge detector for one sample against the flat rolling baseline.
fn agent_verdict(sample_value: f64) -> ReasonVerdict {
    reason_impl(
        agent_context(flat_rolling_baseline()),
        ReasonSample {
            value: sample_value,
            observed_at_unix_nano: None,
        },
    )
    .expect("edge detector should return a verdict for a finite sample")
}

/// Build a synthetic seasonal `(dow,hod)` cell whose EXCLUDED baseline (the other
/// `n` samples in the bucket) is centered at `mu` with a per-sample spread of `d`.
///
/// The CAGG sums INCLUDE `sample_value` (the natural aggregate the kernel
/// algebraically de-aggregates). We place the `n` excluded samples symmetrically at
/// `mu ± d`, giving `excl_sum = n*mu` and `excl_sum_sq = n*mu^2 + n*d^2`. After the
/// kernel removes the sample, the excluded mean is exactly `mu` and the
/// Bessel-corrected excluded stddev is `d * sqrt(n / (n-1))`.
fn seasonal_cell(mu: f64, d: f64, n: usize, sample_value: f64) -> SeasonalRow {
    let nf = n as f64;
    let excl_sum = nf * mu;
    let excl_sum_sq = nf * mu * mu + nf * d * d;
    SeasonalRow {
        series_key: "sr:e2e:cpu_busy".to_string(),
        dow: 2,
        hod: 14,
        sample_value,
        // bucket_count INCLUDES the sample under test for MeanStddev.
        bucket_count: n + 1,
        bucket_sum: excl_sum + sample_value,
        bucket_sum_sq: excl_sum_sq + sample_value * sample_value,
        // center/mad/p05/p95 are ONLY consumed by the robust statistics; the default
        // MeanStddev config ignores them. We still set center to mu so the row reads
        // truthfully.
        center: mu,
        mad: 0.0,
        p05: 0.0,
        p95: 0.0,
        consecutive_anomalous: 0,
        baseline_excludes_latest: true,
    }
}

/// CASE 1 — a TRUE spike escalates through both stages.
///
/// Rolling baseline ~100, sample 1000 (10x): the edge flags it. The seasonal cell
/// for this hour is also centered at 100 with a tight spread, so the deseasonalized
/// residual is enormous and the core confirms a `SeasonalBreach`. Both stages agree:
/// this is a real incident.
#[test]
fn e2e_real_anomaly_escalates() {
    let sample = 1000.0;

    // AGENT edge detector: 1000 vs a flat ~100 rolling window is wildly anomalous.
    let edge = agent_verdict(sample);
    assert!(
        edge.anomalous,
        "edge detector should flag a 10x spike vs the rolling baseline (state={}, score={})",
        edge.state, edge.score
    );
    assert_eq!(edge.state, "anomalous");
    assert!(edge.breached);

    // CORE seasonal disposition: this hour's cell is centered at 100 (spread ~1), so
    // a 1000 sample is a massive deseasonalized residual -> confirmed breach.
    let row = seasonal_cell(
        /* mu */ 100.0, /* d */ 1.0, /* n */ 29, sample,
    );
    // confirm_slots = 1 so a single over-threshold bucket confirms immediately here;
    // the confirm-slot hysteresis (now default 2, D-Q3) is exercised separately in
    // `drift_pending_until_confirm_slots_met`.
    let core = dispose_seasonal(
        row,
        &SeasonalConfig {
            confirm_slots: 1,
            ..SeasonalConfig::default()
        },
    );
    assert!(
        matches!(core.disposition, Disposition::SeasonalBreach { .. }),
        "core should escalate a true spike to SeasonalBreach, got {:?} (score={})",
        core.disposition,
        core.score
    );
    // A confirmed breach surfaces upstream as an anomaly.
    assert!(core.disposition.surfaces());
}

/// CASE 2 — a RECURRING-NORMAL value is SUPPRESSED by the seasonal stage. (centerpiece)
///
/// SAME rolling baseline ~100, SAME sample 1000: the edge's rolling window only
/// remembers the recent flat ~100, so the onset jump to 1000 looks anomalous to the
/// EDGE and it flags it. But for THIS hour-of-week the value 1000 is exactly what
/// the seasonal cell expects (center 1000, moderate spread): the deseasonalized
/// residual is ~0, so the core SUPPRESSES it. This is the whole reason the seasonal
/// stage exists — a predictable weekly peak must not page, even though a purely
/// local rolling detector would fire on its onset.
#[test]
fn e2e_recurring_normal_suppressed() {
    let sample = 1000.0;

    // AGENT edge detector: identical to case 1 — the rolling window flags the jump.
    let edge = agent_verdict(sample);
    assert!(
        edge.anomalous,
        "edge detector flags the onset jump vs its local rolling window (state={})",
        edge.state
    );
    assert_eq!(edge.state, "anomalous");

    // CORE seasonal disposition: this hour's cell is centered at 1000, so 1000 is
    // recurring-normal -> the seasonal stage SUPPRESSES what the edge flagged.
    let row = seasonal_cell(
        /* mu */ 1000.0, /* d */ 10.0, /* n */ 29, sample,
    );
    let core = dispose_seasonal(row, &SeasonalConfig::default());
    assert_eq!(
        core.disposition,
        Disposition::Suppress,
        "CENTERPIECE: recurring-normal must be SUPPRESSED by the seasonal cell even \
         though the edge rolling detector flagged the onset jump (got {:?}, score={})",
        core.disposition,
        core.score
    );
    // A suppressed disposition does NOT surface upstream — no page.
    assert!(!core.disposition.surfaces());
}

/// CASE 3 — normal data stays quiet at the edge.
///
/// Rolling baseline ~100, sample 100: nothing to see, the detector stays clean and
/// never breaches.
#[test]
fn e2e_normal_stays_clean() {
    let edge = agent_verdict(100.0);
    assert_eq!(
        edge.state, "clean",
        "a sample equal to the rolling baseline should be clean (score={})",
        edge.score
    );
    assert!(!edge.anomalous, "normal data must not be flagged anomalous");
    assert!(!edge.breached, "normal data must not breach");
}
