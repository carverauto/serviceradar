/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::Field;

/// Represents a **Complex Field** — a field extension of the reals with
/// complex conjugation and component access.
///
/// A complex field is a field where elements can be decomposed into real
/// and imaginary parts, and complex conjugation is defined.
///
/// # Mathematical Definition
///
/// A complex field `K` over a real field `R` satisfies:
/// 1. `K` is a `Field`.
/// 2. There exists an involution (conjugation) `*: K → K` such that:
///    - `(a + b)* = a* + b*`
///    - `(a · b)* = a* · b*`
///    - `(a*)* = a`
///    - `a · a*` is a non-negative real for all `a`
/// 3. Every element `z ∈ K` can be written as `z = x + iy` where `x, y ∈ R`.
///
/// # Examples
/// - Complex numbers `ℂ` over `ℝ`
/// - Split-complex numbers (hyperbolic numbers)
///
/// # Note
/// Quaternions and Octonions are NOT complex fields because they are not
/// commutative (Quaternions) or not associative (Octonions). They implement
/// `DivisionAlgebra` instead.
pub trait ComplexField<R>: Field
where
    R: Field,
{
    /// Returns the real part of the complex number.
    ///
    /// For `z = a + bi`, returns `a`.
    fn real(&self) -> R;

    /// Returns the imaginary part of the complex number.
    ///
    /// For `z = a + bi`, returns `b`.
    fn imag(&self) -> R;

    /// Returns the complex conjugate.
    ///
    /// For `z = a + bi`, returns `z* = a - bi`.
    ///
    /// # Properties
    /// - `(z*)* = z`
    /// - `(z + w)* = z* + w*`
    /// - `(z · w)* = z* · w*`
    fn conjugate(&self) -> Self;

    /// Returns the squared modulus (norm squared).
    ///
    /// `|z|² = z · z* = a² + b²`
    ///
    /// This is guaranteed to be a non-negative real number.
    fn norm_sqr(&self) -> R;

    /// Returns the modulus (absolute value).
    ///
    /// `|z| = √(a² + b²)`
    fn norm(&self) -> R;

    /// Returns the argument (phase angle) in radians.
    ///
    /// `arg(z) = atan2(b, a)` for `z = a + bi`.
    ///
    /// The result is in the range `(-π, π]`.
    fn arg(&self) -> R;

    /// Constructs a complex number from real and imaginary parts.
    ///
    /// Returns `re + im·i`.
    fn from_re_im(re: R, im: R) -> Self;

    /// Constructs a complex number from polar form.
    ///
    /// Returns `r·(cos(θ) + i·sin(θ)) = r·e^(iθ)`.
    fn from_polar(r: R, theta: R) -> Self;

    /// Returns the imaginary unit `i`.
    ///
    /// Satisfies `i² = -1`.
    fn i() -> Self;

    /// Returns `true` if the imaginary part is zero.
    fn is_real(&self) -> bool;

    /// Returns `true` if the real part is zero.
    fn is_imaginary(&self) -> bool;
}
