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
            // `confidence` now carries the prediction interval's nominal coverage
            // level (0.95), not the old `clamp(1 - rmse/scale)` heuristic (D2).
            assert!((f.confidence - 0.95).abs() < 1e-9);
        }
        other => panic!("expected Projected, got {other:?}"),
    }
}

#[test]
fn linear_eta_beyond_two_history_spans_is_suppressed() {
    let points: Vec<CapacityPoint> = (0..(7 * 24))
        .map(|h| point(h, 10.0 + h as f64 * 0.1))
        .collect();
    let cfg = config(Some(82.0), 90 * 24 * 3_600, CapacityModelKind::Linear);
    let out = dispose_capacity(
        CapacityRow {
            series_key: "svc/disk".to_string(),
            points,
        },
        &cfg,
    );

    match out.disposition {
        Disposition::Projected(f) => {
            assert_eq!(f.projected_exhaustion_at_unix_micros, None);
            assert!(f.raw_projected_value > 200.0);
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

/// Flat/decreasing trend below the threshold is not a runway forecast.
#[test]
fn decreasing_trend_is_not_significant() {
    let cfg = config(Some(100.0), 24 * 3_600, CapacityModelKind::Linear);
    let points: Vec<CapacityPoint> = (0..48).map(|h| point(h, 90.0 - h as f64 * 0.25)).collect();
    let out = dispose_capacity(
        CapacityRow {
            series_key: "s".to_string(),
            points,
        },
        &cfg,
    );
    assert_eq!(
        out.disposition,
        Disposition::Skipped {
            reason: "trend_not_significant".to_string()
        }
    );
}

#[test]
fn noisy_weak_positive_trend_is_not_significant() {
    let cfg = config(Some(80.0), 24 * 3_600, CapacityModelKind::Linear);

    let points: Vec<CapacityPoint> = (0..72)
        .map(|h| {
            let noise = if h % 2 == 0 { 8.0 } else { -8.0 };
            point(h, 40.0 + h as f64 * 0.02 + noise)
        })
        .collect();

    let out = dispose_capacity(
        CapacityRow {
            series_key: "s".to_string(),
            points,
        },
        &cfg,
    );

    assert_eq!(
        out.disposition,
        Disposition::Skipped {
            reason: "trend_not_significant".to_string()
        }
    );
}

#[test]
fn already_crossed_threshold_bypasses_trend_significance_gate() {
    let cfg = config(Some(80.0), 24 * 3_600, CapacityModelKind::Linear);
    let points: Vec<CapacityPoint> = (0..48).map(|h| point(h, 95.0 - h as f64 * 0.25)).collect();
    let out = dispose_capacity(
        CapacityRow {
            series_key: "s".to_string(),
            points,
        },
        &cfg,
    );

    match out.disposition {
        Disposition::Projected(f) => {
            assert!(f.current_value >= 80.0);
            assert!(f.slope_per_second < 0.0);
        }
        other => panic!("expected already-crossed Projected, got {other:?}"),
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

#[test]
fn bounded_linear_percent_projection_clamps_display_value_and_bands() {
    let cfg = CapacityConfig {
        value_min: Some(0.0),
        value_max: Some(100.0),
        ..config(Some(100.0), 24 * 3_600, CapacityModelKind::Linear)
    };

    let out = dispose_capacity(
        CapacityRow {
            series_key: "s".to_string(),
            points: linear_points(),
        },
        &cfg,
    );

    match out.disposition {
        Disposition::Projected(f) => {
            assert_eq!(f.model, "linear");
            assert!((f.projected_value - 81.0).abs() < 1e-9);
            assert!((f.raw_projected_value - 81.0).abs() < 1e-9);
            assert!(!f.projection_bounded);
            assert!((f.lower_bound - 81.0).abs() < 1e-9);
            assert!((f.upper_bound - 81.0).abs() < 1e-9);
            assert_eq!(
                f.projected_exhaustion_at_unix_micros,
                Some(START_MICROS + 90 * 3_600 * MICROS_PER_SECOND)
            );
        }
        other => panic!("expected Projected, got {other:?}"),
    }

    let out = dispose_capacity(
        CapacityRow {
            series_key: "s".to_string(),
            points: (0..48).map(|h| point(h, 20.0 + h as f64 * 1.25)).collect(),
        },
        &cfg,
    );

    match out.disposition {
        Disposition::Projected(f) => {
            assert_eq!(f.model, "linear");
            assert_eq!(f.projected_value, 100.0);
            assert!(
                f.raw_projected_value > 100.0,
                "the diagnostic raw fit should preserve why the bounded display value was clamped"
            );
            assert!(f.projection_bounded);
            assert_eq!(f.lower_bound, 100.0);
            assert_eq!(f.upper_bound, 100.0);
            assert!(
                f.projected_exhaustion_at_unix_micros.is_some(),
                "clamping the display value must not erase the raw-fit ETA"
            );
        }
        other => panic!("expected Projected, got {other:?}"),
    }
}

#[test]
fn bounded_linear_percent_projection_clamps_negative_display_value() {
    let cfg = CapacityConfig {
        value_min: Some(0.0),
        value_max: Some(100.0),
        ..config(None, 24 * 3_600, CapacityModelKind::Linear)
    };

    let out = dispose_capacity(
        CapacityRow {
            series_key: "s".to_string(),
            points: (0..48).map(|h| point(h, 30.0 - h as f64)).collect(),
        },
        &cfg,
    );

    match out.disposition {
        Disposition::Projected(f) => {
            assert!(f.slope_per_second < 0.0);
            assert_eq!(f.projected_value, 0.0);
            assert!(f.raw_projected_value < 0.0);
            assert!(f.projection_bounded);
            assert_eq!(f.lower_bound, 0.0);
            assert_eq!(f.upper_bound, 0.0);
            assert_eq!(f.projected_exhaustion_at_unix_micros, None);
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
fn auto_seasonality_uses_all_complete_periods() {
    let cfg = CapacityConfig {
        min_history: 72,
        ..config(None, 24 * 3_600, CapacityModelKind::Auto)
    };

    let points: Vec<CapacityPoint> = (0..(4 * 24 + 6))
        .map(|h| {
            let period = h / 24;
            let slot = h % 24;
            let seasonal = if period == 0 {
                0.0
            } else if (8..=17).contains(&slot) {
                30.0
            } else {
                -12.0
            };

            point(h, 50.0 + seasonal)
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
            assert_eq!(f.sample_count, 4 * 24 + 6);
        }
        other => panic!("expected Holt-Winters Projected, got {other:?}"),
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

#[test]
fn bounded_holt_winters_percent_projection_clamps_display_value_and_bands() {
    let cfg = CapacityConfig {
        min_history: 48,
        value_min: Some(0.0),
        value_max: Some(100.0),
        ..config(Some(80.0), 24 * 3_600, CapacityModelKind::Seasonal)
    };

    let points: Vec<CapacityPoint> = (0..96)
        .map(|h| {
            let seasonal = if (h % 24) >= 8 && (h % 24) <= 17 {
                45.0
            } else {
                0.0
            };
            point(h, 40.0 + seasonal + h as f64 * 1.2)
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
            assert_eq!(f.projected_value, 100.0);
            assert!(f.raw_projected_value > 100.0);
            assert!(f.projection_bounded);
            assert!(f.lower_bound >= 0.0);
            assert!(f.upper_bound <= 100.0);
            assert!(
                f.projected_exhaustion_at_unix_micros.is_some(),
                "clamping the display value must not erase the raw-fit ETA"
            );
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

/// D2: the closed-form OLS prediction interval must WIDEN with the horizon (the
/// leverage term), unlike the old constant `± 1.96·RMSE` band; and `confidence` now
/// carries the 0.95 coverage level. This is the harness-checkable acceptance for 1.7.
#[test]
fn ols_prediction_interval_widens_with_horizon() {
    // A noisy linear series so the residuals — hence the interval — are non-zero.
    let points: Vec<_> = (0..60)
        .map(|h| point(h, 20.0 + h as f64 * 0.5 + ((h * 7 % 5) as f64 - 2.0)))
        .collect();
    let band = |horizon_seconds: i64| {
        let cfg = config(None, horizon_seconds, CapacityModelKind::Linear);
        match dispose_capacity(
            CapacityRow {
                series_key: "s".to_string(),
                points: points.clone(),
            },
            &cfg,
        )
        .disposition
        {
            Disposition::Projected(f) => {
                assert!((f.confidence - 0.95).abs() < 1e-9);
                assert!(f.lower_bound <= f.projected_value && f.upper_bound >= f.projected_value);
                f.upper_bound - f.lower_bound
            }
            other => panic!("expected Projected, got {other:?}"),
        }
    };
    let near = band(7 * 24 * 3_600);
    let far = band(365 * 24 * 3_600);
    assert!(near > 0.0, "a noisy fit must produce a non-zero PI");
    assert!(
        far > near,
        "the PI must widen with the horizon: far={far} near={near}"
    );
}

#[test]
fn bounded_projection_clamps_non_finite_raw_outputs() {
    let cfg = CapacityConfig {
        value_min: Some(0.0),
        value_max: Some(100.0),
        ..config(None, 24 * 3_600, CapacityModelKind::Linear)
    };

    let (projected, lower, upper, bounded) =
        bounded_projection(&cfg, f64::INFINITY, f64::INFINITY, f64::INFINITY);

    assert_eq!(projected, 100.0);
    assert_eq!(lower, 100.0);
    assert_eq!(upper, 100.0);
    assert!(bounded);

    let (projected, lower, upper, bounded) = bounded_projection(&cfg, f64::NAN, f64::NAN, f64::NAN);

    assert_eq!(projected, 0.0);
    assert_eq!(lower, 0.0);
    assert_eq!(upper, 0.0);
    assert!(bounded);
}
