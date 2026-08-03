/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::{CausalMultiVector, CausalMultiVectorError, HilbertState, Metric, MultiVector};
use deep_causality_algebra::RealField;
use deep_causality_num::FromPrimitive;
use deep_causality_num_complex::Complex;
use std::fmt::{Display, Formatter};

/// A point on the 3-Sphere ($S^3$), representing a unit spinor or rotor in 3D Euclidean space.
///
/// The Hopf Fibration maps this state to a point on the 2-Sphere ($S^2$) via the projection
/// $h(R) = R \sigma_3 \tilde{R}$.
///
/// This structure captures both the **Direction** (the point on $S^2$) and the **Phase/Twist**
/// (the position on the $S^1$ fiber).
///
/// # Applications
/// * **Quantum Mechanics:** Represents a Qubit state $|\psi\rangle = \alpha|0\rangle + \beta|1\rangle$. The projection is the Bloch Vector.
/// * **Robotics:** Represents a rotation without Gimbal Lock (Quaternion). The fiber is the "twist" redundancy.
/// * **Electromagnetism:** Represents Hopfion field configurations.
#[derive(Debug, Clone, PartialEq)]
pub struct HopfState<R: RealField>(CausalMultiVector<R>);

impl<R: RealField> HopfState<R> {
    /// Creates a new HopfState from raw coefficients.
    /// Enforces Euclidean(3) metric and Normalization.
    pub fn new(data: Vec<R>) -> Result<Self, CausalMultiVectorError> {
        let metric = Metric::Euclidean(3);

        // Ensure we are in 3D space (8 components in Cl(3))
        if data.len() != 8 {
            return Err(CausalMultiVectorError::data_length_mismatch(8, data.len()));
        }

        let mv = CausalMultiVector::new(data, metric)?;

        // Enforce S^3 constraint: ||R|| = 1
        // (Project onto the hypersphere)
        let normalized = mv.normalize();

        Ok(Self(normalized))
    }

    /// Constructs a HopfState from two Complex numbers (Spinor formalism).
    ///
    /// Maps $(\alpha, \beta) \in \mathbb{C}^2$ to the 3-Sphere.
    /// $|\alpha|^2 + |\beta|^2 = 1$.
    ///
    /// This connects Standard QM notation to Geometric Algebra.
    pub fn from_spinor(alpha: Complex<R>, beta: Complex<R>) -> Self {
        // Mapping C^2 -> Cl(3) Even Subalgebra (Quaternions)

        let mut data = vec![R::zero(); 8];

        // Scalar part (Real part of alpha)
        data[0] = alpha.re;

        // Bivector parts (Imaginary units)
        // Standard Rotor mapping:
        data[3] = alpha.im; // e12 (Generates Z rotation)
        data[5] = beta.im; // e13 ~ Y
        data[6] = beta.re; // e23 ~ X

        let mv = CausalMultiVector::new(data, Metric::Euclidean(3)).unwrap();
        Self(mv.normalize())
    }

    /// Access underlying algebra
    pub fn as_inner(&self) -> &CausalMultiVector<R> {
        &self.0
    }
}

impl<R: RealField + FromPrimitive> HopfState<R> {
    /// The Projection Map $h: S^3 \to S^2$.
    ///
    /// Returns the vector on the 2-Sphere (The "Shadow" or "Bloch Vector").
    /// $v = R \sigma_3 \tilde{R}$.
    pub fn project(&self) -> CausalMultiVector<R> {
        // 1. Define the reference pole (North Pole / Z-axis / e3)
        let mut z_data = vec![R::zero(); 8];
        z_data[4] = R::one(); // Index 4 is e3 (binary 100)
        let sigma_3 = CausalMultiVector::new(z_data, Metric::Euclidean(3)).unwrap();

        // 2. Apply Sandwich Product: R * e3 * ~R
        let r = &self.0;
        let r_rev = r.reversion();

        let temp = r.geometric_product(&sigma_3);
        let vector = temp.geometric_product(&r_rev);

        // 3. Return only the Vector part (Grade 1) to ensure type purity
        vector.grade_projection(1)
    }

    /// Traverses the Fiber ($S^1$).
    ///
    /// Rotates the state by `phase` radians without changing the projection on $S^2$.
    /// This corresponds to the global phase $e^{i\theta}$ in QM or the "Twist" in robotics.
    ///
    /// $R' = R e^{-\frac{\theta}{2} \mathbf{I}}$
    /// (Where I is the generator of rotation around the pole, typically e12 for Z-axis).
    pub fn fiber_shift(&self, angle_rad: R) -> Self {
        // Generator of the fiber (Z-rotation / Phase)
        let mut bivec_data = vec![R::zero(); 8];
        bivec_data[3] = R::one(); // e12
        let generator = CausalMultiVector::new(bivec_data, Metric::Euclidean(3)).unwrap();

        // Construct Rotor: exp(- B * angle/2)
        // Since B^2 = -1, exp is cos + sin
        let half = R::from_f64(0.5).expect("R::from_f64(0.5) failed");
        let half_angle = angle_rad * half;
        let cos = half_angle.cos();
        let sin = half_angle.sin();

        // R_phase = cos - sin * B
        let term_sin = generator * (-sin);
        let term_cos = CausalMultiVector::scalar(cos, Metric::Euclidean(3));

        let phase_rotor = term_cos + term_sin;

        // Apply phase: R_new = R * R_phase
        let new_mv = self.0.geometric_product(&phase_rotor);

        Self(new_mv)
    }
}

/// Conversion: Quantum State (Spinor) -> Topological Rotor (Hopf).
impl<R: RealField> TryFrom<&HilbertState<R>> for HopfState<R> {
    type Error = CausalMultiVectorError;

    fn try_from(quantum_state: &HilbertState<R>) -> Result<Self, Self::Error> {
        let data = &quantum_state.as_inner().data;

        if data.len() < 2 {
            return Err(CausalMultiVectorError::dimension_mismatch(2, data.len()));
        }

        let alpha = data[0];
        let beta = data[1];

        Ok(HopfState::from_spinor(alpha, beta))
    }
}

/// Conversion: Topological Rotor (Hopf) -> Quantum State (Spinor).
impl<R: RealField> TryFrom<HopfState<R>> for HilbertState<R> {
    type Error = CausalMultiVectorError;

    fn try_from(hopf: HopfState<R>) -> Result<Self, Self::Error> {
        // 1. Access the real Cl(3) coefficients
        let d = hopf.as_inner().data();

        // 2. Reconstruct Complex Amplitudes
        let re_alpha = d[0]; // Scalar
        let im_alpha = d[3]; // e12
        let alpha = Complex::new(re_alpha, im_alpha);

        let re_beta = d[6]; // e23
        let im_beta = d[5]; // e13
        let beta = Complex::new(re_beta, im_beta);

        // 3. Construct HilbertState (Spin(10) target)
        let mut q_data = vec![Complex::new(R::zero(), R::zero()); 1024];
        q_data[0] = alpha;
        q_data[1] = beta;

        HilbertState::new_spin10(q_data)
    }
}

impl<R: RealField + core::fmt::Debug> Display for HopfState<R> {
    fn fmt(&self, f: &mut Formatter<'_>) -> std::fmt::Result {
        write!(f, "HopfState({:?})", self.0)
    }
}
