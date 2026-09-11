// Copyright 2026 Carver Automation Corporation.
//
// Licensed under the Apache License, Version 2.0 (the "License").
// SPDX-License-Identifier: Apache-2.0

//! Labeled-corpus backtest replay + scorecard.
//!
//! Two consumers share this module so they cannot drift apart:
//! - the `anomaly-backtest --truth <csv>` CLI mode, and
//! - the committed-corpus CI floor gate (`tests/scorecard_gate.rs`) over
//!   `testdata/scorecard/` (generated once by `tools/anomaly-proof/gen.py`).
//!
//! [`SeriesState::step`] is the exact per-sample plumbing the `anomaly-backtest`
//! CLI runs (the CLI calls it too). The span-matching scorer is a faithful port
//! of `tools/anomaly-proof/plot.py` `truth_spans` / `score_series`: truth spans
//! are contiguous same-class labeled runs; a span is recalled when any confirmed
//! flag lands in `[start, end + LATENCY_TOL)`; a flag is a precision TP when it
//! lands in any span (with the same tolerance), else an FP.

use std::fs::File;
use std::io::{self, BufRead, BufReader};
use std::path::Path;

use serde::{Deserialize, Serialize};

use crate::cusum::Cusum;
use crate::detector::reason_impl;
use crate::seasonal::hour_of_week;
use crate::types::{ReasonContext, ReasonSample, ReasonVerdict, SaturationGate};
use crate::{
    DEFAULT_CONFIRM_SLOTS, DEFAULT_MIN_SAMPLES, DEFAULT_N_SIGMA, DEFAULT_WINDOW_SIZE,
    HOURS_PER_WEEK,
};

/// Samples of grace when matching a confirmed flag to a truth span (mirrors
/// `tools/anomaly-proof/plot.py` `LATENCY_TOL`).
pub const LATENCY_TOL: usize = 8;

/// Prior values required in an hour-of-week bucket before the CUSUM residual
/// trusts its median as a seasonal reference.
const MIN_SEASONAL_BUCKET: usize = 30;

/// One JSONL input sample in the `anomaly-backtest` contract.
#[derive(Debug, Deserialize)]
pub struct BacktestSample {
    pub series_key: String,
    pub value: f64,
    #[serde(default)]
    pub observed_at_unix_nano: Option<u64>,
}

/// Detector + CUSUM configuration for one replay; mirrors the `anomaly-backtest`
/// CLI flags (and its defaults).
#[derive(Clone, Debug)]
pub struct ReplayConfig {
    pub window_size: usize,
    pub min_samples: usize,
    pub n_sigma: f64,
    pub confirm_slots: usize,
    pub saturation_gate_min: Option<f64>,
    pub min_std_floor: Option<f64>,
    pub min_cv: Option<f64>,
    pub seasonal: bool,
    pub seasonal_n_sigma: Option<f64>,
    pub seasonal_min_samples: Option<usize>,
    pub cusum: bool,
    pub cusum_k: f64,
    pub cusum_h: f64,
}

impl Default for ReplayConfig {
    fn default() -> Self {
        Self {
            window_size: DEFAULT_WINDOW_SIZE,
            min_samples: DEFAULT_MIN_SAMPLES,
            n_sigma: DEFAULT_N_SIGMA,
            confirm_slots: DEFAULT_CONFIRM_SLOTS,
            saturation_gate_min: None,
            min_std_floor: None,
            min_cv: None,
            seasonal: false,
            seasonal_n_sigma: None,
            seasonal_min_samples: None,
            cusum: false,
            cusum_k: 0.5,
            cusum_h: 5.0,
        }
    }
}

/// Per-series replay state (the exact state the `anomaly-backtest` CLI keeps).
#[derive(Debug, Default)]
pub struct SeriesState {
    window_tail: Vec<f64>,
    consecutive_anomalous: usize,
    cusum: Option<Cusum>,
    cusum_anchor: Option<(f64, f64)>,
    /// Causal hour-of-week baseline for deseasonalizing the CUSUM input: the prior
    /// values per (dow*24+hod) bucket (168). The baseline is their MEDIAN — robust to
    /// a persistent shift polluting the reference (a running mean is not). Lazily
    /// sized to 168; the current sample is appended AFTER scoring (latest-excluded).
    how_vals: Vec<Vec<f64>>,
}

