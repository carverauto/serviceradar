/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! The power-of-two workhorse: an iterative mixed radix-4/radix-2 Stockham
//! pipeline (decimation in frequency).
//!
//! Stockham autosorts — there is no bit-reversal pass and every stage
//! reads and writes with unit-stride runs, which is the regular,
//! auto-vectorizable access pattern the state-of-the-art survey
//! recommends over flop-minimal split-radix. The pipeline ping-pongs
//! between the data buffer and the caller's scratch; if the stage count
//! is odd the result is copied back once.

use deep_causality_num_complex::Complex;

use crate::traits::fft_scalar::FftScalar;
use crate::utils::complex_ops::{mul_i, mul_neg_i};
use crate::utils::twiddles::twiddle;

/// One pipeline stage. Radix-4 twiddles are interleaved
/// `[W^p, W^2p, W^3p]` per butterfly index `p`.
#[derive(Debug, Clone)]
enum Stage<R: FftScalar> {
    Radix2 { tw: Vec<Complex<R>> },
    Radix4 { tw: Vec<Complex<R>> },
}

/// Precomputed stage schedule for one power-of-two length `> 32`.
#[derive(Debug, Clone)]
pub(crate) struct StockhamPipeline<R: FftScalar> {
    n: usize,
    stages: Vec<Stage<R>>,
}

impl<R: FftScalar> StockhamPipeline<R> {
    /// Build the schedule: radix-4 stages while the remaining length is
    /// divisible by four, one final radix-2 stage when `log₂ n` is odd.
    pub(crate) fn new(n: usize) -> Self {
        debug_assert!(n.is_power_of_two() && n > 32);
        let mut stages = Vec::new();
        let mut n_cur = n;
        while n_cur > 1 {
            if n_cur.is_multiple_of(4) {
                let m = n_cur / 4;
                let mut tw = Vec::with_capacity(3 * m);
                for p in 0..m {
                    tw.push(twiddle::<R>(p, n_cur));
                    tw.push(twiddle::<R>(2 * p, n_cur));
                    tw.push(twiddle::<R>(3 * p, n_cur));
                }
                stages.push(Stage::Radix4 { tw });
                n_cur = m;
            } else {
                let m = n_cur / 2;
                let tw = (0..m).map(|p| twiddle::<R>(p, n_cur)).collect();
                stages.push(Stage::Radix2 { tw });
                n_cur = m;
            }
        }
        Self { n, stages }
    }

    /// Forward transform; `scratch.len()` must be at least `n`.
    pub(crate) fn execute(&self, data: &mut [Complex<R>], scratch: &mut [Complex<R>]) {
        let scratch = &mut scratch[..self.n];
        let mut n_cur = self.n;
        let mut s = 1usize;
        let mut in_data = true;
        for stage in &self.stages {
            let radix = match stage {
                Stage::Radix2 { tw } => {
                    if in_data {
                        apply_radix2(data, scratch, s, n_cur, tw);
                    } else {
                        apply_radix2(scratch, data, s, n_cur, tw);
                    }
                    2
                }
                Stage::Radix4 { tw } => {
                    if in_data {
                        apply_radix4(data, scratch, s, n_cur, tw);
                    } else {
                        apply_radix4(scratch, data, s, n_cur, tw);
                    }
                    4
                }
            };
            n_cur /= radix;
            s *= radix;
            in_data = !in_data;
        }
        if !in_data {
            data.copy_from_slice(scratch);
        }
    }
}

/// One radix-2 DIF Stockham stage over `s` interleaved sub-transforms of
/// length `n_cur` (invariant: `s · n_cur == n`).
fn apply_radix2<R: FftScalar>(
    src: &[Complex<R>],
    dst: &mut [Complex<R>],
    s: usize,
    n_cur: usize,
    tw: &[Complex<R>],
) {
    let m = n_cur / 2;
    for (p, &w) in tw.iter().enumerate().take(m) {
        let in0 = s * p;
        let in1 = s * (p + m);
        let out0 = s * 2 * p;
        let out1 = s * (2 * p + 1);
        for q in 0..s {
            let a = src[in0 + q];
            let b = src[in1 + q];
            dst[out0 + q] = a + b;
            dst[out1 + q] = (a - b) * w;
        }
    }
}

/// One radix-4 DIF Stockham stage (forward, `W_4 = −i`).
fn apply_radix4<R: FftScalar>(
    src: &[Complex<R>],
    dst: &mut [Complex<R>],
    s: usize,
    n_cur: usize,
    tw: &[Complex<R>],
) {
    let m = n_cur / 4;
    for p in 0..m {
        let w1 = tw[3 * p];
        let w2 = tw[3 * p + 1];
        let w3 = tw[3 * p + 2];
        let in0 = s * p;
        let in1 = s * (p + m);
        let in2 = s * (p + 2 * m);
        let in3 = s * (p + 3 * m);
        let out0 = s * 4 * p;
        let out1 = s * (4 * p + 1);
        let out2 = s * (4 * p + 2);
        let out3 = s * (4 * p + 3);
        for q in 0..s {
            let a = src[in0 + q];
            let b = src[in1 + q];
            let c = src[in2 + q];
            let d = src[in3 + q];
            let apc = a + c;
            let amc = a - c;
            let bpd = b + d;
            let bmd = b - d;
            dst[out0 + q] = apc + bpd;
            dst[out1 + q] = (amc + mul_neg_i(bmd)) * w1;
            dst[out2 + q] = (apc - bpd) * w2;
            dst[out3 + q] = (amc + mul_i(bmd)) * w3;
        }
    }
}
