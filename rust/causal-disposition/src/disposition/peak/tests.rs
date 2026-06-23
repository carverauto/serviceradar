// Copyright 2026 Carver Automation Corporation.
//
// Licensed under the Apache License, Version 2.0 (the "License").
// SPDX-License-Identifier: Apache-2.0

//! The UASB invariant suite. Each test is the adversarial scenario that
//! established the invariant during design verification. I3 (localized prior) is
//! enforced in SQL and I7 (suppress does not reset the confirm-slot) lives in the
//! `CausalFlow`, so they are covered by their own tests elsewhere.

use super::band::decide;
use super::types::{PassReason, PeakConfig, PeakDisposition, PeakRow};

fn cfg() -> PeakConfig {
    PeakConfig::default()
}

/// A warm, tight, well-behaved cell: n=8, center 20, scale 2, prior 2.
fn warm_row() -> PeakRow {
    PeakRow {
        series_key: "s".into(),
        hod: 3,
        peak: 20.0,
        n: 8,
        cell_center: 20.0,
        cell_scale: 2.0,
        prior_scale: 2.0,
        q95: 24.0,
    }
}

#[test]
fn i6_cold_cell_passes_through() {
    let mut r = warm_row();
    r.n = 3; // below n_min = 4
    r.peak = 99.0; // even an extreme peak must not be touched
    assert_eq!(
        decide(&r, &cfg()),
        PeakDisposition::PassThrough {
            reason: PassReason::Cold
        }
    );
}

#[test]
fn normal_peak_within_band_suppresses() {
    // The happy path: a warm cell with the peak at its own normal center.
    assert_eq!(decide(&warm_row(), &cfg()), PeakDisposition::Suppress);
}

#[test]
fn i1_downward_anomaly_escalates_not_suppressed() {
    // A collapse to 0 on a series that normally sits at 20 must escalate, proving
    // the band is two-sided (a one-sided upper band would silence this).
    let mut r = warm_row();
    r.peak = 0.0;
    assert!(
        matches!(decide(&r, &cfg()), PeakDisposition::Escalate { .. }),
        "downward anomaly must escalate (two-sided)"
    );
}

#[test]
fn i2_poisoned_cell_cannot_widen_suppression() {
    // s_cell inflated to 2.5x the prior (between cap=2 and d=3, so the
    // over-dispersion guard is NOT tripped). The inner band is therefore capped at
    // cap*prior = 4, not s_cell = 5. A real spike just past the prior-justified
    // band must NOT be suppressed. (Without the cap, s_inner=5 would suppress it.)
    let mut r = warm_row();
    r.prior_scale = 2.0;
    r.cell_scale = 5.0;
    r.peak = 40.0;
    assert!(
        !matches!(decide(&r, &cfg()), PeakDisposition::Suppress),
        "a poisoned cell must not widen the suppression band (I2)"
    );
}

#[test]
fn i5_over_dispersed_cell_passes_through() {
    let mut r = warm_row();
    r.prior_scale = 2.0;
    r.cell_scale = 10.0; // > d_overdispersion(3) * prior(2) = 6
    r.peak = 25.0;
    assert_eq!(
        decide(&r, &cfg()),
        PeakDisposition::PassThrough {
            reason: PassReason::OverDispersed
        }
    );
}

#[test]
fn i4_ceiling_proximity_passes_through() {
    // No upward headroom below 100 → the band cannot discriminate → pass through,
    // and never emit a >100 upper bound.
    let mut r = warm_row();
    r.cell_center = 96.0;
    r.q95 = 99.0;
    r.peak = 97.0;
    assert_eq!(
        decide(&r, &cfg()),
        PeakDisposition::PassThrough {
            reason: PassReason::CeilingProximity
        }
    );
}

#[test]
fn novel_spike_above_outer_escalates() {
    let mut r = warm_row();
    r.peak = 60.0;
    assert!(matches!(
        decide(&r, &cfg()),
        PeakDisposition::Escalate { .. }
    ));
}

#[test]
fn ambiguous_peak_downgrades_not_silenced() {
    // A peak in the annulus between the inner and outer bands is kept visible.
    let mut r = warm_row();
    r.peak = 31.0;
    assert!(matches!(
        decide(&r, &cfg()),
        PeakDisposition::Downgrade { .. }
    ));
}

#[test]
fn i8_asymmetry_uncertain_never_suppresses() {
    let base = warm_row();
    let cold = PeakRow {
        n: 2,
        ..base.clone()
    };
    let over = PeakRow {
        cell_scale: 100.0,
        prior_scale: 2.0,
        ..base.clone()
    };
    let ceil = PeakRow {
        cell_center: 98.0,
        q95: 99.5,
        ..base.clone()
    };
    for r in [cold, over, ceil] {
        assert!(
            !matches!(decide(&r, &cfg()), PeakDisposition::Suppress),
            "every uncertain regime must resolve away from Suppress (I8)"
        );
    }
}
