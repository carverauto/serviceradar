// Copyright 2026 Carver Automation Corporation.
//
// Licensed under the Apache License, Version 2.0 (the "License").
// SPDX-License-Identifier: Apache-2.0

//! Sliding-window helpers for baseline reconstruction.

use crate::WINDOW_CAPACITY_MULTIPLE;
use crate::stats::WelfordAcc;
use crate::types::ReasonContext;
use deep_causality_data_structures::{SlidingWindow, VectorStorage, window_type};

pub type BaselineWindow = SlidingWindow<VectorStorage<f64>, f64>;

pub fn compact_rolling_state(
    context: &ReasonContext,
    window_size: usize,
) -> (Vec<f64>, WelfordAcc) {
    let source = context.window_tail.as_ref().unwrap_or(&context.baseline);
    let clean_values = clean_window_values(source, window_size);

    // This is the STATELESS path (reason / reason_batch and checkpoint restore).
    // The caller-supplied `rolling_acc` is transported across the BEAM/NIF
    // boundary with no provenance guarantee, and `valid_for_count` only checks
    // count + finiteness — NOT that mean/m2 are consistent with `clean_values`.
    // A count-matching-but-stale acc would therefore install a wrong baseline,
    // and unlike the stateful runtime there is no eviction-driven recompute
    // guard to heal it here. Since `clean_values` is already bounded to
    // `window_size` (so recompute is O(window)), we always rebuild the acc from
    // the window itself instead of trusting the transported one. The
    // transported-acc fast path is retained only in the stateful `reason_state_*`
    // flow where provenance is guaranteed.
    let acc = WelfordAcc::from_values(&clean_values);

    (clean_values, acc)
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

        let (values, acc) =
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
    }

    #[test]
    fn correct_acc_still_yields_consistent_baseline() {
        let window_tail = vec![10.0, 12.0, 11.0, 13.0];
        let correct = WelfordAcc::from_values(&window_tail);
        let (values, acc) =
            compact_rolling_state(&context_with_window(window_tail.clone(), Some(correct)), 4);

        assert_eq!(acc, WelfordAcc::from_values(&values));
        assert_eq!(acc, correct);
    }

    #[test]
    fn missing_acc_recomputes_from_window() {
        let window_tail = vec![1.0, 2.0, 3.0];
        let (values, acc) = compact_rolling_state(&context_with_window(window_tail, None), 4);
        assert_eq!(acc, WelfordAcc::from_values(&values));
        assert_eq!(acc.count, 3);
    }
}
