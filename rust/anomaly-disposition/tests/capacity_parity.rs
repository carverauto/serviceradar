// Copyright 2026 Carver Automation Corporation.
//
// Licensed under the Apache License, Version 2.0 (the "License").
// SPDX-License-Identifier: Apache-2.0

//! Golden-fixture capacity parity gate (OpenSpec add-core-causal-disposition-nif,
//! task 7.3 / 8.2 / graft #4).
//!
//! Asserts the Rust capacity kernel ([`dispose_capacity`]) reproduces the LEGACY
//! `ServiceRadar.Observability.CapacityForecasting.Model.forecast/2` (`model.ex`) to
//! within `1e-9` on EVERY numeric output field — slope, intercept, projected_value,
//! confidence, lower/upper bound, RMSE, and the exhaustion ETA — across seeded
//! CAGG-style slices (linear, decreasing, near-zero-slope-beyond-horizon,
//! already-crossed, no-threshold, noisy-RMSE, auto-linear, auto/forced
//! Holt-Winters, and the seasonal→linear fallback).
//!
//! The fixtures are CAPTURED from `model.ex` and committed as generated Rust source
//! (`fixtures/capacity_parity_fixtures.rs`), so this gate is DURABLE: it keeps
//! protecting the port after `model.ex` is deleted (task 7.5). Regenerate the
//! fixtures, only while `model.ex` still exists, via
//! `fixtures/generate_capacity_parity_fixtures.exs`.
//!
//! Integer-valued fields (`sample_count`, the window timestamps, and in-cap ETA in
//! microseconds) must match EXACTLY — the ETA is an integer of unix microseconds
//! (`DateTime.add(first_at, round(cross_x), :second)`), so an off-by-one would be a
//! real divergence, not a rounding artifact. D3 intentionally diverges from legacy
//! when a legacy ETA projects beyond the new observed-history extrapolation cap. D4
//! intentionally diverges when a legacy projected row has no statistically positive
//! runway trend and is now skipped as `trend_not_significant`.

use serviceradar_anomaly_disposition::{
    CapacityConfig, CapacityModelKind, CapacityPoint, CapacityRow, Disposition, dispose_capacity,
};

/// The expected legacy forecast for a `Projected` case, captured from `model.ex`.
#[derive(Clone, Debug)]
struct ExpectedForecast {
    model: &'static str,
    current_value: f64,
    slope_per_second: f64,
    intercept: f64,
    projected_value: f64,
    projected_exhaustion_at_unix_micros: Option<i64>,
    confidence: f64,
    lower_bound: f64,
    upper_bound: f64,
    rmse: f64,
    sample_count: usize,
    window_started_at_unix_micros: i64,
    window_ended_at_unix_micros: i64,
}

