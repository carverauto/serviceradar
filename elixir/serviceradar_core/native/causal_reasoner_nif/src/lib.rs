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
    min_samples: Option<usize>,
    window_size: Option<usize>,
    n_sigma: Option<f64>,
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
    score: f64,
    reason: String,
    baseline_count: usize,
    sample_value: f64,
    observed_at_unix_nano: Option<u64>,
}

#[rustler::nif(schedule = "DirtyCpu")]
fn reason(context: ReasonContext, sample: ReasonSample) -> Result<ReasonVerdict, String> {
    reason_impl(context, sample)
}

fn reason_impl(context: ReasonContext, sample: ReasonSample) -> Result<ReasonVerdict, String> {
    CausalFlow::value((context, sample))
        .map(|(context, sample)| baseline_gate(context, sample))
        .finish()
        .map_err(|err| err.to_string())
}

fn baseline_gate(context: ReasonContext, sample: ReasonSample) -> ReasonVerdict {
    let baseline = clean_finite_baseline(&context.baseline);
    let window_size = context.window_size.unwrap_or(DEFAULT_WINDOW_SIZE).max(1);
    let min_samples = context.min_samples.unwrap_or(DEFAULT_MIN_SAMPLES).max(1);
    let n_sigma = context.n_sigma.unwrap_or(DEFAULT_N_SIGMA);
    let confirm_slots = context.confirm_slots.unwrap_or(DEFAULT_CONFIRM_SLOTS);
    let consecutive_anomalous = context.consecutive_anomalous.unwrap_or_default();
    let filled_window_count = flow_window_count(&baseline, window_size);

    let (state, reason) = if baseline.len() < min_samples {
        (
            "insufficient_baseline",
            format!(
                "baseline has {} clean samples; requires at least {}",
                baseline.len(),
                min_samples
            ),
        )
    } else {
        (
            "ready",
            format!(
                "baseline ready for Phase 1.2 z-score evaluation (n_sigma={n_sigma}, confirm_slots={confirm_slots}, consecutive_anomalous={consecutive_anomalous})"
            ),
        )
    };

    ReasonVerdict {
        state: state.to_string(),
        anomalous: false,
        score: 0.0,
        reason,
        baseline_count: filled_window_count,
        sample_value: sample.value,
        observed_at_unix_nano: sample.observed_at_unix_nano,
    }
}

fn clean_finite_baseline(values: &[f64]) -> Vec<f64> {
    values
        .iter()
        .copied()
        .filter(|value| value.is_finite())
        .collect()
}

fn flow_window_count(values: &[f64], window_size: usize) -> usize {
    let multiple = DEFAULT_WINDOW_MULTIPLE.max(1);
    let mut window = window_type::new_with_vector_storage(window_size, multiple);

    for value in values.iter().copied().rev().take(window_size).rev() {
        window.push(value);
    }

    let _ = window.size();

    values.len().min(window_size)
}

rustler::init!("Elixir.ServiceRadar.Observability.CausalReasoner.Native");

#[cfg(test)]
mod tests {
    use super::*;

    fn context(baseline: Vec<f64>, min_samples: usize) -> ReasonContext {
        ReasonContext {
            baseline,
            min_samples: Some(min_samples),
            window_size: Some(4),
            n_sigma: Some(3.0),
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
        assert_eq!(first.state, "ready");
        assert_eq!(first.baseline_count, 4);
    }

    #[test]
    fn ignores_non_finite_baseline_values() {
        let verdict = reason_impl(
            context(vec![1.0, f64::NAN, 2.0, f64::INFINITY, 3.0], 3),
            sample(9.0),
        )
        .unwrap();

        assert_eq!(verdict.state, "ready");
        assert_eq!(verdict.baseline_count, 3);
    }
}
