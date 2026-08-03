/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */
use crate::traits::chain_complex::ChainComplex;
use crate::types::manifold::Manifold;
use crate::types::manifold::differential::utils_differential;
use core::fmt::Debug;
use deep_causality_algebra::RealField;
use deep_causality_par::MaybeParallel;
use deep_causality_tensor::CausalTensor;

impl<K, D> Manifold<K, D>
where
    K: ChainComplex,
    D: RealField + MaybeParallel + Default + PartialEq + Debug,
{
    /// Computes the exterior derivative of a k-form.
    ///
    /// The exterior derivative `d` maps k-forms to (k+1)-forms. For a discrete
    /// chain complex, this is represented by the coboundary operator
    /// `C_k = B_{k+1}^T`, available generically via `ChainComplex::coboundary_matrix(k)`.
    ///
    /// # Arguments
    /// * `k` - The degree of the form (0 for scalar fields, 1 for 1-forms, etc.)
    ///
    /// # Returns
    /// A new tensor representing the (k+1)-form `df`.
    ///
    /// # Mathematical Background
    /// The exterior derivative satisfies:
    /// - Linearity: `d(αf + βg) = α df + β dg`
    /// - Nilpotency: `d² = 0` (applying d twice gives zero)
    /// - Leibniz rule: `d(f ∧ g) = df ∧ g + (-1)^k f ∧ dg`
    pub fn exterior_derivative(&self, k: usize) -> CausalTensor<D> {
        self.exterior_derivative_of(&self.get_k_form_data(k), k)
    }

    /// [`Self::exterior_derivative`] evaluated on a caller-supplied k-form
    /// instead of the manifold's stored data. This is the allocation-free
    /// path for hot loops (the CG operator application, the DEC solver's
    /// rate evaluation): no temporary manifold, no data-slab copy — just
    /// the sparse matvec against the memoized coboundary matrix.
    pub fn exterior_derivative_of(&self, field: &[D], k: usize) -> CausalTensor<D> {
        if k >= self.complex.max_dim() {
            // d of the highest dimension is zero.
            return CausalTensor::new(vec![], vec![0]).expect("Tensor alloc failed");
        }

        let coboundary_cow = self.complex.coboundary_matrix(k);
        let coboundary: &deep_causality_sparse::CsrMatrix<i8> = &coboundary_cow;

        // Operation: C_k * omega_k
        let result = utils_differential::apply_operator(coboundary, field);

        // Result size matches the number of (k+1)-cells.
        let next_dim_size = self.complex.num_cells(k + 1);

        // Safety: pad / truncate to the correct skeleton size if the sparse
        // matrix happens to have a different effective row count.
        if result.len() != next_dim_size {
            let mut corrected = result;
            corrected.resize(next_dim_size, D::zero());
            return CausalTensor::new(corrected, vec![next_dim_size]).unwrap();
        }

        CausalTensor::new(result, vec![next_dim_size]).expect("Tensor alloc failed")
    }
}
