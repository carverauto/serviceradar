// Copyright 2026 Carver Automation Corporation.
//
// Licensed under the Apache License, Version 2.0 (the "License").
// SPDX-License-Identifier: Apache-2.0

// The crate root denies `clippy::panic` for production paths (graft #1). Tests
// that assert a specific enum/`Option` variant fall through to `panic!` on the
// wrong variant — the standard test-failure mechanism — so allow it inside the
// test module only (mirrors `capacity/tests.rs`).
#![allow(clippy::panic)]

use crate::disposition::peak_profile::{
    PeakProfileAction, PeakProfileConfig, PeakProfileRow, dispose_peak_profile,
    peak_profile_error_disposition,
};

fn config() -> PeakProfileConfig {
    PeakProfileConfig {
        suppress_n_sigma: 2.0,
        escalate_n_sigma: 3.0,
        min_cell_samples: 6,
        cap_scale: 2.0,
        low_n_inflation: 1.0,
        over_dispersion_ratio: 8.0,
        absolute_scale_floor: 0.5,
        ceiling: f64::INFINITY,
        report_only: true,
        suppression_enabled: false,
        suppress_decay_slots: 1,
    }
}

fn row(peak_value: f64) -> PeakProfileRow {
    PeakProfileRow {
        series_key: "svc/cpu/overall".to_string(),
        hod: 9,
        peak_value,
        cell_sample_count: 16,
        cell_center: 50.0,
        cell_scale: 2.0,
        series_prior_scale: 2.5,
        cell_q95: 54.0,
        consecutive_anomalous: 0,
    }
}

#[test]
fn recurring_peak_within_inner_band_recommends_suppress_but_reports_only() {
    let out = dispose_peak_profile(row(51.0), &config());

    assert_eq!(out.recommended_action, PeakProfileAction::Suppress);
    assert_eq!(
        out.surfaced_action,
        PeakProfileAction::PassThrough,
        "report-only must leave live alert behavior unchanged"
    );
    assert_eq!(out.next_consecutive_anomalous, 0);
    assert!(
        out.band.is_some(),
        "scoreable row should include band evidence"
    );
}

#[test]
fn activation_allows_suppression_only_when_report_only_is_off_and_class_enabled() {
    let cfg = PeakProfileConfig {
        report_only: false,
        suppression_enabled: true,
        ..config()
    };

    let out = dispose_peak_profile(row(51.0), &cfg);

    assert_eq!(out.recommended_action, PeakProfileAction::Suppress);
    assert_eq!(out.surfaced_action, PeakProfileAction::Suppress);
}

#[test]
fn downward_excursion_outside_outer_band_escalates() {
    let cfg = PeakProfileConfig {
        report_only: false,
        suppression_enabled: true,
        ..config()
    };
    let out = dispose_peak_profile(row(20.0), &cfg);

    assert_eq!(out.recommended_action, PeakProfileAction::Escalate);
    assert_eq!(out.surfaced_action, PeakProfileAction::Escalate);
    assert!(
        out.score < 0.0,
        "score should preserve excursion direction, got {}",
        out.score
    );
}

#[test]
fn poisoned_cell_cannot_widen_suppression_band_beyond_series_prior_cap() {
    let poisoned = PeakProfileRow {
        peak_value: 120.0,
        cell_center: 50.0,
        cell_scale: 8.0,
        series_prior_scale: 1.0,
        cell_sample_count: 36,
        ..row(120.0)
    };

    let out = dispose_peak_profile(poisoned, &config());
    let Some(band) = out.band else {
        panic!("poison-bound case should still be scoreable");
    };

    assert_eq!(
        band.inner_scale, 2.0,
        "inner scale must be min(s_cell, CAP * s_prior)"
    );
    assert_eq!(out.recommended_action, PeakProfileAction::Escalate);
}

