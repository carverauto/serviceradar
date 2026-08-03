/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! Gauge transformations for lattice gauge fields.
//!
//! Gauge transformations are local group rotations that preserve physics.

use crate::traits::chain_complex::ChainComplex;
use crate::{GaugeGroup, LatticeGaugeField, LinkVariable, TopologyError};
use deep_causality_algebra::{ComplexField, DivisionAlgebra, Field, RealField};
use deep_causality_num::{FromPrimitive, ToPrimitive};

use std::fmt::Debug;

// ============================================================================
// Gauge Transformations
// ============================================================================

impl<
    G: GaugeGroup,
    const D: usize,
    M: Field + Copy + Default + PartialOrd + Debug + ComplexField<R> + DivisionAlgebra<R>,
    R: RealField + FromPrimitive + ToPrimitive,
    S,
> LatticeGaugeField<G, D, M, R, S>
{
    /// Apply a gauge transformation to the field.
    ///
    /// A gauge transformation rotates link variables according to:
    ///
    /// $$U_\mu(x) \to \Omega(x) \cdot U_\mu(x) \cdot \Omega^\dagger(x + \hat\mu)$$
    ///
    /// where $\Omega(x) \in G$ is a group element at each site.
    ///
    /// # Physics
    ///
    /// Gauge transformations are symmetries of the theory:
    /// - The Wilson action is **invariant** under gauge transformations
    /// - Only gauge-invariant observables (Wilson loops, traces) are physical
    /// - Elitzur's theorem: ⟨non-gauge-invariant⟩ = 0
    ///
    /// # Mathematical Details
    ///
    /// The transformation law ensures that parallel transport transforms covariantly:
    /// - Original: $\psi(x+\hat\mu) = U_\mu(x) \psi(x)$
    /// - Transformed: $\psi'(x+\hat\mu) = U'_\mu(x) \psi'(x)$
    ///
    /// This preserves the gauge-covariant derivative.
    ///
    /// # Arguments
    ///
    /// * `gauge_fn` - Closure providing the gauge element $\Omega(x)$ for each site
    ///
    /// # Errors
    ///
    /// Returns error if any gauge transformation fails.
    ///
    /// # Example
    ///
    /// ```ignore
    /// // Random gauge transformation
    /// field.try_gauge_transform(|site| {
    ///     LinkVariable::<SU2, f64>::random(&mut rng)
    /// })?;
    /// ```
    pub fn try_gauge_transform<F>(&mut self, gauge_fn: F) -> Result<(), TopologyError>
    where
        F: Fn(&[usize; D]) -> LinkVariable<G, M, R>,
        M: Field + DivisionAlgebra<R>,
        R: RealField,
    {
        use std::collections::HashMap;

        // Clone shape upfront to avoid borrow conflict
        let shape: [usize; D] = *self.lattice.shape();
        let edges: Vec<_> = self.links.keys().cloned().collect();

        // Cache Ω(x) so each site uses a single gauge element during this transform
        let mut omega_cache: HashMap<[usize; D], LinkVariable<G, M, R>> = HashMap::new();
        let mut omega_at = |x: &[usize; D]| -> LinkVariable<G, M, R> {
            omega_cache.entry(*x).or_insert_with(|| gauge_fn(x)).clone()
        };

        for edge in edges {
            let site = *edge.position();
            let mu = edge.orientation().trailing_zeros() as usize;

            // Compute site + μ̂ with periodic boundary
            let mut site_plus_mu = site;
            site_plus_mu[mu] = (site_plus_mu[mu] + 1) % shape[mu];

            // Get cached gauge elements
            let omega_x = omega_at(&site);
            let omega_x_plus_mu = omega_at(&site_plus_mu);

            // U'_μ(x) = Ω(x) · U_μ(x) · Ω†(x + μ̂)
            let current = self.get_link_or_identity(&edge);
            let transformed = omega_x
                .try_mul(&current)
                .map_err(TopologyError::from)?
                .try_mul(&omega_x_plus_mu.dagger())
                .map_err(TopologyError::from)?;

            self.set_link(edge, transformed);
        }

        Ok(())
    }

    /// Apply a random gauge transformation (for testing gauge invariance).
    ///
    /// Useful for verifying that observables are gauge-invariant.
    pub fn try_random_gauge_transform<RngType>(
        &mut self,
        rng: &mut RngType,
    ) -> Result<(), TopologyError>
    where
        RngType: deep_causality_rand::Rng,
        M: crate::types::gauge::link_variable::random::RandomField + DivisionAlgebra<R> + Field,
        R: RealField,
    {
        use std::collections::HashMap;

        // Pre-generate gauge elements for all sites
        let mut gauge_elements: HashMap<[usize; D], LinkVariable<G, M, R>> = HashMap::new();

        for site_cell in self.lattice.cells(0) {
            let site = *site_cell.position();
            let omega = LinkVariable::<G, M, R>::try_random(rng).map_err(TopologyError::from)?;
            gauge_elements.insert(site, omega);
        }

        // Apply transformation
        self.try_gauge_transform(|site| {
            gauge_elements
                .get(site)
                .cloned()
                .unwrap_or_else(|| LinkVariable::identity())
        })
    }
}
