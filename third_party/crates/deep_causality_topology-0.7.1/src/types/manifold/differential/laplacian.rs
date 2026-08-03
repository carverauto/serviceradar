/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::traits::chain_complex::ChainComplex;
use crate::traits::has_hodge_star::HasHodgeStar;
use crate::types::manifold::Manifold;
use deep_causality_par::MaybeParallel;

use deep_causality_algebra::RealField;
use deep_causality_num::FromPrimitive;
use deep_causality_tensor::CausalTensor;

impl<K, R> Manifold<K, R>
where
    K: ChainComplex + Clone,
    K::Metric: HasHodgeStar<R, Complex = K> + Clone,
    R: RealField + MaybeParallel + FromPrimitive + Default + PartialEq + std::fmt::Debug,
{
    /// Computes the Hodge-Laplacian operator `Δ` on a k-form.
    ///
    /// The Laplacian is defined as: `Δ = dδ + δd`
    /// where `d` is the exterior derivative and `δ` is the codifferential.
    /// It maps k-forms to k-forms.
    ///
    /// # Panics
    /// Panics if the manifold has no metric attached. Callers must construct
    /// the manifold via `Manifold::with_metric(...)` (or the cubical
    /// equivalent) before calling Hodge-dependent differential operators.
    pub fn laplacian(&self, k: usize) -> CausalTensor<R> {
        self.laplacian_of(&self.get_k_form_data(k), k)
    }

    /// [`Self::laplacian`] evaluated on a caller-supplied k-form instead
    /// of the manifold's stored data. Composes the `_of` variants of `d`
    /// and `δ` directly, so — unlike the stored-data path used to — it
    /// builds **no** temporary manifolds: this is the operator the CG
    /// solves apply once per iteration and the DEC solver's rate evaluates
    /// once per RK4 stage.
    ///
    /// # Panics
    /// As [`Self::laplacian`].
    pub fn laplacian_of(&self, field: &[R], k: usize) -> CausalTensor<R> {
        let n = self.complex.max_dim();
        let current_dim_size = self.complex.num_cells(k);

        let term_a = if k > 0 {
            let delta = self.codifferential_of(field, k);
            self.exterior_derivative_of(delta.as_slice(), k - 1)
        } else {
            CausalTensor::new(vec![R::zero(); current_dim_size], vec![current_dim_size]).unwrap()
        };

        let term_b = if k < n {
            let d = self.exterior_derivative_of(field, k);
            self.codifferential_of(d.as_slice(), k + 1)
        } else {
            CausalTensor::new(vec![R::zero(); current_dim_size], vec![current_dim_size]).unwrap()
        };

        let mut result_data = Vec::with_capacity(current_dim_size);
        let slice_a = term_a.as_slice();
        let slice_b = term_b.as_slice();

        let len = slice_a.len().max(slice_b.len());

        for i in 0..len {
            let a = slice_a.get(i).copied().unwrap_or(R::zero());
            let b = slice_b.get(i).copied().unwrap_or(R::zero());
            result_data.push(a + b);
        }

        CausalTensor::new(result_data, vec![current_dim_size]).unwrap()
    }
}
