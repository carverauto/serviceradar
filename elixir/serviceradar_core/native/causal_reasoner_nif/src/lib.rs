use deep_causality_core::CausalFlow;
use deep_causality_data_structures::window_type;
use rustler::NifMap;

const DEFAULT_MIN_SAMPLES: usize = 30;
const DEFAULT_WINDOW_SIZE: usize = 300;
const DEFAULT_N_SIGMA: f64 = 3.0;
const DEFAULT_CONFIRM_SLOTS: usize = 5;
const DEFAULT_WINDOW_MULTIPLE: usize = 2;

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

    CausalFlow::value((context, sample))
        .map(|(context, sample)| baseline_gate(context, sample))
        .finish()
        .map_err(|err| err.to_string())
}

fn baseline_gate(context: ReasonContext, sample: ReasonSample) -> ReasonVerdict {
    let window_size = context.window_size.unwrap_or(DEFAULT_WINDOW_SIZE).max(1);
    let min_samples = context.min_samples.unwrap_or(DEFAULT_MIN_SAMPLES).max(1);
    let n_sigma = clean_threshold(context.n_sigma.unwrap_or(DEFAULT_N_SIGMA));
    let confirm_slots = context
        .confirm_slots
        .unwrap_or(DEFAULT_CONFIRM_SLOTS)
        .max(1);
    let consecutive_anomalous = context.consecutive_anomalous.unwrap_or_default();
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

    let signals = vec![
        evaluate_signal(
            "rolling",
            &context.baseline,
            context.rolling_enabled.unwrap_or(true),
            min_samples,
            window_size,
            n_sigma,
            sample.value,
        ),
        evaluate_signal(
            "seasonal",
            context.seasonal_baseline.as_deref().unwrap_or(&[]),
            seasonal_enabled,
            context.seasonal_min_samples.unwrap_or(min_samples).max(1),
            window_size,
            clean_threshold(context.seasonal_n_sigma.unwrap_or(n_sigma)),
            sample.value,
        ),
        evaluate_signal(
            "trend",
            context.trend_baseline.as_deref().unwrap_or(&[]),
            trend_enabled,
            context.trend_min_samples.unwrap_or(min_samples).max(1),
            window_size,
            clean_threshold(context.trend_n_sigma.unwrap_or(n_sigma)),
            sample.value,
        ),
    ];

    let ready = signals.iter().any(|signal| signal.ready);
    let breached = signals.iter().any(|signal| signal.breached);
    let score = signals
        .iter()
        .filter(|signal| signal.ready)
        .map(|signal| signal.score)
        .fold(0.0, f64::max);
    let next_consecutive_anomalous = if breached {
        consecutive_anomalous.saturating_add(1)
    } else {
        0
    };
    let anomalous = breached && next_consecutive_anomalous >= confirm_slots;
    let include_in_baseline = !breached;
    let state = if !ready {
        "insufficient_baseline"
    } else if anomalous {
        "anomalous"
    } else if breached {
        "pending_anomaly"
    } else {
        "clean"
    };
    let baseline_count = signals
        .iter()
        .find(|signal| signal.name == "rolling")
        .map(|signal| signal.sample_count)
        .unwrap_or_default();
    let reason = reason_for_state(state, &signals, confirm_slots, next_consecutive_anomalous);

    ReasonVerdict {
        state: state.to_string(),
        anomalous,
        breached,
        include_in_baseline,
        next_consecutive_anomalous,
        score,
        reason,
        baseline_count,
        sample_value: sample.value,
        observed_at_unix_nano: sample.observed_at_unix_nano,
        signals,
    }
}

fn clean_finite_baseline(values: &[f64]) -> Vec<f64> {
    values
        .iter()
        .copied()
        .filter(|value| value.is_finite())
        .collect()
}

fn window_values(values: &[f64], window_size: usize) -> Vec<f64> {
    let values = clean_finite_baseline(values);
    let multiple = DEFAULT_WINDOW_MULTIPLE.max(1);
    let mut window = window_type::new_with_vector_storage(window_size, multiple);
    let recent: Vec<f64> = values
        .iter()
        .copied()
        .rev()
        .take(window_size)
        .collect::<Vec<_>>()
        .into_iter()
        .rev()
        .collect();

    for value in recent.iter().copied() {
        window.push(value);
    }

    let _ = window.size();

    recent
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
}
