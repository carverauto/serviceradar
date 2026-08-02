/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) "2025" . The DeepCausality Authors and Contributors. All Rights Reserved.
 */
use criterion::{Criterion, criterion_group};
use deep_causality_rand::Rng;
use deep_causality_tensor::{CausalTensor, Tensor};
use std::hint::black_box;

// Define some constants for tensor sizes
const LARGE_DIM_1: usize = 100;
const LARGE_DIM_2: usize = 100;
const LARGE_LEN: usize = LARGE_DIM_1 * LARGE_DIM_2;

// --- Benchmark Functions ---

fn bench_tensor_get(c: &mut Criterion) {
    let data: Vec<f64> = (0..LARGE_LEN).map(|i| i as f64).collect();
    let shape = vec![LARGE_DIM_1, LARGE_DIM_2];
    let tensor = CausalTensor::new(data, shape).unwrap();
    let mut rng = deep_causality_rand::rng();
    let idx = [
        rng.random_range(0..LARGE_DIM_1),
        rng.random_range(0..LARGE_DIM_2),
    ];

    c.bench_function("tensor_get", |b| {
        b.iter(|| {
            tensor.get(black_box(&idx)).unwrap();
        })
    });
}

fn bench_tensor_reshape(c: &mut Criterion) {
    let data: Vec<f64> = (0..LARGE_LEN).map(|i| i as f64).collect();
    let shape = vec![LARGE_DIM_1, LARGE_DIM_2];
    let tensor = CausalTensor::new(data, shape).unwrap();
    let new_shape = vec![LARGE_DIM_2, LARGE_DIM_1];

    c.bench_function("tensor_reshape", |b| {
        b.iter(|| {
            tensor.reshape(black_box(&new_shape)).unwrap();
        })
    });
}

fn bench_tensor_scalar_add(c: &mut Criterion) {
    let data: Vec<f64> = (0..LARGE_LEN).map(|i| i as f64).collect();
    let shape = vec![LARGE_DIM_1, LARGE_DIM_2];
    let tensor = CausalTensor::new(data, shape).unwrap();
    let scalar = 10.0;

    c.bench_function("tensor_scalar_add", |b| {
        b.iter(|| {
            let _ = black_box(&tensor) + black_box(scalar);
        })
    });
}

fn bench_tensor_tensor_add(c: &mut Criterion) {
    let data1: Vec<f64> = (0..LARGE_LEN).map(|i| i as f64).collect();
    let shape1 = vec![LARGE_DIM_1, LARGE_DIM_2];
    let t1 = CausalTensor::new(data1, shape1).unwrap();

    let data2: Vec<f64> = (0..LARGE_DIM_2).map(|i| i as f64).collect();
    let shape2 = vec![1, LARGE_DIM_2];
    let t2 = CausalTensor::new(data2, shape2).unwrap();

    c.bench_function("tensor_tensor_add_broadcast", |b| {
        b.iter(|| {
            let _ = black_box(&t1) + black_box(&t2);
        })
    });
}

fn bench_tensor_sum_full(c: &mut Criterion) {
    let data: Vec<f64> = (0..LARGE_LEN).map(|i| i as f64).collect();
    let shape = vec![LARGE_DIM_1, LARGE_DIM_2];
    let tensor = CausalTensor::new(data, shape).unwrap();

    c.bench_function("tensor_sum_full_reduction", |b| {
        b.iter(|| {
            tensor.sum_axes(black_box(&[])).unwrap();
        })
    });
}

criterion_group!(
    name = causal_tensor_benches;
    config = Criterion::default().sample_size(10);
    targets = bench_tensor_get, bench_tensor_reshape, bench_tensor_scalar_add, bench_tensor_tensor_add, bench_tensor_sum_full
);
