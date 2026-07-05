// Copyright 2026 Carver Automation Corporation.
// SPDX-License-Identifier: Apache-2.0
//
//! Replay synthetic, labeled rows through the REAL central disposition kernels
//! (`dispose_seasonal` / `dispose_capacity`) so the core tier can be proven with
//! no database — the core analog of `anomaly-backtest`.
//!
//! `--kind seasonal` (default): one pre-aggregated hour-of-week bucket per line
//!   in  : series_key,dow,hod,sample_value,bucket_count,bucket_sum,bucket_sum_sq,
//!         center,mad,p05,p95,consecutive_anomalous,baseline_excludes_latest
//!   out : series_key,dow,hod,sample_value,disposition,score,next_consecutive,surfaces
//!
//! `--kind capacity`: long-format forecast points (grouped by series_key)
//!   in  : series_key,at_unix_micros,value
//!   out : series_key,model,current_value,slope_per_second,projected_value,
//!         exhaustion_at_unix_micros,confidence,lower_bound,upper_bound,rmse,sample_count

use std::collections::HashMap;
use std::io::{self, BufRead, Read, Write};

use serviceradar_anomaly_disposition::{
    CapacityConfig, CapacityModelKind, CapacityPoint, CapacityRow, Disposition, RobustStatistic,
    SeasonalConfig, SeasonalRow, dispose_capacity, dispose_seasonal,
};

struct Args {
    kind: String,
    input: Option<String>,
    // seasonal
    n_sigma: f64,
    min_bucket_samples: usize,
    confirm_slots: usize,
    robust: RobustStatistic,
    // capacity
    horizon_seconds: i64,
    threshold: Option<f64>,
    model_kind: CapacityModelKind,
    min_history: usize,
    period: usize,
    value_min: Option<f64>,
    value_max: Option<f64>,
}

fn parse_args() -> Args {
    let mut a = Args {
        kind: "seasonal".to_string(),
        input: None,
        n_sigma: 3.0,
        min_bucket_samples: 4,
        confirm_slots: 1,
        robust: RobustStatistic::MeanStddev,
        horizon_seconds: 90 * 24 * 3600,
        threshold: None,
        model_kind: CapacityModelKind::Auto,
        min_history: 24,
        period: 24,
        value_min: None,
        value_max: None,
    };
    let mut it = std::env::args().skip(1);
    while let Some(flag) = it.next() {
        let mut next = || it.next();
        match flag.as_str() {
            "--kind" => a.kind = next().unwrap_or_else(|| "seasonal".to_string()),
            "--input" | "-i" => a.input = next(),
            "--n-sigma" => a.n_sigma = next().and_then(|v| v.parse().ok()).unwrap_or(3.0),
            "--min-bucket-samples" => {
                a.min_bucket_samples = next().and_then(|v| v.parse().ok()).unwrap_or(4)
            }
            "--confirm-slots" => a.confirm_slots = next().and_then(|v| v.parse().ok()).unwrap_or(1),
            "--robust" => {
                a.robust = match next().as_deref() {
                    Some("median_mad") => RobustStatistic::MedianMad,
                    Some("p05p95") => RobustStatistic::P05P95,
                    _ => RobustStatistic::MeanStddev,
                }
            }
            "--horizon-seconds" => {
                a.horizon_seconds = next()
                    .and_then(|v| v.parse().ok())
                    .unwrap_or(a.horizon_seconds)
            }
            "--threshold" => a.threshold = next().and_then(|v| v.parse().ok()),
            "--model" => {
                a.model_kind = match next().as_deref() {
                    Some("linear") => CapacityModelKind::Linear,
                    Some("seasonal") | Some("holt_winters") => CapacityModelKind::Seasonal,
                    _ => CapacityModelKind::Auto,
                }
            }
            "--min-history" => a.min_history = next().and_then(|v| v.parse().ok()).unwrap_or(24),
            "--period" => a.period = next().and_then(|v| v.parse().ok()).unwrap_or(24),
            "--value-min" => a.value_min = next().and_then(|v| v.parse().ok()),
            "--value-max" => a.value_max = next().and_then(|v| v.parse().ok()),
            other => eprintln!("disposition-backtest: ignoring unknown arg {other}"),
        }
    }
    a
}

fn read_lines(path: &Option<String>) -> io::Result<Box<dyn BufRead>> {
    match path {
        Some(p) if p != "-" => Ok(Box::new(io::BufReader::new(std::fs::File::open(p)?))),
        _ => {
            let mut buf = Vec::new();
            io::stdin().read_to_end(&mut buf)?;
            Ok(Box::new(io::BufReader::new(io::Cursor::new(buf))))
        }
    }
}

fn field<T: std::str::FromStr>(cols: &[&str], i: usize, name: &str) -> Result<T, String> {
    cols.get(i)
        .ok_or_else(|| format!("missing column {i} ({name})"))?
        .trim()
        .parse()
        .map_err(|_| format!("bad value for {name}: {:?}", cols.get(i)))
}

fn die(msg: String) -> ! {
    eprintln!("disposition-backtest: {msg}");
    std::process::exit(1);
}

fn main() {
    let args = parse_args();
    let input = read_lines(&args.input).unwrap_or_else(|e| die(e.to_string()));
    match args.kind.as_str() {
        "seasonal" => run_seasonal(args, input),
        "capacity" => run_capacity(args, input),
        other => die(format!("unknown --kind {other} (want seasonal|capacity)")),
    }
}

