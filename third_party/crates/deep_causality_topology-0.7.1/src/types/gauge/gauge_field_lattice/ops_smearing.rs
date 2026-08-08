/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! Smearing algorithms for lattice gauge fields.
//!
//! Implements APE (Array Processor Experiment) smearing and Stout smearing
//! to reduce ultraviolet fluctuations and enhance the signal of long-range physics.

use crate::{GaugeGroup, LatticeGaugeField, TopologyError};
use deep_causality_algebra::{ComplexField, DivisionAlgebra, Field, RealField};
use deep_causality_num::{FromPrimitive, ToPrimitive};
// use deep_causality_tensor::TensorData; // Removed
use std::collections::HashMap;
use std::fmt::Debug;
// ============================================================================
// Smearing Algorithms
// ============================================================================

/// Smearing parameters.
#[derive(Debug, Clone)]
pub struct SmearingParams<R> {
    /// Smearing weight α (APE/HYP) or ρ (stout).
    pub alpha: R,
    /// Number of smearing iterations.
    pub n_steps: usize,
}

impl<R: RealField + FromPrimitive> SmearingParams<R> {
    /// Default APE smearing parameters.
    pub fn ape_default() -> Self {
        Self {
            alpha: R::from_f64(0.45).unwrap(),
            n_steps: 10,
        }
    }

    /// Default stout smearing parameters.
    pub fn stout_default() -> Self {
        Self {
            alpha: R::from_f64(0.12).unwrap(),
            n_steps: 6,
        }
    }
}

impl<
    G: GaugeGroup,
    const D: usize,
    M: Field + Copy + Default + PartialOrd + Debug + ComplexField<R> + DivisionAlgebra<R>,
    R: RealField + FromPrimitive + ToPrimitive,
    S: Clone,
> LatticeGaugeField<G, D, M, R, S>
{
    /// Apply APE smearing to the gauge field.
    ///
    /// # Mathematics
    ///
    /// APE smearing replaces each link $U_\mu(x)$ with a projected average of itself
    /// and its staples:
    ///
    /// $$U'_\mu(x) = \text{Proj}_{SU(N)}\left[ (1-\alpha) U_\mu(x) + \frac{\alpha}{2(D-1)} \sum_{\nu \neq \mu} S_{\mu\nu}(x) \right]$$
    ///
    /// where $S_{\mu\nu}$ is the sum of forward and backward staples in the $\mu-\nu$ plane.
    ///
    /// # Physics
    ///
    /// Smearing suppresses UV fluctuations (short-distance noise) while preserving
    /// the long-distance physical content (IR properties). It is essential for:
    /// - Improving signal-to-noise ratio in glueball/loop operators
    /// - Defining topological charge on the lattice
    ///
    /// # Arguments
    ///
    /// * `params` - Smearing parameters ($\alpha$, number of steps)
    ///
    /// # Returns
    ///
    /// A new `LatticeGaugeField` with smeared links.
    ///
    /// # Errors
    ///
    /// Returns error if smearing computation fails.
    pub fn try_smear(&self, params: &SmearingParams<R>) -> Result<Self, TopologyError>
    where
        M: Field + DivisionAlgebra<R> + ComplexField<R>,
        R: RealField,
    {
        if D <= 1 {
            return Err(TopologyError::LatticeGaugeError(
                "Smearing requires D >= 2".to_string(),
            ));
        }

        let mut current = self.clone();
        let alpha = params.alpha;
        let one = R::from_f64(1.0).ok_or_else(|| {
            TopologyError::LatticeGaugeError("Failed to convert 1.0 to T".to_string())
        })?;
        let one_minus_alpha = one - alpha;
        let staple_divisor = R::from_f64(2.0 * (D - 1) as f64).ok_or_else(|| {
            TopologyError::LatticeGaugeError("Failed to convert staple divisor to T".to_string())
        })?;
        let staple_weight = alpha / staple_divisor;

        // Convert scalars to M for matrix scaling
        let one_minus_alpha_m = M::from_re_im(one_minus_alpha, R::zero());
        let staple_weight_m = M::from_re_im(staple_weight, R::zero());

        for _step in 0..params.n_steps {
            let mut new_links = HashMap::new();

            for (edge, old_link) in current.links.iter() {
                // Compute staple sum
                let staple = current.try_staple(edge)?;

                // Weighted combination: (1-α) U + (α/(2(D-1))) V
                let weighted_old = old_link
                    .try_scale(&one_minus_alpha_m)
                    .map_err(TopologyError::from)?;
                let weighted_staple = staple
                    .try_scale(&staple_weight_m)
                    .map_err(TopologyError::from)?;
                let combined = weighted_old
                    .try_add(&weighted_staple)
                    .map_err(TopologyError::from)?;

                // Project to SU(N)
                let projected = combined.project_sun().map_err(TopologyError::from)?;

                new_links.insert(edge.clone(), projected);
            }

            current.links = new_links;
        }

        Ok(current)
    }
}
