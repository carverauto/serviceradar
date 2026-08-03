/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! Stage-1 core tensor-train algebra: construction (TT-SVD), recompression, canonicalization, the
//! two-step `norm`/`inner` contractions, and the elementwise/reduction operations.

use criterion::{Criterion, criterion_group};
use deep_causality_tensor::{CausalTensor, CausalTensorTrain, TensorTrain, Truncation};
use std::hint::black_box;

const D: usize = 4; // sites
const N: usize = 4; // physical dimension

fn full() -> Truncation<f64> {
    Truncation::by_bond(4096).unwrap()
}

fn dense() -> CausalTensor<f64> {
    let shape = vec![N; D];
    let total: usize = shape.iter().product();
    let data: Vec<f64> = (0..total).map(|i| (i as f64 * 0.07).sin() + 1.5).collect();
    CausalTensor::new(data, shape).unwrap()
}

fn train() -> CausalTensorTrain<f64> {
    CausalTensorTrain::from_dense(&dense(), &full()).unwrap()
}

fn bench_from_dense(c: &mut Criterion) {
    let d = dense();
    let trunc = full();
    c.bench_function("tt_from_dense_4x4", |b| {
        b.iter(|| CausalTensorTrain::from_dense(black_box(&d), black_box(&trunc)).unwrap())
    });
}

fn bench_round(c: &mut Criterion) {
    let x = train();
    let trunc = full();
    c.bench_function("tt_round", |b| {
        b.iter(|| black_box(&x).round(black_box(&trunc)).unwrap())
    });
}

/// The sum of nine rank-1 trains over `[8,8,8,8]` (interior bond up to 9). This is a *small*-unfolding
/// case where deterministic Jacobi is expected to win — randomized rounding's `O(ℓ)` advantage only
/// amortizes once the unfoldings are large and low-rank (see the README crossover table and the
/// `svd_crossover_study` ignored test, where randomized is 38×–935× faster at 100²–1000²). Kept as the
/// honest small-scale data point that motivates keeping the deterministic kernel the default.
fn high_bond_train() -> CausalTensorTrain<f64> {
    let shape = [8usize, 8, 8, 8];
    let mut x = CausalTensorTrain::random_seeded(&shape, 1, 1);
    for s in 2..10u64 {
        x = x
            .add(&CausalTensorTrain::random_seeded(&shape, 1, s))
            .unwrap();
    }
    x
}

fn bench_round_randomized(c: &mut Criterion) {
    let x = high_bond_train();
    let det = Truncation::<f64>::by_tol(1e-8).unwrap();
    let rnd = det.randomized(8, 0xBEEF_CAFE);
    c.bench_function("tt_round_highbond_deterministic", |b| {
        b.iter(|| black_box(&x).round(black_box(&det)).unwrap())
    });
    c.bench_function("tt_round_highbond_randomized", |b| {
        b.iter(|| black_box(&x).round(black_box(&rnd)).unwrap())
    });
}

fn bench_canonicalize_at(c: &mut Criterion) {
    let x = train();
    c.bench_function("tt_canonicalize_at", |b| {
        b.iter(|| black_box(&x).canonicalize_at(2).unwrap())
    });
}

fn bench_norm(c: &mut Criterion) {
    let x = train();
    c.bench_function("tt_norm", |b| b.iter(|| black_box(&x).norm().unwrap()));
}

fn bench_inner(c: &mut Criterion) {
    let x = train();
    let y = train();
    c.bench_function("tt_inner", |b| {
        b.iter(|| black_box(&x).inner(black_box(&y)).unwrap())
    });
}

fn bench_add(c: &mut Criterion) {
    let x = train();
    let y = train();
    c.bench_function("tt_add", |b| {
        b.iter(|| black_box(&x).add(black_box(&y)).unwrap())
    });
}

fn bench_hadamard(c: &mut Criterion) {
    let x = train();
    let y = train();
    c.bench_function("tt_hadamard", |b| {
        b.iter(|| black_box(&x).hadamard(black_box(&y)).unwrap())
    });
}

fn bench_marginalize(c: &mut Criterion) {
    let x = train();
    c.bench_function("tt_marginalize", |b| {
        b.iter(|| black_box(&x).marginalize(black_box(&[1])).unwrap())
    });
}

fn bench_eval(c: &mut Criterion) {
    let x = train();
    let idx = vec![1usize, 2, 0, 3];
    c.bench_function("tt_eval", |b| {
        b.iter(|| black_box(&x).eval(black_box(&idx)).unwrap())
    });
}

criterion_group!(
    tensor_train_core_benches,
    bench_from_dense,
    bench_round,
    bench_round_randomized,
    bench_canonicalize_at,
    bench_norm,
    bench_inner,
    bench_add,
    bench_hadamard,
    bench_marginalize,
    bench_eval,
);
