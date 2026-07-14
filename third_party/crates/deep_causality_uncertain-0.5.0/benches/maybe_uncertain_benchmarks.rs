/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use criterion::{Criterion, criterion_group, criterion_main};
use deep_causality_uncertain::{MaybeUncertain, Uncertain};

// --- Sampling Performance Benchmarks ---

fn bench_sampling_maybe_from_value(c: &mut Criterion) {
    let m = MaybeUncertain::<f64>::from_value(10.0);
    c.bench_function("sampling_maybe_from_value", |b| {
        b.iter(|| m.sample().unwrap());
    });
}

fn bench_sampling_maybe_from_uncertain(c: &mut Criterion) {
    let m = MaybeUncertain::<f64>::from_uncertain(Uncertain::<f64>::normal(10.0, 2.0));
    c.bench_function("sampling_maybe_from_uncertain", |b| {
        b.iter(|| m.sample().unwrap());
    });
}

// Canonical sparse-data case: 70% chance of presence, value ~ Normal(10, 2).
fn bench_sampling_maybe_bernoulli(c: &mut Criterion) {
    let m = MaybeUncertain::<f64>::from_bernoulli_and_uncertain(
        0.7,
        Uncertain::<f64>::normal(10.0, 2.0),
    );
    c.bench_function("sampling_maybe_bernoulli", |b| {
        b.iter(|| m.sample().unwrap());
    });
}

// Absent branch: short-circuits without sampling the value side.
fn bench_sampling_maybe_always_none(c: &mut Criterion) {
    let m = MaybeUncertain::<f64>::always_none();
    c.bench_function("sampling_maybe_always_none", |b| {
        b.iter(|| m.sample().unwrap());
    });
}

fn bench_sampling_maybe_bool(c: &mut Criterion) {
    let m = MaybeUncertain::<bool>::from_bernoulli_and_uncertain(
        0.7,
        Uncertain::<bool>::bernoulli(0.5),
    );
    c.bench_function("sampling_maybe_bool", |b| {
        b.iter(|| m.sample().unwrap());
    });
}

// (a + b) * c with presence-AND propagation on each operator.
fn bench_sampling_maybe_arithmetic_chain(c: &mut Criterion) {
    let a = MaybeUncertain::<f64>::from_bernoulli_and_uncertain(
        0.9,
        Uncertain::<f64>::normal(10.0, 1.0),
    );
    let b = MaybeUncertain::<f64>::from_bernoulli_and_uncertain(
        0.9,
        Uncertain::<f64>::normal(5.0, 0.5),
    );
    let c_val = MaybeUncertain::<f64>::from_bernoulli_and_uncertain(
        0.9,
        Uncertain::<f64>::normal(2.0, 0.1),
    );
    let d = (a + b) * c_val;

    c.bench_function("sampling_maybe_arithmetic_chain", |b| {
        b.iter(|| d.sample().unwrap());
    });
}

// --- Operator Overhead Benchmarks (Graph Construction) ---

fn bench_maybe_uncertain_f64_add_graph_construction(c: &mut Criterion) {
    let a = MaybeUncertain::<f64>::from_value(10.0);
    let b = MaybeUncertain::<f64>::from_value(5.0);
    c.bench_function("maybe_uncertain_f64_add_graph_construction", |bencher| {
        bencher.iter(|| {
            let cloned_a = a.clone();
            let cloned_b = b.clone();
            let _ = cloned_a + cloned_b;
        });
    });
}

fn bench_maybe_uncertain_f64_mul_graph_construction(c: &mut Criterion) {
    let a = MaybeUncertain::<f64>::from_value(10.0);
    let b = MaybeUncertain::<f64>::from_value(5.0);
    c.bench_function("maybe_uncertain_f64_mul_graph_construction", |bencher| {
        bencher.iter(|| {
            let cloned_a = a.clone();
            let cloned_b = b.clone();
            let _ = cloned_a * cloned_b;
        });
    });
}

fn bench_maybe_uncertain_f64_neg_graph_construction(c: &mut Criterion) {
    let a = MaybeUncertain::<f64>::from_value(10.0);
    c.bench_function("maybe_uncertain_f64_neg_graph_construction", |bencher| {
        bencher.iter(|| {
            let cloned_a = a.clone();
            let _ = -cloned_a;
        });
    });
}

// --- Combined Benchmarks (Graph Construction + Sampling) ---

