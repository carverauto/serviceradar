/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! Grade-0 scalars as multivectors.
//!
//! A scalar `s` is a multivector whose only non-zero part is grade 0, so every `MultiVector`
//! operation reduces to plain field arithmetic. Bounding on `RealField` covers every real field —
//! `f32`, `f64`, `Float106`, and any future one — in a single blanket, so generic code that
//! operates on any `MultiVector` handles scalars seamlessly with no per-type implementations.

use crate::{CausalMultiVectorError, MultiVector};
use deep_causality_algebra::RealField;

impl<T> MultiVector<T> for T
where
    T: RealField,
{
    fn grade_projection(&self, k: u32) -> Self {
        // The scalar lives entirely at grade 0; every other grade projects to zero.
        if k == 0 { *self } else { T::zero() }
    }

    fn reversion(&self) -> Self {
        // Reversion multiplies each grade-k part by (-1)^{k(k-1)/2}; for a grade-0 scalar that
        // exponent is 0, so the sign is +1 and the scalar reverses to itself.
        *self
    }

    fn squared_magnitude(&self) -> T {
        *self * *self
    }

    fn inverse(&self) -> Result<Self, CausalMultiVectorError>
    where
        Self: Sized,
    {
        if *self == T::zero() {
            Err(CausalMultiVectorError::zero_magnitude())
        } else {
            Ok(T::one() / *self)
        }
    }

    fn dual(&self) -> Result<Self, CausalMultiVectorError>
    where
        Self: Sized,
    {
        // For a scalar the dual carries no pseudoscalar context; it returns the scalar itself,
        // matching the original grade-0 behaviour.
        Ok(*self)
    }

    fn geometric_product(&self, rhs: &Self) -> Self {
        *self * *rhs
    }

    fn outer_product(&self, rhs: &Self) -> Self {
        *self * *rhs
    }

    fn inner_product(&self, rhs: &Self) -> Self {
        *self * *rhs
    }

    fn commutator_lie(&self, _rhs: &Self) -> Self {
        // Scalars commute, so [a, b] = ab - ba = 0.
        T::zero()
    }

    fn commutator_geometric(&self, _rhs: &Self) -> Self {
        T::zero()
    }

    fn basis_shift(&self, _index: usize) -> Self {
        *self
    }
}