/// The captured legacy outcome: either a `Projected` forecast or a `Skipped` gate.
#[derive(Clone, Debug)]
enum Expected {
    Projected(ExpectedForecast),
    Skipped { reason: &'static str },
}

/// One parity case: the seeded input window + config and the captured legacy output.
struct ParityCase {
    name: &'static str,
    config: CapacityConfig,
    points: Vec<CapacityPoint>,
    expected: Expected,
}

/// The parity tolerance the spec mandates (task 7.3).
const TOL: f64 = 1e-9;

fn close(label: &str, case: &str, got: f64, want: f64) {
    // NaN never appears in these fixtures; if it ever did, equal-NaN would be the
    // only honest parity (assert it explicitly rather than letting `< TOL` lie).
    if got.is_nan() || want.is_nan() {
        assert_eq!(
            got.is_nan(),
            want.is_nan(),
            "[{case}] {label}: NaN mismatch got={got} want={want}"
        );
        return;
    }
    let diff = (got - want).abs();
    assert!(
        diff <= TOL,
        "[{case}] {label}: got {got}, want {want} (|Δ| = {diff} > {TOL})"
    );
}

fn parity_cases() -> Vec<ParityCase> {
    include!("fixtures/capacity_parity_fixtures.rs")
}

#[test]
fn capacity_kernel_matches_legacy_model_within_1e_9() {
    let cases = parity_cases();
    assert!(
        cases.len() >= 12,
        "expected the full captured fixture set, got {}",
        cases.len()
    );

    for case in cases {
        let out = dispose_capacity(
            CapacityRow {
                series_key: case.name.to_string(),
                points: case.points.clone(),
            },
            &case.config,
        );

        match (&out.disposition, &case.expected) {
            (Disposition::Projected(got), Expected::Projected(want)) => {
                assert_eq!(got.model, want.model, "[{}] model kind diverged", case.name);
                close(
                    "current_value",
                    case.name,
                    got.current_value,
                    want.current_value,
                );
                close(
                    "slope_per_second",
                    case.name,
                    got.slope_per_second,
                    want.slope_per_second,
                );
                close("intercept", case.name, got.intercept, want.intercept);
                close(
                    "projected_value",
                    case.name,
                    got.projected_value,
                    want.projected_value,
                );
                close(
                    "raw_projected_value",
                    case.name,
                    got.raw_projected_value,
                    want.projected_value,
                );
                assert!(
                    !got.projection_bounded,
                    "[{}] unbounded parity fixture unexpectedly reported a bounded projection",
                    case.name
                );
                // D2: the band + `confidence` intentionally DIVERGE from the legacy
                // `± 1.96·RMSE` / `clamp(1 - rmse/scale)` fixtures. The fit fields above
                // still hold the parity gate (the port reproduces `model.ex`'s slope/
                // intercept/projection/RMSE/ETA); the band is now a valid prediction
                // interval (closed-form OLS / residual-bootstrap) and `confidence` is the
                // interval's coverage level — so assert the new behaviour, not parity.
                assert!(
                    (got.confidence - 0.95).abs() < 1e-9,
                    "[{}] confidence should be the 0.95 PI coverage level, got {}",
                    case.name,
                    got.confidence
                );
                assert!(
                    got.lower_bound <= got.projected_value + 1e-9
                        && got.upper_bound >= got.projected_value - 1e-9,
                    "[{}] prediction interval [{}, {}] must bracket the projection {}",
                    case.name,
                    got.lower_bound,
                    got.upper_bound,
                    got.projected_value
                );
                // The legacy band/confidence fixtures are retained for reference but are
                // deliberately no longer parity-asserted (D2 changed them).
                let _ = (want.confidence, want.lower_bound, want.upper_bound);
                close("rmse", case.name, got.rmse, want.rmse);
                // Integer fields must match EXACTLY.
                assert_eq!(
                    got.sample_count, want.sample_count,
                    "[{}] sample_count diverged",
                    case.name
                );
                assert_eta_matches_or_is_history_capped(
                    &case,
                    got.projected_exhaustion_at_unix_micros,
                    want.projected_exhaustion_at_unix_micros,
                );
                assert_eq!(
                    got.window_started_at_unix_micros, want.window_started_at_unix_micros,
                    "[{}] window_started diverged",
                    case.name
                );
                assert_eq!(
                    got.window_ended_at_unix_micros, want.window_ended_at_unix_micros,
                    "[{}] window_ended diverged",
                    case.name
                );
            }
            (Disposition::Skipped { reason: got }, Expected::Skipped { reason: want }) => {
                assert_eq!(got, want, "[{}] skip reason diverged", case.name);
            }
            (Disposition::Skipped { reason: got }, Expected::Projected(want))
                if got == "trend_not_significant" =>
            {
                assert!(
                    legacy_projection_lacks_positive_runway(&case, want),
                    "[{}] unexpected trend_not_significant divergence: legacy={want:?}",
                    case.name
                );
            }
            (got, want) => panic!(
                "[{}] disposition shape diverged: kernel={got:?}, legacy={want:?}",
                case.name
            ),
        }
    }
}

fn legacy_projection_lacks_positive_runway(case: &ParityCase, want: &ExpectedForecast) -> bool {
    match case.config.capacity_threshold {
        Some(threshold) if threshold.is_finite() => {
            want.current_value < threshold && want.slope_per_second <= 0.0
        }
        _ => false,
    }
}

fn assert_eta_matches_or_is_history_capped(case: &ParityCase, got: Option<i64>, want: Option<i64>) {
    if got == want {
        return;
    }

    let legacy_eta = want.unwrap_or_else(|| {
        panic!(
            "[{}] exhaustion ETA (unix micros) diverged: kernel={got:?}, legacy={want:?}",
            case.name
        )
    });

    assert!(
        got.is_none() && legacy_eta_beyond_history_cap(case, legacy_eta),
        "[{}] exhaustion ETA (unix micros) diverged: kernel={got:?}, legacy={want:?}",
        case.name
    );
}

fn legacy_eta_beyond_history_cap(case: &ParityCase, legacy_eta: i64) -> bool {
    let (Some(first), Some(last)) = (case.points.first(), case.points.last()) else {
        return false;
    };

    let observed_span_micros = last.at_unix_micros - first.at_unix_micros;
    if observed_span_micros <= 0 {
        return false;
    }

    let history_cap_micros = observed_span_micros.saturating_mul(2);
    let horizon_cap_micros = case
        .config
        .horizon_seconds
        .saturating_mul(10)
        .saturating_mul(1_000_000);
    let extrapolation_cap_micros = history_cap_micros.min(horizon_cap_micros);
    let max_eta_micros = last.at_unix_micros.saturating_add(extrapolation_cap_micros);

    legacy_eta > max_eta_micros
}
