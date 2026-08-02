/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! Monte Carlo primitives.
//!
//! Helper functions for Monte Carlo algorithms, including staple calculation
//! and local action changes.

use crate::{GaugeGroup, LatticeCell, LatticeGaugeField, LinkVariable, TopologyError};
use deep_causality_algebra::{ComplexField, DivisionAlgebra, Field, RealField};
use deep_causality_num::{FromPrimitive, ToPrimitive};
// use deep_causality_tensor::TensorData; // Removed
use std::fmt::Debug;

// ============================================================================
// Monte Carlo Updates
// ============================================================================
impl<
    G: GaugeGroup,
    const D: usize,
    M: Field + Copy + Default + PartialOrd + Debug + ComplexField<R> + DivisionAlgebra<R>,
    R: RealField + FromPrimitive + ToPrimitive,
    S,
> LatticeGaugeField<G, D, M, R, S>
{
    /// Compute the staple sum for a given link.
    ///
    /// # Mathematics
    ///
    /// The staple $V_{\mu}(x)$ is the sum of products of links surrounding $U_{\mu}(x)$
    /// that form closed loops (plaquettes):
    ///
    /// $$V_{\mu}(x) = \sum_{\nu \neq \mu} \left[ U_{\nu}(x+\hat\mu) U_{\mu}^\dagger(x+\hat\nu) U_{\nu}^\dagger(x)
    ///              + U_{\nu}^\dagger(x+\hat\mu-\hat\nu) U_{\mu}^\dagger(x-\hat\nu) U_{\nu}(x-\hat\nu) \right]$$
    ///
    /// # Physics
    ///
    /// The staple represents the local molecular field acting on the link variable.
    /// The Wilson action can be written as $S \propto \text{ReTr}(U_\mu V_\mu^\dagger)$.
    ///
    /// # Arguments
    ///
    /// * `edge` - The link location (x, μ)
    ///
    /// # Returns
    ///
    /// The sum of staples (which is generally NOT in SU(N)).
    ///
    /// # Errors
    ///
    /// Returns error if staple computation fails.
    pub fn try_staple(&self, edge: &LatticeCell<D>) -> Result<LinkVariable<G, M, R>, TopologyError>
    where
        M: Field + DivisionAlgebra<R>,
        R: RealField,
    {
        let site = *edge.position();
        let mu = edge.orientation().trailing_zeros() as usize;
        let shape = self.lattice.shape();

        let mut staple_sum = LinkVariable::<G, M, R>::try_zero().map_err(TopologyError::from)?;

        for nu in 0..D {
            if nu == mu {
                continue;
            }

            // Forward staple: U_ν(n+μ̂) U_μ†(n+ν̂) U_ν†(n)
            let mut site_plus_mu = site;
            site_plus_mu[mu] = (site_plus_mu[mu] + 1) % shape[mu];

            let mut site_plus_nu = site;
            site_plus_nu[nu] = (site_plus_nu[nu] + 1) % shape[nu];

            let u_nu_at_n_plus_mu = self.get_link_or_identity(&LatticeCell::edge(site_plus_mu, nu));
            let u_mu_at_n_plus_nu = self.get_link_or_identity(&LatticeCell::edge(site_plus_nu, mu));
            let u_nu_at_n = self.get_link_or_identity(&LatticeCell::edge(site, nu));

            let forward = u_nu_at_n_plus_mu
                .try_mul(&u_mu_at_n_plus_nu.dagger())
                .map_err(TopologyError::from)?
                .try_mul(&u_nu_at_n.dagger())
                .map_err(TopologyError::from)?;

            // Backward staple: U_ν†(n+μ̂-ν̂) U_μ†(n-ν̂) U_ν(n-ν̂)
            let mut site_minus_nu = site;
            site_minus_nu[nu] = (site_minus_nu[nu] + shape[nu] - 1) % shape[nu];

            let mut site_plus_mu_minus_nu = site_plus_mu;
            site_plus_mu_minus_nu[nu] = (site_plus_mu_minus_nu[nu] + shape[nu] - 1) % shape[nu];

            let u_nu_at_n_plus_mu_minus_nu =
                self.get_link_or_identity(&LatticeCell::edge(site_plus_mu_minus_nu, nu));
            let u_mu_at_n_minus_nu =
                self.get_link_or_identity(&LatticeCell::edge(site_minus_nu, mu));
            let u_nu_at_n_minus_nu =
                self.get_link_or_identity(&LatticeCell::edge(site_minus_nu, nu));

            let backward = u_nu_at_n_plus_mu_minus_nu
                .dagger()
                .try_mul(&u_mu_at_n_minus_nu.dagger())
                .map_err(TopologyError::from)?
                .try_mul(&u_nu_at_n_minus_nu)
                .map_err(TopologyError::from)?;

            // Add staples to sum
            staple_sum = staple_sum.try_add(&forward).map_err(TopologyError::from)?;
            staple_sum = staple_sum.try_add(&backward).map_err(TopologyError::from)?;
        }

        Ok(staple_sum)
    }

    /// Calculate the change in action if a link is updated.
    ///
    /// # Mathematics
    ///
    /// $$\Delta S = S(U') - S(U) = -\frac{\beta}{N} \text{ReTr}((U' - U) V^\dagger)$$
    ///
    /// # Physics
    ///
    /// Used in the Metropolis algorithm to decide whether to accept a proposed update.
    /// Only the local contribution (staples touching the link) needs to be computed.
    ///
    /// # Arguments
    ///
    /// * `edge` - The link being updated
    /// * `new_link` - The proposed new value $U'$
    ///
    /// # Returns
    ///
    /// The change in the total action $\Delta S$.
    ///
    /// # Errors
    ///
    /// Returns error if computation fails.
    pub fn try_local_action_change(
        &self,
        edge: &LatticeCell<D>,
        new_link: &LinkVariable<G, M, R>,
    ) -> Result<R, TopologyError>
    where
        M: Field + DivisionAlgebra<R>,
        R: RealField,
    {
        let old_link = self.get_link_or_identity(edge);
        let staple = self.try_staple(edge)?;

        let n = G::matrix_dim();
        let n_t = R::from_f64(n as f64).ok_or_else(|| {
            TopologyError::LatticeGaugeError("Failed to convert matrix dimension to T".to_string())
        })?;

        // ΔS = β * (Re[Tr(U·V)] - Re[Tr(U'·V)]) / N
        // (This is the change in action, negative means lower action)

        let old_tr = old_link
            .try_mul(&staple)
            .map_err(TopologyError::from)?
            .re_trace();
        let new_tr = new_link
            .try_mul(&staple)
            .map_err(TopologyError::from)?
            .re_trace();

        Ok(self.beta * (old_tr - new_tr) / n_t)
    }
}
