/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! Gradient flow evolution.
//!
//! Implements the Wilson flow equation to continuously smooth gauge fields
//! towards the stationary points of the action. Used for scale setting and renormalization.

use crate::{ChainComplex, GaugeGroup, LatticeGaugeField, TopologyError};
use deep_causality_algebra::{ComplexField, DivisionAlgebra, Field, RealField};
use deep_causality_num::{FromPrimitive, ToPrimitive};
// use deep_causality_tensor::TensorData; // Removed
use std::collections::HashMap;
use std::fmt::Debug;
// ============================================================================
// Gradient Flow (Section 13)
// ============================================================================

/// Integration method for gradient flow.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FlowMethod {
    /// Simple Euler integration.
    Euler,
    /// 3rd order Runge-Kutta (recommended).
    RungeKutta3,
}

/// Gradient flow parameters.
#[derive(Debug, Clone)]
pub struct FlowParams<R> {
    /// Flow time step ε.
    pub epsilon: R,
    /// Maximum flow time.
    pub t_max: R,
    /// Integration method.
    pub method: FlowMethod,
}

impl<R: RealField + From<f64>> FlowParams<R> {
    /// Default flow parameters.
    pub fn default_params() -> Self {
        Self {
            epsilon: R::from(0.01),
            t_max: R::from(1.0),
            method: FlowMethod::RungeKutta3,
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
    /// Perform gradient flow integration.
    ///
    /// # Mathematics
    ///
    /// Integrates the Wilson flow equation:
    ///
    /// $$\frac{\partial V_\mu(x,t)}{\partial t} = -g_0^2 \frac{\partial S_W}{\partial V_\mu(x,t)} V_\mu(x,t)$$
    ///
    /// The derivative of the Wilson action is related to the staple $S_{\mu\nu}$:
    /// $$\dot V_\mu = - \left( \nabla S_W \right) V_\mu$$
    ///
    /// # Physics
    ///
    /// Gradient flow introduces a flow time scale $t$ (dimension $[L^2]$).
    /// Fields at flow time $t$ are effectively smeared over a radius $\sqrt{8t}$.
    /// This defines a renormalization scheme where composite operators are finite.
    ///
    /// # Arguments
    ///
    /// * `params` - Integration parameters (step size $\epsilon$, algorithm, max time)
    ///
    /// # Returns
    ///
    /// The flowed gauge field at $t = t_{max}$.
    ///
    /// # Errors
    ///
    /// Returns error if flow computation fails.
    pub fn try_flow(&self, params: &FlowParams<R>) -> Result<Self, TopologyError>
    where
        M: Field + DivisionAlgebra<R> + ComplexField<R>,
        R: RealField,
    {
        let mut current = self.clone();
        let zero = R::zero();
        if params.epsilon <= zero {
            return Err(TopologyError::LatticeGaugeError(
                "Flow epsilon must be > 0".to_string(),
            ));
        }
        if params.t_max < zero {
            return Err(TopologyError::LatticeGaugeError(
                "Flow t_max must be >= 0".to_string(),
            ));
        }

        let mut t = zero;
        let epsilon = params.epsilon;

        // Integrate from t=0 to t=t_max
        while t < params.t_max {
            current = match params.method {
                FlowMethod::Euler => current.try_euler_step(&epsilon)?,
                FlowMethod::RungeKutta3 => current.try_rk3_step(&epsilon)?,
            };
            t += epsilon;
        }

        Ok(current)
    }

    /// Single Euler step of gradient flow.
    fn try_euler_step(&self, epsilon: &R) -> Result<Self, TopologyError>
    where
        M: Field + DivisionAlgebra<R> + ComplexField<R>,
        R: RealField,
    {
        let mut new_links = HashMap::new();
        let n = G::matrix_dim();
        let n_t = R::from_f64(n as f64).ok_or_else(|| {
            TopologyError::LatticeGaugeError("Failed to convert matrix dimension to T".to_string())
        })?;

        for (edge, u) in self.links.iter() {
            // Compute staple and force
            let staple = self.try_staple(edge)?;
            let staple_dag = staple.dagger();
            let u_v_dag = u.mul(&staple_dag);

            // Force: F = β (U·V† - (1/N) Tr(U·V†) I) / N
            // For flow: we use simplified form proportional to staple
            let neg_eps = R::from_f64(-1.0).ok_or_else(|| {
                TopologyError::LatticeGaugeError("Failed to convert -1.0 to T".to_string())
            })? * *epsilon;
            let neg_eps_m = M::from_re_im(neg_eps, R::zero());
            let beta_norm_m = M::from_re_im(self.beta / n_t, R::zero());
            let update = u_v_dag
                .try_scale(&neg_eps_m)
                .map_err(TopologyError::from)?
                .try_scale(&beta_norm_m)
                .map_err(TopologyError::from)?;

            // U' = U + ε F, then project
            let new_u = u.try_add(&update).map_err(TopologyError::from)?;
            let projected = new_u.project_sun().map_err(TopologyError::from)?;

            new_links.insert(edge.clone(), projected);
        }

        Ok(Self {
            lattice: self.lattice.clone(),
            links: new_links,
            beta: self.beta,
            source: self.source.clone(),
        })
    }

    /// Scales the gauge field by a scalar factor.
    ///
    /// # Mathematics
    ///
    /// $$U_\mu(x) \to \alpha U_\mu(x)$$
    ///
    /// Note: This generally breaks unitarity (U † U = I), so the result
    /// is no longer in SU(N). This is an intermediate operation for RK3.
    fn try_scale(&self, factor: &M) -> Result<Self, TopologyError> {
        let mut new_links = HashMap::new();
        for (cell, link) in self.links.iter() {
            let new_link = link.try_scale(factor).map_err(TopologyError::from)?;
            new_links.insert(cell.clone(), new_link);
        }
        Ok(Self {
            lattice: self.lattice.clone(),
            links: new_links,
            beta: self.beta, // beta doesn't really scale in this context
            source: self.source.clone(),
        })
    }

    /// Adds two gauge fields.
    ///
    /// # Mathematics
    ///
    /// $$U_\mu(x) \to U_\mu^{(1)}(x) + U_\mu^{(2)}(x)$$
    ///
    /// Note: This generally breaks unitarity. Intermediate RK3 operation.
    fn try_add(&self, other: &Self) -> Result<Self, TopologyError> {
        let mut new_links = HashMap::new();
        for (cell, link) in self.links.iter() {
            if let Some(other_link) = other.links.get(cell) {
                let new_link = link.try_add(other_link).map_err(TopologyError::from)?;
                new_links.insert(cell.clone(), new_link);
            } else {
                return Err(TopologyError::LatticeGaugeError(format!(
                    "Missing link at {:?} during add",
                    cell
                )));
            }
        }
        Ok(Self {
            lattice: self.lattice.clone(),
            links: new_links,
            beta: self.beta,
            source: self.source.clone(),
        })
    }

    /// Single 3rd-order Strong Stability Preserving Runge-Kutta (SSP-RK3) step.
    ///
    /// # Mathematics
    ///
    /// Uses the optimal SSP-RK3 scheme:
    /// 1. $U^{(1)} = U^{(n)} + \epsilon F(U^{(n)})$
    /// 2. $U^{(2)} = \frac{3}{4} U^{(n)} + \frac{1}{4} (U^{(1)} + \epsilon F(U^{(1)}))$
    /// 3. $U^{(n+1)} = \frac{1}{3} U^{(n)} + \frac{2}{3} (U^{(2)} + \epsilon F(U^{(2)}))$
    ///
    /// Finally, project back to SU(N) group manifold.
    fn try_rk3_step(&self, epsilon: &R) -> Result<Self, TopologyError>
    where
        M: Field + DivisionAlgebra<R> + ComplexField<R>,
        R: RealField,
    {
        let three_quarters = M::from_re_im(
            R::from_f64(0.75).ok_or_else(|| {
                TopologyError::LatticeGaugeError("Failed to convert 0.75 to T".to_string())
            })?,
            R::zero(),
        );
        let one_quarter = M::from_re_im(
            R::from_f64(0.25).ok_or_else(|| {
                TopologyError::LatticeGaugeError("Failed to convert 0.25 to T".to_string())
            })?,
            R::zero(),
        );
        let one_third = M::from_re_im(
            R::from_f64(1.0 / 3.0).ok_or_else(|| {
                TopologyError::LatticeGaugeError("Failed to convert 1/3 to T".to_string())
            })?,
            R::zero(),
        );
        let two_thirds = M::from_re_im(
            R::from_f64(2.0 / 3.0).ok_or_else(|| {
                TopologyError::LatticeGaugeError("Failed to convert 2/3 to T".to_string())
            })?,
            R::zero(),
        );

        // Stage 1: U1 = Euler(U0)
        // Note: try_euler_step does projection, but for RK intermediate
        // strictly speaking we might want unprojected updates.
        // However, standard Wilson flow often projects at each substep or
        // defines the flow on the manifold directly.
        // For this implementation, using the Euler step (which projects)
        // is the closest equivalent to the "tangent space" update if we
        // consider the projection as part of the flow definition.
        let u1 = self.try_euler_step(epsilon)?;

        // Stage 2: U2 = 3/4 U0 + 1/4 Euler(U1)
        // We mix the fields first (breaking unitarity) then project?
        // Or we rely on Euler steps being unitary?
        // SSP-RK schemes usually assume linear vector space.
        // For Lie Groups, this linear mixing is an approximation valid for small epsilon.
        let term1 = self.try_scale(&three_quarters)?;
        let term2 = u1.try_euler_step(epsilon)?.try_scale(&one_quarter)?;
        let u2_unprojected = term1.try_add(&term2)?;

        // We must project u2 back to SU(N) before calculating force for next step
        // to maintain gauge invariance properties and stability.
        let u2 = u2_unprojected.project_to_group()?;

        // Stage 3: U_new = 1/3 U0 + 2/3 Euler(U2)
        let term3 = self.try_scale(&one_third)?;
        let term4 = u2.try_euler_step(epsilon)?.try_scale(&two_thirds)?;
        let u_new_unprojected = term3.try_add(&term4)?;

        // Final projection
        u_new_unprojected.project_to_group()
    }

    /// Project whole field to SU(N).
    fn project_to_group(&self) -> Result<Self, TopologyError>
    where
        M: Field + DivisionAlgebra<R> + ComplexField<R>,
        R: RealField,
    {
        let mut new_links = HashMap::new();
        for (cell, link) in self.links.iter() {
            let projected = link.project_sun().map_err(TopologyError::from)?;
            new_links.insert(cell.clone(), projected);
        }
        Ok(Self {
            lattice: self.lattice.clone(),
            links: new_links,
            beta: self.beta,
            source: self.source.clone(),
        })
    }

    /// Compute the flow energy density E(t).
    ///
    /// # Mathematics
    ///
    /// $$E(t) = \frac{1}{2} \langle \text{Tr}(F_{\mu\nu} F_{\mu\nu}) \rangle
    ///         \approx \sum_p \left(1 - \frac{1}{N}\text{ReTr} U_p\right)$$
    ///
    /// # Physics
    ///
    /// The energy density is a gauge invariant observable of dimension 4.
    /// Under gradient flow, $\langle E(t) \rangle$ is a renormalized quantity.
    ///
    /// # Returns
    ///
    /// The average energy density.
    ///
    /// # Errors
    ///
    /// Returns error if computation fails.
    pub fn try_energy_density(&self) -> Result<R, TopologyError>
    where
        M: Field + DivisionAlgebra<R>,
        R: RealField,
    {
        let n = G::matrix_dim();
        let n_t = R::from_f64(n as f64).ok_or_else(|| {
            TopologyError::LatticeGaugeError("Failed to convert matrix dimension to T".to_string())
        })?;
        let one = R::one();

        let mut sum = R::zero();
        let mut count = 0usize;

        for site_cell in self.lattice.cells(0) {
            let site = *site_cell.position();
            for mu in 0..D {
                for nu in (mu + 1)..D {
                    let plaq = self.try_plaquette(&site, mu, nu)?;
                    let tr = plaq.re_trace();
                    let e_p = one - tr / n_t;
                    sum += e_p;
                    count += 1;
                }
            }
        }

        if count == 0 {
            return Ok(R::zero());
        }

        let count_t = R::from_f64(count as f64).ok_or_else(|| {
            TopologyError::LatticeGaugeError("Failed to convert count to T".to_string())
        })?;
        Ok(sum / count_t)
    }

    /// Compute t² E(t) for scale setting.
    ///
    /// At flow time t, this quantity is used to define reference scales t₀ and w₀.
    ///
    /// # Errors
    ///
    /// Returns error if computation fails.
    pub fn try_t2_energy(&self, t: R) -> Result<R, TopologyError>
    where
        M: Field + DivisionAlgebra<R>,
        R: RealField,
    {
        let e = self.try_energy_density()?;
        Ok(t * t * e)
    }

    /// Find t₀ scale where t² E(t) = 0.3.
    ///
    /// The scale t₀ provides a non-perturbative reference scale for lattice QCD,
    /// defined by the condition $t^2 \langle E(t) \rangle |_{t=t_0} = 0.3$.
    ///
    /// # Physics
    ///
    /// The Wilson flow smooths gauge configurations, and the energy density
    /// at flow time t is automatically renormalized at scale $\mu \sim 1/\sqrt{8t}$.
    ///
    /// The scale t₀ is widely used in lattice QCD for:
    /// - Setting the lattice spacing in physical units
    /// - Continuum extrapolations
    /// - Comparing results between different collaborations
    ///
    /// Typical values: $\sqrt{8t_0} \approx 0.4$ fm in QCD.
    ///
    /// # Algorithm
    ///
    /// 1. Flow configuration forward in time
    /// 2. Monitor t² E(t) at each step
    /// 3. Interpolate to find t where t² E(t) = 0.3
    ///
    /// # Arguments
    ///
    /// * `params` - Flow parameters (step size, method)
    ///
    /// # Returns
    ///
    /// The flow time t₀ where t² E(t) = 0.3, or an error if the condition
    /// is not reached within t_max.
    ///
    /// # Errors
    ///
    /// Returns error if:
    /// - Flow computation fails
    /// - t² E(t) never reaches 0.3 within t_max
    pub fn try_find_t0(&self, params: &FlowParams<R>) -> Result<R, TopologyError>
    where
        M: Field + DivisionAlgebra<R> + ComplexField<R>,
        R: RealField,
    {
        let zero = R::zero();
        if params.epsilon <= zero {
            return Err(TopologyError::LatticeGaugeError(
                "Flow epsilon must be > 0".to_string(),
            ));
        }
        if params.t_max < zero {
            return Err(TopologyError::LatticeGaugeError(
                "Flow t_max must be >= 0".to_string(),
            ));
        }

        let target = R::from_f64(0.3).ok_or_else(|| {
            TopologyError::LatticeGaugeError("Failed to convert 0.3 to T".to_string())
        })?;
        let mut current = self.clone();
        let mut t = R::zero();
        let epsilon = params.epsilon;

        let mut prev_t = t;
        let mut prev_t2e = current.try_t2_energy(t)?;

        // Flow until t² E(t) crosses 0.3
        while t < params.t_max {
            current = match params.method {
                FlowMethod::Euler => current.try_euler_step(&epsilon)?,
                FlowMethod::RungeKutta3 => current.try_rk3_step(&epsilon)?,
            };
            t += epsilon;

            let t2e = current.try_t2_energy(t)?;

            // Check if we crossed the target
            if t2e >= target && prev_t2e < target {
                // Linear interpolation to find t₀
                // t₀ ≈ prev_t + (target - prev_t2e) * ε / (t2e - prev_t2e)
                let dt = t - prev_t;
                let d_t2e = t2e - prev_t2e;

                if d_t2e == R::zero() {
                    return Ok(prev_t);
                }

                let ratio = (target - prev_t2e) / d_t2e;
                return Ok(prev_t + ratio * dt);
            }

            prev_t = t;
            prev_t2e = t2e;
        }

        Err(TopologyError::LatticeGaugeError(
            "t² E(t) did not reach 0.3 within t_max".to_string(),
        ))
    }
}
