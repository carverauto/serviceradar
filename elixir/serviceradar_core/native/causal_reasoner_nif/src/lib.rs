use deep_causality_core::CausalFlow;
use deep_causality_data_structures::{SlidingWindow, VectorStorage, window_type};
use rustler::NifMap;

const DEFAULT_MIN_SAMPLES: usize = 30;
const DEFAULT_WINDOW_SIZE: usize = 300;
const DEFAULT_N_SIGMA: f64 = 3.0;
const DEFAULT_CONFIRM_SLOTS: usize = 5;
const WINDOW_CAPACITY_MULTIPLE: usize = 2;

type BaselineWindow = SlidingWindow<VectorStorage<f64>, f64>;

#[derive(Clone, Debug, NifMap)]
struct ReasonContext {
    baseline: Vec<f64>,
    seasonal_baseline: Option<Vec<f64>>,
    trend_baseline: Option<Vec<f64>>,
    rolling_enabled: Option<bool>,
    seasonal_enabled: Option<bool>,
    trend_enabled: Option<bool>,
    min_samples: Option<usize>,
    seasonal_min_samples: Option<usize>,
    trend_min_samples: Option<usize>,
    window_size: Option<usize>,
    n_sigma: Option<f64>,
    seasonal_n_sigma: Option<f64>,
    trend_n_sigma: Option<f64>,
    confirm_slots: Option<usize>,
    consecutive_anomalous: Option<usize>,
}

#[derive(Clone, Copy, Debug, NifMap)]
struct ReasonSample {
    value: f64,
    observed_at_unix_nano: Option<u64>,
}

#[derive(Debug, PartialEq, NifMap)]
struct ReasonVerdict {
    state: String,
    anomalous: bool,
    breached: bool,
    include_in_baseline: bool,
    next_consecutive_anomalous: usize,
    score: f64,
    reason: String,
    baseline_count: usize,
    sample_value: f64,
    observed_at_unix_nano: Option<u64>,
    signals: Vec<SignalVerdict>,
}

#[derive(Clone, Debug, PartialEq, NifMap)]
struct SignalVerdict {
    name: String,
    enabled: bool,
    ready: bool,
    breached: bool,
    score: f64,
    threshold: f64,
    sample_count: usize,
    mean: Option<f64>,
    stddev: Option<f64>,
    reason: String,
}

#[derive(Clone, Copy, Debug)]
struct BaselineStats {
    mean: f64,
    stddev: f64,
}

struct DetectorThresholds {
    rolling_enabled: bool,
    min_samples: usize,
    window_size: usize,
    n_sigma: f64,
    confirm_slots: usize,
    seasonal_baseline: Vec<f64>,
    seasonal_enabled: bool,
    seasonal_min_samples: usize,
    seasonal_n_sigma: f64,
    trend_baseline: Vec<f64>,
    trend_enabled: bool,
    trend_min_samples: usize,
    trend_n_sigma: f64,
}

struct DetectorState {
    rolling_window: BaselineWindow,
    consecutive_anomalous: usize,
    sample: ReasonSample,
}

enum DetectorCommand {
    EvaluateSample,
}

enum DetectorValue {
    Command(DetectorCommand),
    Evaluation(DetectionEvaluation),
    Verdict(ReasonVerdict),
}

struct DetectionEvaluation {
    signals: Vec<SignalVerdict>,
    ready: bool,
    breached: bool,
    score: f64,
    rolling_sample_count: usize,
}

impl SignalVerdict {
    fn disabled(name: &str, threshold: f64) -> Self {
        Self {
            name: name.to_string(),
            enabled: false,
            ready: false,
            breached: false,
            score: 0.0,
            threshold,
            sample_count: 0,
            mean: None,
            stddev: None,
            reason: "signal disabled".to_string(),
        }
    }

    fn not_ready(name: &str, threshold: f64, sample_count: usize, reason: String) -> Self {
        Self {
            name: name.to_string(),
            enabled: true,
            ready: false,
            breached: false,
            score: 0.0,
            threshold,
            sample_count,
            mean: None,
            stddev: None,
            reason,
        }
    }

