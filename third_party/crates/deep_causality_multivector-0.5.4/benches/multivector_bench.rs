/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use criterion::{Criterion, criterion_group, criterion_main};
use deep_causality_multivector::{CausalMultiVector, Metric, MultiVector, PGA3DMultiVector};
use std::hint::black_box;

fn bench_geometric_product_euclidean_2d(c: &mut Criterion) {
    let m = Metric::Euclidean(2);
    let a = CausalMultiVector::new(vec![1.0, 2.0, 3.0, 4.0], m).unwrap();
    let b = CausalMultiVector::new(vec![4.0, 3.0, 2.0, 1.0], m).unwrap();

    c.bench_function("geometric_product_euclidean_2d", |bencher| {
        bencher.iter(|| black_box(a.clone()) * black_box(b.clone()))
    });
}

fn bench_geometric_product_pga_3d(c: &mut Criterion) {
    // PGA 3D is 4D algebra (16 elements)
    let p = PGA3DMultiVector::new_point(1.0, 2.0, 3.0);
    let t = PGA3DMultiVector::translator(2.0, 0.0, 0.0);

    c.bench_function("geometric_product_pga_3d", |bencher| {
        bencher.iter(|| black_box(t.clone()) * black_box(p.clone()))
    });
}

fn bench_addition_euclidean_3d(c: &mut Criterion) {
    let m = Metric::Euclidean(3);
    let data = vec![1.0; 8];
    let a = CausalMultiVector::new(data.clone(), m).unwrap();
    let b = CausalMultiVector::new(data, m).unwrap();

    c.bench_function("addition_euclidean_3d", |bencher| {
        bencher.iter(|| black_box(a.clone()) + black_box(b.clone()))
    });
}

fn bench_reversion_pga_3d(c: &mut Criterion) {
    let t = PGA3DMultiVector::translator(2.0, 0.0, 0.0);

    c.bench_function("reversion_pga_3d", |bencher| {
        bencher.iter(|| black_box(t.clone()).reversion())
    });
}

// === Dixon Algebra / Large Dimension Benchmarks ===

fn bench_dixon_cpu(c: &mut Criterion) {
    // Dixon Algebra: Cl(0, 6) -> 64 dimensions
    // Used in particle physics (GUTs).
    let m = Metric::from_signature(0, 6, 0);
    // 2^6 = 64 elements
    let data = vec![0.5; 64];

    // CPU Algebraic Implementation (CausalMultiVector)
    let a = CausalMultiVector::unchecked(data.clone(), m);
    let b = CausalMultiVector::unchecked(data, m);

    c.bench_function("geometric_product_dixon_cpu_algebraic", |bencher| {
        bencher.iter(|| black_box(a.clone()) * black_box(b.clone()))
    });
}

criterion_group!(
    benches,
    bench_geometric_product_euclidean_2d,
    bench_geometric_product_pga_3d,
    bench_addition_euclidean_3d,
    bench_reversion_pga_3d,
    bench_dixon_cpu,
);
criterion_main!(benches);
