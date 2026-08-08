/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! Criterion benchmark for the FFT crate: 1-D power-of-two lengths at the
//! solver-relevant per-axis sizes plus one Bluestein length, and the 3-D
//! complex/real transforms at the solver grids (16³, 32³, 64³), at f32
//! and f64.

use criterion::{Criterion, criterion_group, criterion_main};
use std::hint::black_box;

use deep_causality_fft::{DctPlan, DctType, FftPlan, FftPlanNd, RfftPlanNd};
use deep_causality_num_complex::Complex;

fn cbuf_f64(n: usize) -> Vec<Complex<f64>> {
    (0..n)
        .map(|i| {
            let x = i as f64;
            Complex::new((x * 0.37).sin(), (x * 0.11).cos())
        })
        .collect()
}

fn cbuf_f32(n: usize) -> Vec<Complex<f32>> {
    (0..n)
        .map(|i| {
            let x = i as f32;
            Complex::new((x * 0.37).sin(), (x * 0.11).cos())
        })
        .collect()
}

fn rbuf_f64(n: usize) -> Vec<f64> {
    (0..n).map(|i| ((i as f64) * 0.37).sin()).collect()
}

fn bench_1d(c: &mut Criterion) {
    let mut group = c.benchmark_group("fft_1d_f64");
    for n in [16usize, 32, 64, 4096, 65536] {
        let plan = FftPlan::<f64>::new(n).unwrap();
        let mut data = cbuf_f64(n);
        let mut scratch = vec![Complex::new(0.0, 0.0); plan.scratch_len()];
        group.bench_function(format!("forward_{n}"), |b| {
            b.iter(|| {
                plan.execute(black_box(&mut data), &mut scratch).unwrap();
            })
        });
    }
    // Bluestein path: prime length.
    let n = 1009usize;
    let plan = FftPlan::<f64>::new(n).unwrap();
    let mut data = cbuf_f64(n);
    let mut scratch = vec![Complex::new(0.0, 0.0); plan.scratch_len()];
    group.bench_function("forward_1009_bluestein", |b| {
        b.iter(|| {
            plan.execute(black_box(&mut data), &mut scratch).unwrap();
        })
    });
    group.finish();

    let mut group = c.benchmark_group("fft_1d_f32");
    for n in [64usize, 4096] {
        let plan = FftPlan::<f32>::new(n).unwrap();
        let mut data = cbuf_f32(n);
        let mut scratch = vec![Complex::new(0.0f32, 0.0); plan.scratch_len()];
        group.bench_function(format!("forward_{n}"), |b| {
            b.iter(|| {
                plan.execute(black_box(&mut data), &mut scratch).unwrap();
            })
        });
    }
    group.finish();
}

fn bench_3d(c: &mut Criterion) {
    let mut group = c.benchmark_group("fft_3d_f64");
    group.sample_size(20);
    for d in [16usize, 32, 64] {
        let shape = [d, d, d];
        let n = d * d * d;
        let plan = FftPlanNd::<f64>::new(&shape).unwrap();
        let mut data = cbuf_f64(n);
        let mut scratch = vec![Complex::new(0.0, 0.0); plan.scratch_len()];
        group.bench_function(format!("complex_{d}^3"), |b| {
            b.iter(|| {
                plan.execute(black_box(&mut data), &mut scratch).unwrap();
            })
        });

        let rplan = RfftPlanNd::<f64>::new(&shape).unwrap();
        let input = rbuf_f64(n);
        let mut spec = vec![Complex::new(0.0, 0.0); rplan.spectrum_len()];
        let mut rscratch = vec![Complex::new(0.0, 0.0); rplan.scratch_len()];
        group.bench_function(format!("real_roundtrip_{d}^3"), |b| {
            let mut out = vec![0.0f64; n];
            b.iter(|| {
                rplan
                    .execute(black_box(&input), &mut spec, &mut rscratch)
                    .unwrap();
                rplan
                    .execute_inverse(&mut spec, &mut out, &mut rscratch)
                    .unwrap();
            })
        });
    }
    group.finish();
}

fn bench_dct(c: &mut Criterion) {
    let mut group = c.benchmark_group("dct_1d_f64");
    for (n, label) in [(64usize, "64"), (129, "129_bluestein"), (4096, "4096")] {
        for ty in [DctType::I, DctType::II] {
            let plan = DctPlan::<f64>::new(n, ty).unwrap();
            let input = rbuf_f64(n);
            let mut out = vec![0.0f64; n];
            let mut rs = vec![0.0f64; plan.scratch_real_len()];
            let mut cs = vec![Complex::new(0.0, 0.0); plan.scratch_complex_len()];
            group.bench_function(format!("type_{ty:?}_{label}"), |b| {
                b.iter(|| {
                    plan.execute(black_box(&input), &mut out, &mut rs, &mut cs)
                        .unwrap();
                })
            });
        }
    }
    group.finish();
}

criterion_group!(benches, bench_1d, bench_3d, bench_dct);
criterion_main!(benches);
