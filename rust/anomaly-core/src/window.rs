// Copyright 2026 Carver Automation Corporation.
//
// Licensed under the Apache License, Version 2.0 (the "License").
// SPDX-License-Identifier: Apache-2.0

//! Sliding-window helpers for baseline reconstruction.

use crate::WINDOW_CAPACITY_MULTIPLE;
use crate::stats::{RobustStats, WelfordAcc};
use crate::types::ReasonContext;
use deep_causality_data_structures::{SlidingWindow, VectorStorage, window_type};

pub type BaselineWindow = SlidingWindow<VectorStorage<f64>, f64>;

/// Rebuild the rolling baseline from the retained clean window: the bounded
/// `window_tail`, the robust median/MAD estimator the detector scores against, and
/// the Welford mean/std summary retained as the persisted next-state (the rolling
/// SCORE itself is the robust [`RobustStats`], not the Welford acc).
pub fn compact_rolling_state(
    context: &ReasonContext,
    window_size: usize,
) -> (Vec<f64>, WelfordAcc, RobustStats) {
    let source = context.window_tail.as_ref().unwrap_or(&context.baseline);
    let clean_values = clean_window_values(source, window_size);

    // This is the STATELESS path (reason / reason_batch and checkpoint restore).
    // The robust median/MAD estimator the detector scores against is rebuilt from
    // the window itself (an O(window log window) sort — the deliberate cost of the
    // Hampel estimator over the O(1)-updatable Welford), so a single large spike in
    // the window cannot poison the center/scale and mask a second spike.
    let robust = RobustStats::from_values(&clean_values);

    // The Welford mean/std summary is retained as the persisted `next_rolling_acc`
    // next-state only (a valid summary for a checkpoint consumer); it no longer
    // drives the rolling score. The caller-supplied `rolling_acc` is transported
    // across the BEAM/NIF boundary with no provenance guarantee, so — as before —
    // we always rebuild from `clean_values` rather than trusting the transported
    // acc (which `valid_for_count` cannot prove consistent with the window).
    let acc = WelfordAcc::from_values(&clean_values);

    (clean_values, acc, robust)
}

pub fn window_values(values: &[f64], window_size: usize) -> Vec<f64> {
    baseline_window(values, window_size)
        .vec()
        .unwrap_or_default()
}

fn baseline_window(values: &[f64], window_size: usize) -> BaselineWindow {
    let clean_values = clean_window_values(values, window_size);
    let effective_size = clean_values.len().min(window_size.max(1)).max(1);
    let mut window = window_type::new_with_vector_storage(effective_size, WINDOW_CAPACITY_MULTIPLE);

    for value in clean_values {
        window.push(value);
    }

    window
}

fn clean_window_values(values: &[f64], window_size: usize) -> Vec<f64> {
    values
        .iter()
        .copied()
        .filter(|value| value.is_finite())
        .collect::<Vec<_>>()
        .into_iter()
        .rev()
        .take(window_size.max(1))
        .collect::<Vec<_>>()
        .into_iter()
        .rev()
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::types::ReasonContext;

    fn context_with_window(
        window_tail: Vec<f64>,
        rolling_acc: Option<WelfordAcc>,
    ) -> ReasonContext {
        ReasonContext {
            baseline: Vec::new(),
            rolling_acc,
            window_tail: Some(window_tail),
            seasonal_baseline: None,
            trend_baseline: None,
            rolling_enabled: Some(true),
            seasonal_enabled: None,
            trend_enabled: None,
            min_samples: Some(3),
            seasonal_min_samples: None,
            trend_min_samples: None,
            window_size: Some(4),
            n_sigma: Some(3.0),
            seasonal_n_sigma: None,
            trend_n_sigma: None,
            confirm_slots: Some(5),
            consecutive_anomalous: Some(0),
            min_std_floor: None,
            min_cv: None,
            saturation_gate: None,
        }
    }

    #[test]
    fn stale_count_matching_acc_is_recomputed_from_window() {
        let window_tail = vec![100.0, 101.0, 99.0, 100.0];
        let stale = WelfordAcc {
            count: window_tail.len(),
            mean: 0.0,
            m2: 0.0,
        };
        assert!(
            stale.valid_for_count(window_tail.len()),
            "test premise: the stale acc must look valid by count to exercise the fix"
        );

        let (values, acc, robust) =
            compact_rolling_state(&context_with_window(window_tail.clone(), Some(stale)), 4);

        let expected = WelfordAcc::from_values(&values);
        assert_eq!(
            acc, expected,
            "stateless path must recompute the acc from window_tail, not trust the stale acc"
        );
        assert!(
            (acc.mean - 100.0).abs() < 1.0,
            "recomputed mean {} should reflect the real window, not the stale 0.0",
            acc.mean
        );
        assert!(acc.mean != stale.mean || acc.m2 != stale.m2);
        // The robust estimator is rebuilt from the same window (median ~100).
        assert_eq!(robust, RobustStats::from_values(&values));
        assert!((robust.center - 100.0).abs() < 1.0);
    }

    #[test]
    fn correct_acc_still_yields_consistent_baseline() {
        let window_tail = vec![10.0, 12.0, 11.0, 13.0];
        let correct = WelfordAcc::from_values(&window_tail);
        let (values, acc, robust) =
            compact_rolling_state(&context_with_window(window_tail.clone(), Some(correct)), 4);

        assert_eq!(acc, WelfordAcc::from_values(&values));
        assert_eq!(acc, correct);
        assert_eq!(robust, RobustStats::from_values(&values));
    }

    #[test]
    fn missing_acc_recomputes_from_window() {
        let window_tail = vec![1.0, 2.0, 3.0];
        let (values, acc, robust) =
            compact_rolling_state(&context_with_window(window_tail, None), 4);
        assert_eq!(acc, WelfordAcc::from_values(&values));
        assert_eq!(acc.count, 3);
        assert_eq!(robust, RobustStats::from_values(&values));
    }
}
