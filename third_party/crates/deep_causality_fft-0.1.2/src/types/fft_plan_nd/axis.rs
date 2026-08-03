/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! Axis walkers for the N-dimensional plans (row-column decomposition).
//!
//! The last (contiguous) axis is transformed directly, chunk by chunk.
//! Every other axis is processed per contiguous block: the strided lines
//! are gathered into scratch as contiguous rows (a block-local
//! transpose), transformed there, and scattered back — cache-friendlier
//! than strided butterflies, and it reuses the contiguous 1-D kernels
//! unchanged.
//!
//! Under the `parallel` feature the independent rows fan out via Rayon
//! once a pass is at least [`PARALLEL_THRESHOLD`] elements; smaller
//! passes stay serial (fork-join overhead dominates below the
//! threshold). Parallel sections allocate per-thread scratch; the serial
//! path allocates nothing.

use deep_causality_num_complex::Complex;

use crate::traits::fft_scalar::FftScalar;
use crate::types::fft_plan::FftPlan;

#[cfg(feature = "parallel")]
use crate::utils::complex_ops::czero;
#[cfg(feature = "parallel")]
use rayon::prelude::*;

/// Minimum elements in one axis pass before the Rayon fan-out engages.
/// Measured with the crate benchmark on Apple Silicon: at 32³ (32768
/// elements per pass, line length 32) the fan-out ran 2× slower than
/// serial — fork-join overhead and per-thread scratch dominate short
/// lines — while 64³ (262144 elements, line length 64) gained 1.7×.
/// The threshold sits between the two.
#[cfg(feature = "parallel")]
pub(crate) const PARALLEL_THRESHOLD: usize = 1 << 17;

/// Transform every contiguous line along the last axis.
pub(crate) fn last_axis<R: FftScalar>(
    data: &mut [Complex<R>],
    len: usize,
    plan: &FftPlan<R>,
    scratch: &mut [Complex<R>],
    inverse: bool,
) {
    #[cfg(feature = "parallel")]
    if data.len() >= PARALLEL_THRESHOLD {
        let s_len = plan.scratch_len();
        data.par_chunks_exact_mut(len).for_each_init(
            || vec![czero::<R>(); s_len],
            |scr, line| plan.execute_dir_unchecked(line, scr, inverse),
        );
        return;
    }
    for line in data.chunks_exact_mut(len) {
        plan.execute_dir_unchecked(line, scratch, inverse);
    }
}

/// Transform every line along a non-last axis with stride `inner`
/// (`inner` = product of the dimensions after the axis). `scratch` must
/// hold `len * inner` elements for the block transpose plus the plan's
/// own scratch.
pub(crate) fn mid_axis<R: FftScalar>(
    data: &mut [Complex<R>],
    len: usize,
    inner: usize,
    plan: &FftPlan<R>,
    scratch: &mut [Complex<R>],
    inverse: bool,
) {
    let block = len * inner;
    for block_slice in data.chunks_exact_mut(block) {
        let (rows, plan_scratch) = scratch.split_at_mut(block);
        // Gather: line r becomes the contiguous row r.
        for j in 0..len {
            let src = &block_slice[j * inner..(j + 1) * inner];
            for (r, v) in src.iter().enumerate() {
                rows[r * len + j] = *v;
            }
        }
        transform_rows(rows, len, plan, plan_scratch, inverse);
        // Scatter back.
        for j in 0..len {
            let dst = &mut block_slice[j * inner..(j + 1) * inner];
            for (r, v) in dst.iter_mut().enumerate() {
                *v = rows[r * len + j];
            }
        }
    }
}

fn transform_rows<R: FftScalar>(
    rows: &mut [Complex<R>],
    len: usize,
    plan: &FftPlan<R>,
    plan_scratch: &mut [Complex<R>],
    inverse: bool,
) {
    #[cfg(feature = "parallel")]
    if rows.len() >= PARALLEL_THRESHOLD {
        let s_len = plan.scratch_len();
        rows.par_chunks_exact_mut(len).for_each_init(
            || vec![czero::<R>(); s_len],
            |scr, row| plan.execute_dir_unchecked(row, scr, inverse),
        );
        return;
    }
    for row in rows.chunks_exact_mut(len) {
        plan.execute_dir_unchecked(row, plan_scratch, inverse);
    }
}
