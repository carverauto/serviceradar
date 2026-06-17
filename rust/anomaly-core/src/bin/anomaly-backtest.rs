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
    DEFAULT_CONFIRM_SLOTS, DEFAULT_MIN_SAMPLES, DEFAULT_N_SIGMA, DEFAULT_WINDOW_SIZE,
    ReasonContext, ReasonSample, reason_impl,
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
        let verdict = reason_impl(
            ReasonContext {
                baseline: Vec::new(),
                rolling_acc: None,
                window_tail: Some(state.window_tail.clone()),
                seasonal_baseline: None,
                trend_baseline: None,
                rolling_enabled: Some(true),
                seasonal_enabled: Some(false),
                trend_enabled: Some(false),
                min_samples: Some(args.min_samples),
                seasonal_min_samples: None,
                trend_min_samples: None,
                window_size: Some(args.window_size),
                n_sigma: Some(args.n_sigma),
                seasonal_n_sigma: None,
                trend_n_sigma: None,
                confirm_slots: Some(args.confirm_slots),
                consecutive_anomalous: Some(state.consecutive_anomalous),
            },
            ReasonSample {
                value: sample.value,
                observed_at_unix_nano: sample.observed_at_unix_nano,
            },
        )
        .map_err(|err| format!("line {}: detector failed: {err}", line_number + 1))?;

        state.window_tail = verdict.next_window_tail.clone();
        state.consecutive_anomalous = verdict.next_consecutive_anomalous;

        if should_emit(args.emit, verdict.anomalous, verdict.breached) {
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