/// One replay step's outputs: the detector verdict plus the optional CUSUM step.
#[derive(Debug)]
pub struct StepOutcome {
    pub verdict: ReasonVerdict,
    pub cusum_pos: Option<f64>,
    pub cusum_neg: Option<f64>,
    pub cusum_alarm: Option<bool>,
}

/// Median of a slice (mid value for odd n, average of the two middle for even).
fn median(values: &[f64]) -> f64 {
    if values.is_empty() {
        return 0.0;
    }
    let mut v = values.to_vec();
    v.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));
    let n = v.len();
    if n % 2 == 1 {
        v[n / 2]
    } else {
        (v[n / 2 - 1] + v[n / 2]) / 2.0
    }
}

/// Mean and sample standard deviation (n-1) of a slice; (0,0) when empty.
fn mean_std(values: &[f64]) -> (f64, f64) {
    let n = values.len();
    if n == 0 {
        return (0.0, 0.0);
    }
    let mean = values.iter().sum::<f64>() / n as f64;
    let denom = n.saturating_sub(1).max(1) as f64;
    let var = values.iter().map(|v| (v - mean) * (v - mean)).sum::<f64>() / denom;
    (mean, var.sqrt())
}

impl SeriesState {
    /// Advance the series by one sample: evaluate the detector, then the optional
    /// deseasonalized CUSUM, then update the causal state. This is the single
    /// per-sample step both the `anomaly-backtest` CLI and the scorecard replay run.
    pub fn step(
        &mut self,
        cfg: &ReplayConfig,
        value: f64,
        observed_at_unix_nano: Option<u64>,
    ) -> Result<StepOutcome, String> {
        // Hour-of-week (dow*24+hod) bucket shared by the seasonal signal and the
        // CUSUM residual; it holds the PRIOR values for this slot (the current
        // sample is pushed after scoring, so both reads stay causal).
        let how = observed_at_unix_nano.map(hour_of_week);
        if (cfg.seasonal || cfg.cusum) && self.how_vals.is_empty() {
            self.how_vals = vec![Vec::new(); HOURS_PER_WEEK];
        }
        let seasonal_baseline = if cfg.seasonal {
            how.map(|h| self.how_vals[h].clone())
        } else {
            None
        };

        let verdict = reason_impl(
            ReasonContext {
                baseline: Vec::new(),
                rolling_acc: None,
                window_tail: Some(self.window_tail.clone()),
                seasonal_baseline,
                trend_baseline: None,
                rolling_enabled: Some(true),
                seasonal_enabled: Some(cfg.seasonal),
                trend_enabled: Some(false),
                min_samples: Some(cfg.min_samples),
                seasonal_min_samples: Some(cfg.seasonal_min_samples.unwrap_or(cfg.min_samples)),
                trend_min_samples: None,
                window_size: Some(cfg.window_size),
                n_sigma: Some(cfg.n_sigma),
                seasonal_n_sigma: Some(cfg.seasonal_n_sigma.unwrap_or(cfg.n_sigma)),
                trend_n_sigma: None,
                confirm_slots: Some(cfg.confirm_slots),
                consecutive_anomalous: Some(self.consecutive_anomalous),
                min_std_floor: cfg.min_std_floor,
                min_cv: cfg.min_cv,
                burst_envelope: None,
                saturation_gate: cfg.saturation_gate_min.map(|min_value| SaturationGate {
                    directional: true,
                    min_value,
                }),
            },
            ReasonSample {
                value,
                observed_at_unix_nano,
            },
        )?;

        // CUSUM drift detector on a DESEASONALIZED residual. A rolling z-score's
        // mean tracks a slow ramp and misses it; raw CUSUM floods false positives
        // on a seasonal series (it accumulates every diurnal swing). So we
        // accumulate `(x - hour_of_week_median) / scale` against a CAUSAL
        // hour-of-week baseline (median: robust to a persistent shift polluting
        // the reference, which a running mean is not) — `scale` is the warmed
        // baseline std (~noise). The bucket is updated AFTER scoring (causal) and
        // CUSUM only scores a warm bucket.
        let (mut cusum_pos, mut cusum_neg, mut cusum_alarm) = (None, None, None);
        if cfg.cusum {
            if self.cusum_anchor.is_none() && self.window_tail.len() >= cfg.min_samples {
                let (mean, std) = mean_std(&self.window_tail);
                self.cusum_anchor = Some((mean, std.max(f64::EPSILON)));
                self.cusum = Some(Cusum::new(cfg.cusum_k, cfg.cusum_h));
            }
            if let Some(h) = how
                && self.how_vals[h].len() >= MIN_SEASONAL_BUCKET
            {
                let seasonal = median(&self.how_vals[h]);
                if let (Some((_t, scale)), Some(cusum)) = (self.cusum_anchor, self.cusum.as_mut()) {
                    let step = cusum.update((value - seasonal) / scale);
                    cusum_pos = Some(step.pos);
                    cusum_neg = Some(step.neg);
                    cusum_alarm = Some(step.alarm);
                }
            }
        }

        // Push the current value to its hour-of-week bucket (causal: after both the
        // seasonal-baseline read above and the CUSUM read).
        if let Some(h) = how
            && !self.how_vals.is_empty()
        {
            self.how_vals[h].push(value);
        }

        self.window_tail = verdict.next_window_tail.clone();
        self.consecutive_anomalous = verdict.next_consecutive_anomalous;

        Ok(StepOutcome {
            verdict,
            cusum_pos,
            cusum_neg,
            cusum_alarm,
        })
    }
}

