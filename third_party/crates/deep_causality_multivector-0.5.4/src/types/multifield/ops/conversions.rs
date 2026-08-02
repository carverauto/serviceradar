/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! Conversions between CausalMultiField and other representations.
//!
//! - `from_coefficients`: Create from CausalMultiVector collection
//! - `to_coefficients`: Extract CausalMultiVector collection
//! - Factory methods: `zeros`, `ones`

use crate::types::multifield::ops::gamma;
use crate::{CausalMultiField, CausalMultiVector};
use deep_causality_algebra::Field;
use deep_causality_metric::Metric;
use deep_causality_tensor::{CausalTensor, Tensor};

impl<T> CausalMultiField<T>
where
    T: Field + Copy + Default + PartialOrd,
{
    /// Creates a field filled with zero multivectors.
    ///
    /// # Arguments
    /// * `shape` - Grid dimensions [Nx, Ny, Nz]
    /// * `metric` - The metric signature of the algebra
    /// * `dx` - Grid spacing [dx, dy, dz]
    pub fn zeros(shape: [usize; 3], metric: Metric, dx: [T; 3]) -> Self {
        let matrix_dim = Self::compute_matrix_dim(metric.dimension());
        let full_shape = [shape[0], shape[1], shape[2], matrix_dim, matrix_dim];
        let data = CausalTensor::<T>::zeros(&full_shape);

        Self {
            data,
            metric,
            dx,
            shape,
        }
    }

    /// Creates a field filled with identity matrices (scalar 1).
    ///
    /// Each cell contains the identity element of the algebra.
    pub fn ones(shape: [usize; 3], metric: Metric, dx: [T; 3]) -> Self {
        let matrix_dim = Self::compute_matrix_dim(metric.dimension());
        let full_shape = [shape[0], shape[1], shape[2], matrix_dim, matrix_dim];

        // Create identity matrices for each cell
        let data = CausalTensor::<T>::from_shape_fn(&full_shape, |idx| {
            // Identity matrix: 1 on diagonal, 0 elsewhere
            if idx[3] == idx[4] {
                T::one()
            } else {
                T::zero()
            }
        });

        Self {
            data,
            metric,
            dx,
            shape,
        }
    }

    /// Creates a field from a collection of CausalMultiVectors.
    ///
    /// # Arguments
    /// * `mvs` - Flat array of multivectors in row-major order
    /// * `shape` - Grid dimensions [Nx, Ny, Nz]
    /// * `dx` - Grid spacing [dx, dy, dz]
    pub fn from_coefficients(mvs: &[CausalMultiVector<T>], shape: [usize; 3], dx: [T; 3]) -> Self
    where
        T: std::ops::Neg<Output = T>,
    {
        let expected_len = shape[0] * shape[1] * shape[2];
        assert_eq!(
            mvs.len(),
            expected_len,
            "Expected {} multivectors, got {}",
            expected_len,
            mvs.len()
        );

        if mvs.is_empty() {
            panic!("Cannot create field from empty multivector list");
        }

        let metric = mvs[0].metric();
        let matrix_dim = Self::compute_matrix_dim(metric.dimension());
        let num_blades = 1 << metric.dimension();

        // Flatten all multivector data into a single vector
        let mut flat_data = Vec::with_capacity(mvs.len() * num_blades);
        for mv in mvs {
            flat_data.extend_from_slice(&mv.data);
        }

        let coeffs_shape = [mvs.len(), num_blades];
        let coeffs_tensor = CausalTensor::from_slice(&flat_data, &coeffs_shape);

        // Generate all basis matrices Γ_I [NumBlades, MatrixDim, MatrixDim]
        let basis_tensor = gamma::get_basis_gammas::<T>(&metric);
        let basis_flat = basis_tensor
            .reshape(&[num_blades, matrix_dim * matrix_dim])
            .expect("reshape failed");

        // Compute M = Σ c_I Γ_I via Matrix Multiplication
        // [Batch, Blades] @ [Blades, D*D] -> [Batch, D*D]
        let matrices_flat = coeffs_tensor.matmul(&basis_flat).expect("matmul failed");

        // Reshape to [Nx, Ny, Nz, D, D]
        let full_shape = [shape[0], shape[1], shape[2], matrix_dim, matrix_dim];
        let data = matrices_flat.reshape(&full_shape).expect("reshape failed");

        Self {
            data,
            metric,
            dx,
            shape,
        }
    }

    /// Downloads the field to a collection of CausalMultiVectors.
    ///
    /// Converts from Matrix Representation back to coefficient form using trace projection.
    pub fn to_coefficients(&self) -> Vec<CausalMultiVector<T>>
    where
        T: std::ops::Neg<Output = T>,
    {
        let num_cells = self.num_cells();
        let num_blades = 1 << self.metric.dimension();
        let matrix_dim = Self::compute_matrix_dim(self.metric.dimension());

        // Convert matrix_dim to T using Ring arithmetic
        let exponent = self.metric.dimension().div_ceil(2);
        let mut d_val = T::one();
        let two = T::one() + T::one();

        for _ in 0..exponent {
            d_val = d_val * two;
        }

        let scale = T::one() / d_val;

        // Flatten field data to [Batch, D*D]
        let field_flat = self
            .data
            .reshape(&[num_cells, matrix_dim * matrix_dim])
            .expect("reshape failed");

        // Generate inverse basis matrices (Γ_I)⁻¹
        let basis_dual_tensor = gamma::get_dual_basis_gammas::<T>(&self.metric);
        let basis_dual_flat = basis_dual_tensor
            .reshape(&[num_blades, matrix_dim * matrix_dim])
            .expect("reshape failed");

        // Transpose to [D*D, NumBlades]
        let basis_dual_t = basis_dual_flat
            .permute_axes(&[1, 0])
            .expect("permute failed");

        // Project: Coeffs = Field @ BasisDual_T
        let coeffs_raw = field_flat.matmul(&basis_dual_t).expect("matmul failed");

        // Scale by 1/d
        let scale_tensor = CausalTensor::<T>::from_shape_fn(&[1], |_| scale);
        let coeffs = &coeffs_raw * &scale_tensor;

        // Download and chunk into Multivectors
        let flat_coeffs = coeffs.into_vec();

        flat_coeffs
            .chunks(num_blades)
            .map(|chunk| CausalMultiVector::unchecked(chunk.to_vec(), self.metric))
            .collect()
    }

    /// Computes the matrix dimension for a given algebra dimension.
    ///
    /// For Cl(p,q,r), the matrix dimension is 2^⌈N/2⌉ where N = p + q + r.
    pub fn compute_matrix_dim(n: usize) -> usize {
        1 << n.div_ceil(2)
    }
}
