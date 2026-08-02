/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::CausalMultiVectorError;
use crate::Metric;
use deep_causality_algebra::Field;
use deep_causality_num::Zero;

mod algebra;
mod api;
mod arithmetic;
mod ops;
mod utils;

/// A MultiVector in a Clifford Algebra $Cl(p, q, r)$.
///
/// A multivector $A$ is a linear combination of basis blades $e_I$:
/// $$ A = \sum_{I} a_I e_I $$
/// where $I$ is an ordered subset of $\{1, \dots, N\}$ and $a_I$ are scalar coefficients.
///
/// The data is stored in a flat vector of size $2^N$.
/// Indexing is based on bitmaps: index 3 (binary 011) corresponds to the basis blade $e_1 \wedge e_2$.
#[derive(Debug, Clone, PartialEq)]
pub struct CausalMultiVector<T> {
    pub(crate) data: Vec<T>,
    pub(crate) metric: Metric,
}

impl<T> CausalMultiVector<T> {
    /// Creates a new MultiVector from raw coefficients.
    ///
    /// # Arguments
    /// * `data` - A vector of coefficients of size $2^N$.
    /// * `metric` - The metric signature of the algebra.
    ///
    /// # Returns
    /// * `Result<Self, CausalMultiVectorError>` - The new multivector or an error if the data length is incorrect.
    pub fn new(data: Vec<T>, metric: Metric) -> Result<Self, CausalMultiVectorError> {
        let dim = metric.dimension();
        let expected_len = 1 << dim;
        if data.len() != expected_len {
            return Err(CausalMultiVectorError::data_length_mismatch(
                expected_len,
                data.len(),
            ));
        }
        Ok(Self { data, metric })
    }

    pub fn unchecked(data: Vec<T>, metric: Metric) -> Self {
        Self { data, metric }
    }

    /// Gets a specific component by basis blade bitmap.
    ///
    /// # Arguments
    /// * `idx` - The bitmap index of the basis blade (e.g., 3 for $e_1 \wedge e_2$).
    pub fn get(&self, idx: usize) -> Option<&T> {
        self.data.get(idx)
    }

    /// Creates a scalar multivector (grade 0).
    ///
    /// $$ A = s \cdot 1 $$
    ///
    /// # Arguments
    /// * `val` - The scalar value.
    /// * `metric` - The metric signature.
    pub fn scalar(val: T, metric: Metric) -> Self
    where
        T: Zero + Copy + Clone,
    {
        let size = 1 << metric.dimension();
        let mut data = vec![T::zero(); size];
        data[0] = val;
        Self { data, metric }
    }

    /// Constructs the pseudoscalar $I$ for the algebra.
    ///
    /// The pseudoscalar is the highest grade element, corresponding to the product of all basis vectors:
    /// $$ I = e_1 \wedge e_2 \wedge \dots \wedge e_N $$
    pub fn pseudoscalar(metric: Metric) -> Self
    where
        T: Field + Copy + Clone,
    {
        let dim = metric.dimension();
        let size = 1 << dim;
        let mut data = vec![T::zero(); size];
        // The pseudoscalar is at the last index (all bits 1)
        data[size - 1] = T::one();
        Self { data, metric }
    }

    pub fn data(&self) -> &Vec<T> {
        &self.data
    }

    pub fn metric(&self) -> Metric {
        self.metric
    }
}