/// Open a file as a buffered reader, transparently gunzipping `*.gz` paths.
pub fn open_bufread(path: &Path) -> io::Result<Box<dyn BufRead>> {
    let file = File::open(path)?;
    if path.extension().is_some_and(|ext| ext == "gz") {
        Ok(Box::new(BufReader::new(flate2::read::GzDecoder::new(file))))
    } else {
        Ok(Box::new(BufReader::new(file)))
    }
}

/// Ground-truth labels for one series, indexed by sample position `i`.
#[derive(Debug, Default)]
pub struct TruthSeries {
    pub truth: Vec<bool>,
    pub klass: Vec<String>,
}

/// Parse a `truth.csv` in the `tools/anomaly-proof/gen.py` contract
/// (`series_key,i,t_ns,value,is_truth,klass`, CRLF-terminated, never-quoted
/// fields), preserving first-appearance series order. Rows per series must
/// arrive in `i` order (gen.py interleaves series but keeps `i` ascending).
pub fn load_truth(reader: impl BufRead) -> Result<Vec<(String, TruthSeries)>, String> {
    let mut order: Vec<String> = Vec::new();
    let mut by_key: std::collections::HashMap<String, TruthSeries> =
        std::collections::HashMap::new();
    let mut cols: Option<(usize, usize, usize)> = None; // (series_key, is_truth, klass)

    for (line_number, line) in reader.lines().enumerate() {
        let line = line.map_err(|err| format!("truth line {}: {err}", line_number + 1))?;
        let line = line.trim_end_matches(['\r', '\n']);
        if line.is_empty() {
            continue;
        }
        let fields: Vec<&str> = line.split(',').collect();
        let Some((key_col, truth_col, klass_col)) = cols else {
            let find = |name: &str| {
                fields
                    .iter()
                    .position(|f| *f == name)
                    .ok_or_else(|| format!("truth header missing column {name:?}"))
            };
            cols = Some((find("series_key")?, find("is_truth")?, find("klass")?));
            continue;
        };
        let max_col = key_col.max(truth_col).max(klass_col);
        if fields.len() <= max_col {
            return Err(format!(
                "truth line {}: expected at least {} fields, got {}",
                line_number + 1,
                max_col + 1,
                fields.len()
            ));
        }
        let series = by_key
            .entry(fields[key_col].to_string())
            .or_insert_with(|| {
                order.push(fields[key_col].to_string());
                TruthSeries::default()
            });
        series.truth.push(fields[truth_col] == "1");
        series.klass.push(fields[klass_col].to_string());
    }

    Ok(order
        .into_iter()
        .map(|key| {
            let series = by_key.remove(&key).expect("ordered key present");
            (key, series)
        })
        .collect())
}

