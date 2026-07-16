// Copyright 2026 Carver Automation Corporation.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// SPDX-License-Identifier: Apache-2.0

//! Upper-bound benchmark control for the current protobuf metrics pipeline.
//!
//! This binary is intentionally a spike harness, not a production replacement
//! for EventWriter. It measures:
//! - fixture read bytes;
//! - canonical `MetricBatch` decode + row flattening;
//! - deterministic anomaly/capacity hook CPU loops;
//! - optional batched PostgreSQL writes into a temporary table.
//!
//! Environment:
//! - `METRIC_BENCH_FIXTURE_DIR` (default: `tmp/metric-fixtures/demo-smoke-cli`)
//! - `METRIC_BENCH_REPEAT` (default: `1`)
//! - `METRIC_BENCH_TENANT_ID` (default: `bench`)
//! - `METRIC_BENCH_BATCH_ROWS` (default: `5000`)
//! - `METRIC_BENCH_PG_DSN` (optional; temp-table writes only)

use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use serviceradar_metrics_delta_writer::pipeline::batch_to_rows;
use serviceradar_metrics_delta_writer::sink::MetricRow;
use tokio_postgres::types::ToSql;

const DEFAULT_FIXTURE_DIR: &str = "tmp/metric-fixtures/demo-smoke-cli";
const DEFAULT_TENANT_ID: &str = "bench";
const DEFAULT_BATCH_ROWS: usize = 5_000;

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let config = BenchConfig::from_env();
    let fixture_paths = fixture_paths(&config.fixture_dir)?;

    if fixture_paths.is_empty() {
        anyhow::bail!(
            "no fixture files found in {}; capture MetricBatch payloads or set METRIC_BENCH_FIXTURE_DIR",
            config.fixture_dir.display()
        );
    }

    let read = timed_result(|| read_payloads(&fixture_paths, config.repeat))?;
    let read_elapsed = read.elapsed;
    let payloads = read.value;
    let payload_bytes: usize = payloads.iter().map(Vec::len).sum();

    let decode = timed_result(|| decode_payloads(&config.tenant_id, &payloads))?;
    let decode_elapsed = decode.elapsed;
    let rows = decode.value;

    let anomaly = timed(|| anomaly_hook(&rows));
    let capacity = timed(|| capacity_hook(&rows));

    let pg = if let Some(dsn) = &config.pg_dsn {
        Some(
            postgres_temp_write(dsn, config.batch_rows, &rows)
                .await
                .map_err(|err| anyhow::anyhow!("postgres benchmark failed: {err:#}"))?,
        )
    } else {
        None
    };

    print_report(
        &config,
        &fixture_paths,
        payload_bytes,
        &rows,
        read_elapsed,
        decode_elapsed,
        &anomaly,
        &capacity,
        pg.as_ref(),
    );

    Ok(())
}

#[derive(Debug)]
struct BenchConfig {
    fixture_dir: PathBuf,
    repeat: usize,
    tenant_id: String,
    batch_rows: usize,
    pg_dsn: Option<String>,
}

impl BenchConfig {
    fn from_env() -> Self {
        Self {
            fixture_dir: PathBuf::from(env_string("METRIC_BENCH_FIXTURE_DIR", DEFAULT_FIXTURE_DIR)),
            repeat: env_usize("METRIC_BENCH_REPEAT", 1).max(1),
            tenant_id: env_string("METRIC_BENCH_TENANT_ID", DEFAULT_TENANT_ID),
            batch_rows: env_usize("METRIC_BENCH_BATCH_ROWS", DEFAULT_BATCH_ROWS).max(1),
            pg_dsn: std::env::var("METRIC_BENCH_PG_DSN")
                .ok()
                .filter(|value| !value.trim().is_empty()),
        }
    }
}

#[derive(Debug)]
struct Timed<T> {
    value: T,
    elapsed: Duration,
}

fn timed<T>(f: impl FnOnce() -> T) -> Timed<T> {
    let started = Instant::now();
    let value = f();
    Timed {
        value,
        elapsed: started.elapsed(),
    }
}

fn timed_result<T>(f: impl FnOnce() -> anyhow::Result<T>) -> anyhow::Result<Timed<T>> {
    let started = Instant::now();
    let value = f()?;
    Ok(Timed {
        value,
        elapsed: started.elapsed(),
    })
}

