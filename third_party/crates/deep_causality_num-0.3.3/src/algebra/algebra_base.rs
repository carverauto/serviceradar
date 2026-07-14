/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::Distributive;
use crate::{Module, One, Ring};
use core::ops::{Mul, MulAssign};

/// Represents a Unital Algebra over a `Ring`.
///
/// In abstract algebra, an algebra is a vector space—or, more generally, a
/// module—equipped with a bilinear binary operation. This trait abstracts
/// over this concept.
///
/// This trait defines a **Unital Algebra** because it requires the `One` trait,
/// which provides a multiplicative identity (`1`).
///
/// # Mathematical Definition
///
/// An algebra `A` over a commutative ring `R` is a module over `R` that is also
/// a ring itself, where the ring multiplication is R-bilinear. This implementation
/// is slightly more general, as `R` is only required to be a `Ring`, not necessarily
/// commutative.
///
/// An algebra is **unital** if it has a multiplicative identity element.
///
/// ## Structure:
/// 1. `Self` is a `Module` over a scalar `Ring` `R`. This provides vector addition
///    and scalar multiplication.
/// 2. `Self` has a binary operation `*` (multiplication) that is compatible with
///    the module structure.
/// 3. `Self` has a multiplicative identity `1` (from the `One` trait).
///
/// ## Note:
/// This trait does *not* require the algebra to be associative. For that, see
/// the `AssociativeAlgebra` trait.
/// An Algebra over a Ring R.
///
/// Mathematical Definition: A Vector Space (Module) equipped with a
/// bilinear product.
///
/// Constraints:
/// 1. It is a Module (AddGroup + Scaling).
/// 2. It is Unital (Has One).
/// 3. It is Distributive (a(b+c) = ab + ac).
/// 4. It is NOT necessarily Associative (Octonions allowed).
pub trait Algebra<R: Ring>:
    Module<R> + Mul<Output = Self> + MulAssign + One + Distributive
{
    fn sqr(&self) -> Self {
        self.clone() * self.clone()
    }
}

// Blanket implementation
impl<T, R> Algebra<R> for T
where
    T: Module<R> + Mul<Output = Self> + MulAssign + One + Distributive,
    R: Ring,
{
}
