/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */
use crate::traits::chain_complex::ChainComplex;
use crate::traits::has_hodge_star::HasHodgeStar;
use crate::types::manifold::Manifold;
use crate::types::manifold::differential::utils_differential;
use deep_causality_algebra::RealField;
use deep_causality_num::FromPrimitive;
use deep_causality_par::MaybeParallel;
use deep_causality_tensor::CausalTensor;

impl<K, R> Manifold<K, R>
where
    K: ChainComplex,
    K::Metric: HasHodgeStar<R, Complex = K>,
    R: RealField + MaybeParallel + FromPrimitive + Default + PartialEq,
{
    /// Computes the codifferential `δ` (delta) of a k-form.
    ///
    /// The codifferential is the adjoint of `d` with respect to the inner
    /// product defined by the Mass Matrices (Hodge Stars).
    ///
    /// Formula: `δ_k = M_{k-1}^{-1} · B_k · M_k`
    ///
    /// * `M_k`: Mass matrix for k-forms (diagonal, vended by the metric).
    /// * `B_k`: Boundary operator mapping k → k-1.
    /// * `M_{k-1}^{-1}`: Inverse mass matrix for (k-1)-forms.
    ///
    /// # Arguments
    /// * `k` - The degree of the form (must be > 0).
    ///
    /// # Returns
    /// A `CausalTensor` representing the (k-1)-form.
    ///
    /// # Panics
    /// Panics if the manifold has no metric attached. Callers must construct
    /// the manifold via `Manifold::with_metric(...)` (or the cubical
    /// equivalent) before calling Hodge-dependent differential operators.
    pub fn codifferential(&self, k: usize) -> CausalTensor<R> {
        self.codifferential_of(&self.get_k_form_data(k), k)
    }

    /// [`Self::codifferential`] evaluated on a caller-supplied k-form
    /// instead of the manifold's stored data — the allocation-free path
    /// for hot loops (no temporary manifold, no data-slab copy).
    ///
    /// # Panics
    /// As [`Self::codifferential`].
    pub fn codifferential_of(&self, field: &[R], k: usize) -> CausalTensor<R> {
        if k == 0 {
            return CausalTensor::new(vec![], vec![0]).unwrap();
        }

        let metric = self.metric.as_ref().expect(
            "Manifold::codifferential requires a metric; construct with `with_metric(...)`",
        );
        // Hodge ⋆ availability is validated at `Manifold::with_metric` construction,
        // so the lazy build has already succeeded for any non-degenerate input by
        // the time we reach the differential operators. The `.expect` is therefore
        // an unreachable path in the API surface — only fires if the manifold was
        // constructed by means that bypass the constructor's validation.
        let mass_k_cow = metric
            .hodge_star_matrix(&self.complex, k)
            .expect("Hodge ⋆ availability is validated at Manifold::with_metric");
        let mass_k_minus_1_cow = metric
            .hodge_star_matrix(&self.complex, k - 1)
            .expect("Hodge ⋆ availability is validated at Manifold::with_metric");
        let mass_k: &deep_causality_sparse::CsrMatrix<R> = mass_k_cow.as_ref();
        let mass_k_minus_1: &deep_causality_sparse::CsrMatrix<R> = mass_k_minus_1_cow.as_ref();

        let boundary_k_cow = self.complex.boundary_matrix(k);
        let boundary_k: &deep_causality_sparse::CsrMatrix<i8> = &boundary_k_cow;

        let weighted_form = utils_differential::apply_metric_operator(mass_k, field);
        let integrated_form = utils_differential::apply_operator(boundary_k, &weighted_form);

        let prev_dim_size = self.complex.num_cells(k - 1);
        let mut result_data = Vec::with_capacity(prev_dim_size);

        let zero_tol = <R as FromPrimitive>::from_f64(1e-12)
            .expect("1e-12 is representable in every RealField");

        for i in 0..prev_dim_size {
            let numerator = integrated_form.get(i).copied().unwrap_or(R::zero());

            let mut mass_val = R::zero();
            let start = mass_k_minus_1.row_indices()[i];
            let end = mass_k_minus_1.row_indices()[i + 1];

            for idx in start..end {
                if mass_k_minus_1.col_indices()[idx] == i {
                    mass_val = mass_k_minus_1.values()[idx];
                    break;
                }
            }

            if mass_val.abs() > zero_tol {
                result_data.push(numerator * (R::one() / mass_val));
            } else {
                result_data.push(R::zero());
            }
        }

        CausalTensor::new(result_data, vec![prev_dim_size]).unwrap()
    }
}
