/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) "2025" . The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::CausalTensor;
use deep_causality_algebra::{AbelianGroup, AddGroup};

/// Marker trait for Abelian Group.
/// CausalTensor addition is commutative if T's addition is commutative.
impl<T> AbelianGroup for CausalTensor<T> where
    T: AbelianGroup + Copy + Default + PartialOrd + std::ops::Neg<Output = T>
{
}

// AddGroup is automatically implemented by blanket impl in deep_causality_num
// because CausalTensor implements Zero, Add, Sub, Neg, Clone.

impl<T> CausalTensor<T>
where
    T: AddGroup + Copy + std::ops::Neg<Output = T>,
{
    /// Creates a zero tensor with the specified shape.
    pub fn zero(shape: &[usize]) -> Self {
        let size: usize = shape.iter().product();
        let data = vec![T::zero(); size];
        // We use the unchecked constructor because we know the data matches the shape
        Self::from_vec_and_shape_unchecked(data, shape)
    }

    /// Element-wise addition.
    pub fn add(&self, rhs: &Self) -> Self {
        if self.shape() != rhs.shape() {
            panic!(
                "Shape mismatch in addition: {:?} vs {:?}",
                self.shape(),
                rhs.shape()
            );
        }

        let data = self
            .data
            .iter()
            .zip(rhs.data.iter())
            .map(|(a, b)| *a + *b)
            .collect();

        Self::from_vec_and_shape_unchecked(data, self.shape())
    }

    /// Element-wise subtraction.
    pub fn sub(&self, rhs: &Self) -> Self {
        if self.shape() != rhs.shape() {
            panic!(
                "Shape mismatch in subtraction: {:?} vs {:?}",
                self.shape(),
                rhs.shape()
            );
        }

        let data = self
            .data
            .iter()
            .zip(rhs.data.iter())
            .map(|(a, b)| *a - *b)
            .collect();

        Self::from_vec_and_shape_unchecked(data, self.shape())
    }

    /// Element-wise negation.
    pub fn neg(&self) -> Self {
        let data = self.data.iter().map(|a| -*a).collect();
        Self::from_vec_and_shape_unchecked(data, self.shape())
    }
}