fn fixture_paths(dir: &Path) -> anyhow::Result<Vec<PathBuf>> {
    let mut paths = Vec::new();
    for entry in fs::read_dir(dir)? {
        let entry = entry?;
        let path = entry.path();
        if path.is_file() {
            paths.push(path);
        }
    }
    paths.sort();
    Ok(paths)
}

fn read_payloads(paths: &[PathBuf], repeat: usize) -> anyhow::Result<Vec<Vec<u8>>> {
    let mut payloads = Vec::with_capacity(paths.len() * repeat);
    for _ in 0..repeat {
        for path in paths {
            let mut payload = fs::read(path)?;
            strip_raw_cli_newline(&mut payload);
            payloads.push(payload);
        }
    }
    Ok(payloads)
}

fn decode_payloads(tenant_id: &str, payloads: &[Vec<u8>]) -> anyhow::Result<Vec<MetricRow>> {
    let mut rows = Vec::new();
    for payload in payloads {
        rows.extend(batch_to_rows(tenant_id, payload)?);
    }
    Ok(rows)
}

#[derive(Debug)]
struct AnomalyHookStats {
    series: usize,
    samples: usize,
    verdicts: usize,
}

#[derive(Debug, Default, Clone, Copy)]
struct Welford {
    count: u64,
    mean: f64,
    m2: f64,
}

impl Welford {
    fn observe(&mut self, value: f64) -> bool {
        let stddev = if self.count > 1 {
            (self.m2 / (self.count - 1) as f64).sqrt()
        } else {
            0.0
        };
        let anomalous =
            self.count >= 30 && stddev > 0.0 && ((value - self.mean).abs() / stddev) >= 3.0;

        self.count += 1;
        let delta = value - self.mean;
        self.mean += delta / self.count as f64;
        let delta2 = value - self.mean;
        self.m2 += delta * delta2;

        anomalous
    }
}

fn anomaly_hook(rows: &[MetricRow]) -> AnomalyHookStats {
    let mut states: HashMap<&str, Welford> = HashMap::new();
    let mut verdicts = 0;

    for row in rows {
        let key = if row.series_identity_hint.is_empty() {
            row.metric_name.as_str()
        } else {
            row.series_identity_hint.as_str()
        };
        if states.entry(key).or_default().observe(row.value) {
            verdicts += 1;
        }
    }

    AnomalyHookStats {
        series: states.len(),
        samples: rows.len(),
        verdicts,
    }
}

#[derive(Debug)]
struct CapacityHookStats {
    series: usize,
    samples: usize,
    accumulated_value: f64,
}

fn capacity_hook(rows: &[MetricRow]) -> CapacityHookStats {
    let mut aggregates: HashMap<&str, (usize, f64, f64, f64)> = HashMap::new();

    for row in rows {
        let entry = aggregates
            .entry(row.metric_name.as_str())
            .or_insert((0, row.value, row.value, 0.0));
        entry.0 += 1;
        entry.1 = entry.1.min(row.value);
        entry.2 = entry.2.max(row.value);
        entry.3 += row.value;
    }

    CapacityHookStats {
        series: aggregates.len(),
        samples: rows.len(),
        accumulated_value: aggregates.values().map(|(_, _, _, sum)| sum).sum(),
    }
}

#[derive(Debug)]
struct PostgresWriteStats {
    rows: usize,
    batches: usize,
    elapsed: Duration,
}

async fn postgres_temp_write(
    dsn: &str,
    batch_rows: usize,
    rows: &[MetricRow],
) -> anyhow::Result<PostgresWriteStats> {
    let (client, connection) = tokio_postgres::connect(dsn, tokio_postgres::NoTls).await?;
    tokio::spawn(async move {
        if let Err(err) = connection.await {
            eprintln!("postgres benchmark connection error: {err}");
        }
    });

    client
        .batch_execute(
            r#"
            CREATE TEMP TABLE IF NOT EXISTS sr_metric_bench_points (
              tenant_id text NOT NULL,
              agent_id text NOT NULL,
              metric_name text NOT NULL,
              series_identity_hint text NOT NULL,
              observed_at_unix_nano bigint NOT NULL,
              value double precision NOT NULL
            ) ON COMMIT PRESERVE ROWS;
            TRUNCATE sr_metric_bench_points;
            "#,
        )
        .await?;

    let started = Instant::now();
    let mut batches = 0;
    for chunk in rows.chunks(batch_rows) {
        insert_chunk(&client, chunk).await?;
        batches += 1;
    }

    Ok(PostgresWriteStats {
        rows: rows.len(),
        batches,
        elapsed: started.elapsed(),
    })
}

