/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::{Complex, RealField};

/// A value with a real modulus and real scaling: the bridge that lets generic code treat a real
/// (`f64`) and a complex (`Complex<f64>`) uniformly for norm work.
///
/// Unlike [`DivisionAlgebra`](crate::DivisionAlgebra), which *parameterizes* the real scalar
/// (`DivisionAlgebra<R>`), `Normed` makes the real an **associated** type. A generic carrier can
/// then read `T::Real` without threading a second type parameter — which is what lets a downstream
/// norm expose a single `type Output = T::Real` and be written as one blanket implementation
/// instead of one impl per concrete scalar.
pub trait Normed {
    /// The underlying real type (`f64` for both `f64` and `Complex<f64>`).
    type Real: RealField;

    /// The squared modulus as a real: `x → x²` for reals, `z → re² + im²` for complex.
    fn modulus_squared(&self) -> Self::Real;

    /// Scale by a real.
    fn scale_by_real(&self, s: Self::Real) -> Self;
}

/// A real field element is its own real type; its squared modulus is `x²` and scaling is plain
/// multiplication. Bounding on [`RealField`](RealField) covers every primitive float
/// (`f32` / `f64` / `Float106`, via the `impl<T: Float> RealField for T` tower) in one blanket — no
/// per-type impls, no macro. `Complex` is unordered, hence not a `RealField`, so this does not
/// overlap the `Complex<T>` impl below; `num` can prove that disjointness because it owns
/// `RealField` and `Complex` together (a downstream crate could not).
impl<T: RealField> Normed for T {
    type Real = T;

    #[inline]
    fn modulus_squared(&self) -> T {
        *self * *self
    }

    #[inline]
    fn scale_by_real(&self, s: T) -> T {
        *self * s
    }
}

/// A complex scalar carries the real modulus `|z|² = re² + im²` and scales component-wise.
impl<T: RealField> Normed for Complex<T> {
    type Real = T;

    #[inline]
    fn modulus_squared(&self) -> T {
        (self.re * self.re) + (self.im * self.im)
    }

    #[inline]
    fn scale_by_real(&self, s: T) -> Self {
        Complex::new(self.re * s, self.im * s)
    }
}
