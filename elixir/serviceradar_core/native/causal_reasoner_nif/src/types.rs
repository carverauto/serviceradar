use crate::stats::WelfordAcc;
use rustler::NifMap;

#[derive(Clone, Debug, NifMap)]
pub(crate) struct ReasonContext {
    pub(crate) baseline: Vec<f64>,
    pub(crate) rolling_acc: Option<WelfordAcc>,
    pub(crate) window_tail: Option<Vec<f64>>,
    pub(crate) seasonal_baseline: Option<Vec<f64>>,
    pub(crate) trend_baseline: Option<Vec<f64>>,
    pub(crate) rolling_enabled: Option<bool>,
    pub(crate) seasonal_enabled: Option<bool>,
    pub(crate) trend_enabled: Option<bool>,
    pub(crate) min_samples: Option<usize>,
    pub(crate) seasonal_min_samples: Option<usize>,
    pub(crate) trend_min_samples: Option<usize>,
    pub(crate) window_size: Option<usize>,
    pub(crate) n_sigma: Option<f64>,
    pub(crate) seasonal_n_sigma: Option<f64>,
    pub(crate) trend_n_sigma: Option<f64>,
    pub(crate) confirm_slots: Option<usize>,
    pub(crate) consecutive_anomalous: Option<usize>,
}

#[derive(Clone, Copy, Debug, NifMap)]
pub(crate) struct ReasonSample {
    pub(crate) value: f64,
    pub(crate) observed_at_unix_nano: Option<u64>,
}

#[derive(Clone, Debug, NifMap)]
pub(crate) struct ReasonBatchInput {
    pub(crate) context: ReasonContext,
    pub(crate) sample: ReasonSample,
}

#[derive(Debug, NifMap)]
pub(crate) struct ReasonBatchResult {
    pub(crate) ok: Option<ReasonVerdict>,
    pub(crate) error: Option<String>,
}

#[derive(Debug, NifMap)]
pub(crate) struct ReasonEventBatchResult {
    pub(crate) ok: Option<ReasonEventVerdict>,
    pub(crate) error: Option<String>,
}

#[derive(Debug, PartialEq, NifMap)]
pub(crate) struct ReasonVerdict {
    pub(crate) state: String,
    pub(crate) anomalous: bool,
    pub(crate) breached: bool,
    pub(crate) include_in_baseline: bool,
    pub(crate) next_consecutive_anomalous: usize,
    pub(crate) score: f64,
    pub(crate) reason: String,
    pub(crate) baseline_count: usize,
    pub(crate) next_rolling_acc: WelfordAcc,
    pub(crate) next_window_tail: Vec<f64>,
    pub(crate) sample_value: f64,
    pub(crate) observed_at_unix_nano: Option<u64>,
    pub(crate) signals: Vec<SignalVerdict>,
}

#[derive(Debug, PartialEq, NifMap)]
pub(crate) struct ReasonEventVerdict {
    pub(crate) state: String,
    pub(crate) anomalous: bool,
    pub(crate) breached: bool,
    pub(crate) include_in_baseline: bool,
    pub(crate) next_consecutive_anomalous: usize,
    pub(crate) score: f64,
    pub(crate) reason: String,
    pub(crate) baseline_count: usize,
    pub(crate) sample_value: f64,
    pub(crate) observed_at_unix_nano: Option<u64>,
    pub(crate) signals: Vec<SignalVerdict>,
}

impl ReasonEventVerdict {
    pub(crate) fn from_verdict(verdict: ReasonVerdict) -> Self {
        let signals = if verdict.anomalous || verdict.breached {
            verdict.signals
        } else {
            Vec::new()
        };

        Self {
            state: verdict.state,
            anomalous: verdict.anomalous,
            breached: verdict.breached,
            include_in_baseline: verdict.include_in_baseline,
            next_consecutive_anomalous: verdict.next_consecutive_anomalous,
            score: verdict.score,
            reason: verdict.reason,
            baseline_count: verdict.baseline_count,
            sample_value: verdict.sample_value,
            observed_at_unix_nano: verdict.observed_at_unix_nano,
            signals,
        }
    }
}

#[derive(Clone, Debug, PartialEq, NifMap)]
pub(crate) struct SignalVerdict {
    pub(crate) name: String,
    pub(crate) enabled: bool,
    pub(crate) ready: bool,
    pub(crate) breached: bool,
    pub(crate) score: f64,
    pub(crate) threshold: f64,
    pub(crate) sample_count: usize,
    pub(crate) mean: Option<f64>,
    pub(crate) stddev: Option<f64>,
    pub(crate) reason: String,
}
