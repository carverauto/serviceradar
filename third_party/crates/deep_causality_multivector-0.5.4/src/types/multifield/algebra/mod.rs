/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! Algebraic operations for CausalMultiField.
//!
//! Implements vector space operations (scaling) and advanced algebraic operations
//! (reversion, inverse, normalization, commutators).
//!
//! # Algebraic Hierarchy
//!
//! 1. **Vector Space**: `scale(scalar)` - Scalar multiplication
//! 2. **Normed Space**: `normalize()`, `squared_magnitude()` - Length operations
//! 3. **Algebra**: `inverse()`, `reversion()` - Algebraic inverses
//! 4. **Lie/Geometric Algebra**: `commutator_lie()`, `commutator_geometric()` - Bracket operations
//!
//! All operations preserve the Matrix Isomorphism: they work directly on the
//! matrix representation, avoiding costly coefficient extraction.

// Import local modules
use crate::CausalMultiField;
use crate::MultiVector;
use crate::types::multifield::ops::batched_matmul::BatchedMatMul;
use deep_causality_algebra::{Field, RealField, Ring};
use deep_causality_tensor::CausalTensor;

// ============================================================================
// TIER 2: Vector Space (Scaling)
// ============================================================================

impl<T> CausalMultiField<T>
where
    T: Field + Copy + Default + PartialOrd,
{
    /// Scales the field by a scalar: `result = scalar * self`.
    ///
    /// # Arguments
    /// * `scalar` - The scalar value to multiply by
    pub fn scale(&self, scalar: T) -> Self {
        let scalar_tensor = CausalTensor::<T>::from_shape_fn(&[1], |_| scalar);
        let result = &self.data * &scalar_tensor;

        Self {
            data: result,
            metric: self.metric,
            dx: self.dx,
            shape: self.shape,
        }
    }
}

// ============================================================================
// TIER 3: Normed Space (Normalize, Magnitude)
// ============================================================================

impl<T> CausalMultiField<T>
where
    T: Field + RealField + Copy + Default + PartialOrd,
{
    /// Normalizes the field: `result = self / ||self||`.
    ///
    /// Returns the field scaled to unit magnitude.
    pub fn normalize(&self) -> Self {
        let mag_sq = self.squared_magnitude();
        if mag_sq.is_zero() {
            return self.clone();
        }
        let mag = mag_sq.sqrt();
        let inv_mag = T::one() / mag;
        self.scale(inv_mag)
    }

    /// Computes the squared magnitude of the field.
    ///
    /// Uses the L2 norm of the matrix representation.
    pub fn squared_magnitude(&self) -> T {
        let data_vec = self.data.as_slice();
        let mut sum = T::zero();
        for val in data_vec {
            sum += *val * *val;
        }
        sum
    }
}

// ============================================================================
// TIER 4: Full Algebra (Inverse, Reversion)
// ============================================================================

impl<T> CausalMultiField<T>
where
    T: Field + Copy + Default + PartialOrd + std::ops::Neg<Output = T> + 'static,
{
    /// Computes the reversion (reversal) of the field.
    ///
    /// The reversion is computed by extracting multivectors, applying
    /// the reversion operation, and reconstructing.
    pub fn reversion(&self) -> Self {
        let mvs = self.to_coefficients();
        let reversed: Vec<_> = mvs.iter().map(|mv| mv.reversion()).collect();
        Self::from_coefficients(&reversed, self.shape, self.dx)
    }

    /// Computes the multiplicative inverse of the field.
    ///
    /// Uses matrix inverse for each cell.
    pub fn inverse(&self) -> Self
    where
        T: RealField,
    {
        let mvs = self.to_coefficients();
        let inverted: Vec<_> = mvs
            .iter()
            .map(|mv| mv.inverse().expect("Failed to invert multivector"))
            .collect();
        Self::from_coefficients(&inverted, self.shape, self.dx)
    }
}

// ============================================================================
// TIER 5: Lie Algebra / Geometric Algebra (Commutators)
// ============================================================================

impl<T> CausalMultiField<T>
where
    T: Field + Ring + Copy + Default + PartialOrd,
    CausalTensor<T>: BatchedMatMul<T>,
{
    /// Computes the Lie commutator: `[A, B] = AB - BA`.
    ///
    /// The Lie bracket measures the non-commutativity of the geometric product.
    pub fn commutator_lie(&self, rhs: &Self) -> Self {
        assert_eq!(self.metric, rhs.metric, "Metric mismatch");
        assert_eq!(self.shape, rhs.shape, "Shape mismatch");

        // AB - BA using batched matmul
        let ab = self.data.batched_matmul(&rhs.data);
        let ba = rhs.data.batched_matmul(&self.data);
        let result = &ab - &ba;

        Self {
            data: result,
            metric: self.metric,
            dx: self.dx,
            shape: self.shape,
        }
    }

    /// Computes the geometric commutator: `(AB - BA) / 2`.
    ///
    /// Equivalent to the Lie commutator scaled by 1/2.
    pub fn commutator_geometric(&self, rhs: &Self) -> Self {
        assert_eq!(self.metric, rhs.metric, "Metric mismatch");
        assert_eq!(self.shape, rhs.shape, "Shape mismatch");

        let ab = self.data.batched_matmul(&rhs.data);
        let ba = rhs.data.batched_matmul(&self.data);
        let diff = &ab - &ba;

        // Scale by 0.5
        let half = T::one() / (T::one() + T::one());
        let half_tensor = CausalTensor::<T>::from_shape_fn(&[1], |_| half);
        let result = &diff * &half_tensor;

        Self {
            data: result,
            metric: self.metric,
            dx: self.dx,
            shape: self.shape,
        }
    }
}
