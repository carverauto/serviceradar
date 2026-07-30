/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! Wilson action and observables.
//!
//! Implements the standard Wilson gauge action and Wilson/Polyakov loop observables.

use crate::{ChainComplex, GaugeGroup, LatticeCell, LatticeGaugeField, TopologyError};
use deep_causality_algebra::{ComplexField, DivisionAlgebra, Field, RealField};
use deep_causality_num::{FromPrimitive, ToPrimitive};
// use deep_causality_tensor::TensorData; // Removed
use std::fmt::Debug;

// ============================================================================
// Wilson Action
// ============================================================================
impl<
    G: GaugeGroup,
    const D: usize,
    M: Field + Copy + Default + PartialOrd + Debug + ComplexField<R> + DivisionAlgebra<R>,
    R: RealField + FromPrimitive + ToPrimitive,
    S,
> LatticeGaugeField<G, D, M, R, S>
{
    /// Compute the global Wilson gauge action.
    ///
    /// # Mathematics
    ///
    /// $$S_W = \beta \sum_{x} \sum_{\mu<\nu} \left(1 - \frac{1}{N}\text{ReTr} U_{\mu\nu}(x)\right)$$
    ///
    /// # Physics
    ///
    /// The Wilson action approaches the continuum Yang-Mills action:
    /// $S \to \int d^4x \frac{1}{4} F_{\mu\nu}^a F^{\mu\nu}_a$ as $a \to 0$.
    ///
    /// # Returns
    ///
    /// The total action value.
    ///
    /// # Errors
    ///
    /// Returns error if plaquette computation fails.
    pub fn try_wilson_action(&self) -> Result<R, TopologyError>
    where
        M: Field + DivisionAlgebra<R>,
        R: RealField,
    {
        let n = G::matrix_dim();
        let n_t = R::from_f64(n as f64).ok_or_else(|| {
            TopologyError::LatticeGaugeError("Failed to convert matrix dimension to T".to_string())
        })?;
        let one = R::one();

        let mut action = R::zero();

        // Sum over all sites and all planes μ < ν
        for site_cell in self.lattice.cells(0) {
            let site = *site_cell.position();
            for mu in 0..D {
                for nu in (mu + 1)..D {
                    let plaq = self.try_plaquette(&site, mu, nu)?;
                    let tr = plaq.re_trace();
                    // S_p = 1 - Re[Tr(U_p)] / N
                    let s_p = one - tr / n_t;
                    action += s_p;
                }
            }
        }

        // Multiply by β
        Ok(self.beta * action)
    }

    /// Action contribution from a single plaquette.
    ///
    /// # Mathematics
    ///
    /// $$s_p = \beta \left(1 - \frac{1}{N}\text{ReTr} U_p\right)$$
    ///
    /// # Arguments
    ///
    /// * `site` - Plaquette location
    /// * `mu` - First direction
    /// * `nu` - Second direction
    ///
    /// # Returns
    ///
    /// The local action contribution.
    ///
    /// # Errors
    ///
    /// Returns error if plaquette computation fails.
    pub fn try_plaquette_action(
        &self,
        site: &[usize; D],
        mu: usize,
        nu: usize,
    ) -> Result<R, TopologyError>
    where
        M: Field + DivisionAlgebra<R>,
        R: RealField,
    {
        let n = G::matrix_dim();
        let n_t = R::from_f64(n as f64).ok_or_else(|| {
            TopologyError::LatticeGaugeError("Failed to convert matrix dimension to T".to_string())
        })?;
        let one = R::one();

        let plaq = self.try_plaquette(site, mu, nu)?;
        let tr = plaq.re_trace();
        let s_p = one - tr / n_t;

        Ok(self.beta * s_p)
    }

    // ============================================================================
    // Wilson Loops
    // ============================================================================

    /// Compute an R×T rectangular Wilson loop.
    ///
    /// The Wilson loop is the trace of the ordered product of link variables
    /// around a rectangular closed path of size R×T in the μ-ν plane.
    ///
    /// # Mathematics
    ///
    /// For a rectangle with corner at site n, extending R sites in direction μ
    /// and T sites in direction ν:
    ///
    /// $$W(R,T) = \text{Tr}\left[\prod_{i=0}^{R-1} U_\mu(n + i\hat\mu)
    ///           \cdot \prod_{j=0}^{T-1} U_\nu(n + R\hat\mu + j\hat\nu)
    ///           \cdot \prod_{i=R-1}^{0} U_\mu^\dagger(n + i\hat\mu + T\hat\nu)
    ///           \cdot \prod_{j=T-1}^{0} U_\nu^\dagger(n + j\hat\nu)\right]$$
    ///
    /// # Physics
    ///
    /// The expectation value of large Wilson loops determines the static
    /// quark potential V(R):
    ///
    /// $$\langle W(R,T) \rangle \sim e^{-V(R) T}$$
    ///
    /// - **Area law** (confining): $V(R) = \sigma R$ → linear potential
    /// - **Perimeter law** (deconfined): $V(R) = \text{const}$
    ///
    /// # Arguments
    ///
    /// * `corner` - Starting site coordinates
    /// * `r_dir` - Spatial direction (0 to D-1)
    /// * `t_dir` - Temporal direction (0 to D-1), must differ from r_dir
    /// * `r` - Extent in r_dir
    /// * `t` - Extent in t_dir
    ///
    /// # Returns
    ///
    /// The real part of the trace of the Wilson loop, normalized by N.
    ///
    /// # Errors
    ///
    /// Returns error if directions are invalid or link retrieval fails.
    pub fn try_wilson_loop(
        &self,
        corner: &[usize; D],
        r_dir: usize,
        t_dir: usize,
        r: usize,
        t: usize,
    ) -> Result<R, TopologyError>
    where
        M: Field + DivisionAlgebra<R>,
        R: RealField,
    {
        if r_dir >= D || t_dir >= D || r_dir == t_dir {
            return Err(TopologyError::LatticeGaugeError(format!(
                "Invalid directions: r_dir={}, t_dir={}, D={}",
                r_dir, t_dir, D
            )));
        }

        if r == 0 || t == 0 {
            return Err(TopologyError::LatticeGaugeError(
                "Wilson loop dimensions must be positive".to_string(),
            ));
        }

        let shape = self.lattice.shape();
        let n = G::matrix_dim();
        let n_t = R::from_f64(n as f64).ok_or_else(|| {
            TopologyError::LatticeGaugeError("Failed to convert matrix dimension to T".to_string())
        })?;

        // Start with identity
        let mut result = self.get_link_or_identity(&LatticeCell::edge(*corner, r_dir));
        let mut pos = *corner;

        // Bottom edge: move in r_dir (R links)
        for i in 0..r {
            if i > 0 {
                pos[r_dir] = (pos[r_dir] + 1) % shape[r_dir];
                let link = self.get_link_or_identity(&LatticeCell::edge(pos, r_dir));
                result = result.try_mul(&link).map_err(TopologyError::from)?;
            }
        }
        pos[r_dir] = (pos[r_dir] + 1) % shape[r_dir];

        // Right edge: move in t_dir (T links)
        for _ in 0..t {
            let link = self.get_link_or_identity(&LatticeCell::edge(pos, t_dir));
            result = result.try_mul(&link).map_err(TopologyError::from)?;
            pos[t_dir] = (pos[t_dir] + 1) % shape[t_dir];
        }

        // Top edge: move in -r_dir (R links, conjugated)
        for _ in 0..r {
            pos[r_dir] = (pos[r_dir] + shape[r_dir] - 1) % shape[r_dir];
            let link = self.get_link_or_identity(&LatticeCell::edge(pos, r_dir));
            result = result
                .try_mul(&link.dagger())
                .map_err(TopologyError::from)?;
        }

        // Left edge: move in -t_dir (T links, conjugated)
        for _ in 0..t {
            pos[t_dir] = (pos[t_dir] + shape[t_dir] - 1) % shape[t_dir];
            let link = self.get_link_or_identity(&LatticeCell::edge(pos, t_dir));
            result = result
                .try_mul(&link.dagger())
                .map_err(TopologyError::from)?;
        }

        // Return Re[Tr(W)] / N
        Ok(result.re_trace() / n_t)
    }

    /// Polyakov loop (temporal Wilson line wrapping the lattice).
    ///
    /// The Polyakov loop is the trace of the product of temporal link variables
    /// wrapping around the lattice in the temporal direction.
    ///
    /// # Mathematics
    ///
    /// For a lattice with Nt sites in the temporal direction (assumed to be
    /// direction 0 by convention):
    ///
    /// $$P(\vec{x}) = \text{Tr}\left[\prod_{t=0}^{N_t-1} U_0(\vec{x}, t)\right]$$
    ///
    /// # Physics
    ///
    /// The Polyakov loop is the order parameter for the confinement/deconfinement
    /// phase transition at finite temperature:
    ///
    /// - **Confined phase:** $\langle P \rangle = 0$
    ///   (free energy of isolated quark is infinite)
    /// - **Deconfined phase:** $\langle P \rangle \neq 0$
    ///   (quarks can exist as free particles)
    ///
    /// The expectation value is related to the free energy F_q of a static quark:
    ///
    /// $$\langle P \rangle \sim e^{-F_q / T}$$
    ///
    /// # Arguments
    ///
    /// * `spatial_site` - Spatial coordinates (all dimensions except temporal)
    /// * `temporal_dir` - Which direction is temporal (default: 0)
    ///
    /// # Returns
    ///
    /// The real part of the trace of the Polyakov loop, normalized by N.
    ///
    /// # Errors
    ///
    /// Returns error if the temporal direction is invalid.
    pub fn try_polyakov_loop(
        &self,
        spatial_site: &[usize; D],
        temporal_dir: usize,
    ) -> Result<R, TopologyError>
    where
        M: Field + DivisionAlgebra<R>,
        R: RealField,
    {
        if temporal_dir >= D {
            return Err(TopologyError::LatticeGaugeError(format!(
                "Invalid temporal direction: {} (D={})",
                temporal_dir, D
            )));
        }

        let shape = self.lattice.shape();
        let nt = shape[temporal_dir];
        let n = G::matrix_dim();
        let n_t = R::from_f64(n as f64).ok_or_else(|| {
            TopologyError::LatticeGaugeError("Failed to convert matrix dimension to T".to_string())
        })?;

        let mut pos = *spatial_site;

        // Start with first temporal link
        let mut result = self.get_link_or_identity(&LatticeCell::edge(pos, temporal_dir));

        // Multiply remaining temporal links
        for _ in 1..nt {
            pos[temporal_dir] = (pos[temporal_dir] + 1) % shape[temporal_dir];
            let link = self.get_link_or_identity(&LatticeCell::edge(pos, temporal_dir));
            result = result.try_mul(&link).map_err(TopologyError::from)?;
        }

        // Return Re[Tr(P)] / N
        Ok(result.re_trace() / n_t)
    }

    /// Average Polyakov loop over all spatial sites.
    ///
    /// # Physics
    ///
    /// The spatially averaged Polyakov loop is used to detect the
    /// confinement/deconfinement transition in finite-temperature QCD.
    ///
    /// # Arguments
    ///
    /// * `temporal_dir` - The direction treated as time
    ///
    /// # Returns
    ///
    /// The spatially averaged Polyakov loop value.
    ///
    /// # Errors
    ///
    /// Returns error if computation fails.
    pub fn try_average_polyakov_loop(&self, temporal_dir: usize) -> Result<R, TopologyError>
    where
        M: Field + DivisionAlgebra<R>,
        R: RealField,
    {
        let mut sum = R::zero();
        let mut count = 0usize;

        for site_cell in self.lattice.cells(0) {
            let site = *site_cell.position();
            let p = self.try_polyakov_loop(&site, temporal_dir)?;
            sum += p;
            count += 1;
        }

        if count == 0 {
            return Ok(R::zero());
        }

        let count_t = R::from_f64(count as f64).ok_or_else(|| {
            TopologyError::LatticeGaugeError("Failed to convert count to T".to_string())
        })?;
        Ok(sum / count_t)
    }
}
