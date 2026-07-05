// Copyright 2026 Carver Automation Corporation.
//
// Licensed under the Apache License, Version 2.0 (the "License").
// SPDX-License-Identifier: Apache-2.0

use std::collections::HashMap;
use std::fs::File;
use std::io::{self, BufRead, BufReader, Read, Write};
use std::path::PathBuf;

use clap::{Parser, ValueEnum};
use serde::{Deserialize, Serialize};
use serviceradar_anomaly_core::{
    Cusum, DEFAULT_CONFIRM_SLOTS, DEFAULT_MIN_SAMPLES, DEFAULT_N_SIGMA, DEFAULT_WINDOW_SIZE,
    ReasonContext, ReasonSample, SaturationGate, reason_impl,
};

#[derive(Clone, Debug, Parser)]
#[command(
    name = "anomaly-backtest",
    about = "Replay JSONL metric samples through serviceradar-anomaly-core"
)]
struct Args {
    /// Input JSONL file. Reads stdin when omitted or set to '-'.
    #[arg(short, long)]
    input: Option<PathBuf>,

    /// Emit all verdicts, only breached/pending verdicts, or only confirmed anomalies.
    #[arg(long, default_value_t = EmitMode::Anomalies)]
    emit: EmitMode,

    /// Rolling window size in samples.
    #[arg(long, default_value_t = DEFAULT_WINDOW_SIZE)]
    window_size: usize,

    /// Minimum samples before a rolling baseline is ready.
    #[arg(long, default_value_t = DEFAULT_MIN_SAMPLES)]
    min_samples: usize,

    /// Sigma threshold for rolling z-score breaches.
    #[arg(long, default_value_t = DEFAULT_N_SIGMA)]
    n_sigma: f64,

    /// Consecutive breached samples required to confirm an anomaly.
    #[arg(long, default_value_t = DEFAULT_CONFIRM_SLOTS)]
    confirm_slots: usize,

    /// Attach a directional saturation gate with this absolute floor (percent for
    /// used_percent gauges): only an upward excursion that clears this value can
    /// breach. Mirrors the production cpu/mem/disk gauge profiles (disk/mem 80, cpu
    /// 85). When unset, the series is purely z-based (the default, as for counters).
    #[arg(long)]
    saturation_gate_min: Option<f64>,

    /// Absolute dispersion floor in metric units, applied before the z-score
    /// divides (raises a near-zero stddev so a near-constant series cannot
    /// manufacture a huge z). Mirrors the gauge fidelity profiles.
    #[arg(long)]
    min_std_floor: Option<f64>,

    /// Relative (coefficient-of-variation) dispersion floor: `min_cv * |mean|`.
    #[arg(long)]
    min_cv: Option<f64>,

    /// Enable the detector's SEASONAL signal: z-score the sample against the prior
    /// values in its hour-of-week (dow*24+hod) bucket. Exercises the `ReasonContext`
    /// seasonal path (otherwise hardcoded off) so the seasonal requirement is harness-
    /// provable on real code — a recurring hour-of-week pattern must NOT be flagged.
    #[arg(long)]
    seasonal: bool,

    /// n-sigma for the seasonal signal (defaults to `--n-sigma`).
    #[arg(long)]
    seasonal_n_sigma: Option<f64>,

    /// Min clean samples for the seasonal bucket (defaults to `--min-samples`).
    #[arg(long)]
    seasonal_min_samples: Option<usize>,

    /// Run a two-sided CUSUM drift detector alongside the z-score, anchored to the
    /// frozen baseline when it first warms up. Catches the slow drift/leaks the point
    /// z-score misses. Adds cusum_pos/cusum_neg/cusum_alarm to the output, and a
    /// cusum alarm forces the line to be emitted.
    #[arg(long)]
    cusum: bool,

    /// CUSUM slack (reference value) in sigma units.
    #[arg(long, default_value_t = 0.5)]
    cusum_k: f64,

    /// CUSUM decision interval (alarm threshold).
    #[arg(long, default_value_t = 5.0)]
    cusum_h: f64,
}

#[derive(Clone, Copy, Debug, Default, ValueEnum)]
enum EmitMode {
    All,
    Breaches,
    #[default]
    Anomalies,
}

impl std::fmt::Display for EmitMode {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let value = match self {
            Self::All => "all",
            Self::Breaches => "breaches",
            Self::Anomalies => "anomalies",
        };
        f.write_str(value)
    }
}

