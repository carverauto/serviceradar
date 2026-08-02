/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! Stage-2a matrix-product operator: operator TT-SVD, MPO·MPS `apply`, MPO·MPO `compose`, and the
//! per-site `integrate` contraction.

use criterion::{Criterion, criterion_group};
use deep_causality_tensor::{
    CausalTensor, CausalTensorTrain, CausalTensorTrainOperator, TensorTrain, TensorTrainOperator,
    Truncation,
};
use std::hint::black_box;

const D: usize = 3; // sites
const N: usize = 2; // physical dimension (per leg)

fn full() -> Truncation<f64> {
    Truncation::by_bond(4096).unwrap()
}

fn op_dense() -> CausalTensor<f64> {
    // Site-interleaved [out_0, in_0, …] layout.
    let shape: Vec<usize> = (0..D).flat_map(|_| [N, N]).collect();
    let total: usize = shape.iter().product();
    let data: Vec<f64> = (0..total).map(|i| (i as f64 * 0.05).cos() + 0.5).collect();
    CausalTensor::new(data, shape).unwrap()
}

fn operator() -> CausalTensorTrainOperator<f64> {
    CausalTensorTrainOperator::from_dense(&op_dense(), &[N; D], &[N; D], &full()).unwrap()
}

fn state() -> CausalTensorTrain<f64> {
    let shape = vec![N; D];
    let total: usize = shape.iter().product();
    let data: Vec<f64> = (0..total).map(|i| (i as f64 * 0.1).sin() + 1.0).collect();
    CausalTensorTrain::from_dense(&CausalTensor::new(data, shape).unwrap(), &full()).unwrap()
}

fn bench_mpo_from_dense(c: &mut Criterion) {
    let d = op_dense();
    let trunc = full();
    c.bench_function("mpo_from_dense", |b| {
        b.iter(|| {
            CausalTensorTrainOperator::from_dense(
                black_box(&d),
                &[N; D],
                &[N; D],
                black_box(&trunc),
            )
            .unwrap()
        })
    });
}

fn bench_mpo_apply(c: &mut Criterion) {
    let a = operator();
    let x = state();
    let trunc = full();
    c.bench_function("mpo_apply", |b| {
        b.iter(|| {
            black_box(&a)
                .apply(black_box(&x), black_box(&trunc))
                .unwrap()
        })
    });
}

fn bench_mpo_compose(c: &mut Criterion) {
    let a = operator();
    let trunc = full();
    c.bench_function("mpo_compose", |b| {
        b.iter(|| {
            black_box(&a)
                .compose(black_box(&a), black_box(&trunc))
                .unwrap()
        })
    });
}

fn bench_integrate(c: &mut Criterion) {
    let x = state();
    let weights: Vec<CausalTensor<f64>> = (0..D)
        .map(|_| CausalTensor::new(vec![1.0; N], vec![N]).unwrap())
        .collect();
    c.bench_function("tt_integrate", |b| {
        b.iter(|| black_box(&x).integrate(black_box(&weights)).unwrap())
    });
}

criterion_group!(
    tensor_train_operator_benches,
    bench_mpo_from_dense,
    bench_mpo_apply,
    bench_mpo_compose,
    bench_integrate,
);
