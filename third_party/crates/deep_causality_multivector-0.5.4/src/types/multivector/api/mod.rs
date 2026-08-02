/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! API module for CausalMultiVector.

use crate::{CausalMultiVector, CausalMultiVectorError};
use crate::{MultiVector, MultiVectorL2Norm, ScalarEval};
use deep_causality_algebra::{Field, Real};
use deep_causality_num::{One, Zero};
use std::iter::Sum;
use std::ops::{AddAssign, Neg, SubAssign};

impl<T> MultiVector<T> for CausalMultiVector<T> {
    fn grade_projection(&self, k: u32) -> Self
    where
        T: Field + Copy,
    {
        self.grade_projection_impl(k)
    }

    fn reversion(&self) -> Self
    where
        T: Field + Copy + Clone + Neg<Output = T>,
    {
        self.reversion_impl()
    }

    fn squared_magnitude(&self) -> T
    where
        T: Field + Copy + Clone + AddAssign + SubAssign + Neg<Output = T>,
    {
        self.squared_magnitude_impl()
    }

    fn inverse(&self) -> Result<Self, CausalMultiVectorError>
    where
        T: Field
            + Copy
            + Clone
            + Neg<Output = T>
            + core::ops::Div<Output = T>
            + PartialEq
            + AddAssign
            + SubAssign,
    {
        self.inverse_impl()
    }

    fn dual(&self) -> Result<Self, CausalMultiVectorError>
    where
        T: Field
            + Copy
            + Clone
            + Neg<Output = T>
            + core::ops::Div<Output = T>
            + PartialEq
            + AddAssign
            + SubAssign,
    {
        self.dual_impl()
    }

    fn geometric_product(&self, rhs: &Self) -> Self
    where
        T: Field + Copy + Clone + AddAssign + SubAssign + Neg<Output = T>,
    {
        self.geometric_product_impl(rhs)
    }

    fn outer_product(&self, rhs: &Self) -> Self
    where
        T: Field + Copy + Clone + AddAssign + SubAssign,
    {
        self.outer_product_impl(rhs)
    }

    fn inner_product(&self, rhs: &Self) -> Self
    where
        T: Field + Copy + Clone + AddAssign + SubAssign,
    {
        self.inner_product_impl(rhs)
    }

    fn commutator_lie(&self, rhs: &Self) -> Self
    where
        T: Field + Copy + Clone + AddAssign + SubAssign + Neg<Output = T>,
    {
        self.commutator_lie_impl(rhs)
    }

    fn commutator_geometric(&self, rhs: &Self) -> Self
    where
        T: Field + Copy + Clone + AddAssign + SubAssign + Neg<Output = T>,
    {
        self.commutator_geometric_impl(rhs)
    }

    fn basis_shift(&self, index: usize) -> Self
    where
        T: Clone,
    {
        self.basis_shift_impl(index)
    }
}

impl<T> MultiVectorL2Norm<T> for CausalMultiVector<T>
where
    // T must satisfy Field (required by the trait definition)
    // AND ScalarEval (required by our implementation logic)
    T: Field + Copy + Sum + ScalarEval,
{
    // The output of a Norm is always Real (e.g., f64), even if T is Complex.
    type Output = T::Real;

    fn norm_l2(&self) -> Self::Output {
        let sum_sq = self
            .data
            .iter()
            .map(|x| x.modulus_squared()) // Works for f64 AND Complex
            .fold(T::Real::zero(), |acc, x| acc + x);

        sum_sq.sqrt()
    }

    fn normalize_l2(&self) -> Self {
        let norm = self.norm_l2();

        if norm == T::Real::zero() {
            return self.clone();
        }

        // We scale by 1.0 / norm
        let scale_factor = T::Real::one() / norm;

        let new_data = self
            .data
            .iter()
            .map(|x| x.scale_by_real(scale_factor)) // Works for f64 AND Complex
            .collect();

        Self {
            data: new_data,
            metric: self.metric,
        }
    }
}
