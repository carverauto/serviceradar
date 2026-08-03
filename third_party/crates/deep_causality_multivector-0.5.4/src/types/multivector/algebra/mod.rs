/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! Algebra module for CausalMultiVector.
use crate::{CausalMultiVector, CausalMultiVectorError, Metric};
use deep_causality_algebra::{AbelianGroup, AssociativeRing, Field, Module, RealField, Ring};
use std::ops::{AddAssign, Neg, SubAssign};

// Algebraic Composition
//
// 1.  **Complex Numbers (`Complex<f64>`):**
//     *   **Implements:** `Field` + `Copy` + `RealField` (if wrapped/adapted or treated as scalars).
//     *   **Path:** Uses **Tier 3**. `geometric_product` works correctly (assuming commutativity).
//     *   **Result:** Standard Quantum Mechanics (Spin(10)) works.
//
// 2.  **Quaternions (`Quaternion<f64>`):**
//     *   **Implements:** `AssociativeRing` + `Copy`.
//     *   **Does NOT Implement:** `Field` (Non-commutative).
//     *   **Path:** Uses **Tier 4**. `geometric_product_general` works correctly.
//     *   **Result:** Dixon Algebra nesting works. The non-commutative multiplication `q1 * q2` inside the geometric product loop is preserved.
//
// 3.  **Octonions (`Octonion<f64>`):**
//     *   **Implements:** `AbelianGroup` + `Copy`.
//     *   **Does NOT Implement:** `AssociativeRing` (Non-associative).
//     *   **Path:** Uses **Tier 1**. `add`, `sub` work.
//     *   **Safety:** `geometric_product` is **Compile-Time Blocked**.
//
// You cannot accidentally multiply Octonion-MultiVectors (which would be undefined in standard Clifford terms).
// This is correct behavior.
//
// 4.  **Tensors (`CausalTensor<T>`):**
//     *   **Path:** `CausalMultiVector<f64>` implements `AssociativeRing` (via Tier 3/4).
//     *   **Result:** `CausalTensor` accepts `CausalMultiVector`. You can do `tensor_a * tensor_b` where elements are MultiVectors.
//

// ============================================================================
// TIER 1: The Container (Storage & Linear Combinations)
// Requirements: AddGroup (Add, Sub, Neg, Zero)
// Use Case: Data storage, Accumulators, Octonion buffers (non-associative sums)
// ============================================================================

impl<T> CausalMultiVector<T>
where
    T: AbelianGroup + Copy,
{
    /// Creates a Zero vector (Additive Identity).
    pub fn zero(metric: Metric) -> Self {
        let size = 1 << metric.dimension();
        Self {
            data: vec![T::zero(); size],
            metric,
        }
    }

    /// Element-wise Addition.
    /// Checks metric compatibility.
    pub fn add(&self, rhs: &Self) -> Self {
        assert_eq!(self.metric, rhs.metric, "Metric mismatch in add");
        let new_data = self
            .data
            .iter()
            .zip(rhs.data.iter())
            .map(|(a, b)| *a + *b)
            .collect();

        Self {
            data: new_data,
            metric: self.metric,
        }
    }

    /// Element-wise Subtraction.
    pub fn sub(&self, rhs: &Self) -> Self {
        assert_eq!(self.metric, rhs.metric, "Metric mismatch in sub");
        let new_data = self
            .data
            .iter()
            .zip(rhs.data.iter())
            .map(|(a, b)| *a - *b)
            .collect();

        Self {
            data: new_data,
            metric: self.metric,
        }
    }
}

// ============================================================================
// TIER 2: The Vector Space (Scaling)
// Requirements: Module<S> (Vector Space over Scalar S)
// Use Case: Physics Vectors, Quantum States (Scaling Probability)
// ============================================================================

impl<T> CausalMultiVector<T> {
    /// Scales the multivector by a scalar value.
    /// $v' = s \cdot v$
    pub fn scale<S>(&self, scalar: S) -> Self
    where
        T: Module<S> + Copy, // T is the vector component
        S: Ring + Copy,      // S is the scalar (Must be Ring per Module trait)
    {
        // Note: Module definition usually implies Mul<S, Output=T>
        let new_data = self.data.iter().map(|v| *v * scalar).collect();
        Self {
            data: new_data,
            metric: self.metric,
        }
    }
}

