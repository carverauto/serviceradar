/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! Twiddle-factor generation.
//!
//! Every factor is computed directly from its own reduced angle, so there
//! is no recurrence and therefore no error accumulation across a table —
//! each value is accurate to the precision of the scalar's `sin`/`cos`.
//! Tables are built once at plan construction; the per-call cost is
//! irrelevant on the execution hot path.

use deep_causality_num_complex::Complex;

use crate::traits::fft_scalar::FftScalar;

/// `W_n^k = e^{-2πi·k/n}`, with `k` reduced modulo `n`.
pub(crate) fn twiddle<R: FftScalar>(k: usize, n: usize) -> Complex<R> {
    debug_assert!(n > 0);
    let k = k % n;
    let two_pi = R::pi() + R::pi();
    let kr = R::from_usize(k).expect("twiddle index is representable in every supported scalar");
    let nr = R::from_usize(n).expect("transform length is representable in every supported scalar");
    let theta = two_pi * kr / nr;
    Complex::new(theta.cos(), -theta.sin())
}
