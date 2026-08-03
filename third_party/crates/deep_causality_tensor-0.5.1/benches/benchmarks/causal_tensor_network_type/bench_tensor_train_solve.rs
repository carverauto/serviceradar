/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! Stage-2c/3 solvers sharing the alternating sweep engine: AMEn `linear`, ALS `fit`, DMRG3S
//! `eigen`, and the two-site `tdvp_step`. Instances are small so each solve converges quickly.

use criterion::{Criterion, criterion_group};
use deep_causality_tensor::{
    CausalTensor, CausalTensorTrain, CausalTensorTrainOperator, SolveConfig, TensorTrain,
    TensorTrainOperator, Truncation, solve,
};
use std::hint::black_box;

fn full() -> Truncation<f64> {
    Truncation::by_bond(4096).unwrap()
}

fn interleaved_index(out: usize, inx: usize, dims: &[usize]) -> usize {
    let d = dims.len();
    let (mut o, mut i) = (out, inx);
    let mut o_dig = vec![0usize; d];
    let mut i_dig = vec![0usize; d];
    for k in (0..d).rev() {
        o_dig[k] = o % dims[k];
        o /= dims[k];
        i_dig[k] = i % dims[k];
        i /= dims[k];
    }
    let mut idx = 0usize;
    for k in 0..d {
        idx = idx * dims[k] + o_dig[k];
        idx = idx * dims[k] + i_dig[k];
    }
    idx
}

fn operator_from_matrix(mmat: &[f64], dims: &[usize]) -> CausalTensorTrainOperator<f64> {
    let nn: usize = dims.iter().product();
    let mut inter = vec![0.0f64; nn * nn];
    for out in 0..nn {
        for inx in 0..nn {
            inter[interleaved_index(out, inx, dims)] = mmat[out * nn + inx];
        }
    }
    let shape: Vec<usize> = dims.iter().flat_map(|&d| [d, d]).collect();
    CausalTensorTrainOperator::from_dense(
        &CausalTensor::new(inter, shape).unwrap(),
        dims,
        dims,
        &full(),
    )
    .unwrap()
}

fn state(shape: &[usize], seed: f64) -> CausalTensorTrain<f64> {
    let total: usize = shape.iter().product();
    let data: Vec<f64> = (0..total).map(|i| (i as f64 * seed).sin() + 1.5).collect();
    CausalTensorTrain::from_dense(&CausalTensor::new(data, shape.to_vec()).unwrap(), &full())
        .unwrap()
}

fn bench_amen_linear(c: &mut Criterion) {
    let dims = [2usize, 2];
    let nn = 4usize;
    let amat: Vec<f64> = (0..nn * nn)
        .map(|k| {
            let (i, j) = (k / nn, k % nn);
            if i == j {
                4.0
            } else {
                (k as f64 * 0.3).sin() * 0.2
            }
        })
        .collect();
    let a = operator_from_matrix(&amat, &dims);
    let xstar = state(&dims, 0.6);
    let b = a.apply(&xstar, &full()).unwrap();
    let cfg = SolveConfig::<f64>::new(60, 1e-9, 1e-13).unwrap();
    c.bench_function("amen_linear", |bb| {
        bb.iter(|| solve::linear(black_box(&a), black_box(&b), 4, black_box(&cfg)).unwrap())
    });
}

fn bench_als_fit(c: &mut Criterion) {
    let shape = [2usize, 2, 2];
    let target = state(&shape, 0.4);
    let dense = target.to_dense().unwrap();
    let mut samples = Vec::new();
    let mut idx = vec![0usize; 3];
    for i0 in 0..2 {
        for i1 in 0..2 {
            for i2 in 0..2 {
                idx[0] = i0;
                idx[1] = i1;
                idx[2] = i2;
                samples.push((idx.clone(), *dense.get(&idx).unwrap()));
            }
        }
    }
    let cfg = SolveConfig::<f64>::new(100, 1e-9, 1e-13).unwrap();
    c.bench_function("als_fit", |bb| {
        bb.iter(|| solve::fit(black_box(&shape), 4, black_box(&samples), black_box(&cfg)).unwrap())
    });
}

fn bench_dmrg3s_eigen(c: &mut Criterion) {
    // Symmetric A = s·I + (g − s)·v·vᵀ with a known ground state v (eigenvalue g).
    let dims = [3usize, 3];
    let nn = 9usize;
    let mut v: Vec<f64> = (0..nn).map(|i| (i as f64).sin() + 1.5).collect();
    let nrm = v.iter().map(|x| x * x).sum::<f64>().sqrt();
    for x in v.iter_mut() {
        *x /= nrm;
    }
    let (g, s) = (-3.0f64, 1.0f64);
    let mut amat = vec![0.0f64; nn * nn];
    for out in 0..nn {
        for inx in 0..nn {
            amat[out * nn + inx] = (g - s) * v[out] * v[inx] + if out == inx { s } else { 0.0 };
        }
    }
    let a = operator_from_matrix(&amat, &dims);
    let cfg = SolveConfig::<f64>::new(100, 1e-8, 1e-12).unwrap();
    c.bench_function("dmrg3s_eigen", |bb| {
        bb.iter(|| solve::eigen(black_box(&a), 3, black_box(&cfg)).unwrap())
    });
}

fn bench_tdvp_step(c: &mut Criterion) {
    let dims = [2usize, 2, 2];
    let nn = 8usize;
    let amat: Vec<f64> = (0..nn * nn)
        .map(|k| (k as f64 * 0.17).sin() * 0.3)
        .collect();
    let a = operator_from_matrix(&amat, &dims);
    let x0 = state(&dims, 0.5);
    let trunc = full();
    c.bench_function("tdvp_step", |bb| {
        bb.iter(|| {
            let mut x = x0.clone();
            solve::tdvp_step(black_box(&a), &mut x, 0.05, black_box(&trunc)).unwrap();
        })
    });
}

criterion_group!(
    tensor_train_solve_benches,
    bench_amen_linear,
    bench_als_fit,
    bench_dmrg3s_eigen,
    bench_tdvp_step,
);
