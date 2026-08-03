/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! Stage-0 numerics: the truncated one-sided-Jacobi SVD and the Householder QR — the kernels that
//! gate every downstream tensor-train operation. Sizes are kept small so the suite runs in seconds.

use criterion::{Criterion, criterion_group};
use deep_causality_tensor::{CausalTensor, Truncation};
use std::hint::black_box;

const N: usize = 48; // square matrix dimension

fn matrix(n: usize) -> CausalTensor<f64> {
    let data: Vec<f64> = (0..n * n).map(|i| (i as f64 * 0.1).sin() + 0.3).collect();
    CausalTensor::new(data, vec![n, n]).unwrap()
}

fn bench_svd_truncated(c: &mut Criterion) {
    let m = matrix(N);
    let trunc = Truncation::<f64>::by_bond(N).unwrap();
    c.bench_function("tt_svd_truncated_48x48", |b| {
        b.iter(|| black_box(&m).svd_truncated(black_box(&trunc)).unwrap())
    });
}

fn bench_qr(c: &mut Criterion) {
    let m = matrix(N);
    c.bench_function("tt_qr_48x48", |b| b.iter(|| black_box(&m).qr().unwrap()));
}

criterion_group!(svd_qr_benches, bench_svd_truncated, bench_qr);
