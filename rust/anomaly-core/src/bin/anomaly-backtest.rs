// Copyright 2026 Carver Automation Corporation.
//
// Licensed under the Apache License, Version 2.0 (the "License").
// SPDX-License-Identifier: Apache-2.0

use std::collections::HashMap;
use std::io::{self, BufRead, BufReader, Read, Write};
use std::path::PathBuf;

use clap::{Parser, ValueEnum};
use serde::Serialize;
use serviceradar_anomaly_core::{
    DEFAULT_CONFIRM_SLOTS, DEFAULT_MIN_SAMPLES, DEFAULT_N_SIGMA, DEFAULT_WINDOW_SIZE,
    scorecard::{
        BacktestSample, ReplayConfig, SeriesState, load_truth, open_bufread, run_scorecard,
    },
};

#[derive(Clone, Debug, Parser)]
#[command(
    name = "anomaly-backtest",
    about = "Replay JSONL metric samples through serviceradar-anomaly-core"
)]
struct Args {
    /// Input JSONL file (gzipped when the path ends in .gz). Reads stdin when
    /// omitted or set to '-'.
    #[arg(short, long)]
    input: Option<PathBuf>,

    /// Score the replay against a labeled truth CSV
    /// (`series_key,i,t_ns,value,is_truth,klass`, as written by
    /// tools/anomaly-proof/gen.py; gzipped when the path ends in .gz) and print a
    /// scorecard JSON instead of per-sample verdicts. The span-matching semantics
    /// mirror tools/anomaly-proof/plot.py.
    #[arg(long)]
    truth: Option<PathBuf>,

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

impl Args {
    fn replay_config(&self) -> ReplayConfig {
        ReplayConfig {
            window_size: self.window_size,
            min_samples: self.min_samples,
            n_sigma: self.n_sigma,
            confirm_slots: self.confirm_slots,
            saturation_gate_min: self.saturation_gate_min,
            min_std_floor: self.min_std_floor,
            min_cv: self.min_cv,
            seasonal: self.seasonal,
            seasonal_n_sigma: self.seasonal_n_sigma,
            seasonal_min_samples: self.seasonal_min_samples,
            cusum: self.cusum,
            cusum_k: self.cusum_k,
            cusum_h: self.cusum_h,
        }
    }
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
    let cfg = args.replay_config();
    let input = input_reader(args.input.as_ref()).map_err(|err| err.to_string())?;

    // Scoring mode: replay everything, match against the labeled truth, print the
    // scorecard JSON instead of per-sample verdicts.
    if let Some(truth_path) = &args.truth {
        let truth_reader = open_bufread(truth_path).map_err(|err| err.to_string())?;
        let truth = load_truth(truth_reader)?;
        let scorecard = run_scorecard(input, &truth, &cfg)?;
        serde_json::to_writer_pretty(&mut out, &scorecard).map_err(|err| err.to_string())?;
        out.write_all(b"\n").map_err(|err| err.to_string())?;
        return Ok(());
    }

    let mut states: HashMap<String, SeriesState> = HashMap::new();

    for (line_number, line) in input.lines().enumerate() {
        let line = line.map_err(|err| format!("line {}: {err}", line_number + 1))?;
        let line = line.trim();

        if line.is_empty() {
            continue;
        }

        let sample: BacktestSample = serde_json::from_str(line)
            .map_err(|err| format!("line {}: invalid JSON sample: {err}", line_number + 1))?;

        let state = states.entry(sample.series_key.clone()).or_default();
        let outcome = state
            .step(&cfg, sample.value, sample.observed_at_unix_nano)
            .map_err(|err| format!("line {}: detector failed: {err}", line_number + 1))?;
        let verdict = &outcome.verdict;

        let emit = should_emit(args.emit, verdict.anomalous, verdict.breached)
            || outcome.cusum_alarm == Some(true);
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
                cusum_pos: outcome.cusum_pos,
                cusum_neg: outcome.cusum_neg,
                cusum_alarm: outcome.cusum_alarm,
            };

            serde_json::to_writer(&mut out, &output).map_err(|err| err.to_string())?;
            out.write_all(b"\n").map_err(|err| err.to_string())?;
        }
    }

    Ok(())
}

fn input_reader(input: Option<&PathBuf>) -> io::Result<Box<dyn BufRead>> {
    match input {
        Some(path) if path.as_os_str() != "-" => open_bufread(path),
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
    use std::fs::File;

    fn args_for(input: PathBuf) -> Args {
        Args {
            input: Some(input),
            truth: None,
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
        }
    }

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
        let result = run(args_for(input.clone()), &mut output);
        let _ = std::fs::remove_file(input);
        result.expect("run backtest");

        let lines = String::from_utf8(output).expect("utf8 output");
        assert_eq!(lines.lines().count(), 1);
        assert!(lines.contains(r#""series_key":"s1""#));
        assert!(lines.contains(r#""anomalous":true"#));
    }

    #[test]
    fn truth_mode_scores_replay_against_labels() {
        let dir = std::env::temp_dir();
        let input = dir.join(format!(
            "serviceradar-anomaly-backtest-truth-{}.jsonl",
            std::process::id()
        ));
        let truth = dir.join(format!(
            "serviceradar-anomaly-backtest-truth-{}.csv",
            std::process::id()
        ));

        {
            let mut file = File::create(&input).expect("create temp input");
            for value in [10.0, 10.0, 10.0, 30.0] {
                writeln!(file, r#"{{"series_key":"s1","value":{value}}}"#).expect("write sample");
            }
            let mut file = File::create(&truth).expect("create temp truth");
            writeln!(file, "series_key,i,t_ns,value,is_truth,klass").expect("write header");
            for (i, is_truth) in [(0, 0), (1, 0), (2, 0), (3, 1)] {
                writeln!(file, "s1,{i},{i},10.0,{is_truth},spike").expect("write row");
            }
        }

        let mut output = Vec::new();
        let mut args = args_for(input.clone());
        args.truth = Some(truth.clone());
        let result = run(args, &mut output);
        let _ = std::fs::remove_file(input);
        let _ = std::fs::remove_file(truth);
        result.expect("run truth mode");

        let scorecard: serde_json::Value = serde_json::from_slice(&output).expect("scorecard JSON");
        let series = &scorecard["series"][0];
        assert_eq!(series["series_key"], "s1");
        assert_eq!(series["tp_flags"], 1);
        assert_eq!(series["fp_flags"], 0);
        assert_eq!(series["by_class"][0]["klass"], "spike");
        assert_eq!(series["by_class"][0]["detected"], 1);
    }
}