    fn ready(
        name: &str,
        breached: bool,
        score: f64,
        threshold: f64,
        sample_count: usize,
        stats: BaselineStats,
        reason: String,
    ) -> Self {
        Self {
            name: name.to_string(),
            enabled: true,
            ready: true,
            breached,
            score,
            threshold,
            sample_count,
            mean: Some(stats.mean),
            stddev: Some(stats.stddev),
            reason,
        }
    }
}

#[rustler::nif(schedule = "DirtyCpu")]
fn reason(context: ReasonContext, sample: ReasonSample) -> Result<ReasonVerdict, String> {
    reason_impl(context, sample)
}

fn reason_impl(context: ReasonContext, sample: ReasonSample) -> Result<ReasonVerdict, String> {
    if !sample.value.is_finite() {
        return Err("sample value must be finite".to_string());
    }

    let thresholds = DetectorThresholds::from_context(&context);
    let state = DetectorState::from_context(context, sample, thresholds.window_size);

    CausalFlow::process(state)
        .context(thresholds)
        .map(|()| DetectorValue::Command(DetectorCommand::EvaluateSample))
        .update_value_state_context(evaluate_detector_command)
        .branch_with(
            |value, _state, _context| {
                matches!(value, DetectorValue::Evaluation(evaluation) if evaluation.breached)
            },
            |breach| {
                breach.update_state(|mut state, _value| {
                    state.consecutive_anomalous = state.consecutive_anomalous.saturating_add(1);
                    state
                })
            },
            |clean| {
                clean.update_state(|mut state, _value| {
                    state.consecutive_anomalous = 0;
                    state.rolling_window.push(state.sample.value);
                    state
                })
            },
        )
        .update_value_state_context(finalize_detector_verdict)
        .finish()
        .and_then(|value| match value {
            DetectorValue::Verdict(verdict) => Ok(verdict),
            _ => Err(deep_causality_core::CausalityError::new(
                deep_causality_core::CausalityErrorEnum::ValueNotAvailable,
            )),
        })
        .map_err(|err| err.to_string())
}

impl DetectorThresholds {
    fn from_context(context: &ReasonContext) -> Self {
        let window_size = context.window_size.unwrap_or(DEFAULT_WINDOW_SIZE).max(1);
        let min_samples = context.min_samples.unwrap_or(DEFAULT_MIN_SAMPLES).max(1);
        let n_sigma = clean_threshold(context.n_sigma.unwrap_or(DEFAULT_N_SIGMA));
        let confirm_slots = context
            .confirm_slots
            .unwrap_or(DEFAULT_CONFIRM_SLOTS)
            .max(1);
        let seasonal_enabled = context.seasonal_enabled.unwrap_or_else(|| {
            context
                .seasonal_baseline
                .as_ref()
                .is_some_and(|values| !values.is_empty())
        });
        let trend_enabled = context.trend_enabled.unwrap_or_else(|| {
            context
                .trend_baseline
                .as_ref()
                .is_some_and(|values| !values.is_empty())
        });

        Self {
            rolling_enabled: context.rolling_enabled.unwrap_or(true),
            min_samples,
            window_size,
            n_sigma,
            confirm_slots,
            seasonal_baseline: context.seasonal_baseline.clone().unwrap_or_default(),
            seasonal_enabled,
            seasonal_min_samples: context.seasonal_min_samples.unwrap_or(min_samples).max(1),
            seasonal_n_sigma: clean_threshold(context.seasonal_n_sigma.unwrap_or(n_sigma)),
            trend_baseline: context.trend_baseline.clone().unwrap_or_default(),
            trend_enabled,
            trend_min_samples: context.trend_min_samples.unwrap_or(min_samples).max(1),
            trend_n_sigma: clean_threshold(context.trend_n_sigma.unwrap_or(n_sigma)),
        }
    }
}

impl DetectorState {
    fn from_context(context: ReasonContext, sample: ReasonSample, window_size: usize) -> Self {
        Self {
            rolling_window: baseline_window(&context.baseline, window_size),
            consecutive_anomalous: context.consecutive_anomalous.unwrap_or_default(),
            sample,
        }
    }
}

