use crate::detector::reason_impl;
use crate::reason_batch_impl;
use crate::stats::{WelfordAcc, sample_stats};
use crate::types::{ReasonBatchInput, ReasonContext, ReasonSample, ReasonVerdict};
use crate::window::window_values;

fn context(baseline: Vec<f64>, min_samples: usize) -> ReasonContext {
    ReasonContext {
        baseline,
        rolling_acc: None,
        window_tail: None,
        seasonal_baseline: None,
        trend_baseline: None,
        rolling_enabled: Some(true),
        seasonal_enabled: None,
        trend_enabled: None,
        min_samples: Some(min_samples),
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

fn sample(value: f64) -> ReasonSample {
    ReasonSample {
        value,
        observed_at_unix_nano: Some(42),
    }
}

#[test]
fn reports_insufficient_baseline_without_state() {
    let verdict = reason_impl(context(vec![1.0, 2.0], 3), sample(9.0)).unwrap();

    assert_eq!(verdict.state, "insufficient_baseline");
    assert!(!verdict.anomalous);
    assert!(!verdict.breached);
    assert!(verdict.include_in_baseline);
    assert_eq!(verdict.next_consecutive_anomalous, 0);
    assert_eq!(verdict.baseline_count, 2);
    assert_eq!(verdict.sample_value, 9.0);
}

#[test]
fn repeat_calls_are_deterministic() {
    let context = context(vec![1.0, 2.0, 3.0, 4.0, 5.0], 3);
    let sample = sample(9.0);

    let first = reason_impl(context.clone(), sample).unwrap();
    let second = reason_impl(context, sample).unwrap();

    assert_eq!(first, second);
    assert_eq!(first.state, "pending_anomaly");
    assert_eq!(first.baseline_count, 4);
    assert!(!first.include_in_baseline);
}

#[test]
fn ignores_non_finite_baseline_values() {
    let verdict = reason_impl(
        context(vec![1.0, f64::NAN, 2.0, f64::INFINITY, 3.0], 3),
        sample(9.0),
    )
    .unwrap();

    assert_eq!(verdict.state, "pending_anomaly");
    assert_eq!(verdict.baseline_count, 3);
}

#[test]
fn uses_sample_variance_for_z_score() {
    let verdict = reason_impl(context(vec![1.0, 2.0, 3.0], 3), sample(5.0)).unwrap();

    assert_eq!(verdict.state, "pending_anomaly");
    assert_eq!(verdict.score, 3.0);
    assert!(verdict.breached);
    assert!(!verdict.include_in_baseline);
}

#[test]
fn confirms_only_after_configured_consecutive_slots() {
    let mut context = context(vec![1.0, 2.0, 3.0], 3);
    context.confirm_slots = Some(2);
    context.consecutive_anomalous = Some(1);

    let verdict = reason_impl(context, sample(5.0)).unwrap();

    assert_eq!(verdict.state, "anomalous");
    assert!(verdict.anomalous);
    assert_eq!(verdict.next_consecutive_anomalous, 2);
    assert!(!verdict.include_in_baseline);
}

#[test]
fn clean_tick_resets_consecutive_slots() {
    let mut context = context(vec![1.0, 2.0, 3.0], 3);
    context.confirm_slots = Some(2);
    context.consecutive_anomalous = Some(1);

    let verdict = reason_impl(context, sample(2.0)).unwrap();

    assert_eq!(verdict.state, "clean");
    assert!(!verdict.anomalous);
    assert!(!verdict.breached);
    assert!(verdict.include_in_baseline);
    assert_eq!(verdict.next_consecutive_anomalous, 0);
}

#[test]
fn combines_seasonal_signal_when_rolling_is_not_ready() {
    let mut context = context(vec![1.0], 3);
    context.seasonal_baseline = Some(vec![10.0, 11.0, 12.0, 13.0]);
    context.seasonal_min_samples = Some(3);
    context.seasonal_n_sigma = Some(2.0);

    let verdict = reason_impl(context, sample(30.0)).unwrap();

    assert_eq!(verdict.state, "pending_anomaly");
    assert!(verdict.breached);
    assert_eq!(verdict.baseline_count, 1);
    assert!(
        verdict
            .signals
            .iter()
            .any(|signal| { signal.name == "seasonal" && signal.ready && signal.breached })
    );
}

#[test]
fn treats_zero_variance_spike_as_breach_without_infinite_score() {
    let verdict = reason_impl(context(vec![10.0, 10.0, 10.0], 3), sample(20.0)).unwrap();

    assert_eq!(verdict.state, "pending_anomaly");
    // Zero-variance breach score is now magnitude-aware (finding 3): it still
    // clears the historical breach floor (threshold + 1.0 == 4.0) and stays
    // finite, but grows with the deviation instead of collapsing to a constant.
    assert!(verdict.score.is_finite());
    assert!(verdict.score >= 4.0);
    assert!(!verdict.include_in_baseline);
}

#[test]
fn sustained_flood_does_not_self_mask_when_breached_samples_are_withheld() {
    let mut context = context(vec![100.0, 101.0, 99.0, 100.0], 3);
    context.confirm_slots = Some(3);

    let mut states = Vec::new();
    let mut baseline_lengths = Vec::new();

    for _ in 0..6 {
        let verdict = reason_impl(context.clone(), sample(180.0)).unwrap();

        states.push(verdict.state.clone());
        baseline_lengths.push(context.baseline.len());
        context.consecutive_anomalous = Some(verdict.next_consecutive_anomalous);

        if verdict.include_in_baseline {
            context.baseline.push(verdict.sample_value);
        }
    }

    assert_eq!(
        states,
        vec![
            "pending_anomaly",
            "pending_anomaly",
            "anomalous",
            "anomalous",
            "anomalous",
            "anomalous"
        ]
    );
    assert!(baseline_lengths.iter().all(|len| *len == 4));
    assert_eq!(context.baseline, vec![100.0, 101.0, 99.0, 100.0]);
}

#[test]
fn transient_spikes_do_not_cross_sustained_confirmation_gate() {
    let mut context = context(vec![100.0, 101.0, 99.0, 100.0], 3);
    context.confirm_slots = Some(2);

    let first_spike = reason_impl(context.clone(), sample(180.0)).unwrap();
    assert_eq!(first_spike.state, "pending_anomaly");
    assert!(!first_spike.anomalous);
    assert_eq!(first_spike.next_consecutive_anomalous, 1);

    context.consecutive_anomalous = Some(first_spike.next_consecutive_anomalous);
    let clean = reason_impl(context.clone(), sample(100.5)).unwrap();
    assert_eq!(clean.state, "clean");
    assert_eq!(clean.next_consecutive_anomalous, 0);

    context.consecutive_anomalous = Some(clean.next_consecutive_anomalous);
    context.baseline.push(clean.sample_value);

    let second_spike = reason_impl(context, sample(180.0)).unwrap();
    assert_eq!(second_spike.state, "pending_anomaly");
    assert!(!second_spike.anomalous);
    assert_eq!(second_spike.next_consecutive_anomalous, 1);
}

#[test]
fn reasoner_is_stateless_across_callers_with_same_context() {
    let context = context(vec![100.0, 101.0, 99.0, 100.0], 3);
    let sample = sample(180.0);

    let pod_a = reason_impl(context.clone(), sample).unwrap();
    let pod_b = reason_impl(context, sample).unwrap();

    assert_eq!(pod_a, pod_b);
    assert_eq!(pod_a.next_consecutive_anomalous, 1);
    assert_eq!(pod_b.next_consecutive_anomalous, 1);
}

#[test]
fn sliding_window_keeps_recent_clean_baseline_tail_in_order() {
    let window = window_values(&[1.0, f64::NAN, 2.0, 3.0, 4.0, 5.0], 3);

    assert_eq!(window, vec![3.0, 4.0, 5.0]);
}

#[test]
fn clean_verdict_returns_next_compact_state() {
    let verdict = reason_impl(context(vec![1.0, 2.0, 3.0], 3), sample(2.5)).unwrap();

    assert_eq!(verdict.state, "clean");
    assert_eq!(verdict.baseline_count, 3);
    assert_eq!(verdict.next_window_tail, vec![1.0, 2.0, 3.0, 2.5]);
    assert_eq!(verdict.next_rolling_acc.count, 4);
    assert_in_delta(verdict.next_rolling_acc.mean, 2.125, 1.0e-12);
}

#[test]
fn breached_verdict_does_not_admit_compact_state() {
    let verdict = reason_impl(context(vec![1.0, 2.0, 3.0], 3), sample(5.0)).unwrap();

    assert_eq!(verdict.state, "pending_anomaly");
    assert!(!verdict.include_in_baseline);
    assert_eq!(verdict.next_window_tail, vec![1.0, 2.0, 3.0]);
    assert_eq!(
        verdict.next_rolling_acc,
        WelfordAcc::from_values(&[1.0, 2.0, 3.0])
    );
}

#[test]
fn compact_state_matches_legacy_baseline_context() {
    let baseline = vec![100.0, 101.0, 99.0, 100.0];
    let legacy = context(baseline.clone(), 3);
    let mut compact = context(Vec::new(), 3);
    compact.window_tail = Some(baseline.clone());
    compact.rolling_acc = Some(WelfordAcc::from_values(&baseline));

    let legacy_verdict = reason_impl(legacy, sample(180.0)).unwrap();
    let compact_verdict = reason_impl(compact, sample(180.0)).unwrap();

    assert_eq!(legacy_verdict, compact_verdict);
}

#[test]
fn compact_state_keeps_large_counter_variance_stable() {
    let baseline = (1..=300)
        .map(|order| 1.0e9 + (order as f64).sin() + (order as f64 / 3.0).cos())
        .collect::<Vec<_>>();
    let mut context = context(Vec::new(), 30);
    context.window_size = Some(300);
    context.window_tail = Some(baseline.clone());
    context.rolling_acc = Some(WelfordAcc::from_values(&baseline));

    let verdict = reason_impl(context, sample(1.0e9 + 1.5)).unwrap();
    let rolling = verdict
        .signals
        .iter()
        .find(|signal| signal.name == "rolling")
        .unwrap();

    assert_eq!(verdict.state, "clean");
    assert!(rolling.stddev.unwrap() > 0.5);
    assert!(!verdict.breached);
}

#[test]
fn reason_batch_preserves_order_and_per_item_errors() {
    let results = reason_batch_impl(vec![
        ReasonBatchInput {
            context: context(vec![1.0, 2.0], 3),
            sample: sample(9.0),
        },
        ReasonBatchInput {
            context: context(vec![1.0, 2.0, 3.0], 3),
            sample: sample(f64::NAN),
        },
        ReasonBatchInput {
            context: context(vec![1.0, 2.0, 3.0], 3),
            sample: sample(2.0),
        },
    ]);

    assert_eq!(results.len(), 3);
    assert_eq!(
        results[0].ok.as_ref().unwrap().state,
        "insufficient_baseline"
    );
    assert_eq!(
        results[1].error.as_deref(),
        Some("sample value must be finite")
    );
    assert_eq!(results[2].ok.as_ref().unwrap().state, "clean");
}

#[test]
fn welford_remove_matches_two_pass_stats_after_eviction() {
    let mut acc = WelfordAcc::from_values(&[1.0e9 + 1.0, 1.0e9 + 2.0, 1.0e9 + 3.0]);
    acc.remove(1.0e9 + 1.0);
    acc.add(1.0e9 + 4.0);

    let incremental = acc.stats().unwrap();
    let two_pass = sample_stats(&[1.0e9 + 2.0, 1.0e9 + 3.0, 1.0e9 + 4.0]);

    assert_in_delta(incremental.mean, two_pass.mean, 1.0e-9);
    assert_in_delta(incremental.stddev, two_pass.stddev, 1.0e-9);
}

#[test]
fn compact_state_matches_two_pass_oracle_over_random_eviction_streams() {
    for seed in 1..=8 {
        for window_size in [4, 12, 64, 300] {
            let min_samples = (window_size / 2).clamp(3, 30);
            let mut legacy = context(Vec::new(), min_samples);
            legacy.window_size = Some(window_size);
            legacy.n_sigma = Some(2.75);
            legacy.confirm_slots = Some(3);

            let mut compact = legacy.clone();
            compact.window_tail = Some(Vec::new());
            compact.rolling_acc = Some(WelfordAcc::default());

            let mut rng = Lcg::new(seed * 1_000_003 + window_size as u64);

            for order in 1..=750 {
                let value = random_stream_value(&mut rng, seed, order);
                let sample = ReasonSample {
                    value,
                    observed_at_unix_nano: Some(order),
                };

                let expected = reason_impl(legacy.clone(), sample).unwrap();
                let actual = reason_impl(compact.clone(), sample).unwrap();

                assert_equivalent_verdict(&actual, &expected, seed, window_size, order);

                fold_legacy_context(&mut legacy, &expected);
                fold_compact_context(&mut compact, &actual);
            }
        }
    }
}

#[track_caller]
fn assert_in_delta(actual: f64, expected: f64, tolerance: f64) {
    assert!(
        (actual - expected).abs() <= tolerance,
        "expected {actual} to be within {tolerance} of {expected}"
    );
}

#[track_caller]
fn assert_close(actual: f64, expected: f64, absolute_tolerance: f64, relative_tolerance: f64) {
    let tolerance = absolute_tolerance.max(expected.abs() * relative_tolerance);

    assert!(
        (actual - expected).abs() <= tolerance,
        "expected {actual} to be within {tolerance} of {expected}"
    );
}

fn fold_legacy_context(context: &mut ReasonContext, verdict: &ReasonVerdict) {
    context.consecutive_anomalous = Some(verdict.next_consecutive_anomalous);

    if verdict.include_in_baseline {
        context.baseline.push(verdict.sample_value);
        let window_size = context.window_size.unwrap_or(4).max(1);

        if context.baseline.len() > window_size {
            let drop_count = context.baseline.len() - window_size;
            context.baseline.drain(0..drop_count);
        }
    }
}

fn fold_compact_context(context: &mut ReasonContext, verdict: &ReasonVerdict) {
    context.baseline.clear();
    context.consecutive_anomalous = Some(verdict.next_consecutive_anomalous);
    context.window_tail = Some(verdict.next_window_tail.clone());
    context.rolling_acc = Some(verdict.next_rolling_acc);
}

fn assert_equivalent_verdict(
    actual: &ReasonVerdict,
    expected: &ReasonVerdict,
    seed: u64,
    window_size: usize,
    order: u64,
) {
    let scope = format!("seed={seed} window_size={window_size} order={order}");

    assert_eq!(actual.state, expected.state, "{scope}");
    assert_eq!(actual.anomalous, expected.anomalous, "{scope}");
    assert_eq!(actual.breached, expected.breached, "{scope}");
    assert_eq!(
        actual.include_in_baseline, expected.include_in_baseline,
        "{scope}"
    );
    assert_eq!(
        actual.next_consecutive_anomalous, expected.next_consecutive_anomalous,
        "{scope}"
    );
    assert_eq!(actual.baseline_count, expected.baseline_count, "{scope}");
    assert_eq!(
        actual.next_window_tail, expected.next_window_tail,
        "{scope}"
    );
    assert_eq!(
        actual.next_rolling_acc.count, expected.next_rolling_acc.count,
        "{scope}"
    );
    assert_close(actual.score, expected.score, 0.25, 0.01);
    assert_in_delta(
        actual.next_rolling_acc.mean,
        expected.next_rolling_acc.mean,
        1.0e-3,
    );
    assert_in_delta(
        actual.next_rolling_acc.m2,
        expected.next_rolling_acc.m2,
        1.0e-1,
    );

    for (actual_signal, expected_signal) in actual.signals.iter().zip(expected.signals.iter()) {
        assert_eq!(actual_signal.name, expected_signal.name, "{scope}");
        assert_eq!(actual_signal.ready, expected_signal.ready, "{scope}");
        assert_eq!(actual_signal.breached, expected_signal.breached, "{scope}");
        assert_eq!(
            actual_signal.sample_count, expected_signal.sample_count,
            "{scope}"
        );
        assert_close(actual_signal.score, expected_signal.score, 0.25, 0.01);

        if let (Some(actual_mean), Some(expected_mean)) = (actual_signal.mean, expected_signal.mean)
        {
            assert_in_delta(actual_mean, expected_mean, 1.0e-3);
        }

        if let (Some(actual_stddev), Some(expected_stddev)) =
            (actual_signal.stddev, expected_signal.stddev)
        {
            assert_in_delta(actual_stddev, expected_stddev, 1.0e-3);
        }
    }
}

fn random_stream_value(rng: &mut Lcg, seed: u64, order: u64) -> f64 {
    let base = if seed % 2 == 0 { 1.0e9 } else { 100.0 };
    let periodic = (order as f64 / 7.0).sin() + (order as f64 / 19.0).cos();
    let jitter = (rng.next_unit() - 0.5) * 1.75;

    if order % 97 == 0 {
        base + 35.0 + jitter
    } else if order % 53 == 0 {
        base - 28.0 + jitter
    } else {
        base + periodic + jitter
    }
}

struct Lcg {
    state: u64,
}

impl Lcg {
    fn new(seed: u64) -> Self {
        Self { state: seed }
    }

    fn next_unit(&mut self) -> f64 {
        self.state = self
            .state
            .wrapping_mul(6_364_136_223_846_793_005)
            .wrapping_add(1);
        ((self.state >> 11) as f64) / ((1_u64 << 53) as f64)
    }
}
