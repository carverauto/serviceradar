// Copyright 2026 Carver Automation Corporation.
//
// Licensed under the Apache License, Version 2.0 (the "License").
// SPDX-License-Identifier: Apache-2.0

//! Module-level capacity-kernel tests (the in-crate unit gate; the `1e-9` Elixir
//! golden-fixture parity gate lives in `tests/capacity_parity.rs`).

// The crate root denies `clippy::panic` for production paths (graft #1). Tests
// that assert a specific enum variant fall through to `panic!` on the wrong
// variant — the standard test-failure mechanism — so allow it inside the test
// module only (mirrors the NIF boundary tests' `#[allow(clippy::panic)]`).
#![allow(clippy::panic)]

use super::*;

const START_MICROS: i64 = 1_780_272_000_000_000; // 2026-06-01T00:00:00Z in micros.

fn point(hour: i64, value: f64) -> CapacityPoint {
    CapacityPoint {
        at_unix_micros: START_MICROS + hour * 3_600 * MICROS_PER_SECOND,
        value,
    }
}

fn config(threshold: Option<f64>, horizon: i64, kind: CapacityModelKind) -> CapacityConfig {
    CapacityConfig {
        capacity_threshold: threshold,
        horizon_seconds: horizon,
        model_kind: kind,
        min_history: 24,
        period: 24,
        ..CapacityConfig::default()
    }
}

fn linear_points() -> Vec<CapacityPoint> {
    (0..48).map(|h| point(h, 10.0 + h as f64)).collect()
}

/// Mirrors the Elixir `"linear forecast computes projected value and exhaustion
/// ETA"` test (model_test.exs:8): slope 1/3600, projected 81.0, ETA at +70h.
#[test]
fn linear_forecast_projects_and_etas() {
    let cfg = config(Some(80.0), 24 * 3_600, CapacityModelKind::Linear);
    let out = dispose_capacity(
        CapacityRow {
            series_key: "svc/disk".to_string(),
            points: linear_points(),
        },
        &cfg,
    );
    match out.disposition {
        Disposition::Projected(f) => {
            assert_eq!(f.model, "linear");
            assert!((f.slope_per_second - 1.0 / 3_600.0).abs() < 1e-9);
            assert!((f.projected_value - 81.0).abs() < 1e-3);
            // ETA at +70 hours from window start.
            let expected = START_MICROS + 70 * 3_600 * MICROS_PER_SECOND;
            assert_eq!(f.projected_exhaustion_at_unix_micros, Some(expected));
            assert!(f.confidence > 0.99);
        }
        other => panic!("expected Projected, got {other:?}"),
    }
}

/// A zero period (a malformed config that bypassed the worker's
/// `positive_integer/2` normalization) must NOT panic at `index % period`; both the
/// forced-`Seasonal` and `Auto` paths fall back to the linear model.
#[test]
fn zero_period_falls_back_to_linear_without_panic() {
    for kind in [CapacityModelKind::Seasonal, CapacityModelKind::Auto] {
        let cfg = CapacityConfig {
            capacity_threshold: Some(80.0),
            horizon_seconds: 24 * 3_600,
            model_kind: kind,
            min_history: 24,
            period: 0,
            ..CapacityConfig::default()
        };
        let out = dispose_capacity(
            CapacityRow {
                series_key: "svc/disk".to_string(),
                points: linear_points(),
            },
            &cfg,
        );
        match out.disposition {
            Disposition::Projected(f) => assert_eq!(f.model, "linear", "kind={kind:?}"),
            other => panic!("expected linear Projected fallback, got {other:?}"),
        }
    }
}

/// A pathologically huge period must not overflow `period * 2` / `period + period`
/// (which would wrap and panic the seasonal slice) — saturating math trips the gate
/// and falls back to linear.
#[test]
fn huge_period_does_not_overflow_panic() {
    let cfg = CapacityConfig {
        capacity_threshold: Some(80.0),
        horizon_seconds: 24 * 3_600,
        model_kind: CapacityModelKind::Seasonal,
        min_history: 24,
        period: usize::MAX / 2 + 1,
        ..CapacityConfig::default()
    };
    let out = dispose_capacity(
        CapacityRow {
            series_key: "svc/disk".to_string(),
            points: linear_points(),
        },
        &cfg,
    );
    match out.disposition {
        Disposition::Projected(f) => assert_eq!(f.model, "linear"),
        other => panic!("expected linear Projected fallback, got {other:?}"),
    }
}