fn evaluate_detector_command(
    value: DetectorValue,
    state: DetectorState,
    context: Option<DetectorThresholds>,
) -> (DetectorValue, DetectorState, Option<DetectorThresholds>) {
    let Some(thresholds) = context.as_ref() else {
        return (value, state, context);
    };

    let value = match value {
        DetectorValue::Command(DetectorCommand::EvaluateSample) => {
            DetectorValue::Evaluation(evaluate_detector(&state, thresholds))
        }
        value => value,
    };

    (value, state, context)
}

fn evaluate_detector(
    state: &DetectorState,
    thresholds: &DetectorThresholds,
) -> DetectionEvaluation {
    let rolling_values = state.rolling_window.vec().unwrap_or_default();
    let signals = vec![
        evaluate_signal_window(
            "rolling",
            rolling_values,
            thresholds.rolling_enabled,
            thresholds.min_samples,
            thresholds.n_sigma,
            state.sample.value,
        ),
        evaluate_signal(
            "seasonal",
            &thresholds.seasonal_baseline,
            thresholds.seasonal_enabled,
            thresholds.seasonal_min_samples,
            thresholds.window_size,
            thresholds.seasonal_n_sigma,
            state.sample.value,
        ),
        evaluate_signal(
            "trend",
            &thresholds.trend_baseline,
            thresholds.trend_enabled,
            thresholds.trend_min_samples,
            thresholds.window_size,
            thresholds.trend_n_sigma,
            state.sample.value,
        ),
    ];

    let ready = signals.iter().any(|signal| signal.ready);
    let breached = signals.iter().any(|signal| signal.breached);
    let score = signals
        .iter()
        .filter(|signal| signal.ready)
        .map(|signal| signal.score)
        .fold(0.0, f64::max);
    let rolling_sample_count = signals
        .iter()
        .find(|signal| signal.name == "rolling")
        .map(|signal| signal.sample_count)
        .unwrap_or_default();

    DetectionEvaluation {
        signals,
        ready,
        breached,
        score,
        rolling_sample_count,
    }
}

fn finalize_detector_verdict(
    value: DetectorValue,
    state: DetectorState,
    context: Option<DetectorThresholds>,
) -> (DetectorValue, DetectorState, Option<DetectorThresholds>) {
    let DetectorValue::Evaluation(evaluation) = value else {
        return (value, state, context);
    };
    let Some(thresholds) = context.as_ref() else {
        return (DetectorValue::Evaluation(evaluation), state, context);
    };

    let anomalous = evaluation.breached && state.consecutive_anomalous >= thresholds.confirm_slots;
    let include_in_baseline = !evaluation.breached;
    let verdict_state = if !evaluation.ready {
        "insufficient_baseline"
    } else if anomalous {
        "anomalous"
    } else if evaluation.breached {
        "pending_anomaly"
    } else {
        "clean"
    };
    let reason = reason_for_state(
        verdict_state,
        &evaluation.signals,
        thresholds.confirm_slots,
        state.consecutive_anomalous,
    );

    (
        DetectorValue::Verdict(ReasonVerdict {
            state: verdict_state.to_string(),
            anomalous,
            breached: evaluation.breached,
            include_in_baseline,
            next_consecutive_anomalous: state.consecutive_anomalous,
            score: evaluation.score,
            reason,
            baseline_count: evaluation.rolling_sample_count,
            sample_value: state.sample.value,
            observed_at_unix_nano: state.sample.observed_at_unix_nano,
            signals: evaluation.signals,
        }),
        state,
        context,
    )
}

fn baseline_window(values: &[f64], window_size: usize) -> BaselineWindow {
    let clean_values = values
        .iter()
        .copied()
        .filter(|value| value.is_finite())
        .collect::<Vec<_>>();
    let effective_size = clean_values.len().min(window_size.max(1)).max(1);
    let mut window = window_type::new_with_vector_storage(effective_size, WINDOW_CAPACITY_MULTIPLE);

    for value in clean_values {
        window.push(value);
    }

    window
}

