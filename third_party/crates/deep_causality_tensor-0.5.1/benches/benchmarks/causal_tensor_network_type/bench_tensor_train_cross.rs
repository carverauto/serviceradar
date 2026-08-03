/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! Stage-2b TT-cross: building a tensor train from an oracle without forming the dense tensor. The
//! oracle here is a separable (rank-1) function, recovered at bond dimension 1.

use criterion::{Criterion, criterion_group};
use deep_causality_tensor::{CausalTensorTrain, CrossConfig};
use std::hint::black_box;

const D: usize = 4; // sites
const N: usize = 3; // physical dimension

fn bench_cross_build(c: &mut Criterion) {
    let shape = [N; D];
    let cfg = CrossConfig::<f64>::with_rank_cap(4, 1e-10).unwrap();
    c.bench_function("tt_cross_rank1", |b| {
        b.iter(|| {
            CausalTensorTrain::<f64>::cross(
                black_box(&shape),
                |idx| {
                    idx.iter()
                        .map(|&i| (i as f64 + 1.0).sin() + 1.2)
                        .product::<f64>()
                },
                black_box(&cfg),
            )
            .unwrap()
        })
    });
}

criterion_group!(tensor_train_cross_benches, bench_cross_build);