#[derive(Debug, Deserialize)]
struct InputSample {
    series_key: String,
    value: f64,
    #[serde(default)]
    observed_at_unix_nano: Option<u64>,
}

#[derive(Debug, Default)]
struct SeriesState {
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

/// Hour-of-week bucket (0..167) from a unix-nanosecond timestamp, UTC. 1970-01-01 was
/// a Thursday (dow 4), so `dow = (days + 4) mod 7`.
fn hour_of_week(observed_at_unix_nano: u64) -> usize {
    let secs = (observed_at_unix_nano / 1_000_000_000) as i64;
    let dow = ((secs.div_euclid(86_400) + 4).rem_euclid(7)) as usize;
    let hod = (secs.rem_euclid(86_400) / 3_600) as usize;
    dow * 24 + hod
}

#[derive(Debug, Serialize)]
struct OutputVerdict<'a> {
    series_key: &'a str,
    state: &'a str,
    anomalous: bool,
    breached: bool,
    score: f64,
    reason: &'a str,
    baseline_count: usize,
    sample_value: f64,
    observed_at_unix_nano: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    cusum_pos: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    cusum_neg: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    cusum_alarm: Option<bool>,
}

fn main() {
    if let Err(err) = run(Args::parse(), io::stdout()) {
        eprintln!("anomaly-backtest: {err}");
        std::process::exit(1);
    }
}

fn run(args: Args, mut out: impl Write) -> Result<(), String> {
    let mut states: HashMap<String, SeriesState> = HashMap::new();
    let input = input_reader(args.input.as_ref()).map_err(|err| err.to_string())?;

    for (line_number, line) in input.lines().enumerate() {
        let line = line.map_err(|err| format!("line {}: {err}", line_number + 1))?;
        let line = line.trim();

        if line.is_empty() {
            continue;
        }

        let sample: InputSample = serde_json::from_str(line)
            .map_err(|err| format!("line {}: invalid JSON sample: {err}", line_number + 1))?;

        let state = states.entry(sample.series_key.clone()).or_default();

        // Hour-of-week (dow*24+hod) bucket shared by --seasonal and --cusum; it holds
        // the PRIOR values for this slot (the current sample is pushed after scoring,
        // so both reads stay causal).
        let how = sample.observed_at_unix_nano.map(hour_of_week);
        if (args.seasonal || args.cusum) && state.how_vals.is_empty() {
            state.how_vals = vec![Vec::new(); 168];
        }
        let seasonal_baseline = if args.seasonal {
            how.map(|h| state.how_vals[h].clone())
        } else {
            None
        };

        let verdict = reason_impl(
            ReasonContext {
                baseline: Vec::new(),
                rolling_acc: None,
                window_tail: Some(state.window_tail.clone()),
                seasonal_baseline,
                trend_baseline: None,
                rolling_enabled: Some(true),
                seasonal_enabled: Some(args.seasonal),
                trend_enabled: Some(false),
                min_samples: Some(args.min_samples),
                seasonal_min_samples: Some(args.seasonal_min_samples.unwrap_or(args.min_samples)),
                trend_min_samples: None,
                window_size: Some(args.window_size),
                n_sigma: Some(args.n_sigma),
                seasonal_n_sigma: Some(args.seasonal_n_sigma.unwrap_or(args.n_sigma)),
                trend_n_sigma: None,
                confirm_slots: Some(args.confirm_slots),
                consecutive_anomalous: Some(state.consecutive_anomalous),
                min_std_floor: args.min_std_floor,
                min_cv: args.min_cv,
                saturation_gate: args.saturation_gate_min.map(|min_value| SaturationGate {
                    directional: true,
                    min_value,
                }),
            },
            ReasonSample {
                value: sample.value,
                observed_at_unix_nano: sample.observed_at_unix_nano,
            },
        )
        .map_err(|err| format!("line {}: detector failed: {err}", line_number + 1))?;

        // CUSUM drift detector on a DESEASONALIZED residual (`--cusum`). A rolling
        // z-score's mean tracks a slow ramp and misses it; raw CUSUM floods false
        // positives on a seasonal series (it accumulates every diurnal swing). So we
        // accumulate `(x - hour_of_week_median) / scale` against a CAUSAL hour-of-week
        // baseline (median: robust to a persistent shift polluting the reference, which
        // a running mean is not) — `scale` is the warmed baseline std (~noise). The
        // bucket is updated AFTER scoring (causal) and CUSUM only scores a warm bucket.
        let (mut cusum_pos, mut cusum_neg, mut cusum_alarm) = (None, None, None);
        if args.cusum {
            const MIN_SEASONAL_BUCKET: u32 = 30;
            if state.cusum_anchor.is_none() && state.window_tail.len() >= args.min_samples {
                let (mean, std) = mean_std(&state.window_tail);
                state.cusum_anchor = Some((mean, std.max(f64::EPSILON)));
                state.cusum = Some(Cusum::new(args.cusum_k, args.cusum_h));
            }
            if let Some(h) = how
                && state.how_vals[h].len() as u32 >= MIN_SEASONAL_BUCKET
            {
                let seasonal = median(&state.how_vals[h]);
                if let (Some((_t, scale)), Some(cusum)) = (state.cusum_anchor, state.cusum.as_mut())
                {
                    let step = cusum.update((sample.value - seasonal) / scale);
                    cusum_pos = Some(step.pos);
                    cusum_neg = Some(step.neg);
                    cusum_alarm = Some(step.alarm);
                }
            }
        }

        // Push the current value to its hour-of-week bucket (causal: after both the
        // seasonal-baseline read above and the CUSUM read).
        if let Some(h) = how
            && !state.how_vals.is_empty()
        {
            state.how_vals[h].push(sample.value);
        }

        state.window_tail = verdict.next_window_tail.clone();
        state.consecutive_anomalous = verdict.next_consecutive_anomalous;

        let emit = should_emit(args.emit, verdict.anomalous, verdict.breached)
            || cusum_alarm == Some(true);
        if emit {
            let output = OutputVerdict {
                series_key: &sample.series_key,
                state: &verdict.state,
                anomalous: verdict.anomalous,
                breached: verdict.breached,
                score: verdict.score,
                reason: &verdict.reason,
                baseline_count: verdict.baseline_count,
                sample_value: verdict.sample_value,
                observed_at_unix_nano: verdict.observed_at_unix_nano,
                cusum_pos,
                cusum_neg,
                cusum_alarm,
            };

            serde_json::to_writer(&mut out, &output).map_err(|err| err.to_string())?;
            out.write_all(b"\n").map_err(|err| err.to_string())?;
        }
    }

    Ok(())
}