#[test]
fn quiet_hour_is_not_whitewashed_by_spiky_neighbor_hour_scale() {
    // The row represents the quiet hour's tight `(series, hod)` cell. If a class
    // or neighbor-hour scale around 30 were used, this peak would sit inside the
    // suppression band. With the local cell scale + per-series prior cap it does not.
    let quiet_hour = PeakProfileRow {
        peak_value: 20.0,
        cell_center: 5.0,
        cell_scale: 0.5,
        series_prior_scale: 0.6,
        cell_q95: 5.6,
        cell_sample_count: 12,
        hod: 3,
        ..row(20.0)
    };

    let out = dispose_peak_profile(quiet_hour, &config());
    assert_eq!(out.recommended_action, PeakProfileAction::Escalate);
}

#[test]
fn cold_over_dispersed_and_ceiling_proximity_cells_pass_through() {
    let cold = PeakProfileRow {
        cell_sample_count: 5,
        ..row(90.0)
    };
    let cold_out = dispose_peak_profile(cold, &config());
    assert_eq!(cold_out.recommended_action, PeakProfileAction::PassThrough);
    assert_eq!(cold_out.reason, "cold peak profile cell");

    let over_dispersed = PeakProfileRow {
        cell_scale: 30.0,
        series_prior_scale: 1.0,
        ..row(90.0)
    };
    let dispersed_out = dispose_peak_profile(over_dispersed, &config());
    assert_eq!(
        dispersed_out.recommended_action,
        PeakProfileAction::PassThrough
    );
    assert_eq!(dispersed_out.reason, "over-dispersed peak profile cell");

    let ceiling_cfg = PeakProfileConfig {
        ceiling: 100.0,
        ..config()
    };
    let ceiling = PeakProfileRow {
        cell_center: 97.0,
        cell_scale: 0.5,
        series_prior_scale: 0.5,
        cell_q95: 99.0,
        ..row(99.5)
    };
    let ceiling_out = dispose_peak_profile(ceiling, &ceiling_cfg);
    assert_eq!(
        ceiling_out.recommended_action,
        PeakProfileAction::PassThrough
    );
    assert_eq!(ceiling_out.reason, "ceiling-proximity peak profile cell");
}

#[test]
fn low_n_inflation_is_sigma_relative_and_decays_with_sample_count() {
    let low_n = dispose_peak_profile(
        PeakProfileRow {
            cell_sample_count: 6,
            ..row(55.0)
        },
        &config(),
    );
    let mature = dispose_peak_profile(
        PeakProfileRow {
            cell_sample_count: 36,
            ..row(55.0)
        },
        &config(),
    );

    let Some(low_band) = low_n.band else {
        panic!("low-n scoreable row should include a band");
    };
    let Some(mature_band) = mature.band else {
        panic!("mature scoreable row should include a band");
    };

    assert!(low_band.low_n_multiplier > mature_band.low_n_multiplier);
    assert!(
        low_band.inner_upper - low_band.center > mature_band.inner_upper - mature_band.center,
        "low-n inflation should widen by multiplying the robust scale"
    );
}

#[test]
fn suppress_decays_confirm_counter_instead_of_resetting_it() {
    let expected_peak = PeakProfileRow {
        peak_value: 51.0,
        consecutive_anomalous: 5,
        ..row(51.0)
    };

    let out = dispose_peak_profile(expected_peak, &config());

    assert_eq!(out.recommended_action, PeakProfileAction::Suppress);
    assert_eq!(
        out.next_consecutive_anomalous, 4,
        "suppress must leak the counter down, not reset it to zero"
    );
}

#[test]
fn flow_error_preserves_confirm_counter_instead_of_resetting_it() {
    let out = peak_profile_error_disposition("svc/cpu/overall".to_string(), 7, "boom");

    assert_eq!(out.recommended_action, PeakProfileAction::PassThrough);
    assert_eq!(out.surfaced_action, PeakProfileAction::PassThrough);
    assert_eq!(
        out.next_consecutive_anomalous, 7,
        "flow errors must not reset the carried confirmation counter"
    );
    assert!(out.reason.contains("boom"));
}

#[test]
fn invalid_inputs_take_asymmetric_pass_through_path() {
    let out = dispose_peak_profile(
        PeakProfileRow {
            peak_value: f64::NAN,
            ..row(99.0)
        },
        &config(),
    );

    assert_eq!(out.recommended_action, PeakProfileAction::PassThrough);
    assert_eq!(out.surfaced_action, PeakProfileAction::PassThrough);
    assert_eq!(out.band, None);
}
