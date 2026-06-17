// Copyright 2026 Carver Automation Corporation.
//
// Licensed under the Apache License, Version 2.0 (the "License").
// SPDX-License-Identifier: Apache-2.0

//! Reasoner-only microbenchmark. Isolates the causaloid evaluation from the
//! per-series engine (no HashMap, no decode, no counter normalization) so the
//! cost of the reasoner itself can be separated from the cost of the stateless
//! window rebuild. Three modes over a warm window:
//!   (1) reason_impl          -- the shipped `CausalFlow` reasoner, which rebuilds
//!                               the Welford accumulator from the window each call
//!                               (the stateless path, O(window));
//!   (2) kernel recompute O(W)-- `WelfordAcc::from_values` + `z_score` alone (the
//!                               O(window) rebuild cost on its own);
//!   (3) kernel incremental O(1)-- a reversible Welford add/remove + `z_score`
//!                               (the ceiling if the engine carried the accumulator
//!                               instead of rebuilding it).
//!
//! Usage: `reasoner_bench [window] [iters]`  (defaults: 300, 5_000_000).

use std::time::Instant;

use serviceradar_anomaly_core::{
    DEFAULT_CONFIRM_SLOTS, DEFAULT_MIN_SAMPLES, DEFAULT_N_SIGMA, DEFAULT_WINDOW_SIZE, ReasonContext,
    ReasonSample, WelfordAcc, reason_impl, z_score,
};

fn deterministic_window(window: usize) -> Vec<f64> {
    (0..window)
        .map(|i| 100.0 + ((i as u64).wrapping_mul(2_654_435_761) % 1000) as f64 / 100.0)
        .collect()
}

fn ctx_template(window_tail: Vec<f64>) -> ReasonContext {
    ReasonContext {
        baseline: Vec::new(),
        rolling_acc: None,
        window_tail: Some(window_tail),
        seasonal_baseline: None,
        trend_baseline: None,
        rolling_enabled: Some(true),
        seasonal_enabled: Some(false),
        trend_enabled: Some(false),
        min_samples: Some(DEFAULT_MIN_SAMPLES),
        seasonal_min_samples: None,
        trend_min_samples: None,
        window_size: Some(DEFAULT_WINDOW_SIZE),
        n_sigma: Some(DEFAULT_N_SIGMA),
        seasonal_n_sigma: None,
        trend_n_sigma: None,
        confirm_slots: Some(DEFAULT_CONFIRM_SLOTS),
        consecutive_anomalous: Some(0),
    }
}

fn report(label: &str, iters: usize, elapsed: f64, sink: f64) {
    println!(
        "  {label:<26} {:>13.0} eval/s   ({iters} in {elapsed:.3}s, sink={sink:.1})",
        iters as f64 / elapsed
    );
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let window: usize = args
        .get(1)
        .and_then(|s| s.parse().ok())
        .unwrap_or(DEFAULT_WINDOW_SIZE);
    let iters: usize = args
        .get(2)
        .and_then(|s| s.parse().ok())
        .unwrap_or(5_000_000);
    let win = deterministic_window(window);
    let template = ctx_template(win.clone());
    let threshold = DEFAULT_N_SIGMA;

    println!("reasoner_bench: window={window} iters={iters}");

    // (1) Full shipped reasoner: CausalFlow pipeline + O(window) rebuild. A fresh
    // context is supplied each call, exactly as the engine builds one per sample.
    let mut sink = 0.0f64;
    let start = Instant::now();
    for i in 0..iters {
        let value = 100.0 + (i % 7) as f64 * 0.1;
        let verdict = reason_impl(
            template.clone(),
            ReasonSample {
                value,
                observed_at_unix_nano: Some(i as u64),
            },
        )
        .expect("finite sample");
        sink += verdict.score;
    }
    report(
        "reason_impl (CausalFlow)",
        iters,
        start.elapsed().as_secs_f64(),
        sink,
    );

    // (2) Kernel recompute: rebuild the Welford accumulator from the window and
    // score. This is the O(window) work the stateless path repeats every call.
    let mut sink = 0.0f64;
    let start = Instant::now();
    for i in 0..iters {
        let value = 100.0 + (i % 7) as f64 * 0.1;
        let stats = WelfordAcc::from_values(&win).stats().expect("ready");
        sink += z_score(value, stats, threshold);
    }
    report(
        "kernel recompute O(W)",
        iters,
        start.elapsed().as_secs_f64(),
        sink,
    );

    // (3) Kernel incremental: reversible Welford add/remove + score, the O(1)
    // ceiling if the engine carried the accumulator instead of rebuilding it.
    let mut acc = WelfordAcc::from_values(&win);
    let mut ring = win.clone();
    let mut head = 0usize;
    let mut sink = 0.0f64;
    let start = Instant::now();
    for i in 0..iters {
        let value = 100.0 + (i % 7) as f64 * 0.1;
        let stats = match acc.stats() {
            Some(s) => s,
            None => {
                acc = WelfordAcc::from_values(&ring);
                acc.stats().expect("rebuilt")
            }
        };
        sink += z_score(value, stats, threshold);
        let evicted = ring[head];
        acc.remove(evicted);
        ring[head] = value;
        acc.add(value);
        head = (head + 1) % ring.len();
    }
    report(
        "kernel incremental O(1)",
        iters,
        start.elapsed().as_secs_f64(),
        sink,
    );
}