/// A `min_history` of 0 must not let an empty window reach `points[len - 1]`; the
/// empty-window guard gates it to `Skipped` instead of an index panic.
#[test]
fn empty_points_with_zero_min_history_is_skipped() {
    let cfg = CapacityConfig {
        min_history: 0,
        ..config(None, 24 * 3_600, CapacityModelKind::Linear)
    };
    let out = dispose_capacity(
        CapacityRow {
            series_key: "s".to_string(),
            points: vec![],
        },
        &cfg,
    );
    assert_eq!(
        out.disposition,
        Disposition::Skipped {
            reason: "insufficient_history".to_string()
        }
    );
}

/// Sorting parity: a reversed input must produce the same fit as the ordered one
/// (model_test.exs:29).
#[test]
fn reversed_input_fits_identically() {
    let cfg = config(Some(40.0), 12 * 3_600, CapacityModelKind::Linear);
    let ordered: Vec<CapacityPoint> = (0..48).map(|h| point(h, 5.0 + h as f64 * 0.5)).collect();
    let mut reversed = ordered.clone();
    reversed.reverse();

    let a = dispose_capacity(
        CapacityRow {
            series_key: "s".to_string(),
            points: ordered,
        },
        &cfg,
    );
    let b = dispose_capacity(
        CapacityRow {
            series_key: "s".to_string(),
            points: reversed,
        },
        &cfg,
    );
    match (a.disposition, b.disposition) {
        (Disposition::Projected(fa), Disposition::Projected(fb)) => {
            assert!((fa.slope_per_second - fb.slope_per_second).abs() < 1e-12);
            assert!((fa.projected_value - fb.projected_value).abs() < 1e-9);
            assert_eq!(
                fa.projected_exhaustion_at_unix_micros,
                fb.projected_exhaustion_at_unix_micros
            );
            assert_eq!(
                fa.window_started_at_unix_micros,
                fb.window_started_at_unix_micros
            );
            assert_eq!(
                fa.window_ended_at_unix_micros,
                fb.window_ended_at_unix_micros
            );
        }
        other => panic!("expected two Projected, got {other:?}"),
    }
}

/// Flat/decreasing trend ⇒ no ETA (model_test.exs:60).
#[test]
fn decreasing_trend_has_no_eta() {
    let cfg = config(Some(100.0), 24 * 3_600, CapacityModelKind::Linear);
    let points: Vec<CapacityPoint> = (0..48).map(|h| point(h, 90.0 - h as f64 * 0.25)).collect();
    let out = dispose_capacity(
        CapacityRow {
            series_key: "s".to_string(),
            points,
        },
        &cfg,
    );
    match out.disposition {
        Disposition::Projected(f) => {
            assert!(f.slope_per_second < 0.0);
            assert_eq!(f.projected_exhaustion_at_unix_micros, None);
        }
        other => panic!("expected Projected, got {other:?}"),
    }
}

/// A near-zero positive slope whose crossing lands beyond `10×` the horizon ⇒ no
/// ETA (the year-5256 collapse, model_test.exs:80).
#[test]
fn beyond_horizon_crossing_collapses_to_no_eta() {
    let cfg = config(Some(100.0), 24 * 3_600, CapacityModelKind::Linear);
    let points: Vec<CapacityPoint> = (0..48)
        .map(|h| point(h, 10.0 + h as f64 * 0.0001))
        .collect();
    let out = dispose_capacity(
        CapacityRow {
            series_key: "s".to_string(),
            points,
        },
        &cfg,
    );
    match out.disposition {
        Disposition::Projected(f) => {
            assert!(f.slope_per_second > 0.0);
            assert_eq!(f.projected_exhaustion_at_unix_micros, None);
        }
        other => panic!("expected Projected, got {other:?}"),
    }
}

/// Already-crossed-in-window ⇒ no ETA (model_test.exs:100).
#[test]
fn already_crossed_has_no_eta() {
    let cfg = config(Some(100.0), 24 * 3_600, CapacityModelKind::Linear);
    let points: Vec<CapacityPoint> = (0..48).map(|h| point(h, 150.0 + h as f64)).collect();
    let out = dispose_capacity(
        CapacityRow {
            series_key: "s".to_string(),
            points,
        },
        &cfg,
    );
    match out.disposition {
        Disposition::Projected(f) => {
            assert_eq!(f.projected_exhaustion_at_unix_micros, None)
        }
        other => panic!("expected Projected, got {other:?}"),
    }
}

