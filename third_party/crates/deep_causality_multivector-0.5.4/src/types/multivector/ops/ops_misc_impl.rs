/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */
use crate::CausalMultiVector;
use core::ops::Neg;
use deep_causality_algebra::Field;

impl<T> CausalMultiVector<T> {
    /// Projects the multivector onto a specific grade $k$.
    ///
    /// $$ \langle A \rangle_k = \sum_{I : |I|=k} a_I e_I $$
    pub(in crate::types::multivector) fn grade_projection_impl(&self, k: u32) -> Self
    where
        T: Field + Copy,
    {
        let mut result_data = vec![T::zero(); self.data.len()];
        for (i, val) in self.data.iter().enumerate() {
            if i.count_ones() == k {
                result_data[i] = *val;
            }
        }
        Self {
            data: result_data,
            metric: self.metric,
        }
    }
    /// Computes the reverse of the multivector, denoted $\tilde{A}$ or $A^\dagger$.
    ///
    /// Reverses the order of vectors in each basis blade.
    /// $$ \tilde{A} = \sum_{k=0}^N (-1)^{k(k-1)/2} \langle A \rangle_k $$
    pub(in crate::types::multivector) fn reversion_impl(&self) -> Self
    where
        T: Field + Copy + Clone + Neg<Output = T>,
    {
        let mut result_data = vec![T::zero(); self.data.len()];
        for (i, val) in self.data.iter().enumerate() {
            let grade = i.count_ones() as i32;
            let sign_power = (grade * (grade - 1)) / 2;
            if sign_power % 2 != 0 {
                result_data[i] = -(*val);
            } else {
                result_data[i] = *val;
            }
        }
        Self {
            data: result_data,
            metric: self.metric,
        }
    }
}

impl<T> CausalMultiVector<T> {
    /// Cyclically shifts the basis coefficients.
    /// This effectively changes the "viewpoint" of the algebra,
    /// making the coefficient at `index` the new scalar (index 0).
    ///
    /// Used for Comonadic 'extend' operations.
    pub(in crate::types::multivector) fn basis_shift_impl(&self, index: usize) -> Self
    where
        T: Clone,
    {
        // Null check is no needed since length is guaranteed to be >0
        let mut new_data = self.data.clone();
        let shift = index % self.data.len();
        new_data.rotate_left(shift);

        Self {
            data: new_data,
            metric: self.metric,
        }
    }
}