// ============================================================================
// TIER 4: The Generalized Algebra (Non-Commutative Coefficients)
// Requirements: AssociativeRing (No Commutativity guaranteed)
// Use Case: Dixon Algebra (Nesting), Tensor<MultiVector>
// ============================================================================

impl<T> CausalMultiVector<T>
where
    T: AssociativeRing + Copy,
{
    /// Generalized Geometric Product.
    ///
    /// Unlike the standard product, this does NOT assume coefficients commute.
    /// $ (a e_i) (b e_j) = (a b) (e_i e_j) $
    ///
    /// It strictly preserves the order `lhs * rhs` for coefficients.
    /// This allows `CausalMultiVector<Quaternion>` or `CausalMultiVector<Matrix>`.
    pub fn geometric_product_general(&self, rhs: &Self) -> Self {
        if self.metric != rhs.metric {
            panic!("Metric mismatch");
        }

        let dim = self.metric.dimension();
        let count = 1 << dim;
        let mut result_data = vec![T::zero(); count];

        // Dense Loop (Optimization: Add Sparsity check if T supports is_zero)
        for i in 0..count {
            // If T supports cheap zero check, add: if self.data[i].is_zero() continue;

            for j in 0..count {
                // 1. Compute Basis Sign/Index (The Geometry)
                // e_i * e_j = sign * e_k
                let (sign, k) = Self::basis_product(i, j, &self.metric);

                if sign == 0 {
                    continue;
                } // Degenerate metric

                // 2. Compute Coefficient Product (The Algebra)
                // CRITICAL: Order (i * j) must be preserved for non-commutative T.
                let term = self.data[i] * rhs.data[j];

                // 3. Accumulate
                // If sign is negative, we subtract.
                if sign > 0 {
                    result_data[k] = result_data[k] + term;
                } else {
                    result_data[k] = result_data[k] - term;
                }
            }
        }

        Self {
            data: result_data,
            metric: self.metric,
        }
    }
}

// ============================================================================
// TIER 3: The Standard Clifford Algebra (Commutative Coefficients)
// Methods `normalize`, `commutator`, `inverse`, `geometric_product etc
// ============================================================================

// Internal implementation methods
impl<T> CausalMultiVector<T> {
    /// Computes the squared magnitude (squared norm) of the multivector.
    ///
    /// $$ ||A||^2 = \langle A \tilde{A} \rangle_0 $$
    pub(in crate::types::multivector) fn squared_magnitude_impl(&self) -> T
    where
        T: Field + Copy + Clone + AddAssign + SubAssign + Neg<Output = T>,
    {
        let reverse = self.reversion_impl();
        let product = self.geometric_product_impl(&reverse);
        product.data[0] // Scalar part
    }

    /// Computes the inverse of the multivector $A^{-1}$ (CPU-only).
    pub(in crate::types::multivector) fn inverse_impl(&self) -> Result<Self, CausalMultiVectorError>
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
        let sq_mag = self.squared_magnitude_impl();
        if sq_mag == T::zero() {
            return Err(CausalMultiVectorError::zero_magnitude());
        }

        let reverse = self.reversion_impl();
        Ok(reverse / sq_mag)
    }

    /// Computes the dual of the multivector $A^*$ (CPU-only).
    pub(in crate::types::multivector) fn dual_impl(&self) -> Result<Self, CausalMultiVectorError>
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
        let pseudo = Self::pseudoscalar(self.metric);
        let pseudo_inv = pseudo.inverse_impl()?;
        Ok(self.geometric_product_impl(&pseudo_inv))
    }
}

// Public API methods - Tier 3 operations (CPU version)
impl<T> CausalMultiVector<T>
where
    T: RealField + Copy,
{
    /// Normalizes the multivector to unit magnitude.
    pub fn normalize(&self) -> Self {
        let mag_sq = self.squared_magnitude_impl();
        if mag_sq <= T::epsilon() {
            return self.clone();
        }
        let scale_factor = T::one() / mag_sq.sqrt();
        self.scale(scale_factor)
    }
}

