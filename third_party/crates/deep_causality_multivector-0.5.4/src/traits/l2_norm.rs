/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use deep_causality_algebra::{Field, RealField};

/// Defines L2 norm operations for multivectors, treating their coefficients as a vector space.
pub trait MultiVectorL2Norm<T>
where
    T: Field + Copy + std::iter::Sum,
{
    /// Returns the Real magnitude type (e.g. f64 for `Complex<f64>`)
    type Output: RealField + Copy;

    /// Computes the L2 norm (Euclidean length) of the multivector's coefficient vector.
    ///
    /// $$ \text{norm} = \sqrt{\sum_i |c_i|^2} $$
    ///
    /// This is a pure vector space norm and is independent of the algebra's geometric metric.
    fn norm_l2(&self) -> Self::Output;

    /// Normalizes the multivector's coefficient vector to have a unit L2 norm.
    ///
    /// The resulting multivector `M'` will satisfy `M'.norm_l2() == 1.0`.
    ///
    /// This is a pure vector space normalization and is independent of the algebra's geometric metric.
    fn normalize_l2(&self) -> Self;
}