/// A contiguous run of same-class labeled truth samples (`[start, end)`).
#[derive(Clone, Debug, PartialEq)]
pub struct TruthSpan {
    pub start: usize,
    pub end: usize,
    pub klass: String,
}

/// Contiguous same-class truth spans (port of `plot.py` `truth_spans`).
pub fn truth_spans(series: &TruthSeries) -> Vec<TruthSpan> {
    let mut spans = Vec::new();
    let n = series.truth.len();
    let mut i = 0;
    while i < n {
        if series.truth[i] {
            let klass = &series.klass[i];
            let mut j = i;
            while j < n && series.truth[j] && series.klass[j] == *klass {
                j += 1;
            }
            spans.push(TruthSpan {
                start: i,
                end: j,
                klass: klass.clone(),
            });
            i = j;
        } else {
            i += 1;
        }
    }
    spans
}

/// Span-recall + first-hit latency for one truth class.
#[derive(Debug, Serialize)]
pub struct ClassScore {
    pub klass: String,
    pub spans: usize,
    pub detected: usize,
    pub recall: f64,
    /// Median of per-span first-hit latencies, `int(np.median(...))`-style
    /// (truncated mean-of-two-middles for an even count); `None` when undetected.
    pub median_latency_samples: Option<i64>,
}

/// Confirmed spike flags inside one explicitly labeled negative class.
///
/// The corpus keeps `is_truth=0` for expected operational shapes such as a
/// recurring nightly load, while retaining a non-empty `klass`. Reporting those
/// regions separately lets CI enforce the exact false-positive regression instead
/// of hiding it inside aggregate precision.
#[derive(Debug, Serialize)]
pub struct FalsePositiveClassScore {
    pub klass: String,
    pub samples: usize,
    pub flags: usize,
    pub rate: f64,
}

/// CUSUM alarm coverage of one truth span (`alarm_samples` counts alarms inside
/// `[start, end)`, no tolerance — the `216/300`-style drift-recall numerator).
#[derive(Debug, Serialize)]
pub struct CusumSpanScore {
    pub klass: String,
    pub start: usize,
    pub len: usize,
    pub alarm_samples: usize,
    pub first_alarm_offset: Option<usize>,
}

/// CUSUM false-alarm accounting for one series: alarms outside every truth span
/// (+`LATENCY_TOL`) over the clean-sample count.
#[derive(Debug, Serialize)]
pub struct CusumScore {
    pub fp_alarms: usize,
    pub clean_samples: usize,
    pub fp_rate: Option<f64>,
    pub spans: Vec<CusumSpanScore>,
}

/// The full scorecard for one series.
#[derive(Debug, Serialize)]
pub struct SeriesScore {
    pub series_key: String,
    /// `tp_flags / (tp_flags + fp_flags)`; `None` when the series never flagged.
    pub precision: Option<f64>,
    pub flags: usize,
    pub tp_flags: usize,
    pub fp_flags: usize,
    pub by_class: Vec<ClassScore>,
    pub false_positive_by_class: Vec<FalsePositiveClassScore>,
    /// Largest `|score|` over every per-sample verdict of the replay.
    pub max_abs_score: f64,
    /// False only if any per-sample verdict score was NaN/inf.
    pub all_scores_finite: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cusum: Option<CusumScore>,
}

