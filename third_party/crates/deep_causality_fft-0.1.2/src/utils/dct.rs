/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! Naïve O(n²) discrete cosine transforms — the correctness references
//! for the plan-based DCTs, in the same role `naive_dft` plays for the
//! complex planner. Never selected by any plan.
//!
//! Conventions (unnormalized, matching `DctPlan`):
//!
//! * DCT-I  (`n ≥ 2`): `X_k = ½(x_0 + (−1)^k x_{n−1}) + Σ_{j=1}^{n−2} x_j cos(πjk/(n−1))`
//! * DCT-II : `X_k = Σ_{j=0}^{n−1} x_j cos(π(2j+1)k/(2n))`
//! * DCT-III: `X_k = ½x_0 + Σ_{j=1}^{n−1} x_j cos(πj(2k+1)/(2n))`
//!
//! Pairings: `DCT-III(DCT-II(x)) = (n/2)·x`; `DCT-I(DCT-I(x)) = ((n−1)/2)·x`.

use crate::traits::fft_scalar::FftScalar;

fn cos_pi_ratio<R: FftScalar>(numer: usize, denom: usize) -> R {
    let pi = R::pi();
    let n = R::from_usize(numer).expect("index is representable");
    let d = R::from_usize(denom).expect("length is representable");
    (pi * n / d).cos()
}

/// Naïve DCT-I (unnormalized). Requires `input.len() >= 2`.
pub fn naive_dct_i<R: FftScalar>(input: &[R]) -> Vec<R> {
    let n = input.len();
    debug_assert!(n >= 2, "DCT-I requires at least two samples");
    let m = n - 1;
    let two = R::one() + R::one();
    let half = R::one() / two;
    (0..n)
        .map(|k| {
            let mut acc = (input[0]
                + if k % 2 == 0 {
                    input[m]
                } else {
                    R::zero() - input[m]
                })
                * half;
            for (j, &x) in input.iter().enumerate().take(m).skip(1) {
                acc += x * cos_pi_ratio::<R>((j * k) % (2 * m), m);
            }
            acc
        })
        .collect()
}

/// Naïve DCT-II (unnormalized).
pub fn naive_dct_ii<R: FftScalar>(input: &[R]) -> Vec<R> {
    let n = input.len();
    (0..n)
        .map(|k| {
            let mut acc = R::zero();
            for (j, &x) in input.iter().enumerate() {
                acc += x * cos_pi_ratio::<R>(((2 * j + 1) * k) % (4 * n), 2 * n);
            }
            acc
        })
        .collect()
}

/// Naïve DCT-III (unnormalized).
pub fn naive_dct_iii<R: FftScalar>(input: &[R]) -> Vec<R> {
    let n = input.len();
    let two = R::one() + R::one();
    let half = R::one() / two;
    (0..n)
        .map(|k| {
            let mut acc = input[0] * half;
            for (j, &x) in input.iter().enumerate().skip(1) {
                acc += x * cos_pi_ratio::<R>((j * (2 * k + 1)) % (4 * n), 2 * n);
            }
            acc
        })
        .collect()
}