/// Task 8.2: the `insufficient_history` gate → `Skipped{reason}`, never a panic.
#[test]
fn insufficient_history_is_skipped() {
    let cfg = CapacityConfig {
        min_history: 3,
        ..config(None, 24 * 3_600, CapacityModelKind::Auto)
    };
    let out = dispose_capacity(
        CapacityRow {
            series_key: "s".to_string(),
            points: vec![point(0, 10.0), point(1, 11.0)],
        },
        &cfg,
    );
    assert_eq!(
        out.disposition,
        Disposition::Skipped {
            reason: "insufficient_history".to_string()
        }
    );
}

/// Auto model with no seasonality ⇒ linear (model_test.exs:132). A flat series
/// fits slope 0 and projects its own current value.
#[test]
fn auto_without_seasonality_is_linear() {
    let cfg = CapacityConfig {
        min_history: 48,
        ..config(None, 24 * 3_600, CapacityModelKind::Auto)
    };
    let points: Vec<CapacityPoint> = (0..72).map(|h| point(h, 40.0)).collect();
    let out = dispose_capacity(
        CapacityRow {
            series_key: "s".to_string(),
            points,
        },
        &cfg,
    );
    match out.disposition {
        Disposition::Projected(f) => {
            assert_eq!(f.model, "linear");
            assert_eq!(f.sample_count, 72);
            assert_eq!(f.slope_per_second, 0.0);
            assert_eq!(f.projected_value, f.current_value);
        }
        other => panic!("expected Projected, got {other:?}"),
    }
}

/// Auto model with strong seasonality ⇒ additive Holt-Winters (model_test.exs:152).
#[test]
fn auto_with_seasonality_is_holt_winters() {
    let cfg = CapacityConfig {
        min_history: 48,
        ..config(None, 24 * 3_600, CapacityModelKind::Auto)
    };
    let points: Vec<CapacityPoint> = (0..72)
        .map(|h| {
            let seasonal = if (h % 24) >= 8 && (h % 24) <= 17 {
                25.0
            } else {
                -10.0
            };
            point(h, 50.0 + seasonal + h as f64 * 0.05)
        })
        .collect();
    let out = dispose_capacity(
        CapacityRow {
            series_key: "s".to_string(),
            points,
        },
        &cfg,
    );
    match out.disposition {
        Disposition::Projected(f) => {
            assert_eq!(f.model, "holt_winters_additive");
            assert_eq!(f.sample_count, 72);
            assert!(f.projected_value > 0.0);
        }
        other => panic!("expected Projected, got {other:?}"),
    }
}

#[test]
fn holt_winters_negative_horizon_slope_has_no_eta() {
    let cfg = CapacityConfig {
        min_history: 48,
        ..config(Some(70.0), 24 * 3_600, CapacityModelKind::Seasonal)
    };
    let points: Vec<CapacityPoint> = (0..72)
        .map(|h| {
            let seasonal = if (h % 24) >= 8 && (h % 24) <= 17 {
                35.0
            } else {
                -5.0
            };
            point(h, 55.0 + seasonal - h as f64 * 0.2)
        })
        .collect();
    let out = dispose_capacity(
        CapacityRow {
            series_key: "s".to_string(),
            points,
        },
        &cfg,
    );
    match out.disposition {
        Disposition::Projected(f) => {
            assert_eq!(f.model, "holt_winters_additive");
            assert!(f.slope_per_second < 0.0);
            assert_eq!(f.projected_exhaustion_at_unix_micros, None);
        }
        other => panic!("expected Projected, got {other:?}"),
    }
}

/// A non-finite value in the window is dropped by normalize (mirrors
/// `normalize_point/1` rejecting non-numbers); if that drops below the gate it
/// Skips rather than panicking.
#[test]
fn non_finite_value_is_dropped_then_gated() {
    let cfg = CapacityConfig {
        min_history: 48,
        ..config(None, 24 * 3_600, CapacityModelKind::Linear)
    };
    let mut points: Vec<CapacityPoint> = (0..48).map(|h| point(h, 10.0 + h as f64)).collect();
    points.push(CapacityPoint {
        at_unix_micros: START_MICROS + 100 * 3_600 * MICROS_PER_SECOND,
        value: f64::NAN,
    });
    let out = dispose_capacity(
        CapacityRow {
            series_key: "s".to_string(),
            points,
        },
        &cfg,
    );
    // 48 finite points survive (NaN dropped) → still a Projected linear fit.
    assert!(matches!(out.disposition, Disposition::Projected { .. }));
}
