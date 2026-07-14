/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! High-precision floating-point type using double-double arithmetic.
//!
//! `DoubleFloat` represents a number as the unevaluated sum of two `f64` values:
//! $$ x = x_{hi} + x_{lo} $$
//! where $|x_{lo}| \le 0.5 \cdot \text{ulp}(x_{hi})$.
//!
//! This provides approximately 106 bits of significand (~31 decimal digits) while
//! maintaining the same exponent range as `f64`.
//!
//! # DoubleFloat vs f128 Comparison
//!
//! | Aspect | DoubleFloat | f128 (IEEE binary128) |
//! |--------|-------------|----------------------|
//! | Mantissa | 106 bits | 112 bits |
//! | Precision | ~32 decimal digits (10⁻³¹) | ~34 decimal digits (10⁻³⁴) |
//! | Speed | ~2-4× slower than f64 | ~10-100× slower (software emulated) |
//! | Hardware support | None (pure software) | Very rare (POWER9, some ARMs) |
//! | Rust status | **Available now** | Nightly only |
//!
//! DoubleFloat provides precision comparable to f128 (~2 fewer digits) while
//! being significantly faster on most hardware since it uses native f64 FMA operations.
//!
//! # Physical Scale Context
//!
//! | Type | Precision | Scale |
//! |------|-----------|-------|
//! | f64 | ~15 digits | 10⁻¹⁵ (femto) — Proton size |
//! | **DoubleFloat** | **~32 digits** | **10⁻³¹ (quecto)** — Near Planck length |
//! | f128 | ~34 digits | 10⁻³⁴ — Planck length (10⁻³⁵) |
mod attributes;
mod constants;
mod debug;
mod display;
mod erf;
mod from;
mod getters;
mod ops_arithmetic;
mod ops_comparison;
mod traits_algebra;
mod traits_num;

/// A high-precision 106bit floating point number represented as the sum of two `f64`s.
///
/// Precision: ~31 decimal digits (106 bits significand).
/// Range: Same as `f64` (approx $10^{\pm 308}$).
///
/// # Layout
/// * **Alignment**: 16-byte aligned to enable efficient SIMD loads/stores.
/// * **Representation**: `C` compatible for FFI and stable layout.
///
/// # Invariant
/// For normalized values: `|lo| <= 0.5 * ulp(hi)`
#[derive(Copy, Clone, Default)]
#[repr(C, align(16))]
pub struct Float106 {
    /// High-order component (most significant bits)
    pub(crate) hi: f64,
    /// Low-order component (correction term)
    pub(crate) lo: f64,
}

// =============================================================================
// Constructors
// =============================================================================

impl Float106 {
    /// Creates a new `DoubleFloat` from high and low components.
    ///
    /// The components are normalized so that `|lo| <= 0.5 * ulp(hi)`.
    #[inline]
    pub fn new(hi: f64, lo: f64) -> Self {
        let (h, l) = quick_two_sum(hi, lo);
        Self { hi: h, lo: l }
    }

    /// Creates a `DoubleFloat` from a single `f64`.
    ///
    /// The low component is zero.
    #[inline]
    pub const fn from_f64(x: f64) -> Self {
        Self { hi: x, lo: 0.0 }
    }

    /// Creates a `DoubleFloat` from raw components without normalization.
    ///
    /// # Safety
    /// Caller must ensure the invariant `|lo| <= 0.5 * ulp(hi)` holds.
    #[inline]
    pub const fn from_raw(hi: f64, lo: f64) -> Self {
        Self { hi, lo }
    }
}

// =============================================================================
// Error-Free Transformations (EFT)
// =============================================================================

/// Knuth's TwoSum: Computes `s = a + b` and error `e` exactly.
///
/// Returns `(s, e)` such that `a + b = s + e` exactly.
#[inline]
pub(crate) fn two_sum(a: f64, b: f64) -> (f64, f64) {
    let s = a + b;
    let v = s - a;
    let e = (a - (s - v)) + (b - v);
    (s, e)
}

/// Quick TwoSum for when `|a| >= |b|`.
///
/// More efficient than `two_sum` when the magnitude ordering is known.
#[inline]
pub(crate) fn quick_two_sum(a: f64, b: f64) -> (f64, f64) {
    let s = a + b;
    let e = b - (s - a);
    (s, e)
}

/// Dekker's TwoProd: Computes `p = a * b` and error `e` exactly using FMA.
///
/// Returns `(p, e)` such that `a * b = p + e` exactly.
#[inline]
pub(crate) fn two_prod(a: f64, b: f64) -> (f64, f64) {
    let p = a * b;
    #[cfg(feature = "std")]
    let e = a.mul_add(b, -p);
    #[cfg(all(not(feature = "std"), feature = "libm_math"))]
    let e = libm::fma(a, b, -p);
    (p, e)
}
