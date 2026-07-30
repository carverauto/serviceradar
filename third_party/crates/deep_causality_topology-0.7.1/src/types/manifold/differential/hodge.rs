/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */
use crate::traits::chain_complex::ChainComplex;
use crate::traits::has_hodge_star::HasHodgeStar;
use crate::types::manifold::Manifold;
use crate::types::manifold::differential::utils_differential;
use core::fmt::Debug;
use deep_causality_algebra::RealField;
use deep_causality_num::FromPrimitive;
use deep_causality_par::MaybeParallel;
use deep_causality_tensor::CausalTensor;

impl<K, R> Manifold<K, R>
where
    K: ChainComplex,
    K::Metric: HasHodgeStar<R, Complex = K>,
    R: RealField + MaybeParallel + FromPrimitive + Default + PartialEq + Debug,
{
    /// Computes the Hodge star operator on a k-form.
    ///
    /// The Hodge star `⋆` maps k-forms to (n-k)-forms, where n is the dimension
    /// of the manifold. This implementation routes through the
    /// [`HasHodgeStar<R, Complex = K>`] capability trait on the manifold's
    /// metric: simplicial metrics (`ReggeGeometry<R>`) vend `Cow::Borrowed`
    /// against the precomputed `SimplicialComplex::hodge_star_operators` cache;
    /// cubical metrics (`CubicalReggeGeometry<D, R>`) vend `Cow::Owned` from
    /// per-cell volume data.
    ///
    /// # Panics
    /// Panics if the manifold has no metric attached. Callers must construct
    /// the manifold via `Manifold::with_metric(...)` (or the cubical
    /// equivalent) before calling Hodge-dependent differential operators.
    pub fn hodge_star(&self, k: usize) -> CausalTensor<R> {
        self.hodge_star_of(&self.get_k_form_data(k), k)
    }

    /// [`Self::hodge_star`] evaluated on a caller-supplied k-form instead
    /// of the manifold's stored data — the allocation-free path for hot
    /// loops (no temporary manifold, no data-slab copy).
    ///
    /// # Panics
    /// As [`Self::hodge_star`].
    pub fn hodge_star_of(&self, field: &[R], k: usize) -> CausalTensor<R> {
        let n = self.complex.max_dim();

        if k > n {
            return CausalTensor::new(vec![], vec![0]).expect("Failed to create empty tensor");
        }

        let metric = self
            .metric
            .as_ref()
            .expect("Manifold::hodge_star requires a metric; construct with `with_metric(...)`");
        // Hodge ⋆ availability is validated at `Manifold::with_metric` construction.
        let star = metric
            .hodge_star_matrix(&self.complex, k)
            .expect("Hodge ⋆ availability is validated at Manifold::with_metric");

        let result_data = utils_differential::apply_metric_operator(star.as_ref(), field);
        let result_len = result_data.len();

        CausalTensor::new(result_data, vec![result_len]).expect("Failed to create dual form")
    }
}
