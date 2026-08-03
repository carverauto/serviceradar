/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::{GaugeField, GaugeGroup, Manifold, SimplicialComplex};
use deep_causality_metric::Metric;
use deep_causality_tensor::CausalTensor;

impl<G: GaugeGroup, M, R: deep_causality_algebra::RealField> GaugeField<G, M, R> {
    /// Returns a reference to the base manifold.
    ///
    /// # Returns
    ///
    /// Reference to the underlying spacetime manifold.
    #[inline]
    pub fn base(&self) -> &Manifold<SimplicialComplex<R>, R> {
        &self.base
    }

    /// Returns the spacetime metric signature.
    ///
    /// # Returns
    ///
    /// The metric variant (e.g. Minkowski) and dimension.
    #[inline]
    pub fn metric(&self) -> Metric {
        self.metric
    }

    /// Returns a reference to the gauge connection (potential).
    ///
    /// # Returns
    ///
    /// The connection tensor $A_\mu$.
    #[inline]
    pub fn connection(&self) -> &CausalTensor<M> {
        &self.connection
    }

    /// Returns a reference to the field strength (curvature).
    ///
    /// # Returns
    ///
    /// The curvature tensor $F_{\mu\nu}$.
    #[inline]
    pub fn field_strength(&self) -> &CausalTensor<M> {
        &self.field_strength
    }

    /// Returns the human-readable name of the gauge group.
    ///
    /// # Returns
    ///
    /// Name string (e.g. "SU(3)").
    #[inline]
    pub fn gauge_group_name(&self) -> &'static str {
        G::name()
    }

    /// Returns the dimension of the Lie algebra (number of generators).
    ///
    /// # Returns
    ///
    /// Number of generators (e.g. 8 for SU(3)).
    #[inline]
    pub fn lie_algebra_dim(&self) -> usize {
        G::LIE_ALGEBRA_DIM
    }

    /// Returns whether the gauge group is abelian.
    ///
    /// For abelian groups: F = dA
    /// For non-abelian groups: F = dA + A∧A
    ///
    /// # Returns
    ///
    /// `true` if group is abelian (U(1)), `false` otherwise.
    #[inline]
    pub fn is_abelian(&self) -> bool {
        G::IS_ABELIAN
    }

    /// Returns the spacetime dimension.
    ///
    /// # Returns
    ///
    /// Spacetime dimension D.
    #[inline]
    pub fn spacetime_dim(&self) -> usize {
        G::SPACETIME_DIM
    }

    /// Checks if using East Coast convention (-+++).
    ///
    /// East Coast is standard in GR textbooks (MTW, Wald).
    ///
    /// # Returns
    ///
    /// `true` if metric signature starts with -1 (time) followed by +1 (space).
    #[inline]
    pub fn is_east_coast(&self) -> bool {
        self.metric.sign_of_sq(0) == -1
    }

    /// Checks if using West Coast convention (+---).
    ///
    /// West Coast is standard in particle physics (Weinberg, Peskin & Schroeder).
    ///
    /// # Returns
    ///
    /// `true` if metric signature starts with +1 (time) followed by -1 (space).
    #[inline]
    pub fn is_west_coast(&self) -> bool {
        self.metric.sign_of_sq(0) == 1
            && self.metric.dimension() > 1
            && self.metric.sign_of_sq(1) == -1
    }
}
