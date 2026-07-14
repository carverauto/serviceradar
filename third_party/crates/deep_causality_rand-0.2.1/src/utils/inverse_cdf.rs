/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! Inverse-CDF (quantile) transforms.
//!
//! Each transform maps a single uniform input `u ∈ [0,1)` to a draw, monotonically and
//! without rejection, so that it preserves the structure of a low-discrepancy sequence
//! (unlike Ziggurat/Box–Muller, which consume a variable number of uniforms). They are the
//! sampling primitive for the Quasi-Monte-Carlo path.
//!
//! The standard-normal quantile uses Acklam's rational approximation (~1.15e-9) as a seed;
//! the `Float106` variant then refines it to double-double precision with Halley iteration on
//! `Φ(x) − u = 0`, using the double-double `erfc`/`exp`.

use deep_causality_algebra::RealField;
use deep_causality_num::{Float, Float106};

/// Smallest `u` admitted by the standard-normal quantile; keeps the result finite at the
/// open-interval endpoints (`u = 0` would map to `−∞`).
const U_CLAMP_LO: f64 = 1e-300;
/// Largest `u` admitted (symmetric upper clamp, just below 1).
const U_CLAMP_HI: f64 = 1.0 - f64::EPSILON;

/// Acklam's rational approximation to the standard-normal quantile `Φ⁻¹(u)` (≈1.15e-9).
fn acklam(u: f64) -> f64 {
    const A: [f64; 6] = [
        -3.969683028665376e+01,
        2.209460984245205e+02,
        -2.759285104469687e+02,
        1.38357751867269e+02,
        -3.066479806614716e+01,
        2.506628277459239e+00,
    ];
    const B: [f64; 5] = [
        -5.447609879822406e+01,
        1.615858368580409e+02,
        -1.556989798598866e+02,
        6.680131188771972e+01,
        -1.328068155288572e+01,
    ];
    const C: [f64; 6] = [
        -7.784894002430293e-03,
        -3.223964580411365e-01,
        -2.400758277161838e+00,
        -2.549732539343734e+00,
        4.374664141464968e+00,
        2.938163982698783e+00,
    ];
    const D: [f64; 4] = [
        7.784695709041462e-03,
        3.224671290700398e-01,
        2.445134137142996e+00,
        3.754408661907416e+00,
    ];
    const P_LOW: f64 = 0.02425;
    const P_HIGH: f64 = 1.0 - P_LOW;

    let u = u.clamp(U_CLAMP_LO, U_CLAMP_HI);
    if u < P_LOW {
        let q = (-2.0 * u.ln()).sqrt();
        (((((C[0] * q + C[1]) * q + C[2]) * q + C[3]) * q + C[4]) * q + C[5])
            / ((((D[0] * q + D[1]) * q + D[2]) * q + D[3]) * q + 1.0)
    } else if u <= P_HIGH {
        let q = u - 0.5;
        let r = q * q;
        (((((A[0] * r + A[1]) * r + A[2]) * r + A[3]) * r + A[4]) * r + A[5]) * q
            / (((((B[0] * r + B[1]) * r + B[2]) * r + B[3]) * r + B[4]) * r + 1.0)
    } else {
        let q = (-2.0 * (1.0 - u).ln()).sqrt();
        -(((((C[0] * q + C[1]) * q + C[2]) * q + C[3]) * q + C[4]) * q + C[5])
            / ((((D[0] * q + D[1]) * q + D[2]) * q + D[3]) * q + 1.0)
    }
}

/// Halley refinement of the standard-normal quantile at double-double precision.
///
/// Solves `Φ(x) − u = 0` with `Φ(x) = ½·erfc(−x/√2)` and `φ(x) = e^{−x²/2}/√(2π)`.
/// The Halley step is `x ← x − 2(Φ−u) / (2φ + x(Φ−u))`. Cubic convergence takes the
/// ~1e-9 seed below double-double epsilon in three iterations.
fn refine_f106(u: Float106, x0: Float106) -> Float106 {
    let half = Float106::from_f64(0.5);
    let two = Float106::from_f64(2.0);
    let sqrt2 = two.sqrt();
    let inv_sqrt_2pi = Float106::from_f64(1.0) / Float106::TWO_PI.sqrt();

    let mut x = x0;
    for _ in 0..3 {
        let cdf = half * (-x / sqrt2).erfc();
        let pdf = (-(x * x) * half).exp() * inv_sqrt_2pi;
        let diff = cdf - u;
        let denom = two * pdf + x * diff;
        x -= two * diff / denom;
    }
    x
}

/// Standard-normal quantile `Φ⁻¹(u)` at `f64` precision (Acklam seed + double-double Halley
/// refinement, downcast), monotone and finite for all `u`.
pub fn standard_normal_inverse_cdf(u: f64) -> f64 {
    let u_c = u.clamp(U_CLAMP_LO, U_CLAMP_HI);
    refine_f106(Float106::from_f64(u_c), Float106::from_f64(acklam(u_c))).to_f64()
}

/// Standard-normal quantile `Φ⁻¹(u)` at `Float106` precision. The Acklam seed is taken at
/// `f64`, then refined against the full double-double `u`, so the result reflects `u`'s low limb.
pub fn standard_normal_inverse_cdf_f106(u: Float106) -> Float106 {
    let u_c = u.hi().clamp(U_CLAMP_LO, U_CLAMP_HI);
    let u_full = if u.hi() <= U_CLAMP_LO || u.hi() >= U_CLAMP_HI {
        Float106::from_f64(u_c)
    } else {
        u
    };
    refine_f106(u_full, Float106::from_f64(acklam(u_c)))
}

/// Uniform quantile: `low + u·(high − low)`, exact at the value type's precision.
pub fn uniform_inverse_cdf<R: RealField>(u: R, low: R, high: R) -> R {
    low + u * (high - low)
}

/// Bernoulli quantile: `true` iff `u < p`.
pub fn bernoulli_inverse_cdf(u: f64, p: f64) -> bool {
    u < p
}