fn input_reader(input: Option<&PathBuf>) -> io::Result<Box<dyn BufRead>> {
    match input {
        Some(path) if path.as_os_str() != "-" => {
            let file = File::open(path)?;
            Ok(Box::new(BufReader::new(file)))
        }
        _ => {
            let mut data = Vec::new();
            io::stdin().read_to_end(&mut data)?;
            Ok(Box::new(BufReader::new(io::Cursor::new(data))))
        }
    }
}

fn should_emit(mode: EmitMode, anomalous: bool, breached: bool) -> bool {
    match mode {
        EmitMode::All => true,
        EmitMode::Breaches => breached,
        EmitMode::Anomalies => anomalous,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn emit_mode_filters_verdicts() {
        assert!(should_emit(EmitMode::All, false, false));
        assert!(should_emit(EmitMode::Breaches, false, true));
        assert!(!should_emit(EmitMode::Breaches, false, false));
        assert!(should_emit(EmitMode::Anomalies, true, true));
        assert!(!should_emit(EmitMode::Anomalies, false, true));
    }

    #[test]
    fn backtest_replays_jsonl_and_emits_anomaly() {
        let input = std::env::temp_dir().join(format!(
            "serviceradar-anomaly-backtest-{}.jsonl",
            std::process::id()
        ));

        {
            let mut file = File::create(&input).expect("create temp input");
            for value in [10.0, 10.0, 10.0, 30.0] {
                writeln!(file, r#"{{"series_key":"s1","value":{value}}}"#).expect("write sample");
            }
        }

        let mut output = Vec::new();
        let result = run(
            Args {
                input: Some(input.clone()),
                emit: EmitMode::Anomalies,
                window_size: 10,
                min_samples: 3,
                n_sigma: 3.0,
                confirm_slots: 1,
                saturation_gate_min: None,
                min_std_floor: None,
                min_cv: None,
                seasonal: false,
                seasonal_n_sigma: None,
                seasonal_min_samples: None,
                cusum: false,
                cusum_k: 0.5,
                cusum_h: 5.0,
            },
            &mut output,
        );
        let _ = std::fs::remove_file(input);
        result.expect("run backtest");

        let lines = String::from_utf8(output).expect("utf8 output");
        assert_eq!(lines.lines().count(), 1);
        assert!(lines.contains(r#""series_key":"s1""#));
        assert!(lines.contains(r#""anomalous":true"#));
    }
}
