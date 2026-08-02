/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! Metropolis algorithm for Monte Carlo gauge field updates.
//!
//! The Metropolis algorithm is a Markov chain Monte Carlo method for
//! importance sampling gauge configurations according to the Boltzmann weight.

use crate::types::gauge::link_variable::random::RandomField;
use crate::{GaugeGroup, LatticeCell, LatticeGaugeField, LinkVariable, TopologyError};
use deep_causality_algebra::{ComplexField, DivisionAlgebra, Field, Real, RealField};
use deep_causality_num::{FromPrimitive, ToPrimitive};
use std::fmt::Debug;

// ============================================================================
// Metropolis Updates
// ============================================================================

impl<
    G: GaugeGroup,
    const D: usize,
    M: Field + Copy + Default + PartialOrd + Debug + ComplexField<R> + DivisionAlgebra<R>,
    R: RealField + FromPrimitive + ToPrimitive,
    S,
> LatticeGaugeField<G, D, M, R, S>
{
    /// Perform a single Metropolis update on a link.
    ///
    /// Proposes a random modification to link U and accepts or rejects
    /// based on the Metropolis criterion.
    ///
    /// # Algorithm
    ///
    /// 1. Propose: U' = R · U where R is a random SU(N) element near identity
    /// 2. Compute: ΔS = `S[U'] - S[U]` using the local action change
    /// 3. Accept with probability: min(1, e^{-ΔS})
    ///
    /// # Mathematics
    ///
    /// The Metropolis algorithm satisfies detailed balance:
    ///
    /// $$`P[U] \cdot T(U \to U') = P[U'] \cdot T(U' \to U)`$$
    ///
    /// where `$P[U] \propto e^{-S[U]}$` is the Boltzmann distribution.
    ///
    /// # Arguments
    ///
    /// * `edge` - The link (1-cell) to update
    /// * `epsilon` - Proposal width (smaller = higher acceptance, slower decorrelation)
    /// * `rng` - Random number generator
    ///
    /// # Returns
    ///
    /// `Ok(true)` if update was accepted, `Ok(false)` if rejected.
    ///
    /// # Errors
    ///
    /// Returns error if staple computation or link creation fails.
    pub fn try_metropolis_update<RngType>(
        &mut self,
        edge: &LatticeCell<D>,
        epsilon: R,
        rng: &mut RngType,
    ) -> Result<bool, TopologyError>
    where
        RngType: deep_causality_rand::Rng,
        M: RandomField + DivisionAlgebra<R> + Field + ComplexField<R>,
        R: RealField,
    {
        if epsilon <= R::zero() {
            return Err(TopologyError::LatticeGaugeError(
                "Invalid Metropolis epsilon: (must be > 0)".to_string(),
            ));
        }

        // Get current link
        let current = self.get_link_or_identity(edge);

        // Generate a small random perturbation
        let perturbation = self.generate_small_su_n_update(epsilon, rng)?;

        // Propose: U' = R · U
        let proposed = perturbation
            .try_mul(&current)
            .map_err(TopologyError::from)?;

        // Compute action change (negative means lower action = favorable)
        // Returns R
        let delta_s = self.try_local_action_change(edge, &proposed)?;

        // Metropolis accept/reject
        let accept = if delta_s < R::zero() {
            // Always accept if action decreases
            true
        } else {
            // Accept with probability exp(-ΔS)
            let rnd: f64 = rng.random();
            let r = R::from_f64(rnd).ok_or_else(|| {
                TopologyError::LatticeGaugeError("Failed to convert random value to T".to_string())
            })?;

            if !delta_s.is_finite() {
                false // Reject NaN/Inf actions
            } else {
                r < Real::exp(-delta_s)
            }
        };

        if accept {
            self.set_link(edge.clone(), proposed);
        }

        Ok(accept)
    }

    /// Perform a full Metropolis sweep over all links.
    ///
    /// Updates each link once in a sequential sweep. The order is determined
    /// by the lattice cell iteration order.
    ///
    /// # Physics
    ///
    /// A single sweep updates each of the D × V links once (V = lattice volume).
    /// Multiple sweeps are needed for thermalization and to reduce autocorrelation.
    ///
    /// Typical simulation structure:
    /// 1. Thermalization: 100-1000 sweeps (discard)
    /// 2. Measurements: Every N sweeps to reduce autocorrelation
    ///
    /// # Arguments
    ///
    /// * `epsilon` - Proposal width (tune for ~50% acceptance rate)
    /// * `rng` - Random number generator
    ///
    /// # Returns
    ///
    /// The acceptance rate (fraction of accepted updates).
    ///
    /// # Errors
    ///
    /// Returns error if any update fails.
    pub fn try_metropolis_sweep<RngType>(
        &mut self,
        epsilon: R,
        rng: &mut RngType,
    ) -> Result<f64, TopologyError>
    where
        RngType: deep_causality_rand::Rng,
        M: RandomField + DivisionAlgebra<R> + Field + ComplexField<R>,
        R: RealField,
    {
        let edges: Vec<_> = self.links.keys().cloned().collect();
        let total = edges.len();

        if total == 0 {
            return Ok(0.0);
        }

        let mut accepted = 0usize;

        for edge in edges {
            if self.try_metropolis_update(&edge, epsilon, rng)? {
                accepted += 1;
            }
        }

        Ok(accepted as f64 / total as f64)
    }

    /// Generate a small SU(N) element near identity for Metropolis proposals.
    ///
    /// Creates R ≈ 𝟙 + ε·X where X is a random traceless Hermitian matrix.
    /// Generate a small SU(N) element near identity for Metropolis proposals.
    ///
    /// Creates R ≈ 𝟙 + ε·X where X is a random traceless Hermitian matrix.
    fn generate_small_su_n_update<RngType>(
        &self,
        epsilon: R,
        rng: &mut RngType,
    ) -> Result<LinkVariable<G, M, R>, TopologyError>
    where
        RngType: deep_causality_rand::Rng,
        M: RandomField + DivisionAlgebra<R> + Field + ComplexField<R>,
        R: RealField,
    {
        // Start with identity
        let result = LinkVariable::<G, M, R>::try_identity().map_err(TopologyError::from)?;

        // Add small random perturbation
        let n = G::matrix_dim();
        let data = result.as_slice();
        let mut new_data = data.to_vec();

        // Convert epsilon to M for scaling
        let eps_m = M::from_re_im(epsilon, R::zero());

        // Create a traceless Hermitian matrix X in `new_data` buffer
        let mut x_data = vec![M::zero(); n * n];

        let mut diagonal_sum = M::zero();

        // 1. Fill off-diagonal elements (upper triangular) and mirror to lower triangular (Hermitian)
        for i in 0..n {
            for j in (i + 1)..n {
                let r_val = M::generate_uniform(rng);
                x_data[i * n + j] = r_val;
                x_data[j * n + i] = ComplexField::conjugate(&r_val);
            }
        }

        // 2. Fill diagonal elements
        // For i < n-1, fill with random real values (imaginary part = 0 for Hermitian diagonal)
        // For i == n-1, set value to make trace = 0
        for i in 0..(n - 1) {
            let r_val = M::generate_uniform(rng);
            let val = r_val + ComplexField::conjugate(&r_val);
            x_data[i * n + i] = val;
            diagonal_sum = diagonal_sum + val;
        }

        // Set last diagonal element to -sum(others) to ensure Tr(X) = 0
        x_data[(n - 1) * n + (n - 1)] = M::zero() - diagonal_sum;

        // 3. Compute U' = I + epsilon * X
        for i in 0..(n * n) {
            new_data[i] = new_data[i] + eps_m * x_data[i];
        }

        // Create perturbed matrix and project to SU(N)
        let tensor = deep_causality_tensor::CausalTensor::new(new_data, vec![n, n])
            .map_err(|e| TopologyError::LatticeGaugeError(format!("{:?}", e)))?;

        let perturbed = LinkVariable::from_matrix_unchecked(tensor);
        perturbed.project_sun().map_err(TopologyError::from)
    }
}
