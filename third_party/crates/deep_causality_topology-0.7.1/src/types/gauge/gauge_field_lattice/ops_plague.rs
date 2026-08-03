/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! Plaquette and elementary loop operations.
//!
//! Calculates fundamental gauge invariant quantities like plaquettes (1x1 loops)
//! and rectangles (1x2 loops) used in actions and observables.

use crate::{
    ChainComplex, GaugeGroup, LatticeCell, LatticeGaugeField, LinkVariable, TopologyError,
};
use deep_causality_algebra::{ComplexField, DivisionAlgebra, Field, RealField};
use deep_causality_num::{FromPrimitive, ToPrimitive};
// use deep_causality_tensor::TensorData; // Removed
use std::fmt::Debug;

impl<
    G: GaugeGroup,
    const D: usize,
    M: Field + Copy + Default + PartialOrd + Debug + ComplexField<R> + DivisionAlgebra<R>,
    R: RealField + FromPrimitive + ToPrimitive,
    S,
> LatticeGaugeField<G, D, M, R, S>
{
    /// Compute the plaquette U_μν(n) at a given site.
    ///
    /// # Mathematics
    ///
    /// The plaquette is the ordered product of links around a 1x1 unit square:
    ///
    /// $$U_{\mu\nu}(n) = U_\mu(n) U_\nu(n+\hat\mu) U_\mu^\dagger(n+\hat\nu) U_\nu^\dagger(n)$$
    ///
    /// # Physics
    ///
    /// The plaquette is the smallest gauge invariant closed loop.
    /// It is related to the field strength tensor:
    /// $U_{\mu\nu} = \exp(iga^2 F_{\mu\nu} + O(a^3))$
    ///
    /// # Arguments
    ///
    /// * `site` - Base vertex position [x₀, x₁, ..., x_{D-1}]
    /// * `mu` - First direction (0 to D-1)
    /// * `nu` - Second direction (0 to D-1)
    ///
    /// # Returns
    ///
    /// The SU(N) matrix product around the plaquette.
    ///
    /// # Errors
    ///
    /// Returns error if directions are invalid (e.g. mu == nu).
    pub fn try_plaquette(
        &self,
        site: &[usize; D],
        mu: usize,
        nu: usize,
    ) -> Result<LinkVariable<G, M, R>, TopologyError>
    where
        M: Field + DivisionAlgebra<R>,
        R: RealField,
    {
        if mu >= D || nu >= D || mu == nu {
            return Err(TopologyError::LatticeGaugeError(format!(
                "Invalid plaquette directions: mu={}, nu={}, D={}",
                mu, nu, D
            )));
        }

        let shape = self.lattice.shape();

        // Edge 1: n → n + μ̂
        let edge1 = LatticeCell::edge(*site, mu);

        // Edge 2: n + μ̂ → n + μ̂ + ν̂
        let mut site_plus_mu = *site;
        site_plus_mu[mu] = (site_plus_mu[mu] + 1) % shape[mu];
        let edge2 = LatticeCell::edge(site_plus_mu, nu);

        // Edge 3: n + ν̂ → n + μ̂ + ν̂ (traversed backwards)
        let mut site_plus_nu = *site;
        site_plus_nu[nu] = (site_plus_nu[nu] + 1) % shape[nu];
        let edge3 = LatticeCell::edge(site_plus_nu, mu);

        // Edge 4: n → n + ν̂ (traversed backwards)
        let edge4 = LatticeCell::edge(*site, nu);

        // Get link variables
        let u1 = self.get_link_or_identity(&edge1);
        let u2 = self.get_link_or_identity(&edge2);
        let u3 = self.get_link_or_identity(&edge3);
        let u4 = self.get_link_or_identity(&edge4);

        // Plaquette = U_μ(n) U_ν(n+μ̂) U_μ†(n+ν̂) U_ν†(n)
        // Plaquette = U_μ(n) U_ν(n+μ̂) U_μ†(n+ν̂) U_ν†(n)
        let u1_u2 = u1.try_mul(&u2).map_err(TopologyError::from)?;
        let u3_dag = u3.dagger();
        let u4_dag = u4.dagger();
        let u1_u2_u3dag = u1_u2.try_mul(&u3_dag).map_err(TopologyError::from)?;
        let result = u1_u2_u3dag.try_mul(&u4_dag).map_err(TopologyError::from)?;

        Ok(result)
    }

    /// Compute the 1×2 rectangle Wilson loop.
    ///
    /// # Mathematics
    ///
    /// The rectangle loop extends 1 unit in $\mu$ and 2 units in $\nu$.
    /// It involves a product of 6 link variables.
    ///
    /// # Physics
    ///
    /// Rectangular loops are used in improved actions (e.g. Symanzik, Iwasaki)
    /// to cancel $O(a^2)$ discretization errors.
    ///
    /// # Arguments
    ///
    /// * `site` - Base vertex position
    /// * `mu` - Direction of length 1 side
    /// * `nu` - Direction of length 2 side
    ///
    /// # Returns
    ///
    /// The SU(N) matrix product around the rectangle.
    ///
    /// # Errors
    ///
    /// Returns error if directions are invalid.
    pub fn try_rectangle(
        &self,
        site: &[usize; D],
        mu: usize,
        nu: usize,
    ) -> Result<LinkVariable<G, M, R>, TopologyError>
    where
        M: Field + DivisionAlgebra<R>,
        R: RealField,
    {
        if mu >= D || nu >= D || mu == nu {
            return Err(TopologyError::LatticeGaugeError(format!(
                "Invalid rectangle directions: mu={}, nu={}, D={}",
                mu, nu, D
            )));
        }

        let shape = self.lattice.shape();

        // Path: n → n+μ̂ → n+μ̂+ν̂ → n+μ̂+2ν̂ → n+2ν̂ → n+ν̂ → n
        // Forward: U_μ(n), U_ν(n+μ̂), U_ν(n+μ̂+ν̂)
        // Backward: U_μ†(n+2ν̂), U_ν†(n+ν̂), U_ν†(n)

        let _pos = *site;
        let mut pos = *site;
        let mut result = LinkVariable::<G, M, R>::identity();

        // Step 1: n → n+μ̂
        let edge1 = LatticeCell::edge(pos, mu);
        result = result
            .try_mul(&self.get_link_or_identity(&edge1))
            .map_err(TopologyError::from)?;
        pos[mu] = (pos[mu] + 1) % shape[mu];

        // Step 2: n+μ̂ → n+μ̂+ν̂
        let edge2 = LatticeCell::edge(pos, nu);
        result = result
            .try_mul(&self.get_link_or_identity(&edge2))
            .map_err(TopologyError::from)?;
        pos[nu] = (pos[nu] + 1) % shape[nu];

        // Step 3: n+μ̂+ν̂ → n+μ̂+2ν̂
        let edge3 = LatticeCell::edge(pos, nu);
        result = result
            .try_mul(&self.get_link_or_identity(&edge3))
            .map_err(TopologyError::from)?;
        pos[nu] = (pos[nu] + 1) % shape[nu];

        // Step 4: n+μ̂+2ν̂ → n+2ν̂ (backward in μ)
        pos[mu] = (pos[mu] + shape[mu] - 1) % shape[mu];
        let edge4 = LatticeCell::edge(pos, mu);
        result = result
            .try_mul(&self.get_link_or_identity(&edge4).dagger())
            .map_err(TopologyError::from)?;

        // Step 5: n+2ν̂ → n+ν̂ (backward in ν)
        pos[nu] = (pos[nu] + shape[nu] - 1) % shape[nu];
        let edge5 = LatticeCell::edge(pos, nu);
        result = result
            .try_mul(&self.get_link_or_identity(&edge5).dagger())
            .map_err(TopologyError::from)?;

        // Step 6: n+ν̂ → n (backward in ν)
        pos[nu] = (pos[nu] + shape[nu] - 1) % shape[nu];
        let edge6 = LatticeCell::edge(pos, nu);
        result = result
            .try_mul(&self.get_link_or_identity(&edge6).dagger())
            .map_err(TopologyError::from)?;

        Ok(result)
    }

    /// Average plaquette value: (1/N_p) Σ_p Re[Tr(U_p)] / N.
    ///
    /// This is related to the action density.
    /// For identity configuration, returns 1.0.
    /// For random configuration, approaches 0.0.
    ///
    /// # Returns
    ///
    /// The average normalized trace of the plaquette.
    ///
    /// # Errors
    ///
    /// Returns error if plaquette computation fails.
    pub fn try_average_plaquette(&self) -> Result<R, TopologyError>
    where
        M: Field + DivisionAlgebra<R>,
        R: RealField,
    {
        let n = G::matrix_dim();
        let n_t = R::from_f64(n as f64).ok_or_else(|| {
            TopologyError::LatticeGaugeError("Failed to convert matrix dimension to T".to_string())
        })?;

        let mut sum = R::zero();
        let mut count = 0usize;

        // Sum over all sites and all planes μ < ν
        for site_cell in self.lattice.cells(0) {
            let site = *site_cell.position();
            for mu in 0..D {
                for nu in (mu + 1)..D {
                    let plaq = self.try_plaquette(&site, mu, nu)?;
                    let tr = plaq.re_trace();
                    sum += tr;
                    count += 1;
                }
            }
        }

        if count == 0 {
            return Ok(R::one());
        }

        // Average = sum / (count * N)
        let count_t = R::from_f64(count as f64).ok_or_else(|| {
            TopologyError::LatticeGaugeError("Failed to convert count to T".to_string())
        })?;
        Ok(sum / (count_t * n_t))
    }
}