/// Score one series' confirmed-anomaly flags against its truth labels — a
/// faithful port of `plot.py` `score_series` (`LATENCY_TOL` grace, span recall,
/// per-flag precision). `anomalous` is index-aligned with the truth vectors;
/// like `plot.py`, scoring runs over the shorter of the two.
pub fn score_flags(series: &TruthSeries, anomalous: &[bool]) -> (Vec<ClassScore>, usize, usize) {
    let m = series.truth.len().min(anomalous.len());
    let clipped = TruthSeries {
        truth: series.truth[..m].to_vec(),
        klass: series.klass[..m].to_vec(),
    };
    let spans = truth_spans(&clipped);
    let flagged: Vec<usize> = (0..m).filter(|&i| anomalous[i]).collect();

    // Recall per span: detected if any confirmed flag lands in [start, end + tol).
    let mut class_order: Vec<String> = Vec::new();
    let mut per_class: std::collections::HashMap<String, (usize, usize, Vec<i64>)> =
        std::collections::HashMap::new();
    for span in &spans {
        let entry = per_class.entry(span.klass.clone()).or_insert_with(|| {
            class_order.push(span.klass.clone());
            (0, 0, Vec::new())
        });
        entry.0 += 1;
        let hit = flagged
            .iter()
            .find(|&&i| i >= span.start && i < span.end + LATENCY_TOL);
        if let Some(&first) = hit {
            entry.1 += 1;
            entry.2.push(first as i64 - span.start as i64);
        }
    }

    // Precision: a flag is a TP if it lands in any truth span (+ tol), else an FP.
    let mut tp = 0usize;
    let mut fp = 0usize;
    for &idx in &flagged {
        if spans
            .iter()
            .any(|span| idx >= span.start && idx < span.end + LATENCY_TOL)
        {
            tp += 1;
        } else {
            fp += 1;
        }
    }

    let by_class = class_order
        .into_iter()
        .map(|klass| {
            let (spans, detected, mut latencies) =
                per_class.remove(&klass).expect("ordered class present");
            latencies.sort_unstable();
            let median_latency_samples = match latencies.len() {
                0 => None,
                n if n % 2 == 1 => Some(latencies[n / 2]),
                n => Some(((latencies[n / 2 - 1] + latencies[n / 2]) as f64 / 2.0) as i64),
            };
            ClassScore {
                klass,
                spans,
                detected,
                recall: detected as f64 / spans as f64,
                median_latency_samples,
            }
        })
        .collect();

    (by_class, tp, fp)
}

/// Score explicitly named negative regions (`is_truth=0`, non-empty `klass`).
pub fn score_false_positive_classes(
    series: &TruthSeries,
    anomalous: &[bool],
) -> Vec<FalsePositiveClassScore> {
    let m = series.truth.len().min(anomalous.len());
    let mut order = Vec::new();
    let mut counts: std::collections::HashMap<String, (usize, usize)> =
        std::collections::HashMap::new();

    for (i, is_anomalous) in anomalous.iter().take(m).enumerate() {
        let klass = &series.klass[i];
        if series.truth[i] || klass.is_empty() {
            continue;
        }
        let entry = counts.entry(klass.clone()).or_insert_with(|| {
            order.push(klass.clone());
            (0, 0)
        });
        entry.0 += 1;
        if *is_anomalous {
            entry.1 += 1;
        }
    }

    order
        .into_iter()
        .map(|klass| {
            let (samples, flags) = counts.remove(&klass).expect("ordered class present");
            FalsePositiveClassScore {
                klass,
                samples,
                flags,
                rate: flags as f64 / samples as f64,
            }
        })
        .collect()
}