fn run_seasonal(args: Args, input: Box<dyn BufRead>) {
    let config = SeasonalConfig {
        seasonal_n_sigma: args.n_sigma,
        min_bucket_samples: args.min_bucket_samples,
        confirm_slots: args.confirm_slots,
        robust_statistic: args.robust,
    };
    let mut out = io::stdout().lock();
    let _ = writeln!(
        out,
        "series_key,dow,hod,sample_value,disposition,score,next_consecutive,surfaces"
    );
    for (n, line) in input.lines().enumerate() {
        let line = line.unwrap_or_else(|e| die(format!("line {}: {e}", n + 1)));
        let line = line.trim();
        if line.is_empty() || (n == 0 && line.starts_with("series_key")) {
            continue;
        }
        let c: Vec<&str> = line.split(',').collect();
        let row = (|| {
            Ok::<SeasonalRow, String>(SeasonalRow {
                series_key: c.first().ok_or("empty line")?.trim().to_string(),
                dow: field(&c, 1, "dow")?,
                hod: field(&c, 2, "hod")?,
                sample_value: field(&c, 3, "sample_value")?,
                bucket_count: field(&c, 4, "bucket_count")?,
                bucket_sum: field(&c, 5, "bucket_sum")?,
                bucket_sum_sq: field(&c, 6, "bucket_sum_sq")?,
                center: field(&c, 7, "center")?,
                mad: field(&c, 8, "mad")?,
                p05: field(&c, 9, "p05")?,
                p95: field(&c, 10, "p95")?,
                consecutive_anomalous: field(&c, 11, "consecutive_anomalous")?,
                baseline_excludes_latest: field::<u8>(&c, 12, "baseline_excludes_latest")? != 0,
            })
        })()
        .unwrap_or_else(|e| die(format!("line {}: {e}", n + 1)));
        let v = dispose_seasonal(row.clone(), &config);
        let label = match &v.disposition {
            Disposition::Suppress => "suppress",
            Disposition::SeasonalBreach { .. } => "seasonal_breach",
            Disposition::SeasonalDrift { .. } => "seasonal_drift",
            Disposition::InsufficientSeasonalBaseline => "insufficient_baseline",
            Disposition::Skipped { .. } => "skipped",
            Disposition::Projected(_) => "projected",
            Disposition::Inactive => "inactive",
        };
        let _ = writeln!(
            out,
            "{},{},{},{:.6},{},{:.6},{},{}",
            v.series_key,
            row.dow,
            row.hod,
            row.sample_value,
            label,
            v.score,
            v.next_consecutive_anomalous,
            v.disposition.surfaces(),
        );
    }
}

fn run_capacity(args: Args, input: Box<dyn BufRead>) {
    let config = CapacityConfig {
        capacity_threshold: args.threshold,
        horizon_seconds: args.horizon_seconds,
        model_kind: args.model_kind,
        min_history: args.min_history,
        period: args.period,
        alpha: 0.35,
        beta: 0.05,
        gamma: 0.25,
        value_min: args.value_min,
        value_max: args.value_max,
    };

    // group long-format points by series_key, preserving first-seen order
    let mut order: Vec<String> = Vec::new();
    let mut points: HashMap<String, Vec<CapacityPoint>> = HashMap::new();
    for (n, line) in input.lines().enumerate() {
        let line = line.unwrap_or_else(|e| die(format!("line {}: {e}", n + 1)));
        let line = line.trim();
        if line.is_empty() || (n == 0 && line.starts_with("series_key")) {
            continue;
        }
        let c: Vec<&str> = line.split(',').collect();
        let key = c.first().unwrap_or(&"").trim().to_string();
        let at: i64 =
            field(&c, 1, "at_unix_micros").unwrap_or_else(|e| die(format!("line {}: {e}", n + 1)));
        let value: f64 =
            field(&c, 2, "value").unwrap_or_else(|e| die(format!("line {}: {e}", n + 1)));
        points.entry(key.clone()).or_insert_with(|| {
            order.push(key.clone());
            Vec::new()
        });
        if let Some(v) = points.get_mut(&key) {
            v.push(CapacityPoint {
                at_unix_micros: at,
                value,
            });
        }
    }

    let mut out = io::stdout().lock();
    let _ = writeln!(
        out,
        "series_key,model,current_value,slope_per_second,projected_value,\
exhaustion_at_unix_micros,confidence,lower_bound,upper_bound,rmse,sample_count"
    );
    for key in order {
        let row = CapacityRow {
            series_key: key.clone(),
            points: points.remove(&key).unwrap_or_default(),
        };
        let v = dispose_capacity(row, &config);
        match v.disposition {
            Disposition::Projected(f) => {
                let _ = writeln!(
                    out,
                    "{},{},{:.6},{:.10},{:.6},{},{:.6},{:.6},{:.6},{:.6},{}",
                    v.series_key,
                    f.model,
                    f.current_value,
                    f.slope_per_second,
                    f.projected_value,
                    f.projected_exhaustion_at_unix_micros
                        .map(|m| m.to_string())
                        .unwrap_or_else(|| "none".to_string()),
                    f.confidence,
                    f.lower_bound,
                    f.upper_bound,
                    f.rmse,
                    f.sample_count,
                );
            }
            Disposition::Skipped { reason } => {
                let _ = writeln!(
                    out,
                    "{},skipped:{},,,,,,,,,",
                    v.series_key,
                    reason.replace(',', ";")
                );
            }
            other => {
                let _ = writeln!(out, "{},{:?},,,,,,,,,", v.series_key, other);
            }
        }
    }
}