impl<T> CausalMultiVector<T>
where
    T: Field + Copy + RealField,
{
    /// Computes the Lie Commutator: $[A, B] = AB - BA$.
    /// Valid for all associative algebras.
    pub fn commutator(&self, rhs: &Self) -> Self {
        self.commutator_lie_impl(rhs)
    }

    /// Computes the Multiplicative Inverse.
    /// $A^{-1} = \tilde{A} / |A|^2$ (For Versors).
    /// Requires Division (Field).
    pub fn inverse(&self) -> Result<Self, CausalMultiVectorError> {
        let mag_sq = self.squared_magnitude_impl();

        if mag_sq.abs() <= T::epsilon() {
            return Err(CausalMultiVectorError::zero_magnitude());
        }

        let conjugate = self.reversion_impl();
        let scale = T::one() / mag_sq;

        Ok(conjugate.scale(scale))
    }

    /// The Geometric Product for Commutative Coefficients.
    /// This is the standard CPU implementation.
    pub fn geometric_product(&self, rhs: &Self) -> Self {
        self.geometric_product_impl(rhs)
    }

    /// Computes the Euclidean squared magnitude of a 3D spatial vector.
    ///
    /// For 4D Lorentzian multivectors with spatial components at indices 2, 3, 4
    /// (corresponding to x, y, z), this returns:
    ///
    /// $$ |v|^2_{\text{Euclidean}} = v_x^2 + v_y^2 + v_z^2 $$
    ///
    /// This differs from `squared_magnitude()` which applies the Lorentzian metric
    /// signature, potentially yielding negative values for spatial vectors.
    ///
    /// # Use Case
    /// Use this for classical EM quantities like energy density where the physical
    /// norm must be positive-definite.
    pub fn euclidean_squared_magnitude_3d(&self) -> T {
        let vx = self.data.get(2).copied().unwrap_or_else(T::zero);
        let vy = self.data.get(3).copied().unwrap_or_else(T::zero);
        let vz = self.data.get(4).copied().unwrap_or_else(T::zero);
        vx * vx + vy * vy + vz * vz
    }

    /// Computes the Euclidean magnitude of a 3D spatial vector.
    ///
    /// $$ |v|_{\text{Euclidean}} = \sqrt{v_x^2 + v_y^2 + v_z^2} $$
    pub fn euclidean_magnitude_3d(&self) -> T {
        self.euclidean_squared_magnitude_3d().sqrt()
    }

    /// Computes the 3D Euclidean cross product of two spatial vectors.
    ///
    /// For vectors with spatial components at indices 2, 3, 4 (x, y, z):
    ///
    /// $$ \mathbf{a} \times \mathbf{b} = (a_y b_z - a_z b_y, a_z b_x - a_x b_z, a_x b_y - a_y b_x) $$
    ///
    /// The result is returned in the same multivector format with the cross product
    /// components at indices 2, 3, 4.
    ///
    /// # Use Case
    /// Use this for classical EM quantities like the Poynting vector S = E × B.
    pub fn euclidean_cross_product_3d(&self, rhs: &Self) -> Self {
        let ax = self.data.get(2).copied().unwrap_or_else(T::zero);
        let ay = self.data.get(3).copied().unwrap_or_else(T::zero);
        let az = self.data.get(4).copied().unwrap_or_else(T::zero);

        let bx = rhs.data.get(2).copied().unwrap_or_else(T::zero);
        let by = rhs.data.get(3).copied().unwrap_or_else(T::zero);
        let bz = rhs.data.get(4).copied().unwrap_or_else(T::zero);

        // Cross product: c = a × b
        let cx = ay * bz - az * by;
        let cy = az * bx - ax * bz;
        let cz = ax * by - ay * bx;

        let mut result_data = vec![T::zero(); self.data.len()];
        result_data[2] = cx;
        result_data[3] = cy;
        result_data[4] = cz;

        Self {
            data: result_data,
            metric: self.metric,
        }
    }
}