/// CUSUM alarm accounting for one series (per-span coverage + FP rate on the
/// clean samples outside every span + `LATENCY_TOL`).
pub fn score_cusum(series: &TruthSeries, alarms: &[bool]) -> CusumScore {
    let m = series.truth.len().min(alarms.len());
    let clipped = TruthSeries {
        truth: series.truth[..m].to_vec(),
        klass: series.klass[..m].to_vec(),
    };
    let spans = truth_spans(&clipped);

    let mut in_any = vec![false; m];
    for span in &spans {
        for slot in in_any
            .iter_mut()
            .take((span.end + LATENCY_TOL).min(m))
            .skip(span.start)
        {
            *slot = true;
        }
    }
    let mut fp_alarms = 0usize;
    let mut clean_samples = 0usize;
    for i in 0..m {
        if !in_any[i] {
            clean_samples += 1;
            if alarms[i] {
                fp_alarms += 1;
            }
        }
    }

    let span_scores = spans
        .iter()
        .map(|span| {
            let alarm_samples = (span.start..span.end).filter(|&i| alarms[i]).count();
            let first_alarm_offset = (span.start..span.end)
                .find(|&i| alarms[i])
                .map(|i| i - span.start);
            CusumSpanScore {
                klass: span.klass.clone(),
                start: span.start,
                len: span.end - span.start,
                alarm_samples,
                first_alarm_offset,
            }
        })
        .collect();

    CusumScore {
        fp_alarms,
        clean_samples,
        fp_rate: (clean_samples > 0).then(|| fp_alarms as f64 / clean_samples as f64),
        spans: span_scores,
    }
}

/// The scorecard over every truth-labeled series of a replay.
#[derive(Debug, Serialize)]
pub struct Scorecard {
    pub series: Vec<SeriesScore>,
}

impl Scorecard {
    /// The scorecard for `series_key`, if the truth file labeled it.
    pub fn series(&self, series_key: &str) -> Option<&SeriesScore> {
        self.series.iter().find(|s| s.series_key == series_key)
    }
}

