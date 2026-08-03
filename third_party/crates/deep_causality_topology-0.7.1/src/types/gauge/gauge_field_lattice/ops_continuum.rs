/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! Continuum limit quantities for lattice gauge theory.
//!
//! These methods extract continuum field theory quantities from lattice configurations.

use crate::{ChainComplex, GaugeGroup, LatticeGaugeField, LinkVariable, TopologyError};
use deep_causality_algebra::{ComplexField, DivisionAlgebra, Field, RealField};
use deep_causality_num::{FromPrimitive, ToPrimitive};

use std::fmt::Debug;

// ============================================================================
// Continuum Limit Quantities
// ============================================================================

impl<
    G: GaugeGroup,
    const D: usize,
    M: Field + Copy + Default + PartialOrd + Debug + ComplexField<R> + DivisionAlgebra<R>,
    R: RealField + FromPrimitive + ToPrimitive,
    S,
> LatticeGaugeField<G, D, M, R, S>
{
    /// Extract the naive lattice field strength tensor F_μν.
    ///
    /// Computes an approximation to the continuum field strength from the plaquette.
    ///
    /// # Mathematics
    ///
    /// The clover (symmetric) definition uses plaquettes centered at site x:
    ///
    /// $$\tilde F_{\mu\nu}(x) = -\frac{i}{8a^2}\left[Q_{\mu\nu}(x) - Q_{\mu\nu}^\dagger(x)\right]$$
    ///
    /// where $Q_{\mu\nu}$ is the sum of four plaquettes ("clover") around x.
    ///
    /// For the naive (asymmetric) discretization used here:
    ///
    /// $$F_{\mu\nu}(x) \approx \frac{1}{2ia^2}\left[U_{\mu\nu}(x) - U_{\mu\nu}^\dagger(x)\right]$$
    ///
    /// This has $O(a^2)$ discretization errors.
    ///
    /// # Physics
    ///
    /// The field strength tensor encodes:
    /// - **Electric field:** $E_i = F_{0i}$
    /// - **Magnetic field:** $B_i = \frac{1}{2}\epsilon_{ijk} F_{jk}$
    ///
    /// For SU(N) gauge theories, $F_{\mu\nu}$ is Lie algebra-valued:
    /// $F_{\mu\nu} = F_{\mu\nu}^a T^a$ where $T^a$ are generators.
    ///
    /// # Arguments
    ///
    /// * `site` - LatticeComplex site coordinates
    /// * `mu` - First Lorentz index (0 to D-1)
    /// * `nu` - Second Lorentz index (0 to D-1)
    ///
    /// # Returns
    ///
    /// The anti-Hermitian traceless matrix approximating $ia^2 F_{\mu\nu}$.
    ///
    /// # Errors
    ///
    /// Returns error if plaquette computation fails.
    pub fn try_field_strength(
        &self,
        site: &[usize; D],
        mu: usize,
        nu: usize,
    ) -> Result<LinkVariable<G, M, R>, TopologyError>
    where
        M: Field + DivisionAlgebra<R>,
        R: RealField,
    {
        if mu == nu {
            // F_μμ = 0 by antisymmetry
            return LinkVariable::<G, M, R>::try_zero().map_err(TopologyError::from);
        }

        // Get plaquette U_μν
        let u_munu = self.try_plaquette(site, mu, nu)?;

        // F_μν ≈ (U_μν - U_μν†) / 2
        // This gives the anti-Hermitian part (proportional to ia²F)
        // F_μν ≈ (U_μν - U_μν†) / 2
        // This gives the anti-Hermitian part (proportional to ia²F)
        let u_dag = u_munu.dagger();
        let neg_one = M::from_re_im(
            R::from_f64(-1.0).ok_or_else(|| {
                TopologyError::LatticeGaugeError("Failed to convert -1 to T".to_string())
            })?,
            R::zero(),
        );
        let diff = u_munu
            .try_add(&u_dag.try_scale(&neg_one).map_err(TopologyError::from)?)
            .map_err(TopologyError::from)?;
        let half = M::from_re_im(
            R::from_f64(0.5).ok_or_else(|| {
                TopologyError::LatticeGaugeError("Failed to convert 0.5 to T".to_string())
            })?,
            R::zero(),
        );

        diff.try_scale(&half).map_err(TopologyError::from)
    }

    /// Compute the topological charge density q(x).
    ///
    /// The topological charge density measures the local winding of the gauge field.
    ///
    /// # Mathematics
    ///
    /// In 4D, the topological charge density is:
    ///
    /// $$q(x) = \frac{1}{32\pi^2} \epsilon_{\mu\nu\rho\sigma}
    ///          \text{Tr}\left[F_{\mu\nu}(x) F_{\rho\sigma}(x)\right]$$
    ///
    /// The total topological charge $Q = \sum_x q(x)$ is quantized to integers
    /// for smooth configurations.
    ///
    /// # Physics
    ///
    /// Topological charge is related to:
    /// - **Instanton number:** Q counts instantons - anti-instantons
    /// - **Chiral anomaly:** $\partial_\mu j_5^\mu = \frac{g^2}{16\pi^2} \text{Tr}(F \tilde F)$
    /// - **U(1) problem:** Explains η' mass via topological fluctuations
    ///
    /// # Note
    ///
    /// This implementation requires D ≥ 4 for the full definition.
    /// For D < 4, returns 0.
    ///
    /// # Arguments
    ///
    /// * `site` - LatticeComplex site coordinates
    ///
    /// # Returns
    ///
    /// The topological charge density q(x).
    ///
    /// # Errors
    ///
    /// Returns error if field strength computation fails.
    pub fn try_topological_charge_density(&self, site: &[usize; D]) -> Result<R, TopologyError>
    where
        M: Field + DivisionAlgebra<R>,
        R: RealField,
    {
        if D < 4 {
            // Topological charge requires 4 dimensions
            return Ok(R::zero());
        }

        // Sum over all (μ,ν,ρ,σ) with proper epsilon tensor
        // For simplicity, sum over independent pairs: (01,23), (02,13), (03,12)
        let mut q = R::zero();
        let normalization = R::from_f64(1.0 / (32.0 * std::f64::consts::PI * std::f64::consts::PI))
            .ok_or_else(|| {
                TopologyError::LatticeGaugeError("Failed to convert normalization to T".to_string())
            })?;

        // F_01 * F_23
        let _f01 = self.try_field_strength(site, 0, 1)?;
        let _f23 = self.try_field_strength(site, 2, 3)?;
        // F_01 * F_23
        let f01 = self.try_field_strength(site, 0, 1)?;
        let f23 = self.try_field_strength(site, 2, 3)?;
        let prod1 = f01.try_mul(&f23).map_err(TopologyError::from)?;
        q += prod1.re_trace();

        // F_02 * F_31 (note: F_31 = -F_13)
        let f02 = self.try_field_strength(site, 0, 2)?;
        let f13 = self.try_field_strength(site, 1, 3)?;
        let prod2 = f02.try_mul(&f13).map_err(TopologyError::from)?;
        q -= prod2.re_trace(); // minus from epsilon

        // F_03 * F_12
        let f03 = self.try_field_strength(site, 0, 3)?;
        let f12 = self.try_field_strength(site, 1, 2)?;
        let prod3 = f03.try_mul(&f12).map_err(TopologyError::from)?;
        q += prod3.re_trace();

        Ok(normalization * q)
    }

    /// Compute the total topological charge Q.
    ///
    /// $$Q = \sum_x q(x)$$
    ///
    /// For smooth gauge configurations, Q is close to an integer.
    ///
    /// # Returns
    ///
    /// The total topological charge Q.
    ///
    /// # Errors
    ///
    /// Returns error if computation fails.
    pub fn try_topological_charge(&self) -> Result<R, TopologyError>
    where
        M: Field + DivisionAlgebra<R>,
        R: RealField,
    {
        let mut total = R::zero();

        for site_cell in self.lattice.cells(0) {
            let site = *site_cell.position();
            let q = self.try_topological_charge_density(&site)?;
            total += q;
        }

        Ok(total)
    }
}
