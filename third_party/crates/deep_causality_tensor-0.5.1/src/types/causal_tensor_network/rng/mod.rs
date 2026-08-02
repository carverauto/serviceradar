/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! Self-contained, **precision-generic** deterministic sampling for the tensor-network kernels.
//!
//! The randomized range-finder/rounding kernels and the seeded train constructors need uniform and
//! standard-normal samples. To stay dependency-free *and* keep the precision invariant, the bit
//! source is an integer `splitmix64` stream (exact, no float), and the floating-point values are
//! assembled at the working precision of the real scalar `R = T::Real`:
//!
//! - a uniform fills `R`'s mantissa by concatenating as many 53-bit integer blocks as `R`'s epsilon
//!   requires (one block for `f64`, two for the double-double `Float106`, …) — so no value is ever
//!   pinned to `f64` precision;
//! - normals use the Box–Muller transform evaluated in `R` (`ln`/`cos`/`sqrt`/`π` from the `Real`
//!   trait), then are injected into `T` on the real axis via `from_real`.
//!
//! For `f64` a single block already fills the mantissa, so the uniform reduces bit-for-bit to the
//! previous `(z >> 11) / 2^53` mapping — the change is transparent at `f64` and only *adds* precision
//! at higher-precision scalars.

use deep_causality_algebra::{ConjugateScalar, Real, Scalar};
use deep_causality_num::{FromPrimitive, One, Zero};

type Re<T> = <T as ConjugateScalar>::Real;

/// One `splitmix64` step, returning the high 53 bits as an integer draw in `[0, 2^53)`.
fn next_block(state: &mut u64) -> u64 {
    *state = state.wrapping_add(0x9E37_79B9_7F4A_7C15);
    let mut z = *state;
    z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
    z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
    z ^= z >> 31;
    z >> 11
}

/// A full-precision uniform in `[0, 1)` in the real scalar `R`, assembled from 53-bit blocks until
/// the next block would fall below `R`'s epsilon (so the mantissa is filled at the working precision).
fn uniform_unit<R: Scalar>(state: &mut u64) -> R {
    let two53 = <R as FromPrimitive>::from_f64((1u64 << 53) as f64).unwrap();
    let inv = R::one() / two53; // 2^-53, exact (power of two)
    let eps = R::epsilon();
    let mut u = R::zero();
    let mut scale = R::one();
    loop {
        scale *= inv; // 2^-53, 2^-106, …
        let block = <R as FromPrimitive>::from_f64(next_block(state) as f64).unwrap();
        u += block * scale;
        if scale <= eps {
            break;
        }
    }
    u
}

/// A precision-generic sample uniform in `[-1, 1)`, injected into `T` on the real axis.
pub(crate) fn uniform_signed<T: ConjugateScalar>(state: &mut u64) -> T {
    let u: Re<T> = uniform_unit(state);
    let two = Re::<T>::one() + Re::<T>::one();
    T::from_real(u * two - Re::<T>::one())
}

/// A row-major `len`-element vector of standard-normal samples injected into `T` (on the real axis).
///
/// Normals are computed in `R = T::Real` by Box–Muller from full-precision uniforms, so the sketch
/// carries no `f64`-pinned intermediary; the result is injected via `from_real` (a real Gaussian
/// sketch is sufficient to capture a column space regardless of conjugation).
pub(crate) fn gaussian_vec<T: ConjugateScalar>(len: usize, seed: u64) -> Vec<T> {
    let mut state = seed;
    let two = Re::<T>::one() + Re::<T>::one();
    let tau = Re::<T>::pi() * two; // full-precision 2π
    let mut out = Vec::with_capacity(len);
    while out.len() < len {
        let mut u1: Re<T> = uniform_unit(&mut state);
        if u1 <= Re::<T>::zero() {
            u1 = Re::<T>::epsilon(); // guard against ln(0)
        }
        let u2: Re<T> = uniform_unit(&mut state);
        let r = (-(two) * u1.ln()).sqrt();
        let theta = tau * u2;
        out.push(T::from_real(r * theta.cos()));
        if out.len() < len {
            out.push(T::from_real(r * theta.sin()));
        }
    }
    out
}