/// Replay a JSONL sample stream through the shared [`SeriesState::step`] and
/// score every truth-labeled series. Sample series absent from `truth` are
/// still replayed (their scores count toward nothing) but not reported.
pub fn run_scorecard(
    samples: impl BufRead,
    truth: &[(String, TruthSeries)],
    cfg: &ReplayConfig,
) -> Result<Scorecard, String> {
    struct Replayed {
        anomalous: Vec<bool>,
        alarms: Vec<bool>,
        max_abs_score: f64,
        all_scores_finite: bool,
    }
    let mut states: std::collections::HashMap<String, SeriesState> =
        std::collections::HashMap::new();
    let mut replayed: std::collections::HashMap<String, Replayed> =
        std::collections::HashMap::new();

    for (line_number, line) in samples.lines().enumerate() {
        let line = line.map_err(|err| format!("line {}: {err}", line_number + 1))?;
        let line = line.trim();
        if line.is_empty() {
            continue;
        }
        let sample: BacktestSample = serde_json::from_str(line)
            .map_err(|err| format!("line {}: invalid JSON sample: {err}", line_number + 1))?;
        let state = states.entry(sample.series_key.clone()).or_default();
        let outcome = state
            .step(cfg, sample.value, sample.observed_at_unix_nano)
            .map_err(|err| format!("line {}: detector failed: {err}", line_number + 1))?;

        let entry = replayed
            .entry(sample.series_key)
            .or_insert_with(|| Replayed {
                anomalous: Vec::new(),
                alarms: Vec::new(),
                max_abs_score: 0.0,
                all_scores_finite: true,
            });
        entry.anomalous.push(outcome.verdict.anomalous);
        entry.alarms.push(outcome.cusum_alarm == Some(true));
        if outcome.verdict.score.is_finite() {
            entry.max_abs_score = entry.max_abs_score.max(outcome.verdict.score.abs());
        } else {
            entry.all_scores_finite = false;
        }
    }

    let empty = Replayed {
        anomalous: Vec::new(),
        alarms: Vec::new(),
        max_abs_score: 0.0,
        all_scores_finite: true,
    };
    let series = truth
        .iter()
        .map(|(key, truth_series)| {
            let r = replayed.get(key).unwrap_or(&empty);
            let (by_class, tp_flags, fp_flags) = score_flags(truth_series, &r.anomalous);
            let false_positive_by_class = score_false_positive_classes(truth_series, &r.anomalous);
            let flags = tp_flags + fp_flags;
            SeriesScore {
                series_key: key.clone(),
                precision: (flags > 0).then(|| tp_flags as f64 / flags as f64),
                flags,
                tp_flags,
                fp_flags,
                by_class,
                false_positive_by_class,
                max_abs_score: r.max_abs_score,
                all_scores_finite: r.all_scores_finite,
                cusum: cfg.cusum.then(|| score_cusum(truth_series, &r.alarms)),
            }
        })
        .collect();

    Ok(Scorecard { series })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn truth_of(pairs: &[(u8, &str)]) -> TruthSeries {
        TruthSeries {
            truth: pairs.iter().map(|(t, _)| *t == 1).collect(),
            klass: pairs.iter().map(|(_, k)| k.to_string()).collect(),
        }
    }

    #[test]
    fn truth_spans_splits_contiguous_same_class_runs() {
        let series = truth_of(&[
            (0, ""),
            (1, "spike"),
            (1, "spike"),
            (1, "step"),
            (0, ""),
            (1, "spike"),
        ]);
        let spans = truth_spans(&series);
        assert_eq!(
            spans,
            vec![
                TruthSpan {
                    start: 1,
                    end: 3,
                    klass: "spike".into()
                },
                TruthSpan {
                    start: 3,
                    end: 4,
                    klass: "step".into()
                },
                TruthSpan {
                    start: 5,
                    end: 6,
                    klass: "spike".into()
                },
            ]
        );
    }

    #[test]
    fn score_flags_matches_plot_py_span_semantics() {
        // Span [2, 4) klass=spike; a flag at 4 + LATENCY_TOL - 1 = 11 still hits
        // ([start, end + tol)); a flag at 12 is an FP.
        let mut pairs = vec![(0u8, ""); 20];
        pairs[2] = (1, "spike");
        pairs[3] = (1, "spike");
        let series = truth_of(&pairs);

        let mut anomalous = vec![false; 20];
        anomalous[11] = true; // TP: inside end (4) + tol (8) = 12 exclusive
        anomalous[12] = true; // FP: at the exclusive bound
        let (by_class, tp, fp) = score_flags(&series, &anomalous);
        assert_eq!((tp, fp), (1, 1));
        assert_eq!(by_class.len(), 1);
        assert_eq!(by_class[0].klass, "spike");
        assert_eq!(by_class[0].detected, 1);
        assert_eq!(by_class[0].median_latency_samples, Some(9)); // 11 - 2
    }

    #[test]
    fn score_cusum_counts_span_coverage_and_clean_fp() {
        let mut pairs = vec![(0u8, ""); 30];
        for slot in pairs.iter_mut().take(14).skip(10) {
            *slot = (1, "drift");
        }
        let series = truth_of(&pairs);
        let mut alarms = vec![false; 30];
        alarms[11] = true; // in-span
        alarms[13] = true; // in-span
        alarms[20] = true; // inside span end (14) + tol (8) = 22: neither FP nor coverage
        alarms[25] = true; // clean-region FP
        let score = score_cusum(&series, &alarms);
        assert_eq!(score.spans.len(), 1);
        assert_eq!(score.spans[0].alarm_samples, 2);
        assert_eq!(score.spans[0].first_alarm_offset, Some(1));
        assert_eq!(score.fp_alarms, 1);
        // 30 samples minus [10, 22) tolerated region = 18 clean.
        assert_eq!(score.clean_samples, 18);
    }

    #[test]
    fn load_truth_parses_crlf_and_orders_by_first_appearance() {
        let csv = "series_key,i,t_ns,value,is_truth,klass\r\n\
                   b,0,1,1.0,0,\r\n\
                   a,0,1,2.0,1,spike\r\n\
                   b,1,2,1.1,1,step\r\n\
                   a,1,2,2.1,0,\r\n";
        let truth = load_truth(std::io::Cursor::new(csv)).expect("parse");
        assert_eq!(truth.len(), 2);
        assert_eq!(truth[0].0, "b");
        assert_eq!(truth[0].1.truth, vec![false, true]);
        assert_eq!(truth[0].1.klass, vec!["", "step"]);
        assert_eq!(truth[1].0, "a");
        assert_eq!(truth[1].1.truth, vec![true, false]);
    }
}