fn bench_maybe_uncertain_f64_add_and_sample(c: &mut Criterion) {
    let a = MaybeUncertain::<f64>::from_bernoulli_and_uncertain(
        0.9,
        Uncertain::<f64>::normal(10.0, 1.0),
    );
    let b = MaybeUncertain::<f64>::from_bernoulli_and_uncertain(
        0.9,
        Uncertain::<f64>::normal(5.0, 0.5),
    );
    c.bench_function("maybe_uncertain_f64_add_and_sample", |bencher| {
        bencher.iter(|| {
            let cloned_a = a.clone();
            let cloned_b = b.clone();
            let sum = cloned_a + cloned_b;
            sum.sample().unwrap();
        });
    });
}

fn bench_maybe_uncertain_complex_chain_and_sample(c: &mut Criterion) {
    let s1 = MaybeUncertain::<f64>::from_bernoulli_and_uncertain(
        0.8,
        Uncertain::<f64>::normal(50.0, 2.0),
    );
    let s2 = MaybeUncertain::<f64>::from_bernoulli_and_uncertain(
        0.8,
        Uncertain::<f64>::normal(52.0, 1.5),
    );
    let s3 = MaybeUncertain::<f64>::from_bernoulli_and_uncertain(
        0.8,
        Uncertain::<f64>::normal(48.0, 1.0),
    );

    let combined = (s1 + s2 + s3) / MaybeUncertain::<f64>::from_value(3.0);

    c.bench_function("maybe_uncertain_complex_chain_and_sample", |b| {
        b.iter(|| {
            combined.sample().unwrap();
        });
    });
}

// --- lift_to_uncertain (SPRT Gate) Benchmarks ---
//
// `lift_to_uncertain` runs an SPRT on the `is_present` branch and only exposes
// the inner Uncertain<T> if the evidence clears a confidence threshold. SPRT
// terminates faster when the true probability is far from the threshold, so
// these three benchmarks span the easy-accept, ambiguous, and easy-reject
// regimes. Threshold = 0.5, confidence = 0.95, epsilon = 0.05, cap = 1000.

fn bench_lift_to_uncertain_confidently_present(c: &mut Criterion) {
    let m = MaybeUncertain::<f64>::from_bernoulli_and_uncertain(
        0.95,
        Uncertain::<f64>::normal(10.0, 1.0),
    );
    c.bench_function("lift_to_uncertain_confidently_present", |bencher| {
        bencher.iter(|| {
            let _ = m.lift_to_uncertain(0.5, 0.95, 0.05, 1000);
        });
    });
}

fn bench_lift_to_uncertain_close_to_threshold(c: &mut Criterion) {
    let m = MaybeUncertain::<f64>::from_bernoulli_and_uncertain(
        0.55,
        Uncertain::<f64>::normal(10.0, 1.0),
    );
    c.bench_function("lift_to_uncertain_close_to_threshold", |bencher| {
        bencher.iter(|| {
            let _ = m.lift_to_uncertain(0.5, 0.95, 0.05, 1000);
        });
    });
}

fn bench_lift_to_uncertain_confidently_absent(c: &mut Criterion) {
    let m = MaybeUncertain::<f64>::from_bernoulli_and_uncertain(
        0.1,
        Uncertain::<f64>::normal(10.0, 1.0),
    );
    c.bench_function("lift_to_uncertain_confidently_absent", |bencher| {
        bencher.iter(|| {
            let _ = m.lift_to_uncertain(0.5, 0.95, 0.05, 1000);
        });
    });
}

criterion_group!(
    benches,
    bench_sampling_maybe_from_value,
    bench_sampling_maybe_from_uncertain,
    bench_sampling_maybe_bernoulli,
    bench_sampling_maybe_always_none,
    bench_sampling_maybe_bool,
    bench_sampling_maybe_arithmetic_chain,
    bench_maybe_uncertain_f64_add_graph_construction,
    bench_maybe_uncertain_f64_mul_graph_construction,
    bench_maybe_uncertain_f64_neg_graph_construction,
    bench_maybe_uncertain_f64_add_and_sample,
    bench_maybe_uncertain_complex_chain_and_sample,
    bench_lift_to_uncertain_confidently_present,
    bench_lift_to_uncertain_close_to_threshold,
    bench_lift_to_uncertain_confidently_absent,
);
criterion_main!(benches);