async fn insert_chunk(client: &tokio_postgres::Client, rows: &[MetricRow]) -> anyhow::Result<()> {
    if rows.is_empty() {
        return Ok(());
    }

    let mut sql = String::from(
        "INSERT INTO sr_metric_bench_points \
         (tenant_id, agent_id, metric_name, series_identity_hint, observed_at_unix_nano, value) VALUES ",
    );
    let observed_at: Vec<i64> = rows
        .iter()
        .map(|row| row.observed_at_unix_nano.min(i64::MAX as u64) as i64)
        .collect();
    let mut params: Vec<&(dyn ToSql + Sync)> = Vec::with_capacity(rows.len() * 6);

    for (idx, row) in rows.iter().enumerate() {
        if idx > 0 {
            sql.push(',');
        }
        let base = idx * 6;
        sql.push_str(&format!(
            "(${}, ${}, ${}, ${}, ${}, ${})",
            base + 1,
            base + 2,
            base + 3,
            base + 4,
            base + 5,
            base + 6
        ));

        params.push(&row.tenant_id);
        params.push(&row.agent_id);
        params.push(&row.metric_name);
        params.push(&row.series_identity_hint);
        params.push(&observed_at[idx]);
        params.push(&row.value);
    }

    client.execute(sql.as_str(), &params).await?;
    Ok(())
}

#[allow(clippy::too_many_arguments)]
fn print_report(
    config: &BenchConfig,
    paths: &[PathBuf],
    payload_bytes: usize,
    rows: &[MetricRow],
    read_elapsed: Duration,
    decode_elapsed: Duration,
    anomaly: &Timed<AnomalyHookStats>,
    capacity: &Timed<CapacityHookStats>,
    pg: Option<&PostgresWriteStats>,
) {
    println!("Metric protobuf Rust benchmark control");
    println!("fixture_dir={}", config.fixture_dir.display());
    println!("fixture_files={}", paths.len());
    println!("repeat={}", config.repeat);
    println!("payload_bytes={payload_bytes}");
    println!("rows={}", rows.len());
    println!();

    print_phase(
        "read_payloads",
        paths.len() * config.repeat,
        payload_bytes,
        read_elapsed,
    );
    print_phase(
        "decode_transform",
        rows.len(),
        payload_bytes,
        decode_elapsed,
    );
    print_phase(
        "anomaly_hook",
        anomaly.value.samples,
        payload_bytes,
        anomaly.elapsed,
    );
    println!(
        "anomaly_hook_series={} anomaly_hook_verdicts={}",
        anomaly.value.series, anomaly.value.verdicts
    );
    print_phase(
        "capacity_hook",
        capacity.value.samples,
        payload_bytes,
        capacity.elapsed,
    );
    println!(
        "capacity_hook_series={} capacity_hook_accumulated_value={:.3}",
        capacity.value.series, capacity.value.accumulated_value
    );

    match pg {
        Some(stats) => {
            print_phase(
                "postgres_temp_insert",
                stats.rows,
                payload_bytes,
                stats.elapsed,
            );
            println!(
                "postgres_temp_insert_batches={} postgres_temp_insert_batch_rows={}",
                stats.batches, config.batch_rows
            );
        }
        None => {
            println!("postgres_temp_insert=skipped set METRIC_BENCH_PG_DSN to enable");
        }
    }
}

fn print_phase(name: &str, units: usize, bytes: usize, elapsed: Duration) {
    let seconds = elapsed.as_secs_f64().max(f64::EPSILON);
    println!(
        "{name}_elapsed_ms={:.3} {name}_units_per_second={:.3} {name}_mib_per_second={:.3}",
        elapsed.as_secs_f64() * 1_000.0,
        units as f64 / seconds,
        (bytes as f64 / 1024.0 / 1024.0) / seconds
    );
}

fn strip_raw_cli_newline(payload: &mut Vec<u8>) {
    if payload.last() == Some(&b'\n') {
        payload.pop();
    }
}

fn env_string(name: &str, default: &str) -> String {
    std::env::var(name).unwrap_or_else(|_| default.to_owned())
}

fn env_usize(name: &str, default: usize) -> usize {
    std::env::var(name)
        .ok()
        .and_then(|value| value.parse().ok())
        .filter(|value| *value > 0)
        .unwrap_or(default)
}