fn window_values(values: &[f64], window_size: usize) -> Vec<f64> {
    baseline_window(values, window_size)
        .vec()
        .unwrap_or_default()
}

fn evaluate_signal(
    name: &str,
    baseline: &[f64],
    enabled: bool,
    min_samples: usize,
    window_size: usize,
    threshold: f64,
    sample_value: f64,
) -> SignalVerdict {
    if !enabled {
        return SignalVerdict::disabled(name, threshold);
    }

    let window = window_values(baseline, window_size);
    evaluate_signal_window(name, window, enabled, min_samples, threshold, sample_value)
}

fn evaluate_signal_window(
    name: &str,
    window: Vec<f64>,
    enabled: bool,
    min_samples: usize,
    threshold: f64,
    sample_value: f64,
) -> SignalVerdict {
    if !enabled {
        return SignalVerdict::disabled(name, threshold);
    }

    if window.len() < min_samples || window.len() < 2 {
        return SignalVerdict::not_ready(
            name,
            threshold,
            window.len(),
            format!(
                "{name} baseline has {} clean samples; requires at least {}",
                window.len(),
                min_samples.max(2)
            ),
        );
    }

    let stats = sample_stats(&window);
    let score = z_score(sample_value, stats, threshold);
    let breached = score >= threshold;
    let reason = if breached {
        format!("{name} z-score {score:.3} breached {threshold:.3}")
    } else {
        format!("{name} z-score {score:.3} is below {threshold:.3}")
    };

    SignalVerdict::ready(
        name,
        breached,
        score,
        threshold,
        window.len(),
        stats,
        reason,
    )
}

fn sample_stats(values: &[f64]) -> BaselineStats {
    let count = values.len() as f64;
    let mean = values.iter().sum::<f64>() / count;
    let variance = values
        .iter()
        .map(|value| {
            let delta = value - mean;
            delta * delta
        })
        .sum::<f64>()
        / (count - 1.0);

    BaselineStats {
        mean,
        stddev: variance.max(0.0).sqrt(),
    }
}

fn z_score(sample_value: f64, stats: BaselineStats, threshold: f64) -> f64 {
    if stats.stddev <= f64::EPSILON {
        if (sample_value - stats.mean).abs() <= f64::EPSILON {
            0.0
        } else {
            threshold + 1.0
        }
    } else {
        ((sample_value - stats.mean) / stats.stddev).abs()
    }
}

fn clean_threshold(threshold: f64) -> f64 {
    if threshold.is_finite() && threshold > 0.0 {
        threshold
    } else {
        DEFAULT_N_SIGMA
    }
}

fn reason_for_state(
    state: &str,
    signals: &[SignalVerdict],
    confirm_slots: usize,
    next_consecutive_anomalous: usize,
) -> String {
    match state {
        "insufficient_baseline" => {
            let reasons = signals
                .iter()
                .filter(|signal| signal.enabled && !signal.ready)
                .map(|signal| signal.reason.as_str())
                .collect::<Vec<_>>()
                .join("; ");

            if reasons.is_empty() {
                "no enabled signal has enough clean baseline samples".to_string()
            } else {
                reasons
            }
        }
        "anomalous" => format!(
            "breach confirmed after {next_consecutive_anomalous}/{confirm_slots} consecutive anomalous slots"
        ),
        "pending_anomaly" => format!(
            "breach pending confirmation at {next_consecutive_anomalous}/{confirm_slots} consecutive anomalous slots"
        ),
        _ => "all ready signals are clean; consecutive anomalous slots reset".to_string(),
    }
}

rustler::init!("Elixir.ServiceRadar.Observability.CausalReasoner.Native");

#[cfg(test)]
mod tests {
    use super::*;

    fn context(baseline: Vec<f64>, min_samples: usize) -> ReasonContext {
        ReasonContext {
            baseline,
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
        assert_eq!(verdict.score, 4.0);
        assert!(verdict.score.is_finite());
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
}
