// Copyright 2026 Carver Automation Corporation.
//
// Licensed under the Apache License, Version 2.0 (the "License").
// SPDX-License-Identifier: Apache-2.0

//! Edge resource benchmark for the anomaly add-on detector
//! (move-anomaly-detection-to-edge §6.2). Drives `DetectorEngine` at a realistic
//! per-host series count and reports evaluation throughput + the live series
//! count; run under `/usr/bin/time -v` to capture max RSS (the on-host memory
//! bound the cgroup limit enforces).
//!
//! Usage: `edge_bench [num_series] [rounds]`  (defaults: 2000 series, 400 rounds).
//! Keys are pre-built so the measured cost is the detector, not string alloc.

use std::time::Instant;

use serviceradar_anomaly_addon::engine::{DetectorEngine, EngineConfig, SeriesProfile};

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let series: usize = args.get(1).and_then(|s| s.parse().ok()).unwrap_or(2000);
    let rounds: usize = args.get(2).and_then(|s| s.parse().ok()).unwrap_or(400);

    let mut engine = DetectorEngine::new(EngineConfig::default());
    let keys: Vec<String> = (0..series).map(|s| format!("series-{s}")).collect();

    let mut breaches: u64 = 0;
    let mut ts: u64 = 0;
    let start = Instant::now();

    for round in 0..rounds {
        for (s, key) in keys.iter().enumerate() {
            ts += 1;
            // Deterministic per-series/round noise (~0..10) around a 100 baseline,
            // with a rare injected spike once the window is warm.
            let noise = ((s as u64)
                .wrapping_mul(2_654_435_761)
                .wrapping_add(round as u64 * 40_503)
                % 1_000) as f64
                / 100.0;
            // Inject a rare spike (~0.1% of evals once warm) so the breach path is
            // exercised, not just the steady-state recompute.
            let value = if round > 50 && s.wrapping_mul(31).wrapping_add(round) % 997 == 0 {
                100.0 + noise + 500.0
            } else {
                100.0 + noise
            };

            if let Some(verdict) = engine.evaluate(key, value, ts, SeriesProfile::default())
                && verdict.breached
            {
                breaches += 1;
            }
        }
    }

    let elapsed = start.elapsed().as_secs_f64();
    let evals = (series * rounds) as f64;
    // Rough working-set estimate: window_tail (window_size f64) + map/counter
    // overhead per live series.
    let approx_kb_per_series = (EngineConfig::default().window_size * 8 + 256) as f64 / 1024.0;

    println!(
        "edge_bench: series={series} rounds={rounds} evals={}",
        evals as u64
    );
    println!(
        "  elapsed={elapsed:.3}s throughput={:.0} evals/s",
        evals / elapsed
    );
    println!(
        "  live_series={} breaches={breaches}",
        engine.series_count()
    );
    println!(
        "  approx detector working set ~= {:.1} MiB ({:.1} KiB/series x {} series)",
        approx_kb_per_series * engine.series_count() as f64 / 1024.0,
        approx_kb_per_series,
        engine.series_count(),
    );
}
